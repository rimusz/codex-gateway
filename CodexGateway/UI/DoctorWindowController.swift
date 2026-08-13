import AppKit
import SwiftUI

final class DoctorWindowController: NSObject, NSWindowDelegate {
  static let shared = DoctorWindowController()

  private var window: NSWindow?

  private override init() {
    super.init()
  }

  func show() {
    if let window {
      present(window)
      NotificationCenter.default.post(name: .codexGatewayDoctorRerunRequested, object: nil)
      return
    }

    let hosting = NSHostingController(rootView: DoctorView())
    let newWindow = Self.makeWindow(contentViewController: hosting, delegate: self)
    window = newWindow
    present(newWindow)
  }

  static func makeWindow(contentViewController: NSViewController, delegate: NSWindowDelegate) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "CodexGateway Doctor"
    window.isReleasedWhenClosed = false
    window.delegate = delegate
    window.contentViewController = contentViewController
    window.hidesOnDeactivate = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.collectionBehavior.insert(.fullScreenNone)
    window.center()
    return window
  }

  private func present(_ window: NSWindow) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  func windowWillClose(_ notification: Notification) {
    AppActivationPolicy.restoreAccessoryIfNoVisibleWindows(excluding: window)
  }
}

extension Notification.Name {
  static let codexGatewayDoctorRerunRequested = Notification.Name("CodexGatewayDoctorRerunRequested")
}
