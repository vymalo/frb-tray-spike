#include "panel_window.h"

#include <gtk/gtk.h>

namespace {

constexpr int kScreenMargin = 12;
// Matches PanelWindow.width/height in lib/panel_window.dart.
constexpr int kPanelWidth = 440;
constexpr int kPanelHeight = 330;

GtkWindow* window_for(FlView* view) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  return GTK_IS_WINDOW(toplevel) ? GTK_WINDOW(toplevel) : nullptr;
}

void configure(GtkWindow* window, int width, int height) {
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_keep_above(window, TRUE);
  gtk_window_set_skip_taskbar_hint(window, TRUE);
  gtk_window_set_skip_pager_hint(window, TRUE);
  // desktop_multi_window gives every window a 1280x720 default size, which
  // would win over a plain resize when the window is first mapped. GTK also
  // still subtracts the margins of the title bar the window was realized
  // with, so pin the Flutter view itself to the panel size.
  gtk_window_set_default_size(window, width, height);
  GtkWidget* view = gtk_bin_get_child(GTK_BIN(window));
  if (view != nullptr) gtk_widget_set_size_request(view, width, height);
  gtk_window_resize(window, width, height);

  // Window placement only takes effect on X11 (main.cc prefers it); Wayland
  // compositors ignore client-requested positions.
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    gtk_window_move(window, area.x + area.width - width - kScreenMargin,
                    area.y + kScreenMargin);
  }
}

// Clicking anywhere outside the popover dismisses it, like a menu bar popover.
gboolean focus_out_cb(GtkWidget* widget, GdkEvent* event, gpointer user_data) {
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(user_data), "focusLost",
                                  nullptr, nullptr, nullptr, nullptr);
  return FALSE;
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  GtkWindow* window = window_for(FL_VIEW(user_data));
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (window == nullptr) {
    response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("no_window", "view has no window", nullptr));
  } else if (g_strcmp0(method, "configure") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* w = fl_value_lookup_string(args, "width");
    FlValue* h = fl_value_lookup_string(args, "height");
    configure(window, w ? fl_value_get_int(w) : 400,
              h ? fl_value_get_int(h) : 300);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "focus") == 0) {
    gtk_window_present(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "hide") == 0) {
    gtk_widget_hide(GTK_WIDGET(window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void panel_window_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "PanelWindow");
  FlView* view = fl_plugin_registrar_get_view(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "agent_tray_demo/panel_window", FL_METHOD_CODEC(codec));
  // The channel lives as long as the engine; tie its lifetime to the view.
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(view), g_object_unref);
  g_object_set_data_full(G_OBJECT(view), "panel_window_channel", channel,
                         g_object_unref);

  // Shape the still-hidden window now, so it first appears as a panel rather
  // than as a full-size decorated window.
  GtkWindow* window = window_for(view);
  if (window != nullptr) {
    configure(window, kPanelWidth, kPanelHeight);
    g_signal_connect_object(window, "focus-out-event", G_CALLBACK(focus_out_cb),
                            channel, static_cast<GConnectFlags>(0));
  }
}
