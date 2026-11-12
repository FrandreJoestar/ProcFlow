import 'dart:async';

import 'package:flutter/services.dart';

import '../models/process_info.dart';
import '../models/traffic_sample.dart';

/// 数据源抽象：Mock 实现与原生实现共享同一套上层逻辑。
abstract interface class TrafficService {
  /// 流量帧流：每秒一帧，key 为 PID。
  Stream<Map<int, TrafficSample>> frames();

  /// 拉取当前系统进程快照
  Future<List<ProcessInfo>> listProcesses();

  /// 告诉原生层需要采集哪些进程（减少内核调用开销）
  Future<void> setMonitoredPids(Set<int> pids);

  /// 结束指定进程（需要管理员权限）
  Future<void> killProcess(int pid);

  /// 关机（需要管理员权限）
  Future<void> shutdownSystem();

  /// 休眠（需要管理员权限，且系统需启用休眠）
  Future<void> hibernateSystem();

  /// 释放底层资源（订阅由调用方取消）
  void dispose();
}

/// 基于 runner 内 C++ 实现的原生数据源。
///
/// 通道约定（见 windows/runner/procflow_channel.cpp）：
/// - MethodChannel `procflow/native`
///     `get_processes` → `[{pid, name}, ...]`
///     `set_monitored_pids` ← `{pids: [int]}`
///     `kill_process` ← `{pid: int}`
/// - EventChannel `traffic_stream` → `[{pid, rx_speed, tx_speed}, ...]`
///   速率为字节/秒，rx 对应下载，tx 对应上传。
class NativeTrafficService implements TrafficService {
  static const MethodChannel _methodChannel = MethodChannel('procflow/native');
  static const EventChannel _eventChannel = EventChannel('traffic_stream');

  @override
  Stream<Map<int, TrafficSample>> frames() {
    return _eventChannel.receiveBroadcastStream().map(_parseFrame);
  }

  @override
  Future<List<ProcessInfo>> listProcesses() async {
    final List<dynamic>? raw = await _methodChannel.invokeListMethod<dynamic>(
      'get_processes',
    );
    if (raw == null) return const <ProcessInfo>[];

    return <ProcessInfo>[
      for (final dynamic item in raw)
        if (item is Map)
          ProcessInfo(
            pid: (item['pid'] as num?)?.toInt() ?? -1,
            // 兼容旧版字段名 processName
            name:
                item['name'] as String? ??
                item['processName'] as String? ??
                'unknown',
            displayName: item['display_name'] as String? ?? '',
            exePath: item['exePath'] as String?,
          ),
    ].where((ProcessInfo p) => p.pid >= 0).toList(growable: false);
  }

  @override
  Future<void> setMonitoredPids(Set<int> pids) {
    return _methodChannel.invokeMethod<void>(
      'set_monitored_pids',
      <String, dynamic>{'pids': pids.toList(growable: false)},
    );
  }

  @override
  Future<void> killProcess(int pid) {
    return _methodChannel.invokeMethod<void>('kill_process', <String, dynamic>{
      'pid': pid,
    });
  }

  @override
  Future<void> shutdownSystem() {
    return _methodChannel.invokeMethod<void>('shutdown_system');
  }

  @override
  Future<void> hibernateSystem() {
    return _methodChannel.invokeMethod<void>('hibernate_system');
  }

  @override
  void dispose() {}

  Map<int, TrafficSample> _parseFrame(dynamic event) {
    if (event is! List) return const <int, TrafficSample>{};

    // 同一帧内所有采样点共用同一个时间戳，保证 X 轴对齐
    final DateTime now = DateTime.now();
    final Map<int, TrafficSample> frame = <int, TrafficSample>{};

    for (final dynamic item in event) {
      if (item is! Map) continue;
      final int? pid = (item['pid'] as num?)?.toInt();
      if (pid == null) continue;

      frame[pid] = TrafficSample(
        timestamp: now,
        // 原生字段：rx_speed=下载，tx_speed=上传；兼容旧字段名
        downloadSpeed:
            (item['rx_speed'] as num?)?.toDouble() ??
            (item['downloadSpeed'] as num?)?.toDouble() ??
            0,
        uploadSpeed:
            (item['tx_speed'] as num?)?.toDouble() ??
            (item['uploadSpeed'] as num?)?.toDouble() ??
            0,
      );
    }
    return frame;
  }
}
