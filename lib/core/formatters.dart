/// 把字节数格式化成 B / KB / MB / GB 自适应文本。
///
/// 图表 Y 轴与列表里的速率都复用这一套规则，保证单位口径一致。
String formatBytes(double bytes, {int decimals = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes;
  var unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  // 字节级别不显示小数；大于 100 的数值保留小数意义不大
  final text = unitIndex == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(decimals);
  return '$text ${units[unitIndex]}';
}

/// 速率格式化，例如 `1.5 MB/s`。
String formatRate(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';
