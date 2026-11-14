import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 支持"长按拖动多选"的固定行高列表。
///
/// - 长按起点决定模式：起点未选中 → 经过的行全部选中；
///   起点已选中 → 经过的行全部取消（与资源管理器一致）；
/// - 选区是"起点 ~ 当前行"的连续区间，区间外的行恢复拖动前的勾选状态，
///   因此反向拖回时会自动取消已经划过的行；
/// - 指针进入上下边缘区域时自动滚动，越靠边越快。
class DragSelectListView extends StatefulWidget {
  const DragSelectListView({
    super.key,
    required this.ids,
    required this.selectedIds,
    required this.onSelectionChanged,
    required this.itemExtent,
    required this.itemBuilder,
  });

  /// 当前可见项（按显示顺序）对应的 ID
  final List<int> ids;

  /// 当前勾选集合，由调用方持有状态
  final Set<int> selectedIds;

  /// 拖动过程中的选区变化
  final ValueChanged<Set<int>> onSelectionChanged;

  /// 固定行高，用于把指针位置换算成行号
  final double itemExtent;

  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  State<DragSelectListView> createState() => _DragSelectListViewState();
}

class _DragSelectListViewState extends State<DragSelectListView> {
  static const double _edgeThreshold = 24;

  final ScrollController _scrollController = ScrollController();

  Timer? _autoScrollTimer;
  bool _dragging = false;
  int? _anchor;
  int? _current;
  bool _selecting = true;
  List<int> _dragIds = const <int>[];
  Set<int> _baseSelection = const <int>{};
  double _dragLocalY = 0;
  double _autoScrollStep = 0;
  double _viewportHeight = 0;

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollController.dispose();
    super.dispose();
  }

  /// 把视口内的 y 坐标换算成行号
  int? _indexAt(double localY) {
    if (_dragIds.isEmpty) return null;
    final double offset =
        _scrollController.hasClients ? _scrollController.offset : 0;
    final int index = ((offset + localY) / widget.itemExtent).floor();
    return index.clamp(0, _dragIds.length - 1);
  }

  void _beginDrag(LongPressStartDetails details) {
    if (widget.ids.isEmpty) return;

    // 先固化拖动期间的 ID 顺序，避免列表刷新导致行号错位
    _dragIds = List<int>.of(widget.ids);
    final int? index = _indexAt(details.localPosition.dy);
    if (index == null) {
      _dragIds = const <int>[];
      return;
    }

    _baseSelection = Set<int>.of(widget.selectedIds);
    _anchor = index;
    _current = index;
    _selecting = !_baseSelection.contains(_dragIds[index]);
    _dragging = true;
    _dragLocalY = details.localPosition.dy;

    _applySelection();
    _updateAutoScroll();
  }

  void _updateDrag(LongPressMoveUpdateDetails details) {
    if (!_dragging) return;
    _dragLocalY = details.localPosition.dy;
    final int? index = _indexAt(_dragLocalY);
    if (index != null) {
      _current = index;
    }
    _applySelection();
    _updateAutoScroll();
  }

  void _endDrag() {
    _stopAutoScroll();
    _dragging = false;
    _anchor = null;
    _current = null;
    _dragIds = const <int>[];
    _baseSelection = const <int>{};
  }

  /// 把 [anchor, current] 区间统一设为选中/取消，区间外恢复拖动前的状态
  void _applySelection() {
    final int? anchor = _anchor;
    final int? current = _current;
    if (!_dragging || anchor == null || current == null) return;

    final int start = math.min(anchor, current);
    final int end = math.max(anchor, current);
    final Set<int> next = Set<int>.of(_baseSelection);
    for (int i = start; i <= end; i++) {
      if (_selecting) {
        next.add(_dragIds[i]);
      } else {
        next.remove(_dragIds[i]);
      }
    }

    if (!setEquals(widget.selectedIds, next)) {
      widget.onSelectionChanged(next);
    }
  }

  /// 指针靠近上下边缘时启动自动滚动
  void _updateAutoScroll() {
    if (!_dragging || _viewportHeight <= 0) {
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
    if (!_dragging || !_scrollController.hasClients) {
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
      _current = index;
    }
    _applySelection();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportHeight = constraints.maxHeight;
        return GestureDetector(
          onLongPressStart: _beginDrag,
          onLongPressMoveUpdate: _updateDrag,
          onLongPressEnd: (LongPressEndDetails _) => _endDrag(),
          onLongPressCancel: _endDrag,
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            // 固定行高，长列表滚动时避免逐行测量
            itemExtent: widget.itemExtent,
            itemCount: widget.ids.length,
            itemBuilder: widget.itemBuilder,
          ),
        );
      },
    );
  }
}
