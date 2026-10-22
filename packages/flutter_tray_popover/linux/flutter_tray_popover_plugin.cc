#include "include/flutter_tray_popover/flutter_tray_popover_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>

#include <algorithm>
#include <string>
#include <vector>

// GtkStatusIcon is deprecated in GTK 3 in favour of AppIndicator, but GNOME's
// AppIndicator extension opens an indicator's native menu on a single click
// and never tells the app. It does forward clicks to legacy X11 tray icons,
// which is what lets a click open a Flutter popover.
G_GNUC_BEGIN_IGNORE_DEPRECATIONS

#define FLUTTER_TRAY_POPOVER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_tray_popover_plugin_get_type(), \
                              FlutterTrayPopoverPlugin))

struct _FlutterTrayPopoverPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(FlutterTrayPopoverPlugin, flutter_tray_popover_plugin,
              g_object_get_type())

static void flutter_tray_popover_plugin_class_init(
    FlutterTrayPopoverPluginClass* klass) {}

static void flutter_tray_popover_plugin_init(FlutterTrayPopoverPlugin* self) {}

namespace {

constexpr char kChannelName[] = "flutter_tray_popover";
constexpr char kPopoverArgument[] = "tray_popover";
constexpr int kScreenMargin = 12;
// A click can arrive both as a GTK signal and as a raw X event; see below.
constexpr gint64 kDuplicateClickUs = 250 * 1000;
// Clicking the tray icon while the popover is open first takes focus away
// from the popover, which closes it; that same click must not reopen it.
constexpr gint64 kReopenGuardUs = 400 * 1000;
// A tray click older than this didn't open the popover.
constexpr guint32 kClickTimeMaxAgeMs = 2000;

// One per process, shared by every engine's registration of the plugin:
// both engines are in this process and see the same tray and popover.
struct State {
  std::vector<FlMethodChannel*> channels;  // one per engine, for events
  FlView* main_view = nullptr;             // the engine that called setUp
  GtkStatusIcon* icon = nullptr;
  GtkWindow* popover = nullptr;
  FlView* popover_view = nullptr;
  gboolean transparent = FALSE;
  int width = 440;
  int height = 330;
  guint32 last_click_time = 0;
  gint64 last_click_us = 0;
  gint64 hidden_by_focus_loss_us = 0;
  FlutterTrayPopoverEngineCreatedCallback engine_created = nullptr;
};

State& state() {
  static State s;
  return s;
}

std::string asset_path(const gchar* asset) {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* path =
      g_build_filename(dir, "data", "flutter_assets", asset, nullptr);
  return path;
}

void broadcast_visibility(gboolean visible) {
  for (FlMethodChannel* channel : state().channels) {
    g_autoptr(FlValue) value = fl_value_new_bool(visible);
    fl_method_channel_invoke_method(channel, "visibilityChanged", value,
                                    nullptr, nullptr, nullptr);
  }
}

gboolean popover_visible() {
  return state().popover != nullptr &&
         gtk_widget_get_visible(GTK_WIDGET(state().popover));
}

// Centers the popover under screen x [anchor_x] (the tray icon), or puts it
// in the top-right corner when there's no anchor. Only effective on X11:
// Wayland compositors ignore client-requested positions.
void place_popover(int anchor_x) {
  State& s = state();
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(s.popover));
  GdkMonitor* monitor =
      anchor_x >= 0 ? gdk_display_get_monitor_at_point(display, anchor_x, 0)
                    : gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  if (monitor == nullptr) return;
  GdkRectangle area;
  gdk_monitor_get_workarea(monitor, &area);
  int right = area.x + area.width - s.width - kScreenMargin;
  int x = anchor_x >= 0 ? CLAMP(anchor_x - s.width / 2,
                                area.x + kScreenMargin, right)
                        : right;
  gtk_window_move(s.popover, x, area.y + kScreenMargin);
}

// GNOME's focus-stealing prevention only focuses a window that asks for it
// on behalf of a recent user action; otherwise it maps the window unfocused
// and flags it "demands attention", and an unfocused popover can never lose
// focus, so click-outside couldn't close it. The tray click that opened it
// is that user action. Opened another way (a button in the app), the
// current server time stands in: the request still follows a user click.
guint32 focus_timestamp() {
  State& s = state();
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(s.popover));
  guint32 time = s.last_click_time;
  if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
    guint32 now = gdk_x11_get_server_time(gdk_window);
    if (time == 0 || now - time > kClickTimeMaxAgeMs) time = now;
  }
  return time;
}

void show_popover(int anchor_x) {
  State& s = state();
  if (s.popover == nullptr) return;
  place_popover(anchor_x);
  gtk_widget_show(GTK_WIDGET(s.popover));
  gtk_window_present_with_time(s.popover, focus_timestamp());
  broadcast_visibility(TRUE);
}

void hide_popover() {
  if (!popover_visible()) return;
  gtk_widget_hide(GTK_WIDGET(state().popover));
  broadcast_visibility(FALSE);
}

