// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
/// ACP（Claude Code 等）会话在 app 状态层的接入点。
///
/// Host 通过 `agent.acp.*` 顶层 RPC 暴露 ACP agent；这些会话不在标准
/// `session/list` 注册表里，所以要在会话列表里额外合并一份投影。
/// id 用 `claude:` 前缀标记为 ACP 行，Host 调用前由 [nativeAcpId] 剥掉。
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionProjections, SessionSummary;
import 'package:dsh_remote/dsh_remote.dart'
    show AcpSession, AcpWorkspace, DshConnectionState, RemoteAcpClient, RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart' show HostConnection;
import 'read_list_identity.dart' show readListLiveConnectionProvider;

/// 从当前实时连接拿 ACP 客户端；连接不支持 ACP 时返回 null。
RemoteAcpClient? acpClientFor(HostConnection? connection) {
  final carrier = connection?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return null;
  final session = carrier.session;
  if (session == null || session.isClosed) return null;
  final client = RemoteAcpClient(session);
  return client.supported ? client : null;
}

/// 观察 ACP 会话所用的 Host session（照抄 remoteWebSessionProvider 的接缝：
/// Noise session 换掉时重新采样，而不是用 carrier 缓存的能力表）。
final acpSessionProvider = StreamProvider.autoDispose<RemoteHostSession?>((ref) {
  final connection = ref.watch(readListLiveConnectionProvider);
  final carrier = connection?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return Stream.value(null);
  return Stream.multi((output) {
    var cancelled = false;
    RemoteHostSession? observed;
    void sample() {
      if (cancelled) return;
      final session = carrier.session;
      if (!identical(observed, session)) {
        observed = session;
        if (session != null) {
          unawaited(
            session.rpc.done.then((_) {
              if (!cancelled && identical(observed, session)) sample();
            }),
          );
        }
      }
      final connected = carrier.state?.isConnected ?? connection!.client.mux.state == DshConnectionState.connected;
      final supported = session != null && !session.isClosed && RemoteAcpClient(session).supported;
      output.addSync(connected && supported ? session : null);
    }

    final sessions = carrier.sessions.listen((_) => sample());
    final states = carrier.states.listen((_) => sample());
    sample();
    output.onCancel = () async {
      cancelled = true;
      await sessions.cancel();
      await states.cancel();
    };
  });
});

/// 把一个 ACP 会话映射成 app 列表用的 [SessionSummary]。
///
/// 关键：`origin='claude'`（不能是 'subagent'，否则会被顶层列表过滤），
/// `projectionsKind='sequenced'`（跳过逐行标题回填），标题直接塞进
/// projections。`copyWith` 不能改 sessionId/origin/raw，所以构造时一次给全。
SessionSummary _toSummary(AcpSession s) {
  final title = s.title.trim();
  return SessionSummary(
    sessionId: 'claude:${s.sessionId}',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(s.updatedAt ?? 0),
    running: false,
    blank: false,
    agentAvailable: true,
    cwd: s.cwd,
    origin: 'claude',
    projections: SessionProjections(-1, <String, Object?>{'title': title}),
    projectionsKind: 'sequenced',
    raw: const <String, Object?>{'backend': 'claude'},
  );
}

/// Claude backend 下所有工作区的会话，映射为可合并进会话列表的投影。
/// ACP 不可用或未登录时静默返回空列表，不影响标准会话。
final acpClaudeSessionsProvider = FutureProvider.autoDispose<List<SessionSummary>>((ref) async {
  final connection = ref.watch(readListLiveConnectionProvider);
  final acp = acpClientFor(connection);
  if (acp == null || !acp.backendAvailable('claude')) return const <SessionSummary>[];
  try {
    final workspaces = await acp.listWorkspaces('claude');
    final out = <SessionSummary>[];
    final seen = <String>{};
    for (final ws in workspaces) {
      final sessions = await acp.listSessions(ws.path, 'claude');
      for (final s in sessions) {
        final id = 'claude:${s.sessionId}';
        if (!seen.add(id)) continue;
        out.add(_toSummary(s));
      }
    }
    return List.unmodifiable(out);
  } on Object {
    // ACP 未登录 / 目录不可读：降级为空，不阻断标准会话列表。
    return const <SessionSummary>[];
  }
});

// ── 会话配置：模型 / 思考强度 / 权限模式 ─────────────────────────────────────

/// 一个可选配置值（Claude 的 `opus` / `sonnet` / `high` …）。
class AcpConfigChoice {
  const AcpConfigChoice({required this.value, required this.name, this.description});

  final String value;
  final String name;
  final String? description;

  static AcpConfigChoice? fromJson(Object? json) {
    if (json is! Map) return null;
    // `configOptions[].options` 用 `value`，而 `modes.availableModes` 用 `id`。
    final value = json['value'] ?? json['id'];
    if (value is! String || value.isEmpty) return null;
    final name = json['name'];
    final description = json['description'];
    return AcpConfigChoice(
      value: value,
      name: name is String && name.isNotEmpty ? name : value,
      description: description is String && description.isNotEmpty ? description : null,
    );
  }
}

/// 一个 ACP 会话的当前配置（`session/load` 返回的 configOptions + modes）。
class AcpSessionConfig {
  const AcpSessionConfig({
    required this.models,
    required this.modelValue,
    required this.efforts,
    required this.effortValue,
    required this.modes,
    required this.modeId,
  });

  final List<AcpConfigChoice> models;
  final String? modelValue;
  final List<AcpConfigChoice> efforts;
  final String? effortValue;
  final List<AcpConfigChoice> modes;
  final String? modeId;

