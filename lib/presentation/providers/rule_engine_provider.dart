import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/models/monitor_item.dart';
import '../../data/models/rule_config.dart';
import '../../data/models/traffic_sample.dart';
import 'monitor_list_provider.dart';
import 'rule_provider.dart';
import 'runtime_providers.dart';

/// 一次规则命中事件。
///
/// [id] 自增，保证同一进程连续触发时 UI 能区分出是新事件。
@immutable
class RuleHit {
  const RuleHit({
    required this.id,
    required this.pid,
    required this.processName,
    required this.processTitle,
    required this.speed,
    required this.rule,
    required this.at,
  });

  final int id;
  final int pid;

  /// 原始进程名，例如 chrome.exe
  final String processName;

  /// 展示名称（软件名优先）
  final String processTitle;

  /// 触发时的速率，单位 B/s
  final double speed;
  final RuleConfig rule;
  final DateTime at;

  /// 面板/弹窗里的描述文案
  String get description =>
      '$processTitle($pid) ${rule.metric.label} ${formatRate(speed)}，'
      '${rule.comparison.label}阈值 ${formatRate(rule.thresholdBytesPerSecond)}'
      ' 已持续 ${rule.durationLabel}';
}

/// 规则引擎：在每一帧流量到达时判断"持续 N 时间满足阈值"。
///
/// 用监听帧代替独立 Timer：
/// - 判定与采样同频（1 秒），不会因为定时器漂移产生误差；
/// - 数据流停止时自然停止判定，不需要额外管理生命周期。
///
/// 每个进程维护两样状态：
/// - 首次满足条件的时刻（用于计算持续时长）；
/// - 是否已触发过（条件恢复前不重复告警）。
class RuleEngineNotifier extends Notifier<RuleHit?> {
  final Map<int, DateTime> _violationSince = <int, DateTime>{};
  final Set<int> _fired = <int>{};

  /// 关机/休眠是系统级动作，一次命中只执行一次
  bool _systemActionIssued = false;
  int _nextId = 0;

  @override
  RuleHit? build() {
    // 规则一改，旧计时作废，避免拿新阈值套用旧起始时间
    ref.listen<RuleConfig>(ruleProvider, (
      RuleConfig? previous,
      RuleConfig next,
    ) {
      _resetTimers();
    });

    // 进程被移出监控时，同步清理它的计时状态
    ref.listen<MonitorListState>(monitorListProvider, (
      MonitorListState? previous,
      MonitorListState next,
    ) {
      final Set<int> pids = next.pids.toSet();
      _violationSince.removeWhere((int pid, _) => !pids.contains(pid));
      _fired.removeWhere((int pid) => !pids.contains(pid));
    });

    return null;
  }

  /// 每帧调用一次
  void evaluate(Map<int, TrafficSample> frame) {
    final RuleConfig rule = ref.read(ruleProvider);
    if (!rule.enabled) {
      _resetTimers();
      return;
    }

    final MonitorListState monitors = ref.read(monitorListProvider);
    if (monitors.isEmpty) return;

    for (final MonitorItem item in monitors.list) {
      final TrafficSample? sample = frame[item.pid];
      if (sample == null) continue;

      final double speed = rule.speedOf(
        uploadSpeed: sample.uploadSpeed,
        downloadSpeed: sample.downloadSpeed,
      );

      if (!rule.matches(speed)) {
        // 条件恢复，清空计时与"已触发"标记，允许下一轮重新告警
        _violationSince.remove(item.pid);
        _fired.remove(item.pid);
        continue;
      }

      if (_fired.contains(item.pid)) continue;

      final DateTime since = _violationSince.putIfAbsent(
        item.pid,
        () => sample.timestamp,
      );
      if (sample.timestamp.difference(since) < rule.duration) continue;

      _fired.add(item.pid);
      _emit(
        RuleHit(
          id: ++_nextId,
          pid: item.pid,
          processName: item.processName,
          processTitle: item.title,
          speed: speed,
          rule: rule,
          at: sample.timestamp,
        ),
      );
    }
  }

  void _resetTimers() {
    _violationSince.clear();
    _fired.clear();
    _systemActionIssued = false;
  }

  void _emit(RuleHit hit) {
    debugPrint('[规则触发] ${hit.description} → 执行：${hit.rule.action.label}');

    switch (hit.rule.action) {
      case RuleAction.notify:
        // 写入状态，Dashboard 监听后弹出警告框
        state = hit;
        break;
      case RuleAction.killProcess:
        state = hit;
        unawaited(_killProcess(hit));
        break;
      case RuleAction.shutdown:
      case RuleAction.hibernate:
        if (_systemActionIssued) break;
        _systemActionIssued = true;
        state = hit;
        unawaited(
          hit.rule.action == RuleAction.shutdown
              ? _runSystemAction(
                  ref.read(trafficServiceProvider).shutdownSystem,
                  '关机',
                )
              : _runSystemAction(
                  ref.read(trafficServiceProvider).hibernateSystem,
                  '休眠',
                ),
        );
        break;
      case RuleAction.logOnly:
        break;
    }
  }

  Future<void> _killProcess(RuleHit hit) async {
    try {
      await ref.read(trafficServiceProvider).killProcess(hit.pid);
      debugPrint('已结束进程 ${hit.processTitle}(${hit.pid})');
    } catch (error) {
      debugPrint('结束进程 ${hit.pid} 失败：$error');
    }
  }

  Future<void> _runSystemAction(
    Future<void> Function() action,
    String label,
  ) async {
    try {
      await action();
      debugPrint('已执行系统操作：$label');
    } catch (error) {
      debugPrint('$label 失败：$error');
    }
  }
}

final NotifierProvider<RuleEngineNotifier, RuleHit?> ruleEngineProvider =
    NotifierProvider<RuleEngineNotifier, RuleHit?>(RuleEngineNotifier.new);
