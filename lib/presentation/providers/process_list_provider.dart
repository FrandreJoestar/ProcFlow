import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/process_info.dart';

/// 左侧进程列表的状态模型。
///
/// 三个字段是相互独立的：
/// - [processes]：原生层上报的全量进程；
/// - [keyword]：搜索框内容，只影响派生出的 [filtered]；
/// - [selectedPids]：用户勾选的 PID，**不会因为搜索而清空**。
@immutable
class ProcessListState {
  const ProcessListState({
    this.processes = const <ProcessInfo>[],
    this.keyword = '',
    this.selectedPids = const <int>{},
  });

  final List<ProcessInfo> processes;
  final String keyword;
  final Set<int> selectedPids;

  /// 搜索后的可见列表（不改变原始数据）
  List<ProcessInfo> get filtered => processes
      .where((ProcessInfo p) => p.matchesKeyword(keyword))
      .toList(growable: false);

  bool isSelected(int pid) => selectedPids.contains(pid);

  /// 搜索关键字为空且没有任何进程时，用来区分"加载中"与"无结果"
  bool get hasKeyword => keyword.trim().isNotEmpty;

  ProcessListState copyWith({
    List<ProcessInfo>? processes,
    String? keyword,
    Set<int>? selectedPids,
  }) {
    return ProcessListState(
      processes: processes ?? this.processes,
      keyword: keyword ?? this.keyword,
      selectedPids: selectedPids ?? this.selectedPids,
    );
  }
}

class ProcessListNotifier extends Notifier<ProcessListState> {
  @override
  ProcessListState build() => const ProcessListState();

  /// 搜索框输入：只更新关键字，勾选状态原样保留
  void search(String keyword) {
    if (keyword == state.keyword) return;
    // 复制一份 Set，保证外部拿到的旧状态不被修改
    state = state.copyWith(keyword: keyword);
  }

  /// 原生层上报进程快照时调用。
  /// 已退出的进程会从勾选集合中剔除，但不会影响仍在运行的进程勾选。
  void setProcesses(List<ProcessInfo> processes) {
    final Set<int> alive = <int>{for (final ProcessInfo p in processes) p.pid};
    state = state.copyWith(
      processes: processes,
      selectedPids: state.selectedPids.intersection(alive),
    );
  }

  /// 单选/取消勾选（Ctrl 多选语义由列表组件负责）
  void toggleSelection(int pid) {
    final Set<int> next = Set<int>.of(state.selectedPids);
    if (!next.remove(pid)) next.add(pid);
    state = state.copyWith(selectedPids: next);
  }

  /// 一次性覆盖勾选集合（用于 Shift 连选、全选）
  void setSelection(Set<int> pids) {
    state = state.copyWith(selectedPids: pids);
  }

  void clearSelection() {
    if (state.selectedPids.isEmpty) return;
    state = state.copyWith(selectedPids: const <int>{});
  }
}

final NotifierProvider<ProcessListNotifier, ProcessListState>
processListProvider = NotifierProvider<ProcessListNotifier, ProcessListState>(
  ProcessListNotifier.new,
);

/// 只监听搜索关键字，避免搜索框每次重建整块进程列表
final processKeywordProvider = Provider.autoDispose<String>(
  (Ref ref) => ref.watch(processListProvider.select((s) => s.keyword)),
);
