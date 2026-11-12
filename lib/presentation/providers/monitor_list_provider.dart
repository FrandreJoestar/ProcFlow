import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../data/models/monitor_item.dart';
import '../../data/models/process_info.dart';
import '../../data/models/traffic_sample.dart';

/// 右侧监控列表的状态模型。
///
/// 用 `Map<pid, MonitorItem>` 而不是 List：
/// - 添加/移除/查重都是 O(1)；
/// - 数据流按 PID 分发时不需要遍历。
@immutable
class MonitorListState {
  const MonitorListState({this.items = const <int, MonitorItem>{}});

  final Map<int, MonitorItem> items;

  List<MonitorItem> get list => items.values.toList(growable: false);

  Iterable<int> get pids => items.keys;

  bool contains(int pid) => items.containsKey(pid);

  MonitorItem? operator [](int pid) => items[pid];

  int get length => items.length;

  bool get isEmpty => items.isEmpty;

  bool get isNotEmpty => items.isNotEmpty;
}

class MonitorListNotifier extends Notifier<MonitorListState> {
  @override
  MonitorListState build() => const MonitorListState();

  /// 添加进程：分配未被占用的颜色，同时立刻建立一条空曲线
  void addAll(Iterable<ProcessInfo> processes) {
    final Map<int, MonitorItem> next = Map<int, MonitorItem>.of(state.items);
    final Set<Color> used = <Color>{
      for (final MonitorItem item in next.values) item.color,
    };

    for (final ProcessInfo process in processes) {
      if (next.containsKey(process.pid)) continue;
      final Color color = ProcessPalette.pick(used);
      used.add(color);
      next[process.pid] = MonitorItem.fromProcess(process, color: color);
    }

    if (next.length == state.items.length) return;
    state = MonitorListState(items: next);
  }

  /// 移除进程：条目被丢弃后，其采样缓冲与图表曲线会一起被 GC 回收
  void removeAll(Iterable<int> pids) {
    final Set<int> targets = pids.toSet();
    if (targets.isEmpty) return;

    final Map<int, MonitorItem> next = Map<int, MonitorItem>.of(state.items)
      ..removeWhere((int pid, _) => targets.contains(pid));
    if (next.length == state.items.length) return;
    state = MonitorListState(items: next);
  }

  void clear() {
    if (state.items.isEmpty) return;
    state = const MonitorListState();
  }

  /// 数据帧到达时批量写入。
  ///
  /// 采样点直接写进各条目的环形缓冲区（原地 O(1)），
  /// 最后用一个新的 Map 包装触发一次刷新，避免每个进程各刷新一次。
  void ingest(Map<int, TrafficSample> samplesByPid) {
    if (state.items.isEmpty) return;

    var changed = false;
    samplesByPid.forEach((int pid, TrafficSample sample) {
      final MonitorItem? item = state.items[pid];
      if (item == null) return;
      item.ingest(sample);
      changed = true;
    });

    if (!changed) return;
    state = MonitorListState(items: Map<int, MonitorItem>.of(state.items));
  }
}

final NotifierProvider<MonitorListNotifier, MonitorListState>
monitorListProvider = NotifierProvider<MonitorListNotifier, MonitorListState>(
  MonitorListNotifier.new,
);

/// 监控条目的 PID 集合：右侧列表用它做多选与高亮
final monitoredPidsProvider = Provider.autoDispose<Set<int>>(
  (Ref ref) => ref.watch(monitorListProvider.select((s) => s.pids.toSet())),
);

/// 右侧监控列表的勾选状态（仅用于"移出监控"，与进程数据无关）
class MonitorSelectionNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const <int>{};

  void toggle(int pid) {
    final Set<int> next = Set<int>.of(state);
    if (!next.remove(pid)) next.add(pid);
    state = next;
  }

  void clear() {
    if (state.isEmpty) return;
    state = const <int>{};
  }
}

final NotifierProvider<MonitorSelectionNotifier, Set<int>>
monitorSelectionProvider = NotifierProvider<MonitorSelectionNotifier, Set<int>>(
  MonitorSelectionNotifier.new,
);
