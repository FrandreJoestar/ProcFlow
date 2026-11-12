import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config.dart';
import '../data/models/process_info.dart';
import '../data/models/traffic_sample.dart';
import '../data/services/traffic_service.dart';
import 'providers/monitor_list_provider.dart';
import 'providers/process_list_provider.dart';
import 'providers/rule_engine_provider.dart';
import 'providers/runtime_providers.dart';

/// 应用运行时：负责启动数据管线。
///
/// 1. 定时拉取进程快照，写入 processListProvider；
/// 2. 订阅流量帧，写入监控列表并交给规则引擎判定。
///
/// 放在 UI 之上而不是 Provider 内部，是为了让定时器/订阅的
/// 创建与销毁严格跟随组件生命周期，便于测试和热重载。
class AppRuntime extends ConsumerStatefulWidget {
  const AppRuntime({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppRuntime> createState() => _AppRuntimeState();
}

class _AppRuntimeState extends ConsumerState<AppRuntime> {
  Timer? _processTimer;
  StreamSubscription<Map<int, TrafficSample>>? _trafficSubscription;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final TrafficService service = ref.read(trafficServiceProvider);

    await _refreshProcesses();
    if (!mounted) return;

    // 把当前监控 PID（启动时通常为空）同步给原生层，
    // 之后每次监控列表变化都会通过 build 中的 ref.listen 再次推送
    unawaited(_pushMonitoredPids(ref.read(monitorListProvider).pids.toSet()));

    _processTimer = Timer.periodic(
      AppConfig.processRefreshInterval,
      (_) => _refreshProcesses(),
    );

    _trafficSubscription = service.frames().listen(
      (Map<int, TrafficSample> frame) {
        // 只把监控中的进程写进图表数据
        ref.read(monitorListProvider.notifier).ingest(frame);
        ref.read(ruleEngineProvider.notifier).evaluate(frame);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('流量数据流异常：$error');
      },
    );
  }

  Future<void> _refreshProcesses() async {
    try {
      final List<ProcessInfo> processes = await ref
          .read(trafficServiceProvider)
          .listProcesses();
      if (!mounted) return;
      ref.read(processListProvider.notifier).setProcesses(processes);
    } catch (error) {
      debugPrint('获取进程列表失败：$error');
    }
  }

  Future<void> _pushMonitoredPids(Set<int> pids) async {
    try {
      await ref.read(trafficServiceProvider).setMonitoredPids(pids);
    } catch (error) {
      debugPrint('同步监控 PID 失败：$error');
    }
  }

  @override
  void dispose() {
    _processTimer?.cancel();
    _trafficSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 监控列表增删时，只把 PID 集合推给原生层，
    // 原生层据此决定每秒只采集这些进程的连接
    ref.listen<MonitorListState>(monitorListProvider, (
      MonitorListState? previous,
      MonitorListState next,
    ) {
      unawaited(_pushMonitoredPids(next.pids.toSet()));
    });

    return widget.child;
  }
}
