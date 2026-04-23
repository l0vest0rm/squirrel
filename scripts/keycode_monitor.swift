import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var monitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    print("Press keys in this window. Press Esc to quit.")
    NSApp.activate(ignoringOtherApps: true)

    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      let chars = event.characters ?? ""
      let charsIgnoring = event.charactersIgnoringModifiers ?? ""
      print("keyCode=\(event.keyCode) chars=[\(chars)] charsIgnoring=[\(charsIgnoring)] modifiers=\(event.modifierFlags.intersection([.shift, .control, .option, .command, .capsLock]))")
      fflush(stdout)
      if event.keyCode == UInt16(kVK_Escape) {
        NSApp.terminate(nil)
        return nil
      }
      return event
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Keycode Monitor"
    window.center()
    window.makeKeyAndOrderFront(nil)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
