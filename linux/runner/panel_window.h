#ifndef RUNNER_PANEL_WINDOW_H_
#define RUNNER_PANEL_WINDOW_H_

#include <flutter_linux/flutter_linux.h>

// Lets an engine turn its own GTK window into a borderless, always-on-top
// panel pinned under the tray (top-right of the primary monitor's work area).
//
// Registering also shapes the engine's (still hidden) window as the panel.
//
// Channel "agent_tray_demo/panel_window":
//   configure {width, height} -> resizes and places the window (no show)
//   focus                     -> raises the shown window and focuses it
//   hide                      -> hides the window
//   focusLost (to Dart)       -> the window lost focus and should dismiss
void panel_window_register(FlPluginRegistry* registry);

#endif  // RUNNER_PANEL_WINDOW_H_
