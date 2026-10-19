#ifndef RUNNER_LINUX_TRAY_H_
#define RUNNER_LINUX_TRAY_H_

#include <flutter_linux/flutter_linux.h>

// Tray icon for the main engine on Linux.
//
// It is an X11 (XEmbed) status icon rather than an AppIndicator: GNOME's
// AppIndicator extension opens the indicator's native menu on a single left
// click and never tells the app, while it forwards real clicks to X11 tray
// icons. That lets a click open the Flutter popover, like the macOS menu bar.
// The menu actions live in the popover, so there is no native menu.
//
// Channel "agent_tray_demo/linux_tray" (native -> Dart):
//   activate {x}   the icon was clicked; x is its screen position, or -1
void linux_tray_register(FlPluginRegistry* registry);

#endif  // RUNNER_LINUX_TRAY_H_
