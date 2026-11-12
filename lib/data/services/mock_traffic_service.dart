import 'dart:async';
import 'dart:math' as math;

import '../../core/app_config.dart';
import '../models/process_info.dart';
import '../models/traffic_sample.dart';
import 'traffic_service.dart';

/// 模拟进程状态：围绕基准速率做随机游走，偶发断流。
class _MockProcess {
  _MockProcess({
    required this.pid,
    required this.name,
    required this.maxDownload,
    required this.uploadRatio,
  }) : download = maxDownload * (0.15 + _seed.nextDouble() * 0.4);

  static final math.Random _seed = math.Random();

  final int pid;
  final String name;

  /// 速率上限，单位 B/s
  final double maxDownload;

  /// 上传速率相对下载速率的比例（多数程序上传远小于下载）
  final double uploadRatio;

  double download;
}

/// 无 C++ 插件时使用的模拟数据源。
///
/// - 进程目录固定，PID 使用 9001 以上的虚构值，避免误杀真实进程；
/// - 每秒生成一帧，速率随机游走并偶发归零，便于演示"低于阈值"类规则；
/// - "结束进程"只把进程从模拟目录移除，不会调用任何系统 API。
class MockTrafficService implements TrafficService {
  static const double _kb = 1024;

  final math.Random _random = math.Random();
  final Set<int> _killed = <int>{};

  late final List<_MockProcess> _processes = <_MockProcess>[
    _MockProcess(
      pid: 9001,
      name: 'chrome.exe',
      maxDownload: 6 * 1024 * _kb,
      uploadRatio: 0.12,
    ),
    _MockProcess(
      pid: 9003,
      name: 'Code.exe',
      maxDownload: 2.5 * 1024 * _kb,
      uploadRatio: 0.08,
    ),
    _MockProcess(
      pid: 9005,
      name: 'msedge.exe',
      maxDownload: 4 * 1024 * _kb,
      uploadRatio: 0.1,
    ),
    _MockProcess(
      pid: 9007,
      name: 'WeChat.exe',
      maxDownload: 1.2 * 1024 * _kb,
      uploadRatio: 0.25,
    ),
    _MockProcess(
      pid: 9009,
      name: 'QQ.exe',
      maxDownload: 1.5 * 1024 * _kb,
      uploadRatio: 0.22,
    ),
    _MockProcess(
      pid: 9011,
      name: 'Spotify.exe',
      maxDownload: 3 * 1024 * _kb,
      uploadRatio: 0.05,
    ),
    _MockProcess(
      pid: 9013,
      name: 'steam.exe',
      maxDownload: 8 * 1024 * _kb,
      uploadRatio: 0.04,
    ),
    _MockProcess(
      pid: 9015,
      name: 'Discord.exe',
      maxDownload: 2 * 1024 * _kb,
      uploadRatio: 0.18,
    ),
    _MockProcess(
      pid: 9017,
      name: 'Telegram.exe',
      maxDownload: 1.8 * 1024 * _kb,
      uploadRatio: 0.2,
    ),
    _MockProcess(
      pid: 9019,
      name: 'node.exe',
      maxDownload: 1 * 1024 * _kb,
      uploadRatio: 0.15,
    ),
    _MockProcess(
      pid: 9021,
      name: 'python.exe',
      maxDownload: 0.8 * 1024 * _kb,
      uploadRatio: 0.12,
    ),
    _MockProcess(
      pid: 9023,
      name: 'idea64.exe',
      maxDownload: 0.6 * 1024 * _kb,
      uploadRatio: 0.06,
    ),
    _MockProcess(
      pid: 9025,
      name: 'Teams.exe',
      maxDownload: 2.2 * 1024 * _kb,
      uploadRatio: 0.3,
    ),
    _MockProcess(
      pid: 9027,
      name: 'OneDrive.exe',
      maxDownload: 3.5 * 1024 * _kb,
      uploadRatio: 0.35,
    ),
    _MockProcess(
      pid: 9029,
      name: 'explorer.exe',
      maxDownload: 0.4 * 1024 * _kb,
      uploadRatio: 0.2,
    ),
    _MockProcess(
      pid: 9031,
      name: 'git.exe',
      maxDownload: 0.5 * 1024 * _kb,
      uploadRatio: 0.1,
    ),
    _MockProcess(
      pid: 9033,
      name: 'Docker Desktop.exe',
      maxDownload: 1.4 * 1024 * _kb,
      uploadRatio: 0.1,
    ),
    _MockProcess(
      pid: 9035,
      name: 'Bilibili.exe',
      maxDownload: 4.5 * 1024 * _kb,
      uploadRatio: 0.03,
    ),
  ];

  @override
  Stream<Map<int, TrafficSample>> frames() {
    return Stream<Map<int, TrafficSample>>.periodic(AppConfig.sampleInterval, (
      _,
    ) {
      final DateTime now = DateTime.now();
      final Map<int, TrafficSample> frame = <int, TrafficSample>{};

      for (final _MockProcess process in _processes) {
        if (_killed.contains(process.pid)) continue;
        final double download = _advance(process);
        frame[process.pid] = TrafficSample(
          timestamp: now,
          uploadSpeed: download * process.uploadRatio,
          downloadSpeed: download,
        );
      }
      return frame;
    });
  }

  /// 随机游走 + 2% 概率断流（用于触发"流量低于阈值"规则）
  double _advance(_MockProcess process) {
    final double delta =
        (_random.nextDouble() - 0.48) * process.maxDownload * 0.25;
    process.download = (process.download + delta).clamp(0, process.maxDownload);

    if (_random.nextDouble() < 0.02) {
      process.download = 0;
    }
    return process.download;
  }

  @override
  Future<List<ProcessInfo>> listProcesses() async {
    final List<ProcessInfo> result = <ProcessInfo>[
      for (final _MockProcess process in _processes)
        if (!_killed.contains(process.pid))
          ProcessInfo(pid: process.pid, name: process.name),
    ];
    result.sort(
      (ProcessInfo a, ProcessInfo b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return result;
  }

  @override
  Future<void> setMonitoredPids(Set<int> pids) async {
    // Mock 会为所有进程生成数据，无需筛选
  }

  @override
  Future<void> killProcess(int pid) async {
    // 模拟结束进程的耗时，但不触碰真实系统进程
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _killed.add(pid);
  }

  @override
  Future<void> shutdownSystem() async {
    // Mock 模式下禁止真的关机
  }

  @override
  Future<void> hibernateSystem() async {
    // Mock 模式下禁止真的休眠
  }

  @override
  void dispose() {
    _killed.clear();
  }
}
