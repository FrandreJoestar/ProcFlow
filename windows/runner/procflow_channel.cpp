// 注意：winsock2.h 必须先于 windows.h 引入，否则 MIB_TCPROW /
// MIB_TCP6ROW 等 Winsock 类型不会生效。
#include <winsock2.h>
#include <ws2tcpip.h>

#include "procflow_channel.h"

#include <iphlpapi.h>
#include <powrprof.h>
#include <tcpestats.h>
#include <winver.h>

#include <flutter/event_stream_handler_functions.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <stdio.h>
#include <string.h>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

// 采样间隔：1 秒
constexpr UINT kSampleIntervalMs = 1000;
constexpr UINT_PTR kTimerId = 1;
constexpr wchar_t kWindowClassName[] = L"ProcFlowSamplerMessageWindow";

// 从 MethodChannel 参数里读取 pid，兼容 int32 / int64 两种编码
int64_t ReadPid(const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return 0;
  }
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (args == nullptr) {
    return 0;
  }
  const auto it = args->find(flutter::EncodableValue("pid"));
  if (it == args->end()) {
    return 0;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  return 0;
}

}  // namespace

ProcFlowChannel::ProcFlowChannel(flutter::BinaryMessenger* messenger) {
  // 创建一个消息专用窗口，用 WM_TIMER 在平台线程上驱动采样。
  // 相比后台线程 + EventSink，这种做法不需要加锁，也不会出现
  // sink 被取消后后台线程仍在推送的竞态。
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.lpfnWndProc = &ProcFlowChannel::WindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClassName;

  bool class_ready = false;
  if (RegisterClassExW(&window_class) != 0) {
    class_ready = true;
  } else if (GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
    class_ready = true;
  }

  if (class_ready) {
    window_ = CreateWindowExW(0, kWindowClassName, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, window_class.hInstance,
                              this);
  }

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "procflow/native",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "traffic_stream",
          &flutter::StandardMethodCodec::GetInstance());

  auto stream_handler =
      std::make_unique<flutter::StreamHandlerFunctions<
          flutter::EncodableValue>>(
          // onListen：Dart 开始监听，保存 sink 并启动 1 秒定时器
          [this](
              const flutter::EncodableValue* arguments,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = std::move(events);
            StartSampling();
            return nullptr;
          },
          // onCancel：Dart 取消监听，立刻停止采样并释放 sink
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            StopSampling();
            sink_.reset();
            last_totals_.clear();
            return nullptr;
          });

  event_channel_->SetStreamHandler(std::move(stream_handler));
}

ProcFlowChannel::~ProcFlowChannel() {
  // 先解除事件通道回调，再销毁窗口，保证窗口过程不会访问已释放的对象
  StopSampling();
  sink_.reset();
  event_channel_.reset();
  method_channel_.reset();

  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

LRESULT CALLBACK ProcFlowChannel::WindowProc(HWND window,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(
        window, GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  }

  auto* self = reinterpret_cast<ProcFlowChannel*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));

  if (self != nullptr && message == WM_TIMER && wparam == kTimerId) {
    self->OnTimer();
    return 0;
  }

  return DefWindowProcW(window, message, wparam, lparam);
}

void ProcFlowChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
    const std::string& method = call.method_name();
    if (method == "get_processes") {
      HandleGetProcesses(*result);
      return;
    }
    if (method == "set_monitored_pids") {
      HandleSetMonitoredPids(call.arguments(), *result);
      return;
    }
    if (method == "kill_process") {
      HandleKillProcess(call.arguments(), *result);
      return;
    }
    if (method == "shutdown_system") {
      HandleShutdownSystem(*result);
      return;
    }
    if (method == "hibernate_system") {
      HandleHibernateSystem(*result);
      return;
    }
    result->NotImplemented();
  } catch (const std::exception& error) {
    // C++ 异常绝不能穿过 Channel 回调边界
    result->Error("native_exception", error.what());
  } catch (...) {
    result->Error("native_exception", "unknown native error");
  }
}

