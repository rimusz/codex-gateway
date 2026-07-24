import AppKit

@MainActor
enum UpdatePanel {
  private static let appName = AppIdentity.productName
  fileprivate static let skipAppVersionTitle = "Skip This Version"
  private static var panel: NSPanel?
  private static var panelDelegate: PanelDelegate?
  private static var host: UpdatePanelHost?

  static func show(
    app: Result<UpdateChecker.AppRelease, Error>,
    onDismiss: @escaping () -> Void
  ) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows])

    let panelHost = UpdatePanelHost(
      app: app,
      onDismiss: onDismiss
    )
    host = panelHost

    let content = panelHost.presentation
    let panelWidth = computedPanelWidth(for: content)
    let rootView = panelHost.makeRootView(panelWidth: panelWidth)
    rootView.layoutSubtreeIfNeeded()
    let size = NSSize(width: panelWidth, height: rootView.fittingSize.height)

    if let panel {
      panel.contentView = rootView
      panel.setContentSize(size)
      configureWindow(panel)
      let delegate = PanelDelegate(onClose: cleanupAndDismiss(onDismiss: panelHost.onDismiss))
      panel.delegate = delegate
      panelDelegate = delegate
      panel.center()
      panel.collectionBehavior.insert(.moveToActiveSpace)
      panel.makeKeyAndOrderFront(nil)
      panel.orderFrontRegardless()
      panelHost.attach(panel: panel)
      return
    }

    let window = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = ""
    window.contentView = rootView
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    configureWindow(window)

    let delegate = PanelDelegate(onClose: cleanupAndDismiss(onDismiss: panelHost.onDismiss))
    window.delegate = delegate
    panelDelegate = delegate

    window.center()
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    panel = window
    panelHost.attach(panel: window)
  }

  static func refreshIfVisible() {
    guard let panel, let host else { return }
    let content = host.presentation
    let panelWidth = computedPanelWidth(for: content)
    let rootView = host.makeRootView(panelWidth: panelWidth)
    rootView.layoutSubtreeIfNeeded()
    panel.contentView = rootView
    panel.setContentSize(NSSize(width: panelWidth, height: rootView.fittingSize.height))
  }

  private static func cleanupAndDismiss(onDismiss: @escaping () -> Void) -> () -> Void {
    {
      let closing = UpdatePanel.panel
      UpdatePanel.host = nil
      UpdatePanel.panelDelegate = nil
      // Re-evaluate on dismiss: About/Settings may have opened or closed while
      // this panel was up. A capture-at-show flag can leave `.regular` stuck
      // with a Dock icon and no windows.
      AppActivationPolicy.restoreAccessoryIfNoVisibleWindows(excluding: closing)
      onDismiss()
    }
  }

  private static func computedPanelWidth(for content: UpdatePanelHost.Presentation) -> CGFloat {
    let horizontalPadding: CGFloat = 72
    let minimumWidth: CGFloat = 320
    return max(minimumWidth, ceil(measuredContentWidth(for: content) + horizontalPadding))
  }

  private static func configureWindow(_ window: NSWindow) {
    window.title = ""
    window.titleVisibility = .hidden
    window.appearance = NSApp.appearance
  }

  private static func measuredContentWidth(for content: UpdatePanelHost.Presentation) -> CGFloat {
    var maxWidth = UpdatePanelStyle.iconDisplaySize
    maxWidth = max(maxWidth, textWidth(appName, font: UpdatePanelStyle.appNameFont))

    for line in content.body.components(separatedBy: "\n") {
      maxWidth = max(maxWidth, textWidth(line, font: UpdatePanelStyle.bodyFont))
    }

    let buttonFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let buttonTitles: [String?] = [
      content.appPrimaryButtonTitle,
      content.appShowSkipButton ? skipAppVersionTitle : nil,
    ]
    for title in buttonTitles.compactMap({ $0 }) {
      maxWidth = max(maxWidth, textWidth(title, font: buttonFont) + 28)
    }

    return maxWidth
  }

  private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }
}

@MainActor
private final class UpdatePanelHost: NSObject {
  struct Presentation {
    let statusLine: String
    let body: String
    let appUpdateAvailable: Bool
    let canInstallInApp: Bool
    let progressText: String?
    let showProgress: Bool
    let progressIndeterminate: Bool
    let progressValue: Double
    let appPrimaryButtonTitle: String?
    let appPrimaryButtonEnabled: Bool
    let appShowSkipButton: Bool
  }

  private let app: Result<UpdateChecker.AppRelease, Error>
  let onDismiss: () -> Void
  private var appPhaseObserver: NSObjectProtocol?
  private weak var panel: NSPanel?

  private(set) var presentation: Presentation

