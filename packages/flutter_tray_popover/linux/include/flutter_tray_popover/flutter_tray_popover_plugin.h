#ifndef FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _FlutterTrayPopoverPlugin FlutterTrayPopoverPlugin;
typedef struct {
  GObjectClass parent_class;
} FlutterTrayPopoverPluginClass;

FLUTTER_PLUGIN_EXPORT GType flutter_tray_popover_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void flutter_tray_popover_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

// Called with the popover engine's registry right after the plugin creates
// it, before its Dart code runs. A new engine starts without plugins, and
// only the app can call its own generated fl_register_plugins(), so the
// app's runner sets this:
//
//   flutter_tray_popover_plugin_set_engine_created_callback(
//       [](FlPluginRegistry* registry) { fl_register_plugins(registry); });
typedef void (*FlutterTrayPopoverEngineCreatedCallback)(
    FlPluginRegistry* registry);

FLUTTER_PLUGIN_EXPORT void
flutter_tray_popover_plugin_set_engine_created_callback(
    FlutterTrayPopoverEngineCreatedCallback callback);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_FLUTTER_TRAY_POPOVER_PLUGIN_H_
