import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procflow/data/models/process_info.dart';
import 'package:procflow/data/models/rule_config.dart';
import 'package:procflow/data/models/traffic_sample.dart';
import 'package:procflow/presentation/providers/monitor_list_provider.dart';
import 'package:procflow/presentation/providers/rule_engine_provider.dart';
import 'package:procflow/presentation/providers/rule_provider.dart';

void main() {
  test('持续满足阈值后触发一次，恢复后可以再次触发', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(monitorListProvider.notifier).addAll(const <ProcessInfo>[
      ProcessInfo(pid: 7, name: 'demo.exe'),
    ]);
    container
        .read(ruleProvider.notifier)
        .activate(
          const RuleConfig(
            thresholdBytesPerSecond: 1024,
            duration: Duration(seconds: 2),
            action: RuleAction.notify,
          ),
        );

    final RuleEngineNotifier engine = container.read(
      ruleEngineProvider.notifier,
    );
    final DateTime t0 = DateTime(2026, 1, 1, 12);

    TrafficSample low(DateTime t) =>
        TrafficSample(timestamp: t, uploadSpeed: 0, downloadSpeed: 512);
    TrafficSample high(DateTime t) => TrafficSample(
      timestamp: t,
      uploadSpeed: 1024 * 1024,
      downloadSpeed: 1024 * 1024,
    );

    // 刚开始低于阈值：开始计时，但不触发
    engine.evaluate(<int, TrafficSample>{7: low(t0)});
    expect(container.read(ruleEngineProvider), isNull);

    // 持续满 2 秒：触发
    engine.evaluate(<int, TrafficSample>{
      7: low(t0.add(const Duration(seconds: 2))),
    });
    final RuleHit? first = container.read(ruleEngineProvider);
    expect(first, isNotNull);
    expect(first!.pid, 7);

    // 条件持续满足时不重复告警
    engine.evaluate(<int, TrafficSample>{
      7: low(t0.add(const Duration(seconds: 3))),
    });
    expect(container.read(ruleEngineProvider)!.id, first.id);

    // 恢复 → 重新计时 → 再次触发一个新的命中事件
    engine.evaluate(<int, TrafficSample>{
      7: high(t0.add(const Duration(seconds: 4))),
    });
    engine.evaluate(<int, TrafficSample>{
      7: low(t0.add(const Duration(seconds: 5))),
    });
    engine.evaluate(<int, TrafficSample>{
      7: low(t0.add(const Duration(seconds: 7))),
    });
    expect(container.read(ruleEngineProvider)!.id, isNot(first.id));
  });
}
