import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/rule_config.dart';

/// 当前生效的自动化规则。
///
/// 面板上的"草稿"由 UI 自己持有，点"执行"后才写入这里并置为启用；
/// 规则引擎（Timer）监听这个 Provider 的变化并重新计时。
class RuleNotifier extends Notifier<RuleConfig> {
  @override
  RuleConfig build() => RuleConfig.initial;

  /// 保存并激活规则
  void activate(RuleConfig rule) {
    state = rule.copyWith(enabled: true);
  }

  void disable() {
    if (!state.enabled) return;
    state = state.copyWith(enabled: false);
  }
}

final NotifierProvider<RuleNotifier, RuleConfig> ruleProvider =
    NotifierProvider<RuleNotifier, RuleConfig>(RuleNotifier.new);
