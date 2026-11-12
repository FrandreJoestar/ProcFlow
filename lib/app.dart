import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'presentation/app_runtime.dart';
import 'presentation/pages/dashboard_page.dart';
import 'presentation/providers/theme_provider.dart';

class ProcFlowApp extends ConsumerWidget {
  const ProcFlowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ProcFlow · 进程流量监控',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ref.watch(themeModeProvider),
      home: const AppRuntime(child: DashboardPage()),
    );
  }
}
