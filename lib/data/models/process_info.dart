import 'package:flutter/foundation.dart';

/// 系统进程的不可变快照（对应左侧进程列表的一行）。
@immutable
class ProcessInfo {
  const ProcessInfo({
    required this.pid,
    required this.name,
    this.displayName = '',
    this.exePath,
  });

  /// 进程 PID，全局唯一，作为列表与图表曲线的标识
  final int pid;

  /// 原始进程名（可执行文件名），例如 `chrome.exe`
  final String name;

  /// 软件名（取自 exe 版本信息 FileDescription），例如 `Google Chrome`。
  /// 系统进程或无法读取版本信息时为空。
  final String displayName;

  /// 可执行文件路径，原生层未提供时为空
  final String? exePath;

  /// 列表主标题：优先显示软件名，退化为进程名
  String get title => displayName.isEmpty ? name : displayName;

  /// 搜索匹配：软件名、进程名或 PID 包含关键字即可
  /// （忽略大小写、忽略首尾空格）。
  bool matchesKeyword(String keyword) {
    final String k = keyword.trim().toLowerCase();
    if (k.isEmpty) return true;
    return title.toLowerCase().contains(k) ||
        name.toLowerCase().contains(k) ||
        pid.toString().contains(k);
  }

  @override
  bool operator ==(Object other) => other is ProcessInfo && other.pid == pid;

  @override
  int get hashCode => pid.hashCode;

  @override
  String toString() => 'ProcessInfo(pid: $pid, name: $name)';
}