void toggle_popover(int anchor_x) {
  if (popover_visible()) {
    hide_popover();
  } else if (g_get_monotonic_time() - state().hidden_by_focus_loss_us >
             kReopenGuardUs) {
    show_popover(anchor_x);
  }
}

// Clicking anywhere outside the popover closes it, like a menu-bar popover.
gboolean popover_focus_out_cb(GtkWidget*, GdkEvent*, gpointer) {
  if (popover_visible()) {
    state().hidden_by_focus_loss_us = g_get_monotonic_time();
    hide_popover();
  }
  return FALSE;
}

// ---- Tray icon ----

int icon_center_x() {
  GdkRectangle area;
  if (gtk_status_icon_get_geometry(state().icon, nullptr, &area, nullptr) &&
      area.x > 0) {
    return area.x + area.width / 2;
  }
  return -1;
}

void on_tray_click(int x, guint32 time) {
  State& s = state();
  gint64 now = g_get_monotonic_time();
  if (now - s.last_click_us < kDuplicateClickUs) return;
  s.last_click_us = now;
  s.last_click_time = time;
  toggle_popover(x);
}

// GNOME Shell forwards clicks on legacy tray icons as synthetic core X button
// events (XSendEvent). GTK 3 only reads pointer input from XInput2, so those
// never become GtkStatusIcon signals; read them here instead. Any button
// toggles the popover: its menu, if any, is drawn by Flutter.
GdkFilterReturn tray_event_filter(GdkXEvent* xevent, GdkEvent*, gpointer) {
  auto* event = static_cast<XEvent*>(xevent);
  if (state().icon == nullptr || event->type != ButtonPress ||
      event->xbutton.window !=
          gtk_status_icon_get_x11_window_id(state().icon)) {
    return GDK_FILTER_CONTINUE;
  }
  int x = event->xbutton.x_root > 0 ? event->xbutton.x_root : icon_center_x();
  on_tray_click(x, static_cast<guint32>(event->xbutton.time));
  return GDK_FILTER_REMOVE;
}

// Desktops that deliver real (XInput2) clicks to tray icons, such as KDE or
// XFCE, come through GTK's own signals.
void tray_activate_cb(GtkStatusIcon*, gpointer) {
  on_tray_click(icon_center_x(), gtk_get_current_event_time());
}

void tray_popup_menu_cb(GtkStatusIcon*, guint, guint, gpointer) {
  on_tray_click(icon_center_x(), gtk_get_current_event_time());
}

void create_tray_icon(const gchar* icon) {
  State& s = state();
  s.icon = gtk_status_icon_new_from_file(asset_path(icon).c_str());
  g_signal_connect(s.icon, "activate", G_CALLBACK(tray_activate_cb), nullptr);
  g_signal_connect(s.icon, "popup-menu", G_CALLBACK(tray_popup_menu_cb),
                   nullptr);
  gdk_window_add_filter(nullptr, tray_event_filter, nullptr);
  gtk_status_icon_set_visible(s.icon, TRUE);
}

// ---- Popover window and engine ----

// The popover's window and its Flutter engine. The window gets an alpha
// channel (with a compositor) before it is realized, as GTK requires, so the
// area around what Flutter draws is see-through. It is a borderless utility
// window: always on top, out of the taskbar and the window switcher.
// Utility rather than a menu-type hint, because window managers may not give
// menu windows keyboard focus, and a popover usually has a text field.
//
// The Linux embedder can only start an engine at `main`, so the popover
// engine runs `main` with ["tray_popover"].
void create_popover() {
  State& s = state();
  GtkWindow* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  GtkWidget* widget = GTK_WIDGET(window);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  GdkVisual* rgba = gdk_screen_get_rgba_visual(screen);
  if (rgba != nullptr && gdk_screen_is_composited(screen)) {
    gtk_widget_set_visual(widget, rgba);
    // Keeps GTK from painting the theme's opaque window background.
    gtk_widget_set_app_paintable(widget, TRUE);
    s.transparent = TRUE;
  }
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_type_hint(window, GDK_WINDOW_TYPE_HINT_UTILITY);
  gtk_window_set_keep_above(window, TRUE);
  gtk_window_set_skip_taskbar_hint(window, TRUE);
  gtk_window_set_skip_pager_hint(window, TRUE);
  gtk_window_set_default_size(window, s.width, s.height);
  g_signal_connect(window, "delete-event",
                   G_CALLBACK(gtk_widget_hide_on_delete), nullptr);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  const char* args[] = {kPopoverArgument, nullptr};
  fl_dart_project_set_dart_entrypoint_arguments(project,
                                                const_cast<char**>(args));
  FlView* view = fl_view_new(project);
  if (s.transparent) {
    GdkRGBA clear = {0, 0, 0, 0};
    fl_view_set_background_color(view, &clear);
  }
  gtk_widget_set_size_request(GTK_WIDGET(view), s.width, s.height);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  s.popover = window;
  s.popover_view = view;

  // Plugins first, so they're there before the popover's Dart code runs.
  if (s.engine_created != nullptr) {
    s.engine_created(FL_PLUGIN_REGISTRY(view));
  } else {
    g_warning(
        "flutter_tray_popover: no engine-created callback set; the popover "
        "engine has no plugins. See "
        "flutter_tray_popover_plugin_set_engine_created_callback().");
  }
  // Realizing the view (which realizes its still hidden window too) starts
  // the engine, so the first click opens an already running popover.
  // Realizing only the window would leave the view, and the engine, idle.
  gtk_widget_realize(GTK_WIDGET(view));
  g_signal_connect(window, "focus-out-event", G_CALLBACK(popover_focus_out_cb),
                   nullptr);
}

