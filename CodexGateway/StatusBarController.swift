import AppKit

enum AppStatus {
    case idle
    case loading
    case error
    case offline

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Ready"
        case .loading: return "Loading"
        case .error: return "Error"
        case .offline: return "Offline"
        }
    }
}

enum RestartCodexConfirmation {
    static let title = "Restart Codex?"
    static let message = "This will restart Codex Desktop so it can reload provider and model configuration."

    static func confirm() -> Bool {
        let shouldRestoreAccessory = NSApp.activationPolicy() == .accessory
          && !NSApp.windows.contains { $0.isVisible }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Codex")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .modalPanel
        let confirmed = alert.runModal() == .alertFirstButtonReturn

        if shouldRestoreAccessory {
            NSApp.setActivationPolicy(.accessory)
        }

        return confirmed
    }
}

enum StatusBarMenuCopy {
  static func updateMenuTitle(hasActionableUpdate: Bool) -> String {
    hasActionableUpdate ? "Upgrade Available…" : "Check for Updates…"
  }

  /// Short label describing the gateway's health for the menu.
  static func gatewayStateLabel(_ status: AppStatus) -> String {
    switch status {
    case .idle: return "Running"
    case .loading: return "Starting…"
    case .error: return "Error"
    case .offline: return "Offline"
    }
  }

  /// Menu line showing gateway health plus the loopback address it listens on.
  static func gatewayStatusTitle(
    _ status: AppStatus,
    host: String = Paths.gatewayHost,
    port: UInt16 = Paths.gatewayPort
  ) -> String {
    "\(gatewayStateLabel(status)) · \(host):\(port)"
  }
}

/// Pure restart-gating logic, extracted so it can be unit-tested without
/// constructing a `StatusBarController` (whose AppKit status item needs a
/// window-server connection unavailable on headless CI runners).
enum RestartCodexGate {
  static func restartIfConfirmed(confirm: () -> Bool, restart: () -> Void) {
    guard confirm() else { return }
    restart()
  }
}

