import 'package:flutter/material.dart';

/// Flutter 原版 Material 3 浅色主题
ThemeData buildLightTheme() => _buildTheme(Brightness.light);

/// Flutter 原版 Material 3 深色主题
ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

ThemeData _buildTheme(Brightness brightness) {
  // 全局统一使用 LXGW WenKai（霞鹜文楷），
  // 中英文出自同一字库，避免系统字体回退造成笔画粗细不一致。
  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: brightness,
    ),
    fontFamily: 'LXGWWenKai',
    fontFamilyFallback: const <String>['Microsoft YaHei UI', 'Segoe UI'],
  );

  // 统一「标题 w600、正文 w400」，避免 500/600 混用造成粗细跳变。
  final TextTheme text = base.textTheme;
  return base.copyWith(
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w400),
      bodyMedium: text.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
      bodySmall: text.bodySmall?.copyWith(fontWeight: FontWeight.w400),
    ),
  );
}
