#include "include/flutter_tray_popover/flutter_tray_popover_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_tray_popover_plugin.h"

void FlutterTrayPopoverPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_tray_popover::FlutterTrayPopoverPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
