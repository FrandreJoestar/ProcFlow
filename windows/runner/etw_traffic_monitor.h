#ifndef RUNNER_ETW_TRAFFIC_MONITOR_H_
#define RUNNER_ETW_TRAFFIC_MONITOR_H_

#include <windows.h>
#include <evntcons.h>
#include <evntrace.h>

#include <atomic>
#include <cstdint>
#include <future>
#include <mutex>
#include <thread>
#include <unordered_map>

// UDP 流量采集。
//
// IP Helper 的 ESTATS 只能拿到 TCP 连接的累计字节，浏览器走 QUIC（HTTP/3）
// 或游戏、传递优化等 UDP 流量完全统计不到。这里用 ETW 的 NT Kernel Logger
// 会话订阅 "Microsoft-Windows-Kernel-Network" 提供者的 UDP 收发事件，
// 按 PID 累计字节数，再由 ProcFlowChannel 与 TCP 的累计值相加后求速率。
//
// 注意：
// - NT Kernel Logger 是系统预留的单实例会话，若已被其他工具（如 Process Monitor）
//   占用，Start() 会失败，此时调用方应继续使用纯 TCP 采集；
// - ETW 回调运行在独立线程，读取累计值必须经过 Snapshot()。
class EtwTrafficMonitor {
 public:
  struct ByteTotals {
    uint64_t rx = 0;
    uint64_t tx = 0;
  };

  EtwTrafficMonitor() = default;
  ~EtwTrafficMonitor();

  EtwTrafficMonitor(const EtwTrafficMonitor&) = delete;
  EtwTrafficMonitor& operator=(const EtwTrafficMonitor&) = delete;

  // 启动实时会话并等待消费线程就绪；失败返回 false（不影响 TCP 采集）
  bool Start();
  void Stop();

  // 拷贝当前所有进程的累计收发字节数
  std::unordered_map<DWORD, ByteTotals> Snapshot() const;

 private:
  static VOID WINAPI OnEvent(PEVENT_RECORD record);

  void ConsumeTrace();
  void StopSession();

  // 通知 Start()：消费线程已完成 OpenTrace
  std::promise<bool> ready_promise_;

  TRACEHANDLE session_handle_ = 0;
  // 只对 "自己启动的会话" 做停止操作，避免误关别人的 NT Kernel Logger
  bool owns_session_ = false;

  std::thread thread_;
  std::atomic<bool> running_{false};

  mutable std::mutex mutex_;
  std::unordered_map<DWORD, ByteTotals> totals_;
};

#endif  // RUNNER_ETW_TRAFFIC_MONITOR_H_