// The window of the engine that called setUp; before that, the window of
// [fallback], the engine asking.
GtkWindow* main_window(FlView* fallback = nullptr) {
  FlView* view = state().main_view != nullptr ? state().main_view : fallback;
  if (view == nullptr) return nullptr;
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  return GTK_IS_WINDOW(toplevel) ? GTK_WINDOW(toplevel) : nullptr;
}

// Closing the main window only hides it; the app lives on in the tray until
// quit. FlView handles the window's delete-event by asking the app to exit,
// so that handler is replaced.
void keep_alive_on_window_close() {
  GtkWindow* window = main_window();
  if (window == nullptr) return;
  gulong handler = g_signal_handler_find(window, G_SIGNAL_MATCH_DATA, 0, 0,
                                         nullptr, nullptr, state().main_view);
  if (handler > 0) g_signal_handler_disconnect(window, handler);
  g_signal_connect(window, "delete-event",
                   G_CALLBACK(gtk_widget_hide_on_delete), nullptr);
}

// ---- Method channel ----

FlValue* lookup(FlValue* args, const char* key) {
  return args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(args, key)
             : nullptr;
}

void method_call_cb(FlMethodChannel*, FlMethodCall* method_call,
                    gpointer user_data) {
  State& s = state();
  FlView* caller = FL_VIEW(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlValue) result = nullptr;

  if (g_strcmp0(method, "setUp") == 0) {
    if (s.popover == nullptr) {
      s.main_view = caller;
      if (FlValue* w = lookup(args, "width")) s.width = fl_value_get_int(w);
      if (FlValue* h = lookup(args, "height")) s.height = fl_value_get_int(h);
      FlValue* keep_alive = lookup(args, "keepAliveOnWindowClose");
      if (keep_alive == nullptr || fl_value_get_bool(keep_alive)) {
        keep_alive_on_window_close();
      }
      FlValue* icon = lookup(args, "icon");
      create_tray_icon(icon != nullptr ? fl_value_get_string(icon) : "");
      create_popover();
    }
    result = fl_value_new_map();
    fl_value_set_string_take(result, "transparent",
                             fl_value_new_bool(s.transparent));
  } else if (g_strcmp0(method, "show") == 0) {
    if (!popover_visible()) show_popover(-1);
  } else if (g_strcmp0(method, "hide") == 0) {
    hide_popover();
  } else if (g_strcmp0(method, "toggle") == 0) {
    toggle_popover(-1);
  } else if (g_strcmp0(method, "isVisible") == 0) {
    result = fl_value_new_bool(popover_visible());
  } else if (g_strcmp0(method, "isTransparent") == 0) {
    result = fl_value_new_bool(s.transparent);
  } else if (g_strcmp0(method, "showMainWindow") == 0) {
    if (GtkWindow* window = main_window(caller)) {
      GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
      gtk_widget_show(GTK_WIDGET(window));
      guint32 time = gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)
                         ? gdk_x11_get_server_time(gdk_window)
                         : GDK_CURRENT_TIME;
      gtk_window_present_with_time(window, time);
    }
  } else if (g_strcmp0(method, "quit") == 0) {
    g_application_quit(g_application_get_default());
  } else {
    fl_method_call_respond(
        method_call,
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()), nullptr);
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(method_call, response, nullptr);
}

void forget_channel(gpointer channel, GObject*) {
  auto& channels = state().channels;
  channels.erase(std::remove(channels.begin(), channels.end(),
                             static_cast<FlMethodChannel*>(channel)),
                 channels.end());
  g_object_unref(channel);
}

}  // namespace

void flutter_tray_popover_plugin_set_engine_created_callback(
    FlutterTrayPopoverEngineCreatedCallback callback) {
  state().engine_created = callback;
}

void flutter_tray_popover_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlView* view = fl_plugin_registrar_get_view(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, view,
                                            nullptr);
  state().channels.push_back(channel);
  // One channel per engine; drop it when that engine's view goes away.
  g_object_weak_ref(G_OBJECT(view), forget_channel, channel);
}

G_GNUC_END_IGNORE_DEPRECATIONS
