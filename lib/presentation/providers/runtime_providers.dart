import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../data/services/mock_traffic_service.dart';
import '../../data/services/traffic_service.dart';

/// 数据源选择：Mock 与原生 ETW 插件共用同一接口。
///
/// 接入 C++ 插件后，把 [AppConfig.useMockData] 改为 false 即可。
final Provider<TrafficService> trafficServiceProvider =
    Provider<TrafficService>((Ref ref) {
      final TrafficService service = AppConfig.useMockData
          ? MockTrafficService()
          : NativeTrafficService();

      ref.onDispose(service.dispose);
      return service;
    });