void ProcFlowChannel::HandleGetProcesses(
    flutter::MethodResult<flutter::EncodableValue>& result) {
  struct ProcessEntry {
    DWORD pid;
    std::string name;
    std::string display_name;
  };

  std::vector<ProcessEntry> processes;
  for (const DWORD pid : EnumerateConnectedPids()) {
    std::string name;
    std::string display_name;
    QueryProcessNames(pid, &name, &display_name);
    if (name.empty()) {
      name = "PID " + std::to_string(pid);
    }
    processes.push_back({pid, std::move(name), std::move(display_name)});
  }

  // 按"软件名优先"排序，没有软件名时退回 exe 名称
  std::sort(processes.begin(), processes.end(),
            [](const ProcessEntry& a, const ProcessEntry& b) {
              const std::string& a_key =
                  a.display_name.empty() ? a.name : a.display_name;
              const std::string& b_key =
                  b.display_name.empty() ? b.name : b.display_name;
              const int compare =
                  _stricmp(a_key.c_str(), b_key.c_str());
              return compare != 0 ? compare < 0 : a.pid < b.pid;
            });

  flutter::EncodableList list;
  list.reserve(processes.size());
  for (const auto& process : processes) {
    flutter::EncodableMap item;
    item[flutter::EncodableValue("pid")] =
        flutter::EncodableValue(static_cast<int32_t>(process.pid));
    item[flutter::EncodableValue("name")] =
        flutter::EncodableValue(process.name);
    item[flutter::EncodableValue("display_name")] =
        flutter::EncodableValue(process.display_name);
    list.emplace_back(std::move(item));
  }

  result.Success(flutter::EncodableValue(std::move(list)));
}

void ProcFlowChannel::HandleSetMonitoredPids(
    const flutter::EncodableValue* arguments,
    flutter::MethodResult<flutter::EncodableValue>& result) {
  const auto* args = arguments == nullptr
                         ? nullptr
                         : std::get_if<flutter::EncodableMap>(arguments);
  if (args == nullptr) {
    result.Error("bad_args", "set_monitored_pids 需要参数 {pids: [...]}");
    return;
  }

  const auto it = args->find(flutter::EncodableValue("pids"));
  if (it == args->end()) {
    result.Error("bad_args", "缺少 pids 字段");
    return;
  }

  const auto* pid_list = std::get_if<flutter::EncodableList>(&it->second);
  if (pid_list == nullptr) {
    result.Error("bad_args", "pids 必须是整数数组");
    return;
  }

  std::set<DWORD> next_pids;
  for (const auto& value : *pid_list) {
    int64_t pid = 0;
    if (const auto* value32 = std::get_if<int32_t>(&value)) {
      pid = *value32;
    } else if (const auto* value64 = std::get_if<int64_t>(&value)) {
      pid = *value64;
    }
    if (pid > 0) {
      next_pids.insert(static_cast<DWORD>(pid));
    }
  }

  monitored_pids_ = std::move(next_pids);

  // 进程被移出监控后，清理它的累计值，避免 last_totals_ 无限增长
  for (auto last_it = last_totals_.begin(); last_it != last_totals_.end();) {
    if (monitored_pids_.find(last_it->first) == monitored_pids_.end()) {
      last_it = last_totals_.erase(last_it);
    } else {
      ++last_it;
    }
  }

  result.Success(flutter::EncodableValue(true));
}

