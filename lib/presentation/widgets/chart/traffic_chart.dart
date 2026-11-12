import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_config.dart';
import '../../../core/formatters.dart';
import '../../../data/models/monitor_item.dart';
import '../../../data/models/rule_config.dart';
import '../../../data/models/traffic_sample.dart';
import '../../providers/monitor_list_provider.dart';
import '../../providers/rule_provider.dart';
import '../common/panel_card.dart';

/// 底部实时流量折线图。
///
/// 设计要点：
/// 1. 曲线数量 = 监控列表数量，增删监控项后自动增删曲线；
/// 2. X 轴窗口固定为最近 N 秒并随时间滚动；
/// 3. Y 轴上界由「窗口内最大流量」与「规则阈值」共同决定；
/// 4. 关闭动画、关闭数据点、环形缓冲裁剪，保证高频刷新不抖动。
class TrafficChartPanel extends ConsumerWidget {
  const TrafficChartPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只监听图表需要的两份状态
    final MonitorListState state = ref.watch(monitorListProvider);
    final RuleConfig rule = ref.watch(ruleProvider);
    final List<MonitorItem> items = state.list;
    final ThemeData theme = Theme.of(context);

    return PanelCard(
      title: '实时流量',
      subtitle: '最近 ${AppConfig.chartWindow.inSeconds} 秒',
      trailing: Text(
        items.isEmpty ? '暂无监控' : '${items.length} 条曲线',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (items.isNotEmpty) ...<Widget>[
            _Legend(items: items),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  // 图表每秒重绘，用 RepaintBoundary 把重绘范围限制在图表内部
                  child: RepaintBoundary(
                    child: _LineChartView(items: items, rule: rule),
                  ),
                ),
                if (items.isEmpty)
                  const Positioned.fill(
                    child: IgnorePointer(child: _ChartEmptyHint()),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条曲线在本次构建中的快照：进程元数据 + 窗口内可见点。
class _Series {
  const _Series({required this.item, required this.spots});

  final MonitorItem item;
  final List<FlSpot> spots;
}

class _LineChartView extends StatelessWidget {
  const _LineChartView({required this.items, required this.rule});

  final List<MonitorItem> items;
  final RuleConfig rule;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // X 轴：以"当前时间"为右边界，向左保留一个窗口
    final double now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final double minX = now - AppConfig.chartWindow.inSeconds;
    var maxX = now;

    final List<_Series> series = <_Series>[];
    var rawMax = 0.0;

    for (final MonitorItem item in items) {
      final List<TrafficSample> samples = item.samples.toList();
      final List<FlSpot> spots = <FlSpot>[];

      for (final TrafficSample sample in samples) {
        // 环形缓冲里可能残留刚滑出窗口的点，这里再兜底裁一次
        if (sample.x < minX) continue;
        spots.add(FlSpot(sample.x, sample.totalSpeed));
        rawMax = math.max(rawMax, sample.totalSpeed);
        if (sample.x > maxX) maxX = sample.x;
      }

      series.add(_Series(item: item, spots: spots));
    }

    // 阈值线也要落在 Y 轴范围内，否则会被裁掉
    final double threshold = rule.thresholdBytesPerSecond;
    final double range = math.max(rawMax, threshold) * 1.15;
    final ({double max, double interval}) yAxis = _niceYAxis(range);
    final double xInterval = AppConfig.chartWindow.inSeconds / 4;

    // 没有数据点的曲线不加入 lineBarsData，减少无意义的绘制
    final List<_Series> visibleSeries = series
        .where((_Series s) => s.spots.isNotEmpty)
        .toList(growable: false);

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: yAxis.max,
        // 关键：动画时长置零，否则每秒数据更新会触发补间动画导致抖动
        clipData: const FlClipData.all(),
        lineBarsData: <LineChartBarData>[
          for (final _Series s in visibleSeries) _buildBar(s),
        ],
        extraLinesData: ExtraLinesData(
          horizontalLines: <HorizontalLine>[
            if (threshold > 0)
              HorizontalLine(
                y: threshold,
                color: scheme.error,
                strokeWidth: 1.4,
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.only(right: 4, bottom: 2),
                  style: TextStyle(fontSize: 10, color: scheme.error),
                  labelResolver: (HorizontalLine line) =>
                      '阈值 ${formatRate(line.y)}',
                ),
              ),
          ],
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: yAxis.interval,
          verticalInterval: xInterval,
          getDrawingHorizontalLine: (double value) => FlLine(
            color: scheme.outlineVariant,
            strokeWidth: 1,
            dashArray: const <int>[4, 4],
          ),
          getDrawingVerticalLine: (double value) => FlLine(
            color: scheme.outlineVariant,
            strokeWidth: 1,
            dashArray: const <int>[4, 4],
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 62,
              interval: yAxis.interval,
              getTitlesWidget: (double value, TitleMeta meta) {
                return SideTitleWidget(
                  meta: meta,
                  space: 8,
                  child: Text(
                    // 单位随量级自动在 B/s、KB/s、MB/s 之间切换
                    value == 0 ? '0' : formatRate(value),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: xInterval,
              getTitlesWidget: (double value, TitleMeta meta) {
                return SideTitleWidget(
                  meta: meta,
                  space: 6,
                  child: Text(
                    _formatClock(value),
                    style: TextStyle(
                      fontSize: 9.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: visibleSeries.isNotEmpty,
          touchSpotThreshold: 16,
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 240,
            getTooltipColor: (LineBarSpot spot) =>
                scheme.surfaceContainerHighest,
            getTooltipItems: (List<LineBarSpot> touchedSpots) {
              return touchedSpots.map((LineBarSpot spot) {
                final int index = spot.barIndex;
                if (index < 0 || index >= visibleSeries.length) return null;
                final MonitorItem item = visibleSeries[index].item;
                return LineTooltipItem(
                  '${item.title}  ${formatRate(spot.y)}',
                  TextStyle(fontSize: 11, height: 1.5, color: item.color),
                );
              }).toList();
            },
          ),
        ),
      ),
      // 动画时长必须为 0：高频数据下动画会让曲线"追不上"真实值
      duration: Duration.zero,
    );
  }

  LineChartBarData _buildBar(_Series s) {
    final Color color = s.item.color;
    return LineChartBarData(
      spots: s.spots,
      color: color,
      barWidth: 2,
      isCurved: true,
      curveSmoothness: 0.22,
      // 防止平滑曲线过冲，出现低于 0 的假象
      preventCurveOverShooting: true,
      isStrokeCapRound: true,
      // 每秒一个点，画圆点既无意义又拖慢渲染
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }

  /// 把 Y 轴量程规整成 1 / 2 / 5 × 10^n 的"整齐"刻度，
  /// 避免出现 3.7 MB/s 这种难读的上界。
  ({double max, double interval}) _niceYAxis(double range) {
    if (range <= 0) return (max: 1024, interval: 256);

    final double target = range / 4;
    final double magnitude = math
        .pow(10, (math.log(target) / math.ln10).floor())
        .toDouble();
    final double residual = target / magnitude;
    final double step =
        (residual <= 1
            ? 1
            : residual <= 2
            ? 2
            : residual <= 5
            ? 5
            : 10) *
        magnitude;

    final double maxY = (range / step).ceilToDouble() * step;
    return (max: maxY, interval: step);
  }

  String _formatClock(double epochSeconds) {
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(
      (epochSeconds * 1000).round(),
    );
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// 图例：颜色与曲线一一对应，可横向滚动以避免挤压图表
class _Legend extends StatelessWidget {
  const _Legend({required this.items});

  final List<MonitorItem> items;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 18,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (final MonitorItem item in items)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: item.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      item.legendLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChartEmptyHint extends StatelessWidget {
  const _ChartEmptyHint();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        '在左侧添加进程后，这里会绘制实时曲线',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
