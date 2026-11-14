<p align="center">
  <img src="assets/images/app_icon.png" width="112" alt="ProcFlow 图标" />
</p>

<h1 align="center">ProcFlow</h1>

<p align="center">
  Windows 端进程网络流量实时监控工具
</p>

<p align="center">
  实时流量曲线 · 多进程拖选 · 自动化规则 · 明暗主题
</p>

Flutter 负责界面与实时图表，C++ 原生层通过 IP Helper API 采集 TCP、通过 ETW 采集 UDP 的每进程收发速率，界面以 Material 3 呈现，并支持自动化规则（告警 / 结束进程 / 关机 / 休眠）。

## 下载

安装包见 [Releases](https://github.com/FrandreJoestar/ProcFlow/releases/latest)（Windows x64 MSI）。

## 功能

- **进程列表**：展示所有运行中的进程（Toolhelp 快照全量枚举），显示软件名（任务管理器同款 `FileDescription`）、原始进程名与 PID；支持模糊搜索，以及长按拖动区间多选、反向拖回反选、拖到上下边缘自动滚动。
- **监控列表**：多选添加 / 移除进程，每个进程分配唯一曲线颜色；与进程列表一致支持长按拖动多选与边缘自动滚动。
- **实时流量图**：`fl_chart` 多曲线折线图，最近 60 秒滑动窗口，Y 轴在 B/s、KB/s、MB/s 间自动切换，带虚线网格与阈值实线。
- **自动化规则**：M3E 风格下拉框配置“指标 + 低于/高于 + 阈值 + 持续时长”，支持弹窗警告、结束进程、关机、休眠、仅记录日志。
- **明暗主题**：默认浅色，AppBar 右侧一键切换深色模式。
- **性能优化**：固定容量环形缓冲、关闭图表动画、隐藏数据点、`RepaintBoundary` 隔离重绘。

## 技术栈

| 层 | 技术 |
|---|---|
| UI | Flutter 3.50 / Material 3 / `fl_chart` / `m3e_dropdown_menu` |
| 状态管理 | Riverpod 3 |
| 原生层 | C++17、IP Helper API（`GetExtendedTcpTable`、`GetPerTcpConnectionEStats`）、ETW（`Microsoft-Windows-Kernel-Network`） |
| 通信 | MethodChannel `procflow/native` + EventChannel `traffic_stream` |
| 字体 | 霞鹜文楷 LXGW WenKai（SIL OFL 1.1） |

## 数据流

```
C++ 消息窗口 (WM_TIMER, 1s)
  ├─ 枚举 TCP 连接 → 读取 ESTATS 累计字节
  └─ ETW 会话（NT Kernel Logger）→ UDP 收发事件累计字节
        └─ 按 PID 合并 → 求差值/时间 = 速率
        │ EventChannel: [{pid, rx_speed, tx_speed}]
        ▼
AppRuntime ──► monitorListProvider.ingest() ──► fl_chart 曲线
        └────► ruleEngineProvider.evaluate() ──► 弹窗 / 结束进程 / 关机 / 休眠
```

进程快照每 5 秒通过 `get_processes` 拉取一次，写入左侧进程列表。

## 目录结构

```
lib/
├─ core/                 # 主题、格式化、全局配置
├─ data/
│  ├─ models/            # ProcessInfo / MonitorItem / RuleConfig / 采样与环形缓冲
│  └─ services/          # 原生通道封装 / Mock 数据源
└─ presentation/
   ├─ app_runtime.dart   # 进程刷新 + 流量订阅
   ├─ providers/         # Riverpod 状态层
   ├─ pages/             # 主界面
   └─ widgets/           # 控制区、图表、公共卡片
windows/runner/
├─ procflow_channel.*    # 原生通道与 ESTATS 采样
├─ etw_traffic_monitor.* # ETW 会话采集 UDP 收发字节
├─ main.cpp              # 默认窗口 1600×1000，居中启动
└─ runner.exe.manifest   # 管理员权限清单
```

## 原生通道协议

MethodChannel `procflow/native`：

| 方法 | 参数 | 返回 |
|---|---|---|
| `get_processes` | — | `[{pid, name, display_name}]` |
| `set_monitored_pids` | `{pids: [int]}` | `bool` |
| `kill_process` | `{pid: int}` | `bool` |
| `shutdown_system` | — | `bool` |
| `hibernate_system` | — | `bool` |

EventChannel `traffic_stream` 每秒推送：

```json
[{ "pid": 1234, "rx_speed": 10240, "tx_speed": 2048 }]
```

速率单位为字节/秒，`rx_speed` 对应下载，`tx_speed` 对应上传。

## 构建与运行

### 环境要求

- Windows 10 1709+ 或 Windows 11（`TcpConnectionEstatsData` 依赖该版本）
- Flutter 3.50+（Dart 3.14）
- Visual Studio 2022，安装“使用 C++ 的桌面开发”工作负载
- **管理员权限**：ESTATS 采集、结束进程、关机、休眠都需要

### 运行

```powershell
git clone https://github.com/FrandreJoestar/ProcFlow.git
cd ProcFlow
flutter pub get
# 必须以管理员身份打开终端 / IDE，否则无法启动（manifest 要求提升权限）
flutter run -d windows
```

或直接以管理员身份运行已构建的程序：

```text
build\windows\x64\runner\Debug\procflow.exe
```

发布构建：

```powershell
flutter build windows --release
```

### 调试 UI（不启动原生采样）

将 [app_config.dart](lib/core/app_config.dart) 中的 `useMockData` 改为 `true`，即可使用内置模拟进程和随机流量，适合纯 UI 调试。

## 已知限制

- TCP 依赖 ESTATS，UDP 依赖 ETW 的 NT Kernel Logger 会话；若该会话已被其他工具（如 Process Monitor）占用，程序会自动退化为只统计 TCP。
- 部分连接（如 TIME_WAIT、驱动不支持）可能读到 0。
- 程序必须管理员运行；`requireAdministrator` 清单已内置，启动时会弹 UAC。
- 休眠需要系统已启用：`powercfg /hibernate on`。
- “关机 / 休眠”规则会直接作用于系统，请谨慎配置持续时间与阈值。

## 版权

Copyright © 2026 FrandreJoestar. All rights reserved.

第三方资源：霞鹜文楷 LXGW WenKai，依据 [SIL Open Font License 1.1](https://github.com/lxgw/LxgwWenKai) 使用。