void ProcFlowChannel::HandleKillProcess(
    const flutter::EncodableValue* arguments,
    flutter::MethodResult<flutter::EncodableValue>& result) {
  const int64_t pid = ReadPid(arguments);
  if (pid <= 0) {
    result.Error("bad_args", "kill_process 需要有效的 pid");
    return;
  }

  // PROCESS_TERMINATE 即可结束进程；结束系统进程仍需要管理员权限
  HANDLE process =
      OpenProcess(PROCESS_TERMINATE, FALSE, static_cast<DWORD>(pid));
  if (process == nullptr) {
    result.Error("open_failed", "无法打开进程，请以管理员身份运行",
                 flutter::EncodableValue(
                     static_cast<int32_t>(GetLastError())));
    return;
  }

  const BOOL terminated = TerminateProcess(process, 1);
  const DWORD last_error = terminated == FALSE ? GetLastError() : ERROR_SUCCESS;
  CloseHandle(process);

  if (terminated == FALSE) {
    result.Error("terminate_failed", "结束进程失败",
                 flutter::EncodableValue(
                     static_cast<int32_t>(last_error)));
    return;
  }

  result.Success(flutter::EncodableValue(true));
}

void ProcFlowChannel::StartSampling() {
  if (window_ == nullptr) {
    return;
  }
  if (timer_id_ == 0) {
    timer_id_ = SetTimer(window_, kTimerId, kSampleIntervalMs, nullptr);
  }
  // 重新开始监听时丢弃旧基线，避免把暂停期间产生的差值算进第一帧
  has_last_sample_ = false;
  last_totals_.clear();
  last_sample_time_ = std::chrono::steady_clock::now();
}

void ProcFlowChannel::StopSampling() {
  if (window_ != nullptr && timer_id_ != 0) {
    KillTimer(window_, timer_id_);
    timer_id_ = 0;
  }
  has_last_sample_ = false;
}

void ProcFlowChannel::OnTimer() {
  try {
    if (!sink_) {
      return;
    }
    sink_->Success(flutter::EncodableValue(BuildTrafficFrame()));
  } catch (const std::exception& error) {
    OutputDebugStringA("ProcFlow OnTimer exception: ");
    OutputDebugStringA(error.what());
    OutputDebugStringA("\n");
  } catch (...) {
    OutputDebugStringA("ProcFlow OnTimer unknown exception\n");
  }
}

flutter::EncodableList ProcFlowChannel::BuildTrafficFrame() {
  const auto now = std::chrono::steady_clock::now();

  std::unordered_map<DWORD, ByteTotals> totals;
  if (!monitored_pids_.empty()) {
    CollectConnectionTotals(&totals);
  }

  double elapsed_seconds = 0.0;
  if (has_last_sample_) {
    elapsed_seconds =
        std::chrono::duration<double>(now - last_sample_time_).count();
  }
  const bool can_diff = has_last_sample_ && elapsed_seconds > 0.0005;

  flutter::EncodableList frame;
  frame.reserve(monitored_pids_.size());

  for (const DWORD pid : monitored_pids_) {
    double rx_speed = 0.0;
    double tx_speed = 0.0;

    if (can_diff) {
      const auto current = totals.find(pid);
      const auto previous = last_totals_.find(pid);
      if (current != totals.end() && previous != last_totals_.end()) {
        // 连接中途关闭会让累计值回退，用 0 兜底而不是产生负速率
        const uint64_t delta_rx =
            current->second.rx >= previous->second.rx
                ? current->second.rx - previous->second.rx
                : 0;
        const uint64_t delta_tx =
            current->second.tx >= previous->second.tx
                ? current->second.tx - previous->second.tx
                : 0;
        rx_speed = static_cast<double>(delta_rx) / elapsed_seconds;
        tx_speed = static_cast<double>(delta_tx) / elapsed_seconds;
      }
    }

    flutter::EncodableMap item;
    item[flutter::EncodableValue("pid")] =
        flutter::EncodableValue(static_cast<int32_t>(pid));
    item[flutter::EncodableValue("rx_speed")] =
        flutter::EncodableValue(rx_speed);
    item[flutter::EncodableValue("tx_speed")] =
        flutter::EncodableValue(tx_speed);
    frame.emplace_back(std::move(item));
  }

  last_totals_ = std::move(totals);
  last_sample_time_ = now;
  has_last_sample_ = true;
  return frame;
}

