import 'package:flutter/foundation.dart';

import '../../core/formatters.dart';

/// 规则监控的指标
enum RuleMetric {
  total('总流量'),
  upload('上传'),
  download('下载');

  const RuleMetric(this.label);

  final String label;
}

/// 触发条件的比较方向
enum RuleComparison {
  below('低于'),
  above('高于');

  const RuleComparison(this.label);

  final String label;
}

/// 命中规则后执行的动作
enum RuleAction {
  notify('弹窗警告'),
  killProcess('结束进程'),
  shutdown('关机'),
  hibernate('休眠'),
  logOnly('仅记录日志');

  const RuleAction(this.label);

  final String label;
}

/// 自动化规则配置。
///
/// 语义：监控列表中任一进程的 [metric] 连续 [duration] 满足
/// `[comparison] [thresholdBytesPerSecond]` 时，执行 [action]。
@immutable
class RuleConfig {
  const RuleConfig({
    this.enabled = false,
    this.metric = RuleMetric.total,
    this.comparison = RuleComparison.below,
    this.thresholdBytesPerSecond = 1024 * 1024,
    this.duration = const Duration(minutes: 5),
    this.action = RuleAction.notify,
  });

  /// 默认草稿：总流量低于 1 MB/s 持续 5 分钟 → 弹窗警告
  static const RuleConfig initial = RuleConfig();

  final bool enabled;
  final RuleMetric metric;
  final RuleComparison comparison;

  /// 阈值，单位 B/s（展示时再换算成 KB/s、MB/s）
  final double thresholdBytesPerSecond;

  /// 持续时间，例如 5 分钟
  final Duration duration;

  final RuleAction action;

  /// 判断某个速率值是否满足阈值条件（持续时间由规则引擎单独计时）
  bool matches(double speed) {
    return comparison == RuleComparison.below
        ? speed < thresholdBytesPerSecond
        : speed > thresholdBytesPerSecond;
  }

  /// 从一帧采样中取出该规则关心的速率
  double speedOf({required double uploadSpeed, required double downloadSpeed}) {
    return switch (metric) {
      RuleMetric.total => uploadSpeed + downloadSpeed,
      RuleMetric.upload => uploadSpeed,
      RuleMetric.download => downloadSpeed,
    };
  }

  /// 面板上展示的规则摘要，例如「总流量低于 1.0 MB/s 持续 5 分钟」
  String get summary =>
      '${metric.label}${comparison.label} ${formatRate(thresholdBytesPerSecond)}'
      ' 持续 $durationLabel';

  String get durationLabel {
    if (duration.inMinutes < 1) return '${duration.inSeconds} 秒';
    if (duration.inHours < 1) return '${duration.inMinutes} 分钟';
    return '${duration.inHours} 小时';
  }

  RuleConfig copyWith({
    bool? enabled,
    RuleMetric? metric,
    RuleComparison? comparison,
    double? thresholdBytesPerSecond,
    Duration? duration,
    RuleAction? action,
  }) {
    return RuleConfig(
      enabled: enabled ?? this.enabled,
      metric: metric ?? this.metric,
      comparison: comparison ?? this.comparison,
      thresholdBytesPerSecond:
          thresholdBytesPerSecond ?? this.thresholdBytesPerSecond,
      duration: duration ?? this.duration,
      action: action ?? this.action,
    );
  }
}
