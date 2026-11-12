import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/process_info.dart';
import '../../providers/monitor_list_provider.dart';
import '../../providers/process_list_provider.dart';

/// 中间的"添加 / 移除"箭头按钮。
class TransferButtons extends ConsumerWidget {
  const TransferButtons({super.key});

  void _addSelected(WidgetRef ref) {
    final ProcessListState state = ref.read(processListProvider);
    if (state.selectedPids.isEmpty) return;

    final Iterable<ProcessInfo> selected = state.processes.where(
      (ProcessInfo p) => state.selectedPids.contains(p.pid),
    );
    ref.read(monitorListProvider.notifier).addAll(selected);
    // 添加后清空左侧勾选，避免误加第二次
    ref.read(processListProvider.notifier).clearSelection();
  }

  void _removeSelected(WidgetRef ref) {
    final Set<int> selected = ref.read(monitorSelectionProvider);
    if (selected.isEmpty) return;

    ref.read(monitorListProvider.notifier).removeAll(selected);
    ref.read(monitorSelectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int leftCount = ref.watch(
      processListProvider.select((s) => s.selectedPids.length),
    );
    final int rightCount = ref.watch(
      monitorSelectionProvider.select((s) => s.length),
    );

    return SizedBox(
      width: 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          _CircleAction(
            icon: Icons.arrow_forward_rounded,
            tooltip: '添加到监控',
            enabled: leftCount > 0,
            onTap: () => _addSelected(ref),
          ),
          const SizedBox(height: 14),
          _CircleAction(
            icon: Icons.arrow_back_rounded,
            tooltip: '移出监控',
            enabled: rightCount > 0,
            onTap: () => _removeSelected(ref),
          ),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = enabled
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final Color foreground = enabled
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant.withValues(alpha: 0.5);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}
