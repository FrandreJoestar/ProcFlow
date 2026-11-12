import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/rule_config.dart';
import '../providers/rule_engine_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/chart/traffic_chart.dart';
import '../widgets/control_panel/monitor_list_panel.dart';
import '../widgets/control_panel/process_list_panel.dart';
import '../widgets/control_panel/rule_panel.dart';
import '../widgets/control_panel/transfer_buttons.dart';

/// 主界面：AppBar + 顶部控制区 + 底部图表区。
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  /// 防止高频触发时弹窗堆叠
  bool _alertVisible = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<RuleHit?>(ruleEngineProvider, (
      RuleHit? previous,
      RuleHit? next,
    ) {
      if (next == null || next.id == previous?.id) return;
      _handleRuleHit(next);
    });

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            // 应用图标（与 exe 图标一致）
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(width: 10),
            Text('ProcFlow', style: theme.textTheme.titleMedium),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '进程网络流量监控',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: isDark ? '切换到浅色模式' : '切换到深色模式',
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 控制区高度：默认窗口下保证规则面板完整显示；
            // 窗口过矮时优先保证图表至少 220px，规则面板改为内部滚动。
            double topHeight = (constraints.maxHeight * 0.5)
                .clamp(460.0, 540.0)
                .toDouble();
            final double maxTopHeight = constraints.maxHeight - 232;
            if (topHeight > maxTopHeight) {
              topHeight = maxTopHeight;
            }
            if (topHeight < 240) {
              topHeight = 240;
            }

            return Column(
              children: <Widget>[
                SizedBox(
                  height: topHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Expanded(flex: 5, child: ProcessListPanel()),
                      const SizedBox(width: 12),
                      const TransferButtons(),
                      const SizedBox(width: 12),
                      const Expanded(flex: 4, child: MonitorListPanel()),
                      // 监控列表与规则面板之间留出间距，避免贴在一起
                      const SizedBox(width: 12),
                      const Expanded(flex: 5, child: RulePanel()),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Expanded(child: TrafficChartPanel()),
              ],
            );
          },
        ),
      ),
    );
  }

  void _handleRuleHit(RuleHit hit) {
    switch (hit.rule.action) {
      case RuleAction.notify:
        _showAlert(hit);
        break;
      case RuleAction.killProcess:
        _showToast('已结束进程：${hit.processTitle} (${hit.pid})');
        break;
      case RuleAction.shutdown:
        _showToast('已请求关机：${hit.processTitle} (${hit.pid})');
        break;
      case RuleAction.hibernate:
        _showToast('已请求休眠：${hit.processTitle} (${hit.pid})');
        break;
      case RuleAction.logOnly:
        break;
    }
  }

  Future<void> _showAlert(RuleHit hit) async {
    if (_alertVisible || !mounted) return;
    _alertVisible = true;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Row(
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(dialogContext).colorScheme.error,
              ),
              const SizedBox(width: 8),
              const Text('规则触发'),
            ],
          ),
          content: Text(hit.description),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );

    _alertVisible = false;
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }
}
