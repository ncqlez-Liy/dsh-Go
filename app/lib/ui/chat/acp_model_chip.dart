// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
/// ACP（Claude Code 等）会话的模型胶囊，以及新对话时选 agent 的胶囊。
///
/// 标准会话的模型来自 Host 的 `session/modelCatalog`；ACP 会话没有这个接口
/// （适配器不实现 `dsh/sessionModels`），模型目录只能从 `session/load` 的
/// `configOptions` 里拿，见 [AcpSessionConfig]。
library;

import 'package:dsh_client/dsh_client.dart' show DshRemoteException;
import 'package:dsh_remote/dsh_remote.dart' show AcpWorkspace, RemoteAcpException, backendFromSessionId;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/acp_state.dart';
import '../../state/connection_state.dart' show activeConnectionProvider;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 顶栏胶囊：`Sonnet 5.5 ⌄`，点开换 Claude 的模型。
class AcpModelChip extends ConsumerWidget {
  const AcpModelChip({super.key, required this.sessionId, required this.backend, this.grouped = false});

  final String sessionId;
  final String backend;
  final bool grouped;

  static const compactWidth = 12 + 16 + 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(acpConfigStoreProvider.select((sessions) => sessions[sessionId]));
    final name = config?.modelName ?? '';
    final label = name.isEmpty ? acpBackendLabel(backend) : name;
    final effort = config?.effortName;
    final em = MediaQuery.textScalerOf(context).scale(13);
    final style = theme.textTheme.labelMedium?.copyWith(fontSize: 13);
    void open() => showAcpModelSheet(context, ref, sessionId: sessionId, backend: backend);

    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: grouped,
      onTap: open,
      child: Semantics(
        label: label,
        button: true,
        onTap: open,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: em * 10, minWidth: em * 2.5),
                  child: Text(
                    effort == null || effort.isEmpty ? label : '$label · $effort',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                Icon(AppIcons.expand, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 新对话时选择用哪个 agent：DSH 还是 Claude Code。
class NewChatBackendChip extends ConsumerWidget {
  const NewChatBackendChip({super.key, this.grouped = false});

  final bool grouped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final backend = ref.watch(newChatBackendProvider);
    final label = backend == null ? 'DSH' : acpBackendLabel(backend);
    final em = MediaQuery.textScalerOf(context).scale(13);
    final style = theme.textTheme.labelMedium?.copyWith(fontSize: 13);
    void open() => showNewChatBackendSheet(context, ref);

    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: grouped,
      onTap: open,
      child: Semantics(
        label: label,
        button: true,
        onTap: open,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: em * 10, minWidth: em * 2.5),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
                Icon(AppIcons.expand, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话是不是 ACP 会话；是的话返回 backend id。
String? acpBackendOfSession(String? sessionId) => sessionId == null ? null : backendFromSessionId(sessionId);

/// 新对话的 agent 选择弹层。DSH 用哨兵值 `'dsh'`（不能用 null，dismiss 也是 null）。
Future<void> showNewChatBackendSheet(BuildContext context, WidgetRef ref) async {
  final current = ref.read(newChatBackendProvider);
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      Widget row(String value, String label, String hint, bool active) => ListTile(
        title: Text(label),
        subtitle: Text(hint, style: theme.textTheme.bodySmall),
        trailing: active ? const Icon(AppIcons.selected, size: 20) : null,
        onTap: () => Navigator.of(sheetContext).pop(value),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row('dsh', 'DeepSeek Harness', '新对话交给 DSH 引擎（默认）', current == null),
            row('claude', 'Claude Code', '新对话交给电脑上的 Claude Code', current == 'claude'),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (picked == null) return;
  ref.read(newChatBackendProvider.notifier).select(picked == 'dsh' ? null : picked);
  if (picked == 'claude') await showAcpWorkspaceSheet(context, ref);
}

/// 选 Claude 的工作区：清单来自 Host 的 ACP 目录（`dsh/workspaceList`），
/// 不是 DSH 的工作区注册表——两者是不同的目录集合。
Future<void> showAcpWorkspaceSheet(BuildContext context, WidgetRef ref) async {
  var spaces = ref.read(acpWorkspacesProvider).value;
  if (spaces == null) {
    try {
      spaces = await ref.read(acpWorkspacesProvider.future);
    } on Object {
      spaces = const <AcpWorkspace>[];
    }
  }
  if (!context.mounted) return;
  final available = spaces ?? const <AcpWorkspace>[];
  if (available.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('电脑上的 Claude 还没有可用工作区')));
    return;
  }
  final current = ref.read(newChatAcpWorkspaceProvider);
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Claude Code 工作区', style: theme.textTheme.titleSmall),
            ),
            for (final space in available)
              ListTile(
                title: Text(space.title == null || space.title!.isEmpty ? space.path : space.title!),
                subtitle: Text(space.path, style: theme.textTheme.bodySmall),
                trailing: space.path == current ? const Icon(AppIcons.selected, size: 20) : null,
                onTap: () => Navigator.of(sheetContext).pop(space.path),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (picked != null) ref.read(newChatAcpWorkspaceProvider.notifier).select(picked);
}

/// 换 Claude 模型的底部弹层。
Future<void> showAcpModelSheet(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String backend,
}) async {
  final config = ref.read(acpConfigStoreProvider)[sessionId];
  final acp = acpClientFor(ref.read(activeConnectionProvider).value);
  if (config == null || acp == null || config.models.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('模型列表还没准备好，稍后再试')));
    return;
  }
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(acpBackendLabel(backend), style: theme.textTheme.titleSmall),
            ),
            for (final choice in config.models)
              ListTile(
                title: Text(choice.name),
                subtitle: choice.description == null ? null : Text(choice.description!),
                trailing: choice.value == config.modelValue ? const Icon(AppIcons.selected, size: 20) : null,
                onTap: () => Navigator.of(sheetContext).pop(choice.value),
              ),
          ],
        ),
      );
    },
  );
  if (picked == null || picked == config.modelValue) return;
  try {
    final updated = await acp.setConfigOption(sessionId, 'model', picked, backend);
    // Host 会剥掉 configOptions，回来的目录可能是空的：这时保留原目录并只改当前值。
    final next = (AcpSessionConfig.parse(updated) ?? config).withBackendFallback(backend).withModel(picked);
    ref.read(acpConfigStoreProvider.notifier).put(sessionId, next);
  } on DshRemoteException catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('换模型失败：${error.message}')));
  } on RemoteAcpException catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('换模型失败：${error.code}')));
  } on Object catch (error) {
    // Host 侧把适配器错误映射成 RpcError，这里兜底给出可读提示。
    if (!context.mounted) return;
    final message = '$error';
    final text = message.contains('METHOD_NOT_ALLOWED')
        ? '这台主机的 Remote 插件还不支持在手机上换 Claude 模型（0.6.6）。'
        : '换模型失败：$message';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
