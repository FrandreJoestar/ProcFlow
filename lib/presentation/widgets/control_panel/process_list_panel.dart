import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
  /// 与 ListView.itemExtent 保持一致，用于把指针位置换算成行号
  static const double _itemExtent = 48;
  static const double _edgeThreshold = 24;

  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();

  // 长按拖动多选状态
  Timer? _autoScrollTimer;
  bool _dragSelecting = false;
  int? _dragAnchor;
  int? _dragIndex;
  bool _dragSelect = true;
  List<int> _dragPids = const <int>[];
  Set<int> _dragBaseSelection = const <int>{};
  double _dragLocalY = 0;
  double _autoScrollStep = 0;
  double _viewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(processListProvider).keyword,
    );
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(processListProvider.notifier).search('');
  }

  /// 把视口内的 y 坐标换算成 filtered 列表的行号
  int? _indexAt(double localY) {
    if (_dragPids.isEmpty) return null;
    final double offset =
        _scrollController.hasClients ? _scrollController.offset : 0;
    final int index = ((offset + localY) / _itemExtent).floor();
    return index.clamp(0, _dragPids.length - 1);
  }

  void _beginDrag(LongPressStartDetails details) {
    final ProcessListState state = ref.read(processListProvider);
    final List<ProcessInfo> visible = state.filtered;
    if (visible.isEmpty) return;

    // 先固化拖动期间的 PID 顺序，避免 5 秒进程刷新导致行号错位
    _dragPids = <int>[for (final ProcessInfo process in visible) process.pid];
    final int? index = _indexAt(details.localPosition.dy);
    if (index == null) {
      _dragPids = const <int>[];
      return;
    }

    _dragBaseSelection = Set<int>.of(state.selectedPids);
    _dragAnchor = index;
    _dragIndex = index;
    // 起点未选中 → 整段选中；起点已选中 → 整段取消（与资源管理器一致）
    _dragSelect = !state.selectedPids.contains(visible[index].pid);
    _dragSelecting = true;
    _dragLocalY = details.localPosition.dy;

    _applyDragSelection();
    _updateAutoScroll();
  }

  void _updateDrag(LongPressMoveUpdateDetails details) {
    if (!_dragSelecting) return;
    _dragLocalY = details.localPosition.dy;
    final int? index = _indexAt(_dragLocalY);
    if (index != null) {
      _dragIndex = index;
    }
    _applyDragSelection();
    _updateAutoScroll();
  }

  void _endDrag() {
    _stopAutoScroll();
    _dragSelecting = false;
    _dragAnchor = null;
    _dragIndex = null;
    _dragPids = const <int>[];
    _dragBaseSelection = const <int>{};
  }

  /// 按下拖动方向，把 [anchor, index] 区间统一设为选中/取消，
  /// 区间外的行恢复成拖动前的状态——反向拖回时即"反选前面选中的行"。
  void _applyDragSelection() {
    final int? anchor = _dragAnchor;
    final int? current = _dragIndex;
    if (!_dragSelecting || anchor == null || current == null) return;

    final int start = math.min(anchor, current);
    final int end = math.max(anchor, current);
    final Set<int> next = Set<int>.of(_dragBaseSelection);
    for (int i = start; i <= end; i++) {
      if (_dragSelect) {
        next.add(_dragPids[i]);
      } else {
        next.remove(_dragPids[i]);
      }
    }

    final Set<int> previous = ref.read(processListProvider).selectedPids;
    if (!setEquals(previous, next)) {
      ref.read(processListProvider.notifier).setSelection(next);
    }
  }

  /// 指针靠近上下边缘时启动自动滚动
  void _updateAutoScroll() {
    if (!_dragSelecting || _viewportHeight <= 0) {
      _stopAutoScroll();
      return;
    }

    double step = 0;
    if (_dragLocalY < _edgeThreshold) {
      step = -_scrollStepFor(_edgeThreshold - _dragLocalY);
    } else if (_dragLocalY > _viewportHeight - _edgeThreshold) {
      step = _scrollStepFor(_dragLocalY - (_viewportHeight - _edgeThreshold));
    }

    if (step == 0) {
      _stopAutoScroll();
      return;
    }

    _autoScrollStep = step;
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _onAutoScrollTick(),
    );
  }

  /// 越靠近边缘滚动越快：每 16ms 滚动 2~12 像素
  double _scrollStepFor(double depth) {
    final double ratio = (depth / _edgeThreshold).clamp(0.0, 1.0);
    return 2 + 10 * ratio;
  }

  void _onAutoScrollTick() {
    if (!_dragSelecting || !_scrollController.hasClients) {
      _stopAutoScroll();
      return;
    }

    final ScrollPosition position = _scrollController.position;
    final double target = (_scrollController.offset + _autoScrollStep)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - _scrollController.offset).abs() < 0.5) {
      // 已经滚到边界
      _stopAutoScroll();
      return;
    }

    _scrollController.jumpTo(target);
    final int? index = _indexAt(_dragLocalY);
    if (index != null) {
      _dragIndex = index;
    }
    _applyDragSelection();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
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
                : LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      _viewportHeight = constraints.maxHeight;
                      return GestureDetector(
                        // 长按后进入拖动多选；拖动过程中由 _updateAutoScroll
                        // 在靠近上下边缘时接管滚动
                        onLongPressStart: _beginDrag,
                        onLongPressMoveUpdate: _updateDrag,
                        onLongPressEnd: (LongPressEndDetails _) => _endDrag(),
                        onLongPressCancel: _endDrag,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.zero,
                          // 固定行高，长列表滚动时避免逐行测量
                          itemExtent: _itemExtent,
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
