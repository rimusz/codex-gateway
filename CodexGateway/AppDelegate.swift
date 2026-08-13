import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var shared: AppDelegate?
  var statusBar: StatusBarController!
  private let logFile = "/tmp/codexgateway_debug.log"
  private var healthTimer: Timer?

  func log(_ message: String) {
    if let handle = FileHandle(forWritingAtPath: logFile) {
      handle.seekToEndOfFile()
      handle.write((message + "\n").data(using: .utf8)!)
      try? handle.close()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppDelegate.shared = self

    // Ensure the log file exists before migration diagnostics write to it.
    if !FileManager.default.fileExists(atPath: logFile) {
      FileManager.default.createFile(atPath: logFile, contents: nil)
    }

    // If an older updater left us at CodexBar.app, migrate to CodexGateway.app and relaunch.
    // Skip the rest of startup — the helper quits this process and opens the renamed app.
    if AppBundleMigration.migrateLegacyBundleIfNeeded() {
      log("[App] Migrating CodexBar.app → CodexGateway.app; quitting to relaunch")
      return
    }

    Paths.prepare()
    GatewayServer.shared.start()
    Task { await CursorBridgeRuntime.startIfNeeded() }
    CodexAuthWatcher.shared.start()
    log("[App] Started embedded Swift gateway on :8765")
    if let appIcon = AppIconProvider.image() {
      NSApplication.shared.applicationIconImage = appIcon
    }
    setupMainMenu()
    UpdateScheduler.start()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(prepareForShutdown),
      name: .codexGatewayPrepareForShutdown,
      object: nil
    )

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      let apiClient = APIClient()
      self.statusBar = StatusBarController(apiClient: apiClient)
      apiClient.fetchStatus()
      self.healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        apiClient.fetchStatus()
      }
      self.log("[App] Ready")
    }
  }

  @objc private func prepareForShutdown() {
    healthTimer?.invalidate()
    CodexAuthWatcher.shared.stop()
    GatewayServer.shared.stop()
    CursorBridgeRuntime.stop()
  }

  func applicationWillTerminate(_ notification: Notification) {
    healthTimer?.invalidate()
    CodexAuthWatcher.shared.stop()
    GatewayServer.shared.stop()
    CursorBridgeRuntime.stop()
    log("[App] Stopped embedded gateway")
  }

  private func setupMainMenu() {
    let mainMenu = NSMenu()
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    editMenuItem.submenu = editMenu
    NSApplication.shared.mainMenu = mainMenu
  }
}
