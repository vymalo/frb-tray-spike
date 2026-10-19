import Carbon
import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  private var hotKey: GlobalHotKey?
  private var hotKeyChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Another — agent client"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ⌥Space toggles the popover from anywhere. Engine A owns the tray, so the
    // shortcut reports to it, like a click on the status item.
    let channel = FlutterMethodChannel(
      name: "agent_tray_demo/hotkey", binaryMessenger: flutterViewController.engine.binaryMessenger)
    hotKeyChannel = channel
    hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
      channel.invokeMethod("toggle", arguments: nil)
    }

    // Every window from desktop_multi_window runs its own Flutter engine, and a
    // new engine starts with no plugins. Register them here, or calls from the
    // tray panel fail with MissingPluginException. AGENT_DEMO_SKIP_PLUGINS=1
    // leaves them out to show that failure.
    if ProcessInfo.processInfo.environment["AGENT_DEMO_SKIP_PLUGINS"] != "1" {
      FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
        RegisterGeneratedPlugins(registry: controller)
        PanelWindowPlugin.register(
          with: controller.registrar(forPlugin: "PanelWindowPlugin"), controller: controller)
      }
    }

    super.awakeFromNib()
  }
}

/// A system-wide shortcut through Carbon's hot key API, which needs no
/// Accessibility permission (unlike monitoring all key events).
final class GlobalHotKey {
  private static let signature: OSType = 0x4154_4453  // 'ATDS'

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let action: () -> Void

  init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
    self.action = action

    var pressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
        return noErr
      },
      1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    guard installed == noErr else { return nil }

    let id = EventHotKeyID(signature: Self.signature, id: 1)
    let registered = RegisterEventHotKey(
      keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    guard registered == noErr else {
      // Another app already owns the shortcut; the tray still works.
      NSLog("agent_tray_demo: ⌥Space is taken by another app (status \(registered))")
      return nil
    }
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
  }
}

/// The popover's window: a non-activating panel, like Spotlight or a menu-bar
/// popover. It takes keyboard focus for its text field without bringing the
/// whole app (and its main window) to the front, stays out of ⌘-Tab and the
/// window list, and floats above other apps.
final class PopoverPanel: NSPanel {
  init(size: NSSize) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    // Transparent outside the card Flutter draws, so the window takes the
    // card's rounded shape; the system shadow follows that shape.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = false
  }

  // A borderless panel can't become key by default, and the text field needs
  // keyboard focus.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Moves the popover engine's Flutter view into a [PopoverPanel], places it
/// under the menu-bar icon, and reports when it loses focus.
///
/// desktop_multi_window creates a plain NSWindow for every engine and can't
/// create panels, so the engine's view controller is moved into our panel. The
/// original window is never shown; showing and hiding go through this channel,
/// not through desktop_multi_window.
///
/// Channel "agent_tray_demo/panel_window":
///   configure {width, height} -> resizes and places the panel (no show)
///   focus                     -> places it under the icon, shows it and focuses it
///   hide                      -> hides the panel
///   focusLost (to Dart)       -> the panel lost focus and should dismiss
class PanelWindowPlugin: NSObject, FlutterPlugin {
  private static let gap: CGFloat = 4
  private static let defaultSize = NSSize(width: 440, height: 330)

  private let channel: FlutterMethodChannel
  private let panel: PopoverPanel
  private var size = PanelWindowPlugin.defaultSize
  private var resignObserver: NSObjectProtocol?

  init(channel: FlutterMethodChannel, panel: PopoverPanel) {
    self.channel = channel
    self.panel = panel
    super.init()
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
    ) { [weak self] _ in
      // Clicking anywhere outside the popover dismisses it.
      self?.channel.invokeMethod("focusLost", arguments: nil)
    }
  }

  deinit {
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }

  // FlutterPlugin requires this entry point; the runner calls the variant
  // that also gets the engine's view controller.
  static func register(with registrar: FlutterPluginRegistrar) {}

  static func register(with registrar: FlutterPluginRegistrar, controller: FlutterViewController) {
    let original = controller.view.window
    let panel = PopoverPanel(size: defaultSize)
    controller.backgroundColor = .clear
    original?.contentViewController = nil
    original?.orderOut(nil)
    panel.contentViewController = controller
    panel.setContentSize(defaultSize)

    let channel = FlutterMethodChannel(
      name: "agent_tray_demo/panel_window", binaryMessenger: registrar.messenger)
    let plugin = PanelWindowPlugin(channel: channel, panel: panel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    plugin.place()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      let args = call.arguments as? [String: Any] ?? [:]
      size = NSSize(
        width: CGFloat(args["width"] as? Int ?? Int(Self.defaultSize.width)),
        height: CGFloat(args["height"] as? Int ?? Int(Self.defaultSize.height)))
      place()
      result(nil)
    case "focus":
      place()
      // A non-activating panel takes key focus without activating the app.
      panel.makeKeyAndOrderFront(nil)
      result(nil)
    case "hide":
      panel.orderOut(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Centers the popover under the menu-bar icon (tray_manager's status item),
  /// falling back to the top-right corner of the screen.
  private func place() {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var x = visible.maxX - size.width - Self.gap
    var top = visible.maxY - Self.gap
    if let item = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }) {
      x = item.frame.midX - size.width / 2
      top = item.frame.minY - Self.gap
    }
    x = min(max(x, visible.minX + Self.gap), visible.maxX - size.width - Self.gap)
    panel.setFrame(
      NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
  }
}
