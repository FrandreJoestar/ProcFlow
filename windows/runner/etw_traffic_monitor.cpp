#include "etw_traffic_monitor.h"

#include <cstring>
#include <future>
#include <string>
#include <vector>

namespace {

// NT Kernel Logger 的系统预留名称，只能用这个名字启动内核会话
constexpr wchar_t kSessionName[] = L"NT Kernel Logger";

// Microsoft-Windows-Kernel-Network 提供者
constexpr GUID kKernelNetworkProvider = {
    0x7dd42a49, 0x5329, 0x4832,
    {0x8d, 0xfd, 0x43, 0xd9, 0x79, 0x15, 0x3a, 0x88}};

// UDP 事件 ID（经典 MOF 事件）：
// 30/31 = IPv4 发送/接收，42/43 = IPv6 发送/接收
constexpr USHORT kUdpIpv4Sent = 30;
constexpr USHORT kUdpIpv4Received = 31;
constexpr USHORT kUdpIpv6Sent = 42;
constexpr USHORT kUdpIpv6Received = 43;

// 事件负载前 8 字节固定为 {PID, size}，IPv4/IPv6 布局一致
constexpr ULONG kUdpPayloadMinSize = 8;

void LogError(const char* message, ULONG code) {
  OutputDebugStringA("ProcFlow ETW: ");
  OutputDebugStringA(message);
  OutputDebugStringA(" (");
  OutputDebugStringA(std::to_string(code).c_str());
  OutputDebugStringA(")\n");
}

std::vector<uint8_t> MakePropertiesBuffer() {
  const size_t name_bytes = sizeof(kSessionName);
  std::vector<uint8_t> buffer(sizeof(EVENT_TRACE_PROPERTIES) + name_bytes);
  auto* properties = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(buffer.data());
  properties->Wnode.BufferSize = static_cast<ULONG>(buffer.size());
  properties->Wnode.Flags = WNODE_FLAG_TRACED_GUID;
  properties->Wnode.ClientContext = 1;  // QPC 时间戳
  properties->LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
  properties->EnableFlags = EVENT_TRACE_FLAG_NETWORK_TCPIP;
  properties->FlushTimer = 1;
  properties->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
  properties->LogFileNameOffset = 0;
  return buffer;
}

}  // namespace

EtwTrafficMonitor::~EtwTrafficMonitor() { Stop(); }

bool EtwTrafficMonitor::Start() {
  if (running_.load()) {
    return true;
  }

  std::vector<uint8_t> buffer = MakePropertiesBuffer();
  auto* properties = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(buffer.data());

  const ULONG status =
      StartTraceW(&session_handle_, kSessionName, properties);
  if (status != ERROR_SUCCESS) {
    // ERROR_ALREADY_EXISTS 表示会话被其他工具占用，此时只能退回 TCP-only
    LogError("StartTrace failed", status);
    session_handle_ = 0;
    return false;
  }
  owns_session_ = true;

  ready_promise_ = std::promise<bool>();
  std::future<bool> ready = ready_promise_.get_future();
  thread_ = std::thread(&EtwTrafficMonitor::ConsumeTrace, this);

  bool opened = false;
  if (ready.wait_for(std::chrono::seconds(5)) == std::future_status::ready) {
    opened = ready.get();
  }

  if (!opened) {
    StopSession();
    if (thread_.joinable()) {
      thread_.join();
    }
    return false;
  }

  running_.store(true);
  return true;
}

void EtwTrafficMonitor::Stop() {
  running_.store(false);
  StopSession();
  if (thread_.joinable()) {
    thread_.join();
  }

  std::lock_guard<std::mutex> guard(mutex_);
  totals_.clear();
}

std::unordered_map<DWORD, EtwTrafficMonitor::ByteTotals>
EtwTrafficMonitor::Snapshot() const {
  std::lock_guard<std::mutex> guard(mutex_);
  return totals_;
}

void EtwTrafficMonitor::StopSession() {
  // 只停止自己启动的会话，避免误关其他工具的 NT Kernel Logger
  if (!owns_session_) {
    return;
  }

  std::vector<uint8_t> buffer = MakePropertiesBuffer();
  auto* properties = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(buffer.data());
  const ULONG status =
      ControlTraceW(0, kSessionName, properties, EVENT_TRACE_CONTROL_STOP);
  if (status != ERROR_SUCCESS) {
    LogError("ControlTrace stop failed", status);
  }

  owns_session_ = false;
  session_handle_ = 0;
}

void EtwTrafficMonitor::ConsumeTrace() {
  EVENT_TRACE_LOGFILEW logfile{};
  logfile.LoggerName = const_cast<LPWSTR>(kSessionName);
  logfile.ProcessTraceMode =
      PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
  logfile.EventRecordCallback = &EtwTrafficMonitor::OnEvent;
  logfile.Context = this;

  TRACEHANDLE trace = OpenTraceW(&logfile);
  if (trace == INVALID_PROCESSTRACE_HANDLE) {
    LogError("OpenTrace failed", GetLastError());
    ready_promise_.set_value(false);
    return;
  }

  ready_promise_.set_value(true);

  // 阻塞直到会话被停止（Stop() 里调用 ControlTrace STOP）
  const ULONG status = ProcessTrace(&trace, 1, nullptr, nullptr);
  if (status != ERROR_SUCCESS && status != ERROR_CANCELLED) {
    LogError("ProcessTrace failed", status);
  }
  CloseTrace(trace);
}

VOID WINAPI EtwTrafficMonitor::OnEvent(PEVENT_RECORD record) {
  if (record == nullptr || record->UserContext == nullptr) {
    return;
  }
  auto* self = static_cast<EtwTrafficMonitor*>(record->UserContext);

  // 内核会话里混杂了各种提供者事件，只处理网络事件
  if (!IsEqualGUID(record->EventHeader.ProviderId, kKernelNetworkProvider)) {
    return;
  }
  if (record->UserData == nullptr ||
      record->UserDataLength < kUdpPayloadMinSize) {
    return;
  }

  bool received = false;
  switch (record->EventHeader.EventDescriptor.Id) {
    case kUdpIpv4Sent:
    case kUdpIpv6Sent:
      received = false;
      break;
    case kUdpIpv4Received:
    case kUdpIpv6Received:
      received = true;
      break;
    default:
      // 10/11 是 TCP 事件，已由 IP Helper ESTATS 统计，忽略避免重复计数
      return;
  }

  const auto* payload = static_cast<const uint8_t*>(record->UserData);
  uint32_t pid = 0;
  uint32_t bytes = 0;
  std::memcpy(&pid, payload, sizeof(pid));
  std::memcpy(&bytes, payload + sizeof(pid), sizeof(bytes));
  if (pid == 0 || bytes == 0) {
    return;
  }

  std::lock_guard<std::mutex> guard(self->mutex_);
  ByteTotals& totals = self->totals_[pid];
  if (received) {
    totals.rx += bytes;
  } else {
    totals.tx += bytes;
  }
}
