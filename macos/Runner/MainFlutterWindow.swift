import Cocoa
import FlutterMacOS
import flutter_tray_popover

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Another — agent client"

    // The popover runs in a second Flutter engine, created by the
    // flutter_tray_popover plugin, and a new engine starts with no plugins.
    // Only the app can register its own, so it does that here for the popover
    // engine; otherwise the popover's calls fail with MissingPluginException.
    // AGENT_DEMO_SKIP_PLUGINS=1 leaves them out to show that failure.
    if ProcessInfo.processInfo.environment["AGENT_DEMO_SKIP_PLUGINS"] != "1" {
      FlutterTrayPopoverPlugin.onEngineCreated = { RegisterGeneratedPlugins(registry: $0) }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // FlutterViewController only launches its engine in viewWillAppear, i.e. the
    // first time its window is shown. This window is hidden at launch (the app
    // lives in the menu bar), so without this the main engine never runs: Dart
    // never creates the tray icon or the popover engine, and nothing appears.
    _ = flutterViewController.engine.run(withEntrypoint: nil)

    super.awakeFromNib()
  }
}
