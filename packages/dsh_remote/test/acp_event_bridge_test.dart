// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

AcpFrame _chunk(String text, {String kind = 'agent_message_chunk'}) => AcpFrame(
      streamId: 's1',
      frame: {
        'method': 'session/update',
        'params': {
          'sessionId': 'a8723acc',
          'update': {
            'sessionUpdate': kind,
            'content': [
              {'type': 'text', 'text': text},
            ],
          },
        },
      },
    );

void main() {
  final now = DateTime.utc(2026, 11, 20, 12);

  group('AcpEventBridge', () {
    test('native id 与 backend 从展示 id 解析', () {
      final bridge = AcpEventBridge(sessionId: 'claude:a8723acc', now: now);
      expect(bridge.nativeId, 'a8723acc');
      expect(bridge.backend, 'claude');
    });

    test('titleEvent 补一条标准 session/title 事件且 seq 递增', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final event = bridge.titleEvent('问候');
      expect(event, isA<TitleChangedEvent>());
      expect((event as TitleChangedEvent).title, '问候');
      expect(event.seq, 0);
      expect(bridge.titleEvent('再改').seq, 1);
    });

    test('initialSnapshot 提供标题投影与空事件', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', title: '问候', cwd: 'E:\\work', now: now);
      final snap = bridge.initialSnapshot();
      expect(snap.sessionId, 'claude:c1');
      expect(snap.header.origin, 'claude');
      expect(snap.header.cwd, 'E:\\work');
      expect(snap.projections.title, '问候');
      expect(snap.events, isEmpty);
      expect(snap.cursor, -1);
      expect(snap.assistantRevision, 0);
    });

    test('beginTurn 产出 turn/start + user/message，请求 id 透传', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final events = bridge.beginTurn('你好', requestId: 'req-1');
      expect(events, hasLength(2));
      expect(events[0], isA<TurnStartedEvent>());
      final user = events[1] as UserMessageEvent;
      expect(user.message.text, '你好');
      expect(user.requestId, 'req-1');
      expect(user.message.source.isHuman, isTrue);
    });

    test('没有 beginTurn 时，首个 chunk 先补 turn/start 再开 stream', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final first = bridge.onFrame(_chunk('你'));
      expect(first, hasLength(3));
      expect(first[0], isA<TurnStartedEvent>());
      expect(first[1], isA<AssistantStreamStarted>());
      expect(first[2], isA<AssistantChunkEvent>());
      expect((first[2] as AssistantChunkEvent).chunk, isA<TextDeltaChunk>());
      expect(((first[2] as AssistantChunkEvent).chunk as TextDeltaChunk).text, '你');
      final second = bridge.onFrame(_chunk('好'));
      expect(second, hasLength(1));
      expect(second[0], isA<AssistantChunkEvent>());
    });

    test('prompt_completed 终止帧收口一轮并补放 catchUp', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final all = <DshEvent>[];
      all.addAll(bridge.beginTurn('问题'));
      // 本轮实时帧全部丢失，只有终止帧带着 catchUp 回来。
      final terminal = AcpFrame(streamId: 's1', frame: {
        'method': 'session/update',
        'params': {
          'sessionId': 'c1',
          'update': {
            'sessionUpdate': 'prompt_completed',
            'stopReason': 'end_turn',
            'catchUp': [
              {
                'method': 'session/update',
                'params': {
                  'sessionId': 'c1',
                  'update': {
                    'sessionUpdate': 'agent_message_chunk',
                    'content': [
                      {'type': 'text', 'text': '补放的正文'},
                    ],
                  },
                },
              },
            ],
          },
        },
      });
      all.addAll(bridge.onFrame(terminal));
      expect(all.whereType<TurnStartedEvent>(), hasLength(1));
      expect(all.whereType<AssistantChunkEvent>(), hasLength(1));
      final assistant = all.whereType<AssistantMessageEvent>().single;
      expect(assistant.message.text, '补放的正文');
      expect(all.whereType<TurnEndedEvent>(), hasLength(1));
      // 收口后再来终止帧不应重复结束同一轮。
      expect(bridge.onFrame(terminal), isEmpty);
    });

    test('实时帧已收到时，终止帧的 catchUp 不再重复渲染正文', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final all = <DshEvent>[];
      all.addAll(bridge.beginTurn('问题'));
      all.addAll(bridge.onFrame(_chunk('实时正文')));
      final terminal = AcpFrame(streamId: 's1', frame: {
        'method': 'session/update',
        'params': {
          'sessionId': 'c1',
          'update': {
            'sessionUpdate': 'prompt_completed',
            'stopReason': 'end_turn',
            'catchUp': [
              {
                'method': 'session/update',
                'params': {
                  'sessionId': 'c1',
                  'update': {
                    'sessionUpdate': 'agent_message_chunk',
                    'content': [
                      {'type': 'text', 'text': '实时正文'},
                    ],
                  },
                },
              },
            ],
          },
        },
      });
      all.addAll(bridge.onFrame(terminal));
      // 只有实时那一份，catchUp 不应再补一遍。
      expect(all.whereType<AssistantChunkEvent>(), hasLength(1));
      expect(all.whereType<AssistantMessageEvent>().single.message.text, '实时正文');
    });

    test('thought chunk 生成 reasoning delta', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final events = bridge.onFrame(_chunk('思考', kind: 'agent_thought_chunk'));
      final chunk = events.last as AssistantChunkEvent;
      expect(chunk.chunk, isA<ReasoningDeltaChunk>());
      expect((chunk.chunk as ReasoningDeltaChunk).text, '思考');
    });

    test('非 session/update 帧被忽略', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final frame = AcpFrame(streamId: 's1', frame: {'method': 'session/info', 'params': {}});
      expect(bridge.onFrame(frame), isEmpty);
    });

    test('beginTurn + chunks + endTurn 产出完整一轮，durable 先于 stream end', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final all = <DshEvent>[];
      all.addAll(bridge.beginTurn('问题'));
      all.addAll(bridge.onFrame(_chunk('答案')));
      all.addAll(bridge.endTurn());
      expect(all.whereType<TurnStartedEvent>(), hasLength(1));
      expect(all.whereType<UserMessageEvent>(), hasLength(1));
      expect(all.whereType<AssistantChunkEvent>(), hasLength(1));
      expect(all.whereType<AssistantMessageEvent>(), hasLength(1));
      expect(all.whereType<AssistantStreamEnded>(), hasLength(1));
      expect(all.whereType<TurnEndedEvent>(), hasLength(1));
      final assistant = all.whereType<AssistantMessageEvent>().single;
      expect(assistant.message.text, '答案');
      // durable assistant/message 必须在 stream/ended 之前
      expect(all.indexWhere((e) => e is AssistantMessageEvent),
          lessThan(all.indexWhere((e) => e is AssistantStreamEnded)));
      expect(all.whereType<TurnEndedEvent>().single.reason.kind, 'completed');
    });

    test('endTurn(failed:true) 写 error 原因', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      bridge.beginTurn('问题');
      final events = bridge.endTurn(failed: true);
      expect(events.whereType<TurnEndedEvent>().single.reason.kind, 'error');
    });

    test('adoptHistory 把 seq 推到历史之后，新一轮不冲突', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final history = <SessionLogEvent>[
        TurnStartedEvent(5, now, const {}, turn: 1),
        TurnEndedEvent(9, now, const {}, turn: 1, reason: TurnEndReason('completed')),
      ];
      bridge.adoptHistory(history);
      final events = bridge.beginTurn('新一轮');
      expect((events[0] as SessionLogEvent).seq, 10);
      expect((events[1] as SessionLogEvent).seq, 11);
    });

    test('字符串形式的 content 也能提取', () {
      final bridge = AcpEventBridge(sessionId: 'claude:c1', now: now);
      final frame = AcpFrame(
        streamId: 's1',
        frame: {
          'method': 'session/update',
          'params': {'update': {'sessionUpdate': 'agent_message_chunk', 'content': '纯文本'}},
        },
      );
      final events = bridge.onFrame(frame);
      expect(((events.last as AssistantChunkEvent).chunk as TextDeltaChunk).text, '纯文本');
    });
  });
}
