import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/rule_config.dart';
import '../../providers/rule_provider.dart';
import '../common/panel_card.dart';

/// 阈值单位
enum _RateUnit {
  kb('KB/s', 1024),
  mb('MB/s', 1024 * 1024);

  const _RateUnit(this.label, this.factor);

  final String label;
  final int factor;
}

/// 持续时间单位
enum _TimeUnit {
  second('秒', 1),
  minute('分钟', 60);

  const _TimeUnit(this.label, this.seconds);

  final String label;
  final int seconds;
}

/// 最右侧：自动化规则配置面板。
///
/// 面板内维护"草稿"状态，点击"执行"后才写入 ruleProvider 并生效，
/// 因此用户中途修改下拉框不会影响正在运行的规则。
class RulePanel extends ConsumerStatefulWidget {
  const RulePanel({super.key});

  @override
  ConsumerState<RulePanel> createState() => _RulePanelState();
}

class _RulePanelState extends ConsumerState<RulePanel> {
  late final TextEditingController _thresholdController;
  late final TextEditingController _durationController;

  late RuleMetric _metric;
  late RuleComparison _comparison;
  late RuleAction _action;
  late _RateUnit _rateUnit;
  late _TimeUnit _timeUnit;

  @override
  void initState() {
    super.initState();
    final RuleConfig rule = ref.read(ruleProvider);

    _metric = rule.metric;
    _comparison = rule.comparison;
    _action = rule.action;

    // 用当前生效规则回填草稿，方便用户在其基础上微调
    _rateUnit = rule.thresholdBytesPerSecond >= 1024 * 1024
        ? _RateUnit.mb
        : _RateUnit.kb;
    _thresholdController = TextEditingController(
      text: _formatNumber(rule.thresholdBytesPerSecond / _rateUnit.factor),
    );

    if (rule.duration.inSeconds >= 60 && rule.duration.inSeconds % 60 == 0) {
      _timeUnit = _TimeUnit.minute;
      _durationController = TextEditingController(
        text: '${rule.duration.inMinutes}',
      );
    } else {
      _timeUnit = _TimeUnit.second;
      _durationController = TextEditingController(
        text: '${rule.duration.inSeconds}',
      );
    }
  }

  @override
  void dispose() {
    _thresholdController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  /// 整数不显示 `.0`
  static String _formatNumber(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  void _execute() {
    final double? threshold = double.tryParse(_thresholdController.text.trim());
    if (threshold == null || threshold <= 0) {
      _showMessage('请输入有效的流量阈值');
      return;
    }

    final int? duration = int.tryParse(_durationController.text.trim());
    if (duration == null || duration <= 0) {
      _showMessage('请输入有效的持续时间');
      return;
    }

    final RuleConfig rule = RuleConfig(
      metric: _metric,
      comparison: _comparison,
      thresholdBytesPerSecond: threshold * _rateUnit.factor,
      duration: Duration(seconds: duration * _timeUnit.seconds),
      action: _action,
      enabled: true,
    );

    ref.read(ruleProvider.notifier).activate(rule);
    _showMessage('规则已生效：${rule.summary}');
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(labelText: label, isDense: true);
  }

  @override
  Widget build(BuildContext context) {
    final RuleConfig active = ref.watch(ruleProvider);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return PanelCard(
      title: '自动化规则',
      trailing: _StatusBadge(enabled: active.enabled),
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('当监控列表', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<RuleMetric>(
                    initialValue: _metric,
                    isDense: true,
                    isExpanded: true,
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('指标'),
                    items: <DropdownMenuItem<RuleMetric>>[
                      for (final RuleMetric metric in RuleMetric.values)
                        DropdownMenuItem<RuleMetric>(
                          value: metric,
                          child: Text(metric.label),
                        ),
                    ],
                    onChanged: (RuleMetric? value) {
                      if (value == null) return;
                      setState(() => _metric = value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<RuleComparison>(
                    initialValue: _comparison,
                    isDense: true,
                    isExpanded: true,
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('条件'),
                    items: <DropdownMenuItem<RuleComparison>>[
                      for (final RuleComparison c in RuleComparison.values)
                        DropdownMenuItem<RuleComparison>(
                          value: c,
                          child: Text(c.label),
                        ),
                    ],
                    onChanged: (RuleComparison? value) {
                      if (value == null) return;
                      setState(() => _comparison = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _thresholdController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('阈值'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<_RateUnit>(
                    initialValue: _rateUnit,
                    isDense: true,
                    isExpanded: true,
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('单位'),
                    items: <DropdownMenuItem<_RateUnit>>[
                      for (final _RateUnit unit in _RateUnit.values)
                        DropdownMenuItem<_RateUnit>(
                          value: unit,
                          child: Text(unit.label),
                        ),
                    ],
                    onChanged: (_RateUnit? value) {
                      if (value == null) return;
                      setState(() => _rateUnit = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _durationController,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('持续'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<_TimeUnit>(
                    initialValue: _timeUnit,
                    isDense: true,
                    isExpanded: true,
                    style: theme.textTheme.bodyMedium,
                    decoration: _decoration('单位'),
                    items: <DropdownMenuItem<_TimeUnit>>[
                      for (final _TimeUnit unit in _TimeUnit.values)
                        DropdownMenuItem<_TimeUnit>(
                          value: unit,
                          child: Text(unit.label),
                        ),
                    ],
                    onChanged: (_TimeUnit? value) {
                      if (value == null) return;
                      setState(() => _timeUnit = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<RuleAction>(
              initialValue: _action,
              isDense: true,
              isExpanded: true,
              style: theme.textTheme.bodyMedium,
              decoration: _decoration('执行动作'),
              items: <DropdownMenuItem<RuleAction>>[
                for (final RuleAction action in RuleAction.values)
                  DropdownMenuItem<RuleAction>(
                    value: action,
                    child: Text(action.label),
                  ),
              ],
              onChanged: (RuleAction? value) {
                if (value == null) return;
                setState(() => _action = value);
              },
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 40,
              child: FilledButton.icon(
                onPressed: _execute,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('执行'),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              active.enabled ? '生效中：${active.summary}' : '规则未启用',
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = enabled ? scheme.primary : scheme.outline;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(enabled ? '已启用' : '未启用', style: TextStyle(color: color)),
        ],
      ),
    );
  }
}
