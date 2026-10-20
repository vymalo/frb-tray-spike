#include "panel_window.h"

#include <gdk/gdkx.h>
#include <gtk/gtk.h>

#include "linux_tray.h"

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
  // A utility window floats above normal windows and stays out of the window
  // switcher. Menu-type hints would match a popover more closely, but window
  // managers may not give those keyboard focus, and the text field needs it.
  gtk_window_set_type_hint(window, GDK_WINDOW_TYPE_HINT_UTILITY);
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

// Centers the popover horizontally on the tray icon, kept on screen.
void move_under(GtkWindow* window, int anchor_x) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_monitor_at_point(display, anchor_x, 0);
  if (monitor == nullptr) return;
  GdkRectangle area;
  gdk_monitor_get_workarea(monitor, &area);
  int width, height;
  gtk_window_get_size(window, &width, &height);
  int x = CLAMP(anchor_x - width / 2, area.x + kScreenMargin,
                area.x + area.width - width - kScreenMargin);
  gtk_window_move(window, x, area.y + kScreenMargin);
}

// Shows the popover with keyboard focus. GNOME's focus-stealing prevention
// only focuses a window that asks for it on behalf of a recent user action;
// otherwise it maps the window unfocused and flags it "demands attention".
// An unfocused popover can never lose focus, so click-outside couldn't close
// it. The timestamp of the tray click that opened it is that user action.
// Opened another way (the chat window's button), the current server time
// stands in: the request still follows a click the user just made.
void present_focused(GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  guint32 time = linux_tray_last_click_time();
  if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
    guint32 now = gdk_x11_get_server_time(gdk_window);
    // A click older than a couple of seconds didn't open this popover.
    if (time == 0 || now - time > 2000) time = now;
  }
  gtk_window_present_with_time(window, time);
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
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(
        result, "transparent",
        fl_value_new_bool(GPOINTER_TO_INT(g_object_get_data(
            G_OBJECT(user_data), "panel_window_transparent"))));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "focus") == 0) {
    FlValue* anchor = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                          ? fl_value_lookup_string(args, "anchorX")
                          : nullptr;
    if (anchor != nullptr && fl_value_get_type(anchor) == FL_VALUE_TYPE_INT) {
      move_under(window, fl_value_get_int(anchor));
    }
    present_focused(window);
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

void panel_window_prepare_visual(GtkWindow* window) {
  GtkWidget* widget = GTK_WIDGET(window);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  GdkVisual* rgba = gdk_screen_get_rgba_visual(screen);
  if (rgba == nullptr || !gdk_screen_is_composited(screen) ||
      gtk_widget_get_realized(widget)) {
    return;
  }
  gtk_widget_set_visual(widget, rgba);
  // Keeps GTK from painting the theme's opaque window background.
  gtk_widget_set_app_paintable(widget, TRUE);
}

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
    // panel_window_prepare_visual gave the window an alpha channel; let the
    // Flutter view draw on a transparent background to use it.
    gboolean transparent =
        gtk_widget_get_visual(GTK_WIDGET(window)) ==
        gdk_screen_get_rgba_visual(gtk_widget_get_screen(GTK_WIDGET(window)));
    if (transparent) {
      GdkRGBA clear = {0, 0, 0, 0};
      fl_view_set_background_color(view, &clear);
    }
    g_object_set_data(G_OBJECT(view), "panel_window_transparent",
                      GINT_TO_POINTER(transparent));
    configure(window, kPanelWidth, kPanelHeight);
    g_signal_connect_object(window, "focus-out-event", G_CALLBACK(focus_out_cb),
                            channel, static_cast<GConnectFlags>(0));
  }
}
