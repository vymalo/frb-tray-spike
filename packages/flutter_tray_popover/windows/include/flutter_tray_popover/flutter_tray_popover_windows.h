#ifndef FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_WINDOWS_H_
#define FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_WINDOWS_H_

#include <flutter/plugin_registry.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_TRAY_POPOVER_EXPORT __declspec(dllexport)
#else
#define FLUTTER_TRAY_POPOVER_EXPORT __declspec(dllimport)
#endif

// Called with the popover engine's registry right after the plugin creates
// it, before its Dart code runs. A new engine starts without plugins, and
// only the app can call its own generated RegisterPlugins(), so the app's
// runner sets this (windows/runner/flutter_window.cpp):
//
//   FlutterTrayPopoverPluginSetEngineCreatedCallback(
//       [](flutter::PluginRegistry* registry) { RegisterPlugins(registry); });
using FlutterTrayPopoverEngineCreatedCallback =
    void (*)(flutter::PluginRegistry* registry);

FLUTTER_TRAY_POPOVER_EXPORT void FlutterTrayPopoverPluginSetEngineCreatedCallback(
    FlutterTrayPopoverEngineCreatedCallback callback);

#endif  // FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_WINDOWS_H_
