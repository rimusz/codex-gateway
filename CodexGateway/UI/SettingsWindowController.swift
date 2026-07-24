import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private var window: NSWindow?
  private let store = SettingsStore()

  private override init() {
    super.init()
  }

  func show() {
    if let window {
      present(window)
      store.reload()
      return
    }

    let hosting = NSHostingController(rootView: SettingsView(store: store))
    let newWindow = Self.makeWindow(contentViewController: hosting, delegate: self)
    window = newWindow
    present(newWindow)
  }

  static func makeWindow(contentViewController: NSViewController, delegate: NSWindowDelegate) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "CodexGateway Settings"
    // Programmatic NSWindows default to isReleasedWhenClosed = true, which over-releases
    // the window while `window` still references it — reopening then crashes. Let ARC own it.
    window.isReleasedWhenClosed = false
    window.delegate = delegate
    window.contentViewController = contentViewController
    window.setFrameAutosaveName("CodexGatewaySettingsWindow")
    window.minSize = NSSize(width: 620, height: 520)
    window.hidesOnDeactivate = false
    return window
  }

  private func present(_ window: NSWindow) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    if window.frame.size.width < 620 || window.frame.size.height < 520 {
      window.setContentSize(NSSize(width: 680, height: 640))
      window.center()
    }
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  func windowWillClose(_ notification: Notification) {
    AppActivationPolicy.restoreAccessoryIfNoVisibleWindows(excluding: window)
  }
}
