#include "linux_tray.h"

#include <gdk/gdkx.h>
#include <gtk/gtk.h>

#include <string>

// GtkStatusIcon is deprecated in GTK 3 in favour of AppIndicator, which cannot
// report left clicks under GNOME; see linux_tray.h.
G_GNUC_BEGIN_IGNORE_DEPRECATIONS

namespace {

// A click can arrive both as a GTK signal and as a raw X event; see below.
constexpr gint64 kDuplicateClickUs = 250 * 1000;

struct Tray {
  GtkStatusIcon* icon;
  FlMethodChannel* channel;
  gint64 last_click_us;
};

std::string icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* path = g_build_filename(
      dir, "data", "flutter_assets", "assets", "tray_icon.png", nullptr);
  return path;
}

void send_activate(Tray* tray, int x) {
  gint64 now = g_get_monotonic_time();
  if (now - tray->last_click_us < kDuplicateClickUs) return;
  tray->last_click_us = now;

  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "x", fl_value_new_int(x));
  fl_method_channel_invoke_method(tray->channel, "activate", args, nullptr,
                                  nullptr, nullptr);
}

// The icon's screen center, or -1 when unknown. Under GNOME Shell the icon is
// re-parented into the shell, so its geometry is often missing or off screen.
int icon_center_x(GtkStatusIcon* icon) {
  GdkRectangle area;
  if (gtk_status_icon_get_geometry(icon, nullptr, &area, nullptr) &&
      area.x > 0) {
    return area.x + area.width / 2;
  }
  return -1;
}

// GNOME Shell forwards clicks on legacy tray icons as synthetic core X button
// events (XSendEvent). GTK 3 only reads pointer input from XInput2, so those
// never become GtkStatusIcon signals; read them here instead. Any button opens
// the popover: its menu is in Flutter, not a native context menu.
GdkFilterReturn x_event_filter(GdkXEvent* xevent, GdkEvent*, gpointer data) {
  auto* tray = static_cast<Tray*>(data);
  auto* event = static_cast<XEvent*>(xevent);
  if (event->type != ButtonPress ||
      event->xbutton.window != gtk_status_icon_get_x11_window_id(tray->icon)) {
    return GDK_FILTER_CONTINUE;
  }
  int x = event->xbutton.x_root > 0 ? event->xbutton.x_root
                                    : icon_center_x(tray->icon);
  send_activate(tray, x);
  return GDK_FILTER_REMOVE;
}

// Desktops that deliver real (XInput2) clicks to tray icons, such as KDE or
// XFCE, come through GTK's own signals.
void activate_cb(GtkStatusIcon* icon, gpointer data) {
  send_activate(static_cast<Tray*>(data), icon_center_x(icon));
}

void popup_menu_cb(GtkStatusIcon* icon, guint, guint, gpointer data) {
  send_activate(static_cast<Tray*>(data), icon_center_x(icon));
}

}  // namespace

void linux_tray_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "LinuxTray");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  // Lives for the whole process, like the tray icon itself.
  auto* tray = g_new0(Tray, 1);
  tray->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "agent_tray_demo/linux_tray",
      FL_METHOD_CODEC(codec));
  tray->icon = gtk_status_icon_new_from_file(icon_path().c_str());
  gtk_status_icon_set_title(tray->icon, "Another");
  gtk_status_icon_set_tooltip_text(tray->icon, "Another");
  g_signal_connect(tray->icon, "activate", G_CALLBACK(activate_cb), tray);
  g_signal_connect(tray->icon, "popup-menu", G_CALLBACK(popup_menu_cb), tray);
  gdk_window_add_filter(nullptr, x_event_filter, tray);
  gtk_status_icon_set_visible(tray->icon, TRUE);
}

G_GNUC_END_IGNORE_DEPRECATIONS
