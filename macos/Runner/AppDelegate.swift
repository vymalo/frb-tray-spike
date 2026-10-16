import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // The app lives in the menu bar: closing the main window only hides it
  // (it is not released when closed), and Quit in the tray menu ends it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
