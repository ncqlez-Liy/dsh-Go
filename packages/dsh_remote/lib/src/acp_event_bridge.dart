// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
/// 把 ACP 会话流式帧投影成 DSH 标准 [DshEvent]，让现有 ChatTranscript /
/// 聊天 UI 零改动复用。
///
/// 官方客户端靠 `AcpVirtualHarness` 在宿主侧做这件事；dsh-Go 走另一条路：
/// 直接调 `agent.acp.*` 顶层 RPC，帧在本类里折叠成 DSH 事件序列。
/// 详见 issue ccch1mneyyy/dsh-Go#1625。
library;

import 'package:dsh_client/dsh_client.dart';

import 'package:dsh_remote/src/acp_client.dart'
    show AcpFrame, backendFromSessionId, nativeAcpId;
import 'package:dsh_remote/src/util/bytes.dart' show asMap, asString;

class AcpEventBridge {
  AcpEventBridge({
    required this.sessionId,
    this.title = '',
    this.cwd,
    DateTime? now,
  }) : _now = now ?? DateTime.now();

  /// 展示用 session id（`claude:<native>`）。
  final String sessionId;
  final String title;
  final String? cwd;
  final DateTime _now;

  late final String nativeId = nativeAcpId(sessionId);
  late final String backend = backendFromSessionId(sessionId) ?? 'claude';

  /// 持久事件 seq（快照 cursor = -1，从 0 开始）。
  int _seq = 0;

  /// 流式 revision（快照 assistantRevision = 0，每帧 +1）。
  int _revision = 0;
  int _turn = 1;
  int _chunkIndex = 0;
  bool _streaming = false;
  bool _turnOpen = false;
  String _attemptId = '';
  final StringBuffer _assistantText = StringBuffer();
  final StringBuffer _reasoningText = StringBuffer();

  /// 加载历史后调用：把内部 seq / turn 推到历史末尾之后，避免 live 帧与
  /// 历史事件在 transcript 里交错（turn 号重复会让新消息插到旧消息中间）。
  void adoptHistory(List<SessionLogEvent> history) {
    var maxTurn = 0;
    for (final event in history) {
      if (event.seq >= _seq) _seq = event.seq + 1;
      switch (event) {
        case TurnStartedEvent(:final turn):
        case TurnEndedEvent(:final turn):
          if (turn > maxTurn) maxTurn = turn;
        default:
          break;
      }
    }
    if (maxTurn + 1 > _turn) _turn = maxTurn + 1;
  }

  /// 首屏基线：durable log + 标题投影。ChatTranscript 应用后置 `_synchronized`。
  SessionSnapshotEvent initialSnapshot({List<SessionLogEvent> events = const <SessionLogEvent>[]}) =>
      SessionSnapshotEvent(
        sessionId: sessionId,
        header: SessionHeader(
          id: sessionId,
          version: 0,
          createdAt: _now,
          isSeeded: false,
          cwd: cwd,
          origin: backend,
        ),
        cursor: events.isEmpty ? -1 : events.last.seq,
        events: events,
        hasMore: false,
        projections: SessionProjections(-1, {'title': title}),
        assistantRevision: 0,
      );

  /// 发送前调用：合成 turn/start + user/message，让 UI 立刻显示正在生成。
  List<DshEvent> beginTurn(String text, {String? requestId}) {
    _turnOpen = true;
    final startSeq = _seq++;
    final userSeq = _seq++;
    return [
      TurnStartedEvent(startSeq, _now, const <String, Object?>{}, turn: _turn),
      UserMessageEvent(
        userSeq,
        _now,
        const <String, Object?>{},
        message: Message.fromJson({
          'id': 'acp-u$userSeq',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {
            'kind': 'user',
            'rpcId': ?requestId,
          },
        }),
      ),
    ];
  }

  /// 收到一帧 `agent.acp.frame`（`{method, params}`）；返回 0..N 个 DSH 事件。
  List<DshEvent> onFrame(AcpFrame frame) => _onFrameMap(frame.frame);

  List<DshEvent> _onFrameMap(Map<String, Object?> frame) {
    if ((asString(frame['method']) ?? '') != 'session/update') return const <DshEvent>[];
    final params = asMap(frame['params']);
    if (params == null) return const <DshEvent>[];
    // ACP 通知形如 {sessionId, update:{sessionUpdate, content}}。
    final update = asMap(params['update']) ?? params;
    return _onUpdate(update);
  }

