import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procflow/app.dart';
import 'package:procflow/data/models/process_info.dart';
import 'package:procflow/data/models/traffic_sample.dart';
import 'package:procflow/data/services/traffic_service.dart';
import 'package:procflow/presentation/providers/monitor_list_provider.dart';
import 'package:procflow/presentation/providers/process_list_provider.dart';
import 'package:procflow/presentation/providers/runtime_providers.dart';

/// 测试替身：不启动真实定时数据，只提供固定的进程快照。
class _FakeTrafficService implements TrafficService {
  _FakeTrafficService(this.processes);

  final List<ProcessInfo> processes;
  final StreamController<Map<int, TrafficSample>> _controller =
      StreamController<Map<int, TrafficSample>>.broadcast();

  @override
  Stream<Map<int, TrafficSample>> frames() => _controller.stream;

  @override
  Future<List<ProcessInfo>> listProcesses() async => processes;

  @override
  Future<void> setMonitoredPids(Set<int> pids) async {}

  @override
  Future<void> killProcess(int pid) async {}

  @override
  Future<void> shutdownSystem() async {}

  @override
  Future<void> hibernateSystem() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

void main() {
  /// 默认窗口为 1600x1000，测试使用相同尺寸避免小窗口下布局溢出
  Future<void> useDesktopSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('控制区默认展示四个面板', (WidgetTester tester) async {
    await useDesktopSurface(tester);
    final _FakeTrafficService service = _FakeTrafficService(
      const <ProcessInfo>[],
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [trafficServiceProvider.overrideWithValue(service)],
        child: const ProcFlowApp(),
      ),
    );
    await tester.pump();

    expect(find.text('进程列表'), findsOneWidget);
    expect(find.text('监控列表'), findsOneWidget);
    expect(find.text('自动化规则'), findsOneWidget);
    expect(find.text('当监控列表'), findsOneWidget);
    expect(find.text('等待进程数据…'), findsOneWidget);

    // 卸载页面，取消 AppRuntime 里的定时器
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('添加进程后绘制曲线，搜索不影响勾选，移除后销毁曲线', (WidgetTester tester) async {
    await useDesktopSurface(tester);
    final _FakeTrafficService service = _FakeTrafficService(const <ProcessInfo>[
      ProcessInfo(pid: 100, name: 'chrome.exe'),
      ProcessInfo(pid: 200, name: 'game.exe'),
    ]);
    addTearDown(service.dispose);

    final ProviderContainer container = ProviderContainer(
      overrides: [trafficServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ProcFlowApp(),
      ),
    );
    // 等待 AppRuntime 完成首次进程快照
    await tester.pump();
    expect(container.read(processListProvider).processes.length, 2);

    container.read(processListProvider.notifier).toggleSelection(100);
    container.read(processListProvider.notifier).toggleSelection(200);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pump();

    expect(container.read(monitorListProvider).length, 2);
    expect(
      container.read(monitorListProvider)[100]?.color,
      isNot(container.read(monitorListProvider)[200]?.color),
    );

    // 搜索只影响可见列表，不影响已添加的监控项
    container.read(processListProvider.notifier).search('chrome');
    await tester.pump();
    expect(container.read(processListProvider).filtered.length, 1);
    expect(container.read(monitorListProvider).length, 2);

    // 写入一帧采样，图表应绘制出两条曲线
    final DateTime now = DateTime.now();
    container.read(monitorListProvider.notifier).ingest(<int, TrafficSample>{
      100: TrafficSample(
        timestamp: now,
        uploadSpeed: 1024,
        downloadSpeed: 2048,
      ),
      200: TrafficSample(
        timestamp: now,
        uploadSpeed: 4096,
        downloadSpeed: 8192,
      ),
    });
    await tester.pump();
    expect(find.text('2 条曲线'), findsOneWidget);

    // 移除后曲线与数据一起销毁
    container.read(monitorSelectionProvider.notifier).toggle(100);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pump();

    expect(container.read(monitorListProvider).length, 1);
    expect(container.read(monitorListProvider).contains(100), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按拖动区间多选，反向拖动取消区间外的行', (WidgetTester tester) async {
    await useDesktopSurface(tester);
    final _FakeTrafficService service = _FakeTrafficService(const <ProcessInfo>[
      ProcessInfo(pid: 100, name: 'procA'),
      ProcessInfo(pid: 200, name: 'procB'),
      ProcessInfo(pid: 300, name: 'procC'),
    ]);
    addTearDown(service.dispose);

    final ProviderContainer container = ProviderContainer(
      overrides: [trafficServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ProcFlowApp(),
      ),
    );
    await tester.pump();

    final Offset rowA = tester.getCenter(find.text('procA'));
    final Offset rowB = tester.getCenter(find.text('procB'));
    final Offset rowC = tester.getCenter(find.text('procC'));

    // 长按第一行，进入拖动多选
    final TestGesture gesture = await tester.startGesture(rowA);
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(processListProvider).selectedPids, <int>{100});

    // 拖到第三行：整段选中
    await gesture.moveTo(rowC);
    await tester.pump();
    expect(container.read(processListProvider).selectedPids, <int>{100, 200, 300});

    // 反向拖回第二行：第三行恢复为拖动前的未选中状态
    await gesture.moveTo(rowB);
    await tester.pump();
    expect(container.read(processListProvider).selectedPids, <int>{100, 200});

    await gesture.up();
    await tester.pump();
    expect(container.read(processListProvider).selectedPids, <int>{100, 200});

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖到列表底部边缘时自动滚动并继续选中', (WidgetTester tester) async {
    await useDesktopSurface(tester);
    final _FakeTrafficService service = _FakeTrafficService(<ProcessInfo>[
      for (int i = 0; i < 30; i++)
        ProcessInfo(pid: 1000 + i, name: 'proc$i'),
    ]);
    addTearDown(service.dispose);

    final ProviderContainer container = ProviderContainer(
      overrides: [trafficServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ProcFlowApp(),
      ),
    );
    await tester.pump();

    final Finder scrollable = find.ancestor(
      of: find.text('proc0'),
      matching: find.byType(Scrollable),
    );
    final Rect viewport = tester.getRect(scrollable);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('proc0')),
    );
    await tester.pump(const Duration(milliseconds: 600));

    // 拖到视口底部边缘之外，触发自动滚动
    await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom + 40));
    await tester.pump(const Duration(milliseconds: 900));

    // 视口内只能放下十几行，能选到第 21 行说明列表确实自动滚动了
    expect(
      container.read(processListProvider).selectedPids.contains(1020),
      isTrue,
    );

    await gesture.up();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