  /// 当前模型在目录里的展示名；没有目录时退回原始值。
  String get modelName {
    for (final choice in models) {
      if (choice.value == modelValue) return choice.name;
    }
    return modelValue ?? '';
  }

  String? get effortName {
    for (final choice in efforts) {
      if (choice.value == effortValue) return choice.name;
    }
    return effortValue;
  }

  /// Host 0.6.6 的 `sanitizeSessionResult` 只透传 `sessionId`/`stopReason`/
  /// `mode`/`currentModeId`/`modes`，`configOptions` 会被剥掉，上游的模型目录
  /// 到不了客户端。Claude 的模型集合是固定的，这里兜底一份；上游以后透传
  /// 时以它为准（[withBackendFallback] 只在目录为空时补）。
  static const claudeModels = <AcpConfigChoice>[
    AcpConfigChoice(value: 'default', name: 'Default', description: 'Opus'),
    AcpConfigChoice(value: 'opus', name: 'Opus 5.5'),
    AcpConfigChoice(value: 'fable', name: 'Fable 5.2'),
    AcpConfigChoice(value: 'sonnet', name: 'Sonnet 5.5'),
    AcpConfigChoice(value: 'haiku', name: 'Haiku 5.5'),
  ];

  /// 目录为空时用已知后端的兜底模型目录补上。
  AcpSessionConfig withBackendFallback(String backend) {
    if (models.isNotEmpty || backend != 'claude') return this;
    return AcpSessionConfig(
      models: claudeModels,
      modelValue: modelValue,
      efforts: efforts,
      effortValue: effortValue,
      modes: modes,
      modeId: modeId,
    );
  }

  /// 只改当前模型名（上游没回新的 configOptions 时用）。
  AcpSessionConfig withModel(String value) => AcpSessionConfig(
    models: models,
    modelValue: value,
    efforts: efforts,
    effortValue: effortValue,
    modes: modes,
    modeId: modeId,
  );

  static List<AcpConfigChoice> _choices(Object? raw) {
    if (raw is! List) return const [];
    return [for (final item in raw) ?AcpConfigChoice.fromJson(item)];
  }

  /// 解析上游 `session/load` / `session/new` 的结果。
  static AcpSessionConfig? parse(Object? result) {
    if (result is! Map) return null;
    final options = result['configOptions'];
    List<AcpConfigChoice> models = const [];
    List<AcpConfigChoice> efforts = const [];
    String? modelValue;
    String? effortValue;
    if (options is List) {
      for (final raw in options) {
        if (raw is! Map) continue;
        final category = raw['category'];
        final id = raw['id'];
        final choices = _choices(raw['options']);
        final current = raw['currentValue'];
        if (category == 'model' || id == 'model') {
          models = choices;
          if (current is String) modelValue = current;
        } else if (category == 'thought_level' || id == 'effort') {
          efforts = choices;
          if (current is String) effortValue = current;
        }
      }
    }
    List<AcpConfigChoice> modes = const [];
    String? modeId;
    final modesRaw = result['modes'];
    if (modesRaw is Map) {
      modes = _choices(modesRaw['availableModes']);
      final current = modesRaw['currentModeId'];
      if (current is String) modeId = current;
    }
    if (models.isEmpty && modes.isEmpty) return null;
    return AcpSessionConfig(
      models: models,
      modelValue: modelValue,
      efforts: efforts,
      effortValue: effortValue,
      modes: modes,
      modeId: modeId,
    );
  }
}

/// 打开过的 ACP 会话的配置，按展示 id 缓存；模型胶囊从这里读当前模型。
class AcpConfigStore extends Notifier<Map<String, AcpSessionConfig>> {
  @override
  Map<String, AcpSessionConfig> build() => const {};

  void put(String sessionId, AcpSessionConfig config) {
    state = {...state, sessionId: config};
  }

  void forget(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    final next = {...state}..remove(sessionId);
    state = next;
  }
}

final acpConfigStoreProvider = NotifierProvider<AcpConfigStore, Map<String, AcpSessionConfig>>(AcpConfigStore.new);
/// backend id → 展示名。
String acpBackendLabel(String backend) => switch (backend) {
  'claude' => 'Claude Code',
  'cursor' => 'Cursor',
  'pi' => 'Pi',
  'opencode' => 'OpenCode',
  'antigravity' => 'Antigravity',
  'hermes' => 'Hermes',
  _ => backend,
};

/// 新对话用哪个 backend：null = 标准 DSH，其余为 ACP backend id。
class NewChatBackendController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? backend) => state = backend;
}

final newChatBackendProvider = NotifierProvider<NewChatBackendController, String?>(NewChatBackendController.new);

/// Claude（ACP）可用的工作区目录，供新对话选择落点。
final acpWorkspacesProvider = FutureProvider.autoDispose<List<AcpWorkspace>>((ref) async {
  final connection = ref.watch(readListLiveConnectionProvider);
  final acp = acpClientFor(connection);
  if (acp == null || !acp.backendAvailable('claude')) return const <AcpWorkspace>[];
  try {
    return List.unmodifiable(await acp.listWorkspaces('claude'));
  } on Object {
    return const <AcpWorkspace>[];
  }
});

/// 新对话用哪个 ACP 工作区（绝对路径）；null = 还没选，交给默认值。
class NewChatAcpWorkspaceController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? path) => state = path;
}

final newChatAcpWorkspaceProvider =
    NotifierProvider<NewChatAcpWorkspaceController, String?>(NewChatAcpWorkspaceController.new);