void ProcFlowChannel::CollectConnectionTotals(
    std::unordered_map<DWORD, ByteTotals>* totals) const {
  CollectIpv4Totals(totals);
  CollectIpv6Totals(totals);
  // 说明：ESTATS 只覆盖 TCP；UDP 连接没有累计字节统计，
  // 若需要统计 UDP 流量，应改用 ETW（后续版本）。
}

void ProcFlowChannel::CollectIpv4Totals(
    std::unordered_map<DWORD, ByteTotals>* totals) const {
  ULONG size = 0;
  DWORD status = GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET,
                                     TCP_TABLE_OWNER_PID_ALL, 0);
  if (status != ERROR_INSUFFICIENT_BUFFER || size == 0) {
    return;
  }

  std::vector<uint8_t> buffer(size);
  auto* table =
      reinterpret_cast<PMIB_TCPTABLE_OWNER_PID>(buffer.data());
  status = GetExtendedTcpTable(buffer.data(), &size, FALSE, AF_INET,
                               TCP_TABLE_OWNER_PID_ALL, 0);
  if (status != NO_ERROR) {
    return;
  }

  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const MIB_TCPROW_OWNER_PID& row = table->table[i];
    if (monitored_pids_.find(row.dwOwningPid) == monitored_pids_.end()) {
      continue;
    }

    MIB_TCPROW connection{};
    connection.dwState = row.dwState;
    connection.dwLocalAddr = row.dwLocalAddr;
    connection.dwLocalPort = row.dwLocalPort;
    connection.dwRemoteAddr = row.dwRemoteAddr;
    connection.dwRemotePort = row.dwRemotePort;

    // 必须先开启 ESTATS Data 采集，否则 Get 会返回全 0
    TCP_ESTATS_DATA_RW_v0 rw{};
    rw.EnableCollection = TRUE;
    SetPerTcpConnectionEStats(
        &connection, TcpConnectionEstatsData,
        reinterpret_cast<PUCHAR>(&rw), 0, sizeof(rw), 0);

    TCP_ESTATS_DATA_ROD_v0 rod{};
    if (GetPerTcpConnectionEStats(
            &connection, TcpConnectionEstatsData,
            nullptr, 0, 0, nullptr, 0, 0,
            reinterpret_cast<PUCHAR>(&rod), 0, sizeof(rod)) == NO_ERROR) {
      ByteTotals& total = (*totals)[row.dwOwningPid];
      total.rx += rod.DataBytesIn;
      total.tx += rod.DataBytesOut;
    }
  }
}

void ProcFlowChannel::CollectIpv6Totals(
    std::unordered_map<DWORD, ByteTotals>* totals) const {
  ULONG size = 0;
  DWORD status = GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET6,
                                     TCP_TABLE_OWNER_PID_ALL, 0);
  if (status != ERROR_INSUFFICIENT_BUFFER || size == 0) {
    return;
  }

  std::vector<uint8_t> buffer(size);
  auto* table =
      reinterpret_cast<PMIB_TCP6TABLE_OWNER_PID>(buffer.data());
  status = GetExtendedTcpTable(buffer.data(), &size, FALSE, AF_INET6,
                               TCP_TABLE_OWNER_PID_ALL, 0);
  if (status != NO_ERROR) {
    return;
  }

  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const MIB_TCP6ROW_OWNER_PID& row = table->table[i];
    if (monitored_pids_.find(row.dwOwningPid) == monitored_pids_.end()) {
      continue;
    }

    MIB_TCP6ROW connection{};
    connection.State = static_cast<MIB_TCP_STATE>(row.dwState);
    std::memcpy(&connection.LocalAddr, row.ucLocalAddr,
                sizeof(connection.LocalAddr));
    connection.dwLocalScopeId = row.dwLocalScopeId;
    connection.dwLocalPort = row.dwLocalPort;
    std::memcpy(&connection.RemoteAddr, row.ucRemoteAddr,
                sizeof(connection.RemoteAddr));
    connection.dwRemoteScopeId = row.dwRemoteScopeId;
    connection.dwRemotePort = row.dwRemotePort;

    TCP_ESTATS_DATA_RW_v0 rw{};
    rw.EnableCollection = TRUE;
    SetPerTcp6ConnectionEStats(
        &connection, TcpConnectionEstatsData,
        reinterpret_cast<PUCHAR>(&rw), 0, sizeof(rw), 0);

    TCP_ESTATS_DATA_ROD_v0 rod{};
    if (GetPerTcp6ConnectionEStats(
            &connection, TcpConnectionEstatsData,
            nullptr, 0, 0, nullptr, 0, 0,
            reinterpret_cast<PUCHAR>(&rod), 0, sizeof(rod)) == NO_ERROR) {
      ByteTotals& total = (*totals)[row.dwOwningPid];
      total.rx += rod.DataBytesIn;
      total.tx += rod.DataBytesOut;
    }
  }
}

