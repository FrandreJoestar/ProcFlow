import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_dropdown_menu/m3e_dropdown_menu.dart';

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
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: _RuleDropdown<RuleMetric>(
                    label: '指标',
                    values: RuleMetric.values,
                    labelOf: (RuleMetric metric) => metric.label,
                    value: _metric,
                    onChanged: (RuleMetric value) =>
                        setState(() => _metric = value),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _RuleDropdown<RuleComparison>(
                    label: '条件',
                    values: RuleComparison.values,
                    labelOf: (RuleComparison comparison) => comparison.label,
                    value: _comparison,
                    onChanged: (RuleComparison value) =>
                        setState(() => _comparison = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
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
                  width: 104,
                  child: _RuleDropdown<_RateUnit>(
                    label: '单位',
                    values: _RateUnit.values,
                    labelOf: (_RateUnit unit) => unit.label,
                    value: _rateUnit,
                    onChanged: (_RateUnit value) =>
                        setState(() => _rateUnit = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
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
                  width: 104,
                  child: _RuleDropdown<_TimeUnit>(
                    label: '单位',
                    values: _TimeUnit.values,
                    labelOf: (_TimeUnit unit) => unit.label,
                    value: _timeUnit,
                    onChanged: (_TimeUnit value) =>
                        setState(() => _timeUnit = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _RuleDropdown<RuleAction>(
              label: '执行动作',
              values: RuleAction.values,
              labelOf: (RuleAction action) => action.label,
              value: _action,
              onChanged: (RuleAction value) => setState(() => _action = value),
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

/// 规则面板的 M3E 风格下拉框。
///
/// 只替换外观：仍然单选、选中后立即回调，不提供搜索、清空与多选。
class _RuleDropdown<T> extends StatefulWidget {
  const _RuleDropdown({
    required this.label,
    required this.values,
    required this.labelOf,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<T> values;
  final String Function(T value) labelOf;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  State<_RuleDropdown<T>> createState() => _RuleDropdownState<T>();
}

class _RuleDropdownState<T> extends State<_RuleDropdown<T>> {
  /// 与示例一致的弹簧参数
  static final M3EMotion _motion = M3EMotion.custom(
    stiffness: 500.0,
    damping: 0.6,
  );

  final M3EDropdownController<T> _controller = M3EDropdownController<T>();

  /// items 必须保持同一实例：组件在 didUpdateWidget 中检测到新列表会重设
  /// 选中项并回调，若不慎在 build 中重建，等于在构建期触发 setState。
  late final List<M3EDropdownItem<T>> _items = <M3EDropdownItem<T>>[
    for (final T value in widget.values)
      M3EDropdownItem<T>(
        label: widget.labelOf(value),
        value: value,
        selected: value == widget.value,
      ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSelection(List<M3EDropdownItem<T>> selected) {
    if (selected.isEmpty) {
      // 单选字段必须始终有值：用户点掉当前项时把它恢复回来
      _controller.selectWhere(
        (M3EDropdownItem<T> item) => item.value == widget.value,
      );
      return;
    }
    widget.onChanged(selected.first.value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? fieldText = theme.textTheme.bodyMedium;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          widget.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        M3EDropdownMenu<T>(
          items: _items,
          controller: _controller,
          singleSelect: true,
          searchEnabled: false,
          showChipAnimation: false,
          containerRadius: 28.0,
          haptic: M3EHapticFeedback.light,
          openMotion: _motion,
          closeMotion: _motion,
          fieldStyle: M3EDropdownFieldStyle(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            selectedTextStyle: fieldText,
            hintStyle: fieldText?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          dropdownStyle: const M3EDropdownStyle(
            elevation: 4.0,
            maxHeight: 350.0,
            marginTop: 4.0,
            expandDirection: ExpandDirection.auto,
            contentPadding: EdgeInsets.all(8.0),
          ),
          itemStyle: M3EDropdownItemStyle(
            outerRadius: 18.0,
            innerRadius: 6.0,
            itemGap: 3.0,
            itemPadding: const EdgeInsets.all(12.0),
            textStyle: fieldText,
            selectedTextStyle: fieldText,
            selectedIcon: const Icon(Icons.check_rounded, size: 18),
          ),
          onSelectionChanged: _handleSelection,
        ),
      ],
    );
  }
}