class StatusBarController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let apiClient: APIClient
  private var menu: NSMenu
  private var updateCheckItem: NSMenuItem?
  private var gatewayStatusItem: NSMenuItem?
  private var openAtLoginItem: NSMenuItem?
  private(set) var currentStatus: AppStatus = .idle
    private var animationTimer: Timer?
    private var frameIndex = 0

    init(apiClient: APIClient) {
        self.apiClient = apiClient
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()

        setupStatusItem()
        setupMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(for: currentStatus)
        refreshOpenAtLoginMenuItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusChanged(_:)),
            name: .init("CodexGatewayStatusChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateStateChanged),
            name: .codexGatewayUpdateAvailable,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateStateChanged),
            name: .codexGatewayUpdateStateChanged,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateMenuItem()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setStatus(_ status: AppStatus) {
        currentStatus = status
        updateIcon(for: status)
        gatewayStatusItem?.title = StatusBarMenuCopy.gatewayStatusTitle(status)

        if status == .loading {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    @objc private func handleStatusChanged(_ notification: Notification) {
        guard let status = notification.object as? AppStatus else { return }
        setStatus(status)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = CodexBrandIcon.mark() {
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "CodexGateway")
        }

        button.isBordered = false
        button.imagePosition = .imageOnly
    }

    private func updateIcon(for status: AppStatus) {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel("CodexGateway — \(status.accessibilityLabel)")

        if CodexBrandIcon.mark() != nil {
            button.alphaValue = status == .offline ? 0.45 : 1.0
            return
        }

        let color: NSColor
        switch status {
        case .idle:
            color = .systemGreen
        case .loading:
            color = .systemBlue
        case .error:
            color = .systemYellow
        case .offline:
            color = .systemGray
        }

        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()

        let dotSize: CGFloat = 8
        let rect = NSRect(
            x: (size.width - dotSize) / 2,
            y: (size.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )

        color.set()
        NSBezierPath(ovalIn: rect).fill()

        img.unlockFocus()
        button.image = img
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.frameIndex += 1
            let alpha: CGFloat = (self?.frameIndex ?? 0) % 2 == 0 ? 0.4 : 1.0
            self?.statusItem.button?.alphaValue = alpha
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        statusItem.button?.alphaValue = currentStatus == .offline ? 0.45 : 1.0
        frameIndex = 0
    }

    @objc private func handleUpdateStateChanged() {
        Task { @MainActor [weak self] in
            self?.refreshUpdateMenuItem()
        }
    }

    private func setupMenu() {
    let titleItem = NSMenuItem(title: "CodexGateway \(AppVersion.display)", action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    menu.addItem(titleItem)

    let gatewayItem = NSMenuItem(
      title: StatusBarMenuCopy.gatewayStatusTitle(currentStatus),
      action: nil,
      keyEquivalent: ""
    )
    gatewayItem.isEnabled = false
    gatewayStatusItem = gatewayItem
    menu.addItem(gatewayItem)

    menu.addItem(.separator())

    let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openAtLoginItem = NSMenuItem(
          title: OpenAtLoginMenuCopy.title,
          action: #selector(toggleOpenAtLogin),
          keyEquivalent: ""
        )
        openAtLoginItem.target = self
        self.openAtLoginItem = openAtLoginItem
        menu.addItem(openAtLoginItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: StatusBarMenuCopy.updateMenuTitle(hasActionableUpdate: false),
            action: #selector(checkForUpdates),
            keyEquivalent: "u"
        )
        updateItem.target = self
        updateCheckItem = updateItem
        menu.addItem(updateItem)

#if DEBUG
        menu.addItem(makeSimulateUpdatesMenuItem())
#endif

        menu.addItem(.separator())

        let restartItem = NSMenuItem(title: "Restart Codex", action: #selector(restartCodex), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
          title: "About \(AppIdentity.productName)",
          action: #selector(openAbout),
          keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func checkForUpdates() {
        updateCheckItem?.title = "Checking for Updates…"
        updateCheckItem?.isEnabled = false

        Task { @MainActor [weak self] in
            await UpdateScheduler.checkNow()
            self?.resetUpdateMenuItem()
            await UpdateUI.presentUpdatePanel(refresh: false) { [weak self] in
                self?.resetUpdateMenuItem()
            }
        }
    }

    @MainActor
    private func resetUpdateMenuItem() {
        refreshUpdateMenuItem()
        updateCheckItem?.isEnabled = true
    }

    @MainActor
    private func refreshUpdateMenuItem() {
        updateCheckItem?.title = StatusBarMenuCopy.updateMenuTitle(
            hasActionableUpdate: UpdateScheduler.hasActionableAppUpdate
        )
    }

#if DEBUG
    private func makeSimulateUpdatesMenuItem() -> NSMenuItem {
        let simulateItem = NSMenuItem(
            title: "Simulate Update Available",
            action: #selector(simulateAppUpdate),
            keyEquivalent: ""
        )
        simulateItem.target = self

        let clearItem = NSMenuItem(
            title: "Clear Simulated Update",
            action: #selector(clearSimulatedUpdate),
            keyEquivalent: ""
        )
        clearItem.target = self

        let submenu = NSMenu()
        submenu.addItem(simulateItem)
        submenu.addItem(clearItem)

        let item = NSMenuItem(title: "Simulate Updates", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func simulateAppUpdate() {
        Task { @MainActor in
            UpdateDebugSimulator.apply()
            self.refreshUpdateMenuItem()
        }
    }

    @objc private func clearSimulatedUpdate() {
        Task { @MainActor in
            await UpdateDebugSimulator.clear()
            self.refreshUpdateMenuItem()
        }
    }
#endif

    @objc private func openAbout() {
        DispatchQueue.main.async {
            AboutWindowController.shared.show()
        }
    }

    @objc private func openSettings() {
        DispatchQueue.main.async {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func toggleOpenAtLogin() {
      DispatchQueue.main.async { [weak self] in
        self?.applyOpenAtLoginToggle()
      }
    }

    func applyOpenAtLoginToggle(
      currentlyEnabled: Bool = OpenAtLogin.isEnabled,
      setEnabled: (Bool) throws -> OpenAtLogin.Status = OpenAtLogin.setEnabled,
      presentApproval: () -> Void = { OpenAtLoginApproval.present() },
      presentFailure: (Error) -> Void = { OpenAtLoginApproval.presentFailure($0) }
    ) {
      OpenAtLoginToggle.apply(
        currentlyEnabled: currentlyEnabled,
        setEnabled: setEnabled,
        onStatus: { [weak self] status in
          self?.refreshOpenAtLoginMenuItem(status: status)
        },
        onRequiresApproval: presentApproval,
        onFailure: { [weak self] error in
          self?.refreshOpenAtLoginMenuItem()
          presentFailure(error)
        }
      )
    }

    func menuWillOpen(_ menu: NSMenu) {
      refreshOpenAtLoginMenuItem()
    }

    private func refreshOpenAtLoginMenuItem(status: OpenAtLogin.Status = OpenAtLogin.status) {
      openAtLoginItem?.state = status == .enabled ? .on : .off
    }

    @objc private func restartCodex() {
        DispatchQueue.main.async { [weak self] in
            self?.restartCodexIfConfirmed()
        }
    }

    func restartCodexIfConfirmed(confirm: () -> Bool = RestartCodexConfirmation.confirm) {
        RestartCodexGate.restartIfConfirmed(confirm: confirm, restart: apiClient.restartCodex)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

enum OpenAtLoginApproval {
  static func present(
    openSettings: () -> Void = OpenAtLogin.openSystemSettings
  ) {
    let shouldRestoreAccessory = NSApp.activationPolicy() == .accessory
      && !NSApp.windows.contains { $0.isVisible }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    NSRunningApplication.current.activate(options: [.activateAllWindows])

    let alert = NSAlert()
    alert.messageText = OpenAtLoginMenuCopy.approvalTitle
    alert.informativeText = OpenAtLoginMenuCopy.approvalMessage
    alert.alertStyle = .informational
    alert.addButton(withTitle: OpenAtLoginMenuCopy.openSettingsButton)
    alert.addButton(withTitle: OpenAtLoginMenuCopy.cancelButton)
    alert.window.level = .modalPanel
    let response = alert.runModal()

    if shouldRestoreAccessory {
      NSApp.setActivationPolicy(.accessory)
    }

    if response == .alertFirstButtonReturn {
      openSettings()
    }
  }

  static func presentFailure(_ error: Error) {
    let shouldRestoreAccessory = NSApp.activationPolicy() == .accessory
      && !NSApp.windows.contains { $0.isVisible }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    NSRunningApplication.current.activate(options: [.activateAllWindows])

    let alert = NSAlert()
    alert.messageText = OpenAtLoginMenuCopy.failureTitle
    alert.informativeText = OpenAtLoginMenuCopy.failureMessage(error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.window.level = .modalPanel
    _ = alert.runModal()

    if shouldRestoreAccessory {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