std::set<DWORD> ProcFlowChannel::EnumerateConnectedPids() const {
  std::set<DWORD> pids;

  // IPv4
  ULONG size = 0;
  if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET,
                          TCP_TABLE_OWNER_PID_ALL, 0) ==
          ERROR_INSUFFICIENT_BUFFER &&
      size > 0) {
    std::vector<uint8_t> buffer(size);
    auto* table =
        reinterpret_cast<PMIB_TCPTABLE_OWNER_PID>(buffer.data());
    if (GetExtendedTcpTable(buffer.data(), &size, FALSE, AF_INET,
                            TCP_TABLE_OWNER_PID_ALL, 0) == NO_ERROR) {
      for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const DWORD pid = table->table[i].dwOwningPid;
        if (pid != 0) {
          pids.insert(pid);
        }
      }
    }
  }

  // IPv6
  size = 0;
  if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET6,
                          TCP_TABLE_OWNER_PID_ALL, 0) ==
          ERROR_INSUFFICIENT_BUFFER &&
      size > 0) {
    std::vector<uint8_t> buffer(size);
    auto* table =
        reinterpret_cast<PMIB_TCP6TABLE_OWNER_PID>(buffer.data());
    if (GetExtendedTcpTable(buffer.data(), &size, FALSE, AF_INET6,
                            TCP_TABLE_OWNER_PID_ALL, 0) == NO_ERROR) {
      for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        const DWORD pid = table->table[i].dwOwningPid;
        if (pid != 0) {
          pids.insert(pid);
        }
      }
    }
  }

  return pids;
}

void ProcFlowChannel::QueryProcessNames(DWORD pid,
                                        std::string* exe_name,
                                        std::string* display_name) const {
  if (exe_name != nullptr) {
    exe_name->clear();
  }
  if (display_name != nullptr) {
    display_name->clear();
  }

  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return;
  }

  std::vector<wchar_t> path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (QueryFullProcessImageNameW(process, 0, path.data(), &size) != FALSE) {
    const std::wstring full_path(path.data(), size);
    const size_t separator = full_path.find_last_of(L"\\/");
    const std::wstring file_name =
        separator == std::wstring::npos ? full_path
                                        : full_path.substr(separator + 1);

    if (exe_name != nullptr) {
      *exe_name = Utf8FromUtf16(file_name.c_str());
    }
    // 软件名来自 exe 的版本资源，和任务管家里显示的"名称"一致
    if (display_name != nullptr) {
      *display_name = QueryFileDescription(full_path);
    }
  }

  CloseHandle(process);
}

