import 'dart:ui';

/// 进程曲线配色池。
///
/// 选色原则：色相彼此拉开、在深色背景上对比度足够，且不包含纯红色，
/// 避免与"阈值辅助线"混淆。
abstract final class ProcessPalette {
  static const List<Color> colors = <Color>[
    Color(0xFF4C8DFF), // 蓝
    Color(0xFF00C2A8), // 青绿
    Color(0xFFFF8A3D), // 橙
    Color(0xFFB06BFF), // 紫
    Color(0xFF39C46E), // 绿
    Color(0xFFE0568C), // 玫红
    Color(0xFFF2C230), // 黄
    Color(0xFF00A6D6), // 天蓝
    Color(0xFF8D9BFF), // 靛蓝
    Color(0xFF9ACD32), // 黄绿
    Color(0xFFC97B63), // 棕
    Color(0xFF7FD1F5), // 浅蓝
  ];

  /// 从配色池里取一个当前未被占用的颜色；
  /// 监控进程数超过配色数量时，按索引循环复用。
  static Color pick(Set<Color> used) {
    for (final Color color in colors) {
      if (!used.contains(color)) return color;
    }
    return colors[used.length % colors.length];
  }
}
