/// 全局运行参数：集中管理图表窗口、采样频率等魔法数字。
abstract final class AppConfig {
  /// 是否使用模拟数据。
  ///
  /// 当前已接入 C++ 原生实现，因此为 false。
  /// 若只想调试 UI、不启动原生采样，可临时改为 true。
  static const bool useMockData = false;

  /// 进程列表刷新间隔（原生层拉取全量进程快照）
  static const Duration processRefreshInterval = Duration(seconds: 5);

  /// 图表 X 轴可视时间窗口（最近 60 秒）
  static const Duration chartWindow = Duration(seconds: 60);

  /// 原生层推送频率：每秒一帧
  static const Duration sampleInterval = Duration(seconds: 1);

  /// 环形缓冲区容量 = 窗口内点数 + 冗余。
  /// 多留几个点，避免窗口边界上的曲线被过早裁掉而出现"断头"。
  static int get bufferCapacity =>
      chartWindow.inSeconds ~/ sampleInterval.inSeconds + 5;
}
