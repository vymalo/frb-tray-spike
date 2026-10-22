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

    super.awakeFromNib()
  }
}