  List<DshEvent> _onUpdate(Map<String, Object?> update) {
    final kind = asString(update['sessionUpdate']) ?? asString(update['type']) ?? '';
    final out = <DshEvent>[];
    switch (kind) {
      case 'agent_message_chunk':
      case 'agent_message':
        final text = _extractText(update['content']);
        if (text.isEmpty) break;
        _ensureTurn(out);
        if (!_streaming) out.add(_startStream());
        _assistantText.write(text);
        out.add(AssistantChunkEvent(
          _attemptId,
          ++_revision,
          index: _chunkIndex++,
          time: _now,
          chunk: TextDeltaChunk(0, text),
        ));
        break;
      case 'agent_thought_chunk':
      case 'agent_thought':
        final text = _extractText(update['content']);
        if (text.isEmpty) break;
        _ensureTurn(out);
        if (!_streaming) out.add(_startStream());
        _reasoningText.write(text);
        out.add(AssistantChunkEvent(
          _attemptId,
          ++_revision,
          index: _chunkIndex++,
          time: _now,
          chunk: ReasoningDeltaChunk(1, text),
        ));
        break;
      // Host 在一轮结束时补发终止帧：prompt_completed / prompt_failed。
      // catchUp 是本轮全部帧的副本，只在「实时帧一帧都没收到」时补放，
      // 否则正文会被渲染两遍（官方客户端同样是 catchUp 仅作兜底）。
      case 'prompt_completed':
      case 'prompt_failed':
        // 没有打开的 turn 说明这一轮已经收口（重复终止帧），直接忽略，
        // 否则会把 catchUp 再放一遍造成重复气泡。
        if (!_turnOpen) break;
        final lostLive = !_streaming && _assistantText.isEmpty && _reasoningText.isEmpty;
        final catchUp = update['catchUp'];
        if (lostLive && catchUp is List) {
          for (final item in catchUp) {
            final map = asMap(item);
            if (map != null) out.addAll(_onFrameMap(map));
          }
        }
        out.addAll(endTurn(failed: kind == 'prompt_failed'));
        break;
      // 用户消息在 beginTurn 里已合成，忽略 ACP 回传避免重复气泡。
      case 'user_message_chunk':
      case 'user_message':
        break;
      // 权限请求暂降级：approved 后由 prompt 返回的自然流程接棒。
      // 完整支持见 issue #1625 后续。
      case 'session/request_permission':
        break;
      default:
        break;
    }
    return out;
  }

  /// 没有 beginTurn（例如别处发起的 turn）时也要有 turn/start，否则
  /// transcript 的 running/turn 归属会错乱。
  void _ensureTurn(List<DshEvent> out) {
    if (_turnOpen) return;
    _turnOpen = true;
    out.add(TurnStartedEvent(_seq++, _now, const <String, Object?>{}, turn: _turn));
  }

  AssistantStreamStarted _startStream() {
    _streaming = true;
    _attemptId = 'acp:$nativeId:$_turn';
    _chunkIndex = 0;
    _assistantText.clear();
    _reasoningText.clear();
    return AssistantStreamStarted(
      _attemptId,
      ++_revision,
      turn: _turn,
      step: 0,
      startedAfterSeq: _seq - 1,
    );
  }

  /// prompt 结束时调用：把累积文本落成 durable assistant/message，关闭 stream，
  /// 并写 turn/end。[failed] 时 reason 为 error。turn 已关闭时返回空列表，
  /// 避免 terminate 帧与本地收口重复结束同一轮。
  List<DshEvent> endTurn({bool failed = false}) {
    if (!_turnOpen && !_streaming) return const <DshEvent>[];
    _turnOpen = false;
    final out = <DshEvent>[];
    if (_streaming) {
      final text = _assistantText.toString();
      final reasoning = _reasoningText.toString();
      final seq = _seq++;
      if (text.isNotEmpty || reasoning.isNotEmpty) {
        final message = Message.fromJson({
          'id': 'acp-a$seq',
          'role': 'assistant',
          'content': [
            if (reasoning.isNotEmpty) {'type': 'reasoning', 'text': reasoning},
            if (text.isNotEmpty) {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model'},
        });
        // durable 先落：ChatTranscript 处理 AssistantMessageEvent 时会移除 draft，
        // 随后的 stream end 引用该 seq，文本不丢失。
        out.add(AssistantMessageEvent(
          seq,
          _now,
          const <String, Object?>{},
          turn: _turn,
          step: 0,
          message: message,
        ));
        out.add(AssistantStreamEnded(
          _attemptId,
          ++_revision,
          index: _chunkIndex,
          committed: true,
          committedEventType: 'assistant/message',
          committedSeq: seq,
        ));
      } else {
        out.add(AssistantStreamEnded(
          _attemptId,
          ++_revision,
          index: _chunkIndex,
          committed: false,
        ));
      }
      _streaming = false;
    }
    final endSeq = _seq++;
    out.add(TurnEndedEvent(
      endSeq,
      _now,
      const <String, Object?>{},
      turn: _turn,
      reason: TurnEndReason(failed ? 'error' : 'completed'),
    ));
    _turn++;
    _chunkIndex = 0;
    _assistantText.clear();
    _reasoningText.clear();
    return List.unmodifiable(out);
  }

  /// ACP content 可能是字符串或 `[{type:'text',text:...}]`。
  static String _extractText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final item in content) {
        final map = asMap(item);
        if (map == null) continue;
        final type = asString(map['type']);
        if (type == 'text' || type == 'reasoning') {
          final text = asString(map['text']);
          if (text != null) buffer.write(text);
        }
      }
      return buffer.toString();
    }
    final map = asMap(content);
    if (map != null) return asString(map['text']) ?? '';
    return '';
  }
}
