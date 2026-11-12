import 'traffic_sample.dart';

/// 定长环形缓冲区：只保留最近 [capacity] 个采样点。
///
/// 相比 `List.removeAt(0)`，这里用「定长数组 + 头指针」实现：
/// - 写入是 O(1)，不会每秒搬移整块内存；
/// - 容量固定，天然防止长时间运行导致的内存增长（OOM）。
class SampleRingBuffer {
  SampleRingBuffer(this.capacity)
    : assert(capacity > 0),
      _slots = List<TrafficSample?>.filled(capacity, null);

  final int capacity;
  final List<TrafficSample?> _slots;

  /// 下一个写入位置
  int _head = 0;
  int _length = 0;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length > 0;

  /// 最新写入的采样点
  TrafficSample? get last =>
      _length == 0 ? null : _slots[(_head - 1 + capacity) % capacity];

  void add(TrafficSample sample) {
    _slots[_head] = sample;
    _head = (_head + 1) % capacity;
    if (_length < capacity) _length++;
  }

  /// 按时间正序导出，供图表直接消费。
  ///
  /// 每次导出都会生成一个新列表，因此调用方不需要关心内部指针；
  /// 单条曲线最多 [capacity] 个点，开销可控。
  List<TrafficSample> toList() {
    if (_length == 0) return const <TrafficSample>[];
    return List<TrafficSample>.generate(
      _length,
      (int i) => _slots[(_head - _length + i) % capacity]!,
      growable: false,
    );
  }

  /// 丢弃早于 [cutoff] 的采样点。
  /// 用于窗口滚动时把"已经滑出可视区"的数据真正释放掉。
  void trimBefore(DateTime cutoff) {
    var removed = 0;
    while (removed < _length) {
      final TrafficSample oldest =
          _slots[(_head - _length + removed) % capacity]!;
      if (!oldest.timestamp.isBefore(cutoff)) break;
      removed++;
    }
    if (removed == 0) return;

    _length -= removed;
    if (_length == 0) _head = 0;
  }

  void clear() {
    _length = 0;
    _head = 0;
  }
}
