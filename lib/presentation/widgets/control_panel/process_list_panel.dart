import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/process_info.dart';
import '../../providers/monitor_list_provider.dart';
import '../../providers/process_list_provider.dart';
import '../common/panel_card.dart';

/// 左上：支持"软件名 / 进程名 / PID"实时模糊搜索的多选进程列表。
class ProcessListPanel extends ConsumerStatefulWidget {
  const ProcessListPanel({super.key});

  @override
  ConsumerState<ProcessListPanel> createState() => _ProcessListPanelState();
}

class _ProcessListPanelState extends ConsumerState<ProcessListPanel> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(processListProvider).keyword,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(processListProvider.notifier).search('');
  }

  @override
  Widget build(BuildContext context) {
    final ProcessListState state = ref.watch(processListProvider);
    final Set<int> monitored = ref.watch(monitoredPidsProvider);
    final ThemeData theme = Theme.of(context);

    return PanelCard(
      title: '进程列表',
      subtitle: '${state.filtered.length} / ${state.processes.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _searchController,
            onChanged: ref.read(processListProvider.notifier).search,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: '搜索软件名、进程名或 PID…',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              suffixIcon: state.keyword.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: '清空搜索',
                      onPressed: _clearSearch,
                    ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: state.filtered.isEmpty
                ? _EmptyHint(
                    icon: state.hasKeyword
                        ? Icons.search_off_rounded
                        : Icons.hourglass_empty_rounded,
                    text: state.hasKeyword ? '未找到匹配的进程' : '等待进程数据…',
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    // 固定行高，长列表滚动时避免逐行测量
                    itemExtent: 48,
                    itemCount: state.filtered.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ProcessInfo process = state.filtered[index];
                      return _ProcessTile(
                        process: process,
                        selected: state.isSelected(process.pid),
                        monitored: monitored.contains(process.pid),
                        onTap: () => ref
                            .read(processListProvider.notifier)
                            .toggleSelection(process.pid),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProcessTile extends StatelessWidget {
  const _ProcessTile({
    required this.process,
    required this.selected,
    required this.monitored,
    required this.onTap,
  });

  final ProcessInfo process;
  final bool selected;

  /// 已在右侧监控列表中：用图标提示，添加时会被去重
  final bool monitored;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

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
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 主行：任务管理器同款软件名（取自 exe 版本信息）
                  Text(
                    process.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: monitored
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    ),
                  ),
                  // 副行：原始进程名 + PID
                  Text(
                    '${process.name} · ${process.pid}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (monitored)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.timeline_rounded,
                  size: 14,
                  color: scheme.tertiary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 26, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
