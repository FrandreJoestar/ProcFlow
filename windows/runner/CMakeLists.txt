cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  # 原生数据桥：进程列表 + 实时流量 EventChannel
  "procflow_channel.cpp"
  # UDP 流量采集（ETW）
  "etw_traffic_monitor.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# 源码包含中文注释：强制 MSVC 以 UTF-8 解析源文件，
# 否则默认按系统代码页（GBK）解析会触发 C4819，并因 /WX 直接编译失败。
if(MSVC)
  target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
  # runner.exe.manifest 已声明 requireAdministrator。
  # 关闭链接器自动生成的 asInvoker 片段，否则两段 manifest
  # 的 level 不一致，mt.exe 会报 c1010001。
  target_link_options(${BINARY_NAME} PRIVATE "/MANIFESTUAC:NO")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# IP Helper API（GetExtendedTcpTable / GetPerTcpConnectionEStats）
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
# Winsock 基础库：MIB_TCPROW / sockaddr 等类型依赖
target_link_libraries(${BINARY_NAME} PRIVATE "ws2_32.lib")
# 电源管理：SetSuspendState（休眠）
target_link_libraries(${BINARY_NAME} PRIVATE "powrprof.lib")
# 读取 exe 版本信息（软件名 FileDescription）
target_link_libraries(${BINARY_NAME} PRIVATE "version.lib")
# ETW 会话控制（StartTrace / OpenTrace / ProcessTrace）
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
