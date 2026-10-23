#ifndef FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace flutter_tray_popover {

// One instance per engine that registers the plugin. They all drive the one
// tray icon and popover the process has (see flutter_tray_popover_plugin.cpp).
class FlutterTrayPopoverPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterTrayPopoverPlugin(
      flutter::PluginRegistrarWindows* registrar,
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);
  ~FlutterTrayPopoverPlugin() override;

  FlutterTrayPopoverPlugin(const FlutterTrayPopoverPlugin&) = delete;
  FlutterTrayPopoverPlugin& operator=(const FlutterTrayPopoverPlugin&) = delete;

  // Tells this engine's Dart side that the popover was shown or hidden.
  void SendVisibility(bool visible);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool set_up_tray_ = false;  // this engine called setUp
};

}  // namespace flutter_tray_popover

#endif  // FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_
