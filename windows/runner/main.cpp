#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // 默认窗口尺寸：1600 x 1000（逻辑像素），保证四个控制面板与图表
  // 不用滚动就能完整显示。按当前 DPI 换算后若超出屏幕，则自动收敛。
  const double dpi_scale = static_cast<double>(GetDpiForSystem()) / 96.0;
  const int screen_width =
      static_cast<int>(GetSystemMetrics(SM_CXSCREEN) / dpi_scale);
  const int screen_height =
      static_cast<int>(GetSystemMetrics(SM_CYSCREEN) / dpi_scale);

  const int window_width = std::min(1600, screen_width - 80);
  const int window_height = std::min(1000, screen_height - 100);

  // 屏幕正中打开
  Win32Window::Point origin(
      static_cast<unsigned int>((screen_width - window_width) / 2),
      static_cast<unsigned int>((screen_height - window_height) / 2));
  Win32Window::Size size(static_cast<unsigned int>(window_width),
                         static_cast<unsigned int>(window_height));
  if (!window.Create(L"ProcFlow - 进程网络流量监控", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
