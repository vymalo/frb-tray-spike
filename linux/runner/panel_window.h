#ifndef RUNNER_PANEL_WINDOW_H_
#define RUNNER_PANEL_WINDOW_H_

#include <flutter_linux/flutter_linux.h>

// Lets an engine turn its own GTK window into a borderless, always-on-top
// panel pinned under the tray (top-right of the primary monitor's work area):
// a utility window that skips the taskbar and pager and, with a compositor,
// is transparent around the card Flutter draws.
//
// Registering also shapes the engine's (still hidden) window as the panel.
//
// Channel "agent_tray_demo/panel_window":
//   configure {width, height} -> resizes and places the window (no show);
//                                answers {transparent: bool}
//   focus {anchorX?}          -> raises and focuses the shown window, centered
//                                under the tray icon when anchorX is given
//   hide                      -> hides the window
//   focusLost (to Dart)       -> the window lost focus and should dismiss
void panel_window_register(FlPluginRegistry* registry);

// Gives a not-yet-realized window an alpha channel, so the area around the
// card Flutter draws is see-through and the popover takes the card's rounded
// shape, like the macOS panel. A window's visual can only be chosen before it
// is realized, which desktop_multi_window does right after creating it, so
// the runner calls this from GtkApplication::window-added. Needs a
// compositing window manager (GNOME and KDE always are); without one the
// popover stays an opaque rectangle.
void panel_window_prepare_visual(GtkWindow* window);

#endif  // RUNNER_PANEL_WINDOW_H_
