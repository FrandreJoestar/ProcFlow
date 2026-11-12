#ifndef RUNNER_PROC_FLOW_CHANNEL_H_
#define RUNNER_PROC_FLOW_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <unordered_map>

#include "etw_traffic_monitor.h"

// 原生数据桥。
//
// - MethodChannel "procflow/native"：
//     get_processes        返回所有运行中的进程 [{pid, name, display_name}, ...]
//     set_monitored_pids   参数 {pids: [int]}，只采集这些进程
//     kill_process         参数 {pid: int}
// - EventChannel "traffic_stream"：
//     每秒推送 [{pid, rx_speed, tx_speed}, ...]，单位为字节/秒。
//
// 所有回调都运行在 Flutter 平台线程上；采样也由该线程的消息循环
// （消息窗口 + WM_TIMER）驱动，因此无需加锁，也没有后台线程的生命周期问题。
class ProcFlowChannel {
 public:
  explicit ProcFlowChannel(flutter::BinaryMessenger* messenger);
  ~ProcFlowChannel();

  ProcFlowChannel(const ProcFlowChannel&) = delete;
  ProcFlowChannel& operator=(const ProcFlowChannel&) = delete;

 private:
  struct ByteTotals {
    uint64_t rx = 0;
    uint64_t tx = 0;
  };

  static LRESULT CALLBACK WindowProc(HWND window,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void HandleGetProcesses(flutter::MethodResult<flutter::EncodableValue>& result);
  void HandleSetMonitoredPids(const flutter::EncodableValue* arguments,
                              flutter::MethodResult<flutter::EncodableValue>& result);
  void HandleKillProcess(const flutter::EncodableValue* arguments,
                         flutter::MethodResult<flutter::EncodableValue>& result);

  void StartSampling();
  void StopSampling();
  void OnTimer();

  // 计算本帧各监控进程的瞬时速率
  flutter::EncodableList BuildTrafficFrame();

  // 汇总所有 TCP 连接的累计收发字节数（按 PID 分组）
  void CollectConnectionTotals(
      std::unordered_map<DWORD, ByteTotals>* totals) const;
  void CollectIpv4Totals(
      std::unordered_map<DWORD, ByteTotals>* totals) const;
  void CollectIpv6Totals(
      std::unordered_map<DWORD, ByteTotals>* totals) const;

  /// 取进程的原始 exe 名与软件名（exe 版本信息中的 FileDescription）
  void QueryProcessNames(DWORD pid,
                         std::string* exe_name,
                         std::string* display_name) const;
  std::string QueryFileDescription(const std::wstring& path) const;

  void HandleShutdownSystem(
      flutter::MethodResult<flutter::EncodableValue>& result);
  void HandleHibernateSystem(
      flutter::MethodResult<flutter::EncodableValue>& result);

  /// 为当前进程启用 SeShutdownPrivilege（关机/休眠必需）
  bool EnableShutdownPrivilege();

  HWND window_ = nullptr;
  UINT_PTR timer_id_ = 0;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  // 只在平台线程读写
  std::set<DWORD> monitored_pids_;
  std::unordered_map<DWORD, ByteTotals> last_totals_;
  std::chrono::steady_clock::time_point last_sample_time_{};
  bool has_last_sample_ = false;

  // UDP 累计字节来自 ETW（内部有独立消费线程，读写已加锁）
  EtwTrafficMonitor udp_monitor_;

  // 按 exe 完整路径缓存软件名，避免每次刷新进程列表都读版本资源
  mutable std::unordered_map<std::wstring, std::string> description_cache_;
};

#endif  // RUNNER_PROC_FLOW_CHANNEL_H_