std::string ProcFlowChannel::QueryFileDescription(
    const std::wstring& path) const {
  DWORD version_handle = 0;
  const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &version_handle);
  if (size == 0) {
    return std::string();
  }

  std::vector<BYTE> data(size);
  if (GetFileVersionInfoW(path.c_str(), 0, size, data.data()) == FALSE) {
    return std::string();
  }

  // 版本资源的语言/代码页随软件不同，先遍历 Translation 表
  struct Translation {
    WORD language;
    WORD code_page;
  };

  Translation* translations = nullptr;
  UINT translations_size = 0;
  if (VerQueryValueW(reinterpret_cast<LPCVOID>(data.data()),
                     L"\\VarFileInfo\\Translation",
                     reinterpret_cast<LPVOID*>(&translations),
                     &translations_size) != FALSE &&
      translations != nullptr) {
    const UINT count = translations_size / sizeof(Translation);
    for (UINT i = 0; i < count; ++i) {
      wchar_t key[128];
      swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\FileDescription",
                 translations[i].language, translations[i].code_page);

      wchar_t* value = nullptr;
      UINT value_size = 0;
      if (VerQueryValueW(reinterpret_cast<LPCVOID>(data.data()), key,
                         reinterpret_cast<LPVOID*>(&value),
                         &value_size) != FALSE &&
          value != nullptr && value_size > 0) {
        std::string description = Utf8FromUtf16(value);
        if (!description.empty()) {
          return description;
        }
      }
    }
  }

  // 兜底：英文（美国）代码页 1200
  wchar_t* value = nullptr;
  UINT value_size = 0;
  if (VerQueryValueW(reinterpret_cast<LPCVOID>(data.data()),
                     L"\\StringFileInfo\\040904b0\\FileDescription",
                     reinterpret_cast<LPVOID*>(&value),
                     &value_size) != FALSE &&
      value != nullptr && value_size > 0) {
    return Utf8FromUtf16(value);
  }

  return std::string();
}

bool ProcFlowChannel::EnableShutdownPrivilege() {
  HANDLE token = nullptr;
  if (OpenProcessToken(GetCurrentProcess(),
                       TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                       &token) == FALSE) {
    return false;
  }

  LUID luid{};
  bool enabled = false;
  if (LookupPrivilegeValueW(nullptr, SE_SHUTDOWN_NAME, &luid) != FALSE) {
    TOKEN_PRIVILEGES privileges{};
    privileges.PrivilegeCount = 1;
    privileges.Privileges[0].Luid = luid;
    privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

    enabled = AdjustTokenPrivileges(token, FALSE, &privileges,
                                    sizeof(privileges), nullptr,
                                    nullptr) != FALSE &&
              GetLastError() == ERROR_SUCCESS;
  }

  CloseHandle(token);
  return enabled;
}

void ProcFlowChannel::HandleShutdownSystem(
    flutter::MethodResult<flutter::EncodableValue>& result) {
  if (!EnableShutdownPrivilege()) {
    result.Error("privilege_failed", "无法获取关机权限，请以管理员身份运行");
    return;
  }

  if (ExitWindowsEx(EWX_SHUTDOWN | EWX_FORCEIFHUNG,
                    SHTDN_REASON_MAJOR_OPERATINGSYSTEM |
                        SHTDN_REASON_MINOR_OTHER |
                        SHTDN_REASON_FLAG_PLANNED) == FALSE) {
    result.Error("shutdown_failed", "关机失败",
                 flutter::EncodableValue(
                     static_cast<int32_t>(GetLastError())));
    return;
  }

  result.Success(flutter::EncodableValue(true));
}

void ProcFlowChannel::HandleHibernateSystem(
    flutter::MethodResult<flutter::EncodableValue>& result) {
  if (!EnableShutdownPrivilege()) {
    result.Error("privilege_failed", "无法获取休眠权限，请以管理员身份运行");
    return;
  }

  // SetSuspendState(TRUE, ...) 表示休眠；系统未启用休眠时会失败
  if (SetSuspendState(TRUE, FALSE, FALSE) == FALSE) {
    result.Error("hibernate_failed", "休眠失败，请确认系统已启用休眠");
    return;
  }

  result.Success(flutter::EncodableValue(true));
}
