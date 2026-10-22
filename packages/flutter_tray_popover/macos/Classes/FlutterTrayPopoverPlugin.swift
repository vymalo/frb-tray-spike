import Carbon
import Cocoa
import FlutterMacOS

/// A status item that opens a Flutter popover, rendered by a second Flutter
/// engine in the same process. See lib/flutter_tray_popover.dart.
public class FlutterTrayPopoverPlugin: NSObject, FlutterPlugin {
  /// Called with the popover engine right after the plugin creates it, before
  /// its Dart code runs. A new engine starts without plugins, and only the
  /// app can call its own generated RegisterGeneratedPlugins, so the app's
  /// runner sets this:
  ///
  ///     FlutterTrayPopoverPlugin.onEngineCreated = { RegisterGeneratedPlugins(registry: $0) }
  public static var onEngineCreated: ((FlutterPluginRegistry) -> Void)?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_tray_popover", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(FlutterTrayPopoverPlugin(), channel: channel)
    TrayPopover.shared.channels.append(channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let popover = TrayPopover.shared
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "setUp":
      popover.setUp(args)
      result(["transparent": true])
    case "show":
      popover.show()
      result(nil)
    case "hide":
      popover.hide()
      result(nil)
    case "toggle":
      popover.toggle()
      result(nil)
    case "isVisible":
      result(popover.isVisible)
    case "isTransparent":
      result(true)
    case "showMainWindow":
      popover.showMainWindow()
      result(nil)
    case "quit":
      result(nil)
      NSApp.terminate(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The popover's window: a non-activating panel, like Spotlight or a menu-bar
/// popover. It takes keyboard focus for a text field without bringing the
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
    // Transparent outside what Flutter draws, so the window takes the shape
    // of the content; the system shadow follows that shape.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
  }

  // A borderless panel can't become key by default, and a text field needs
  // keyboard focus.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// One per process, shared by every engine's registration of the plugin:
/// both engines are in this process and see the same status item and popover.
final class TrayPopover: NSObject {
  static let shared = TrayPopover()

  private static let gap: CGFloat = 4
  // Clicking the status item while the popover is open first takes focus
  // away from the popover, which closes it; that click must not reopen it.
  private static let reopenGuard: TimeInterval = 0.4

  var channels: [FlutterMethodChannel] = []

  private var statusItem: NSStatusItem?
  private var panel: PopoverPanel?
  private var engine: FlutterEngine?
  private var hotKey: GlobalHotKey?
  private var size = NSSize(width: 440, height: 330)
  private var hiddenByFocusLoss = Date.distantPast
  private var resignObserver: NSObjectProtocol?

  var isVisible: Bool { panel?.isVisible ?? false }

  func setUp(_ args: [String: Any]) {
    guard panel == nil else { return }
    size = NSSize(
      width: CGFloat(args["width"] as? Int ?? 440),
      height: CGFloat(args["height"] as? Int ?? 330))
    createStatusItem(icon: args["icon"] as? String ?? "")
    createPopover(entrypoint: args["entrypoint"] as? String ?? "trayMain")
    if args["optionSpaceShortcut"] as? Bool == true {
      hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
        [weak self] in self?.toggle()
      }
    }
  }

  private func createStatusItem(icon: String) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let path = Bundle.main.bundlePath
      + "/Contents/Frameworks/App.framework/Resources/flutter_assets/" + icon
    if let image = NSImage(contentsOfFile: path) {
      image.size = NSSize(width: 18, height: 18)
      item.button?.image = image
    }
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
  }

  @objc private func statusItemClicked() { toggle() }

  /// Starts the popover's engine at the named Dart entry point (kept in
  /// release builds by `@pragma('vm:entry-point')`), hidden, so the first
  /// click opens an already running popover.
  private func createPopover(entrypoint: String) {
    let engine = FlutterEngine(name: "tray_popover", project: FlutterDartProject())
    // Plugins first, so they're there before the popover's Dart code runs.
    if let onEngineCreated = FlutterTrayPopoverPlugin.onEngineCreated {
      onEngineCreated(engine)
    } else {
      NSLog("flutter_tray_popover: no onEngineCreated set; the popover engine has no plugins")
    }
    engine.run(withEntrypoint: entrypoint)
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    controller.backgroundColor = .clear

    let panel = PopoverPanel(size: size)
    panel.contentViewController = controller
    panel.setContentSize(size)
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
    ) { [weak self] _ in
      // Clicking anywhere outside the popover closes it.
      guard let self, self.isVisible else { return }
      self.hiddenByFocusLoss = Date()
      self.hide()
    }
    self.engine = engine
    self.panel = panel
  }

  func show() {
    guard let panel, !panel.isVisible else { return }
    place(panel)
    // A non-activating panel takes key focus without activating the app.
    panel.makeKeyAndOrderFront(nil)
    broadcastVisibility(true)
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    broadcastVisibility(false)
  }

  func toggle() {
    if isVisible {
      hide()
    } else if Date().timeIntervalSince(hiddenByFocusLoss) > Self.reopenGuard {
      show()
    }
  }

  func showMainWindow() {
    let main = NSApp.windows.first {
      $0 !== panel && $0.contentViewController is FlutterViewController
    }
    NSApp.activate(ignoringOtherApps: true)
    main?.makeKeyAndOrderFront(nil)
  }

  /// Centers the popover under the status item, falling back to the
  /// top-right corner of the screen.
  private func place(_ panel: NSPanel) {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var x = visible.maxX - size.width - Self.gap
    var top = visible.maxY - Self.gap
    if let itemFrame = statusItem?.button?.window?.frame {
      x = itemFrame.midX - size.width / 2
      top = itemFrame.minY - Self.gap
    }
    x = min(max(x, visible.minX + Self.gap), visible.maxX - size.width - Self.gap)
    panel.setFrame(
      NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
      display: true)
  }

  private func broadcastVisibility(_ visible: Bool) {
    for channel in channels {
      channel.invokeMethod("visibilityChanged", arguments: visible)
    }
  }
}

/// A system-wide shortcut through Carbon's hot key API, which needs no
/// Accessibility permission (unlike monitoring all key events).
final class GlobalHotKey {
  private static let signature: OSType = 0x5452_5050  // 'TRPP'

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
      // Another app already owns the shortcut; the status item still works.
      NSLog("flutter_tray_popover: ⌥Space is taken by another app (status \(registered))")
      return nil
    }
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
  }
}
