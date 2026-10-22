#include <gtk/gtk.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // The tray popover positions itself under the tray icon, which Wayland
  // does not allow clients to do. Use X11 (XWayland) whenever an X display
  // exists, even if GDK_BACKEND asks for Wayland, and fall back to Wayland
  // otherwise.
  if (g_getenv("DISPLAY") != nullptr) g_setenv("GDK_BACKEND", "x11", TRUE);
  gdk_set_allowed_backends("x11,wayland");

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
