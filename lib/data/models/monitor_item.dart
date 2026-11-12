import 'dart:ui';

import '../../core/app_config.dart';
import 'process_info.dart';
import 'sample_ring_buffer.dart';
import 'traffic_sample.dart';

/// 一个"正在被监控"的进程。
///
/// 设计取舍：元数据（pid/名称/颜色）不可变；[samples] 是原地写入的环形缓冲。
/// 这样每秒刷新时不需要重建整条曲线数据，只有条目增删才会创建新对象。
class MonitorItem {
  MonitorItem({
    required this.pid,
    required this.processName,
    this.displayName = '',
    required this.color,
    int? capacity,
  }) : samples = SampleRingBuffer(capacity ?? AppConfig.bufferCapacity);

  factory MonitorItem.fromProcess(
    ProcessInfo process, {
    required Color color,
    int? capacity,
  }) {
    return MonitorItem(
      pid: process.pid,
      processName: process.name,
      displayName: process.displayName,
      color: color,
      capacity: capacity,
    );
  }

  final int pid;

  /// 原始进程名，例如 chrome.exe
  final String processName;

  /// 软件名（版本信息中的 FileDescription），可能为空
  final String displayName;

  /// 该进程曲线在图例和折线中使用的唯一颜色
  final Color color;

  /// 只保存当前图表窗口内的数据点
  final SampleRingBuffer samples;

  double latestUpload = 0;
  double latestDownload = 0;

  double get latestTotal => latestUpload + latestDownload;

  /// 展示名称：优先软件名，退化为进程名
  String get title => displayName.isEmpty ? processName : displayName;

  /// 图例文案：名称 + PID，区分同名的多个进程
  String get legendLabel => '$title · $pid';

  /// 写入一次采样（原地更新缓冲区）
  void ingest(TrafficSample sample) {
    samples.add(sample);
    latestUpload = sample.uploadSpeed;
    latestDownload = sample.downloadSpeed;
  }
}
