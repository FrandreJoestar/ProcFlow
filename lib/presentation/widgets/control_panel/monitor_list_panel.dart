import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters.dart';
import '../../../data/models/monitor_item.dart';
import '../../providers/monitor_list_provider.dart';
import '../common/panel_card.dart';

/// 右上：已加入监控的进程列表（支持多选以移出监控）。
class MonitorListPanel extends ConsumerWidget {
  const MonitorListPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MonitorListState state = ref.watch(monitorListProvider);
    final Set<int> selection = ref.watch(monitorSelectionProvider);

    return PanelCard(
      title: '监控列表',
      subtitle: '${state.length} 个',
      child: state.isEmpty
          ? const _EmptyHint()
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemExtent: 52,
              itemCount: state.length,
              itemBuilder: (BuildContext context, int index) {
                final MonitorItem item = state.list[index];
                return _MonitorTile(
                  item: item,
                  selected: selection.contains(item.pid),
                  onTap: () => ref
                      .read(monitorSelectionProvider.notifier)
                      .toggle(item.pid),
                );
              },
            ),
    );
  }
}

class _MonitorTile extends StatelessWidget {
  const _MonitorTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final MonitorItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            // 与该进程在图表中的曲线颜色一致
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: item.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium,
                  ),
                  Text(
                    'PID ${item.pid} · ${formatRate(item.latestTotal)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.monitor_heart_outlined,
            size: 26,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            '从左侧选择进程后点击 →',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
