import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Another — agent client"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Every window from desktop_multi_window runs its own Flutter engine, and a
    // new engine starts with no plugins. Register them here, or calls from the
    // tray panel fail with MissingPluginException. AGENT_DEMO_SKIP_PLUGINS=1
    // leaves them out to show that failure.
    if ProcessInfo.processInfo.environment["AGENT_DEMO_SKIP_PLUGINS"] != "1" {
      FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
        RegisterGeneratedPlugins(registry: controller)
        PanelWindowPlugin.register(
          with: controller.registrar(forPlugin: "PanelWindowPlugin"))
      }
    }

    super.awakeFromNib()
  }
}

/// Lets the popover engine turn its own window into a chrome-less popover
/// that drops down under the menu-bar icon, and reports when it loses focus.
///
/// Channel "agent_tray_demo/panel_window":
///   configure {width, height} -> resizes and places the window (no show)
///   focus                     -> places it under the icon, raises and focuses it
///   hide                      -> hides the window
///   focusLost (to Dart)       -> the window lost focus and should dismiss
class PanelWindowPlugin: NSObject, FlutterPlugin {
  private static let gap: CGFloat = 6
  private static let defaultSize = NSSize(width: 440, height: 330)

  private weak var registrar: FlutterPluginRegistrar?
  private let channel: FlutterMethodChannel
  private var size = PanelWindowPlugin.defaultSize
  private var resignObserver: NSObjectProtocol?

  init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
    self.registrar = registrar
    self.channel = channel
  }

  deinit {
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "agent_tray_demo/panel_window", binaryMessenger: registrar.messenger)
    let plugin = PanelWindowPlugin(registrar: registrar, channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    // Shape the still-hidden window now, so it first appears as a popover.
    if let window = registrar.view?.window { plugin.attach(to: window) }
  }

  private func attach(to window: NSWindow) {
    shape(window)
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      // Clicking anywhere outside the popover dismisses it.
      self?.channel.invokeMethod("focusLost", arguments: nil)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = registrar?.view?.window else {
      result(FlutterError(code: "no_window", message: "view has no window", details: nil))
      return
    }
    switch call.method {
    case "configure":
      let args = call.arguments as? [String: Any] ?? [:]
      size = NSSize(
        width: CGFloat(args["width"] as? Int ?? Int(Self.defaultSize.width)),
        height: CGFloat(args["height"] as? Int ?? Int(Self.defaultSize.height)))
      if resignObserver == nil { attach(to: window) } else { shape(window) }
      result(nil)
    case "focus":
      place(window)
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      result(nil)
    case "hide":
      window.orderOut(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func shape(_ window: NSWindow) {
    // A titled window with the title bar hidden can still become key, so the
    // popover's text field accepts typing; a .borderless window could not.
    window.styleMask = [.titled, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    [.closeButton, .miniaturizeButton, .zoomButton].forEach {
      window.standardWindowButton($0)?.isHidden = true
    }
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hasShadow = true
    place(window)
  }

  /// Centers the popover under the menu-bar icon (tray_manager's status item),
  /// falling back to the top-right corner of the screen.
  private func place(_ window: NSWindow) {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var x = visible.maxX - size.width - Self.gap
    var top = visible.maxY - Self.gap
    if let item = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }) {
      x = item.frame.midX - size.width / 2
      top = item.frame.minY - Self.gap
    }
    x = min(max(x, visible.minX + Self.gap), visible.maxX - size.width - Self.gap)
    window.setFrame(
      NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
  }
}
