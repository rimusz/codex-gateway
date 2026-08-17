import AppKit
import SwiftUI

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
  static let shared = SetupWindowController()

  private var window: NSWindow?
  private var store = SetupStore()
  private var didFinish = false

  private override init() {
    super.init()
  }

  static func shouldPresent(
    providers: [ProviderConfig] = ModelCatalog.shared.loadProviders().providers,
    models: [CatalogModel] = ModelCatalog.shared.loadCatalog().models,
    skippedThisLaunch: Bool = SetupSession.skippedThisLaunch,
    isMigrating: Bool = AppBundleMigration.isLegacyBundleMigrationPending,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    if isMigrating { return false }
    #if DEBUG
    if SetupPresentation.shouldForceShow(arguments: arguments) { return true }
    #endif
    return SetupPresentation.shouldShow(
      providers: providers,
      models: models,
      skippedThisLaunch: skippedThisLaunch,
      isMigrating: isMigrating
    )
  }

  func showIfNeeded() {
    guard Self.shouldPresent() else { return }
    show()
  }

  func show() {
    didFinish = false
    store = SetupStore()
    if let window {
      window.contentViewController = NSHostingController(
        rootView: SetupView(store: store, onSkip: { [weak self] in self?.skip() }, onFinished: { [weak self] in
          self?.markFinished()
        })
      )
      present(window)
      return
    }

    let hosting = NSHostingController(
      rootView: SetupView(store: store, onSkip: { [weak self] in self?.skip() }, onFinished: { [weak self] in
        self?.markFinished()
      })
    )
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
    window.title = SetupCopy.windowTitle
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

  func skip() {
    store.discardInstalledProvider()
    SetupSession.skippedThisLaunch = true
    window?.close()
  }

  private func markFinished() {
    didFinish = true
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    if !didFinish {
      store.discardInstalledProvider()
      SetupSession.skippedThisLaunch = true
    }
    AppActivationPolicy.restoreAccessoryIfNoVisibleWindows(excluding: window)
  }
}
