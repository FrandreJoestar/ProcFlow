import 'package:flutter/foundation.dart';

/// 单个进程在某一时刻的流量采样点。
///
/// 速率统一使用 **字节/秒（B/s）** 存储，只在展示层做 KB/MB 换算，
/// 避免"存储单位"和"展示单位"混用导致的计算错误。
@immutable
class TrafficSample {
  const TrafficSample({
    required this.timestamp,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });

  final DateTime timestamp;

  /// 上传速率，单位 B/s
  final double uploadSpeed;

  /// 下载速率，单位 B/s
  final double downloadSpeed;

  /// 总速率（图表默认绘制的值）
  double get totalSpeed => uploadSpeed + downloadSpeed;

  /// X 轴坐标：以毫秒时间戳换算成秒，fl_chart 的 X 轴只接受 double
  double get x => timestamp.millisecondsSinceEpoch / 1000.0;

  @override
  String toString() =>
      'TrafficSample(t: $timestamp, up: $uploadSpeed, down: $downloadSpeed)';
}