  init(app: Result<UpdateChecker.AppRelease, Error>, onDismiss: @escaping () -> Void) {
    self.app = app
    self.onDismiss = onDismiss
    self.presentation = Self.makePresentation(app: app)
    super.init()

    appPhaseObserver = NotificationCenter.default.addObserver(
      forName: .codexGatewayUpdaterPhaseChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshPresentation()
      }
    }
  }

  deinit {
    if let appPhaseObserver {
      NotificationCenter.default.removeObserver(appPhaseObserver)
    }
  }

  func attach(panel: NSPanel) {
    self.panel = panel
  }

  func makeRootView(panelWidth: CGFloat) -> NSView {
    let content = presentation
    let effect = NSVisualEffectView()
    effect.material = .underPageBackground
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false

    let iconView = NSImageView()
    iconView.image = UpdatePanelStyle.icon()
    iconView.imageScaling = .scaleNone
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let nameLabel = centeredLabel(AppIdentity.productName, font: UpdatePanelStyle.appNameFont)

    let bodyLabel = NSTextField(wrappingLabelWithString: content.body)
    bodyLabel.font = UpdatePanelStyle.bodyFont
    bodyLabel.textColor = .labelColor
    bodyLabel.alignment = .center
    bodyLabel.isSelectable = true
    bodyLabel.lineBreakMode = .byWordWrapping
    bodyLabel.preferredMaxLayoutWidth = panelWidth - 40
    bodyLabel.translatesAutoresizingMaskIntoConstraints = false

    effect.addSubview(container)
    container.addSubview(iconView)
    container.addSubview(nameLabel)
    container.addSubview(bodyLabel)

    var bottomAnchor = bodyLabel.bottomAnchor
    var constraints: [NSLayoutConstraint] = [
      effect.widthAnchor.constraint(equalToConstant: panelWidth),

      // Pin top/leading/trailing only — height comes from the content chain so
      // fittingSize includes the button stack (bottom pin would fight measurement).
      container.topAnchor.constraint(equalTo: effect.topAnchor),
      container.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

      iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
      iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      iconView.widthAnchor.constraint(equalToConstant: UpdatePanelStyle.iconDisplaySize),
      iconView.heightAnchor.constraint(equalToConstant: UpdatePanelStyle.iconDisplaySize),

      nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
      nameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

      bodyLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
      bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
    ]

    if content.showProgress {
      let progressLabel = centeredLabel(content.progressText ?? "", font: UpdatePanelStyle.bodyFont)
      let progress = NSProgressIndicator()
      progress.isIndeterminate = content.progressIndeterminate
      if !content.progressIndeterminate {
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = content.progressValue
      }
      progress.translatesAutoresizingMaskIntoConstraints = false
      if content.progressIndeterminate {
        progress.startAnimation(nil)
      }

      container.addSubview(progressLabel)
      container.addSubview(progress)

      constraints += [
        progressLabel.topAnchor.constraint(equalTo: bottomAnchor, constant: 12),
        progressLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

        progress.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
        progress.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        progress.widthAnchor.constraint(equalToConstant: min(panelWidth - 80, 260)),
      ]
      bottomAnchor = progress.bottomAnchor
    }

    if content.appUpdateAvailable || content.appPrimaryButtonTitle != nil {
      let stack = makeButtonStack(
        primaryTitle: content.appPrimaryButtonTitle,
        primaryEnabled: content.appPrimaryButtonEnabled,
        primaryAction: #selector(appPrimaryAction(_:)),
        skipTitle: content.appShowSkipButton ? UpdatePanel.skipAppVersionTitle : nil,
        skipAction: #selector(skipAppVersion(_:))
      )
      container.addSubview(stack)
      constraints += [
        stack.topAnchor.constraint(equalTo: bottomAnchor, constant: 16),
        stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      ]
    } else {
      constraints += [
        bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      ]
    }

    NSLayoutConstraint.activate(constraints)
    container.layoutSubtreeIfNeeded()
    let contentHeight = ceil(max(container.fittingSize.height, 1))
    effect.heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
    effect.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
    return effect
  }

  private func makeButtonStack(
    primaryTitle: String?,
    primaryEnabled: Bool,
    primaryAction: Selector,
    skipTitle: String?,
    skipAction: Selector?
  ) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    if let primaryTitle {
      let button = NSButton(title: primaryTitle, target: self, action: primaryAction)
      // System default (Return) button keeps label contrast correct on macOS Tahoe+.
      button.bezelStyle = .rounded
      button.keyEquivalent = "\r"
      button.isEnabled = primaryEnabled
      stack.addArrangedSubview(button)
    }

    if let skipTitle, let skipAction {
      let button = NSButton(title: skipTitle, target: self, action: skipAction)
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      stack.addArrangedSubview(button)
    }

    return stack
  }

  @objc private func appPrimaryAction(_ sender: NSButton) {
    guard case .success(let release) = app else { return }

    switch AppUpdater.shared.phase {
    case .readyToInstall(let extractedAppURL, _):
      confirmAppInstall(version: release.latestVersion) {
        AppUpdater.shared.installAndRestart(extractedAppURL: extractedAppURL)
      }
    case .idle, .failed:
#if DEBUG
      let canInstall = release.canInstallInApp
        || UpdateDebugSimulator.isAppSimulationActive
        || UpdateDebugSimulator.isSimulatedAppRelease(release)
#else
      let canInstall = release.canInstallInApp
#endif
      guard canInstall else {
        NSWorkspace.shared.open(release.releaseURL)
        return
      }
      // Manual install clears a prior "Skip This Version" for this release.
      if UpdateSettingsStore.dismissedVersion == release.latestVersion {
        UpdateSettingsStore.dismissedVersion = nil
      }
      Task {
        await AppUpdater.shared.downloadAndVerify(release: release)
      }
    case .downloading, .verifying, .installing:
      break
    }
  }

  @objc private func skipAppVersion(_ sender: NSButton) {
    guard case .success(let release) = app else { return }
    UpdateSettingsStore.skipVersion(release.latestVersion)
    onDismiss()
    panel?.close()
  }

  private func confirmAppInstall(version: String, onConfirm: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = "Install \(AppIdentity.productName) \(version)?"
    alert.informativeText = "\(AppIdentity.productName) will quit, replace itself with the new version, and reopen. Save any work first."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Install and Restart")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      onConfirm()
    }
  }

  private func refreshPresentation() {
    presentation = Self.makePresentation(app: app)
    UpdatePanel.refreshIfVisible()
  }

  private static func makePresentation(app: Result<UpdateChecker.AppRelease, Error>) -> Presentation {
    var body = ""
    let decision: UpdatePanelModel.Decision

    switch app {
    case .success(let release):
      let shouldNotify = UpdateSettingsStore.shouldNotify(for: release)
#if DEBUG
      let forceInstall = UpdateDebugSimulator.isAppSimulationActive
        || UpdateDebugSimulator.isSimulatedAppRelease(release)
#else
      let forceInstall = false
#endif
      decision = UpdatePanelModel.decision(
        for: release,
        shouldNotify: shouldNotify,
        forceCanInstallInApp: forceInstall
      )

      let installedAhead = UpdateChecker.compareVersions(
        release.installedVersion,
        release.latestVersion
      ) == .orderedDescending

      var lines = [
        "Installed: \(release.installedVersion)",
        "Latest release: \(release.latestVersion)",
      ]
      if installedAhead {
        lines.append("Status: Installed build is newer than the latest GitHub release.")
      } else if release.updateAvailable {
        lines.append("Status: Update available.")
      } else {
        lines.append("Status: Up to date.")
      }
      body = lines.joined(separator: "\n")
    case .failure(let error):
      decision = UpdatePanelModel.decision(forFailure: error)
      body = "Could not check for updates: \(error.localizedDescription)"
    }

    let appUpdater = AppUpdater.shared
    var progressText: String?
    var showProgress = false
    var progressIndeterminate = false
    var progressValue = 0.0
    var appPrimaryButtonTitle: String?
    var appPrimaryButtonEnabled = true
    let appShowSkipButton = decision.showSkipButton
    let appUpdateAvailable = decision.showsInstallAction
    let canInstallInApp = decision.canInstallInApp

    switch appUpdater.phase {
    case .idle:
      appPrimaryButtonTitle = decision.primaryButtonTitleWhenIdle
    case .downloading(let progress):
      showProgress = true
      progressValue = progress
      progressText = "Downloading \(AppIdentity.productName)… \(Int(progress * 100))%"
      appPrimaryButtonTitle = "Downloading…"
      appPrimaryButtonEnabled = false
    case .verifying:
      showProgress = true
      progressText = "Verifying \(AppIdentity.productName) download…"
      progressValue = 0
      appPrimaryButtonTitle = "Verifying…"
      appPrimaryButtonEnabled = false
    case .readyToInstall(_, let version):
      progressText = "Ready to install \(AppIdentity.productName) \(version)."
      appPrimaryButtonTitle = "Install and Restart"
    case .installing:
      showProgress = true
      progressIndeterminate = true
      progressText = "Installing \(AppIdentity.productName) update…"
      appPrimaryButtonTitle = "Installing…"
      appPrimaryButtonEnabled = false
    case .failed(let message):
      progressText = message
      if appUpdateAvailable {
        appPrimaryButtonTitle = canInstallInApp ? "Retry Update" : "Open Release Page"
      }
    }

    var bodyParts = [decision.statusLine]
    if !appUpdateAvailable, decision.statusLine == "No Updates Available" {
      bodyParts.append("Nothing to install right now.")
    }
    bodyParts.append(body)
    if let progressText, !progressText.isEmpty, !showProgress {
      bodyParts.append(progressText)
    }

    return Presentation(
      statusLine: decision.statusLine,
      body: bodyParts.joined(separator: "\n\n"),
      appUpdateAvailable: appUpdateAvailable,
      canInstallInApp: canInstallInApp,
      progressText: progressText,
      showProgress: showProgress,
      progressIndeterminate: progressIndeterminate,
      progressValue: progressValue,
      appPrimaryButtonTitle: appPrimaryButtonTitle,
      appPrimaryButtonEnabled: appPrimaryButtonEnabled,
      appShowSkipButton: appShowSkipButton
    )
  }

  private func centeredLabel(_ text: String, font: NSFont) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = .labelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
  private let onClose: () -> Void

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  func windowWillClose(_ notification: Notification) {
    onClose()
  }
}
