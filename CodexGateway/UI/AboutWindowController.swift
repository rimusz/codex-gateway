import AppKit

enum AboutContent {
  static let summary = "Use OpenAI-compatible models in Codex Desktop and Codex CLI."
  static let repositoryURL = URL(string: "https://github.com/rimusz/codex-gateway")!
  static let repositoryLabel = "github.com/rimusz/codex-gateway"
  static let copyright = "© 2026 CodexGateway"

  static var versionLine: String {
    "Version \(AppVersion.display)"
  }
}

/// Native About panel styled to match Check for Updates (`UpdatePanel`).
final class AboutWindowController: NSObject, NSWindowDelegate {
  static let shared = AboutWindowController()

  private var window: NSWindow?
  private var linkButton: NSButton?

  private override init() {
    super.init()
  }

  func show() {
    if let window {
      present(window)
      return
    }

    let root = makeRootView()
    root.layoutSubtreeIfNeeded()
    let size = NSSize(
      width: max(320, ceil(root.fittingSize.width)),
      height: max(1, ceil(root.fittingSize.height))
    )
    let newWindow = Self.makeWindow(contentView: root, contentSize: size, delegate: self)
    window = newWindow
    present(newWindow)
  }

  static func makeWindow(
    contentView: NSView,
    contentSize: NSSize = NSSize(width: 360, height: 240),
    delegate: NSWindowDelegate
  ) -> NSWindow {
    let window = NSPanel(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    // Match UpdatePanel chrome: traffic lights only, no title text.
    window.title = ""
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.delegate = delegate
    window.hidesOnDeactivate = false
    window.appearance = NSApp.appearance
    window.contentView = contentView
    window.setContentSize(contentSize)
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

  @objc private func openRepository(_ sender: Any?) {
    NSWorkspace.shared.open(AboutContent.repositoryURL)
  }

  private func makeRootView() -> NSView {
    let panelWidth: CGFloat = 360

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
    let versionLabel = centeredLabel(AboutContent.versionLine, font: UpdatePanelStyle.bodyFont)

    let summaryLabel = NSTextField(wrappingLabelWithString: AboutContent.summary)
    summaryLabel.font = UpdatePanelStyle.bodyFont
    summaryLabel.textColor = .labelColor
    summaryLabel.alignment = .center
    summaryLabel.isSelectable = true
    summaryLabel.lineBreakMode = .byWordWrapping
    summaryLabel.preferredMaxLayoutWidth = panelWidth - 48
    summaryLabel.translatesAutoresizingMaskIntoConstraints = false

    let link = NSButton(title: AboutContent.repositoryLabel, target: self, action: #selector(openRepository(_:)))
    link.isBordered = false
    link.bezelStyle = .inline
    link.font = UpdatePanelStyle.bodyFont
    link.contentTintColor = .linkColor
    link.focusRingType = .none
    link.translatesAutoresizingMaskIntoConstraints = false
    linkButton = link

    let copyrightLabel = centeredLabel(AboutContent.copyright, font: UpdatePanelStyle.bodyFont)

    effect.addSubview(container)
    container.addSubview(iconView)
    container.addSubview(nameLabel)
    container.addSubview(versionLabel)
    container.addSubview(summaryLabel)
    container.addSubview(link)
    container.addSubview(copyrightLabel)

    NSLayoutConstraint.activate([
      effect.widthAnchor.constraint(equalToConstant: panelWidth),

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

      versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
      versionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      versionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
      versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

      summaryLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 8),
      summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

      link.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
      link.centerXAnchor.constraint(equalTo: container.centerXAnchor),

      copyrightLabel.topAnchor.constraint(equalTo: link.bottomAnchor, constant: 8),
      copyrightLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      copyrightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
      copyrightLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
      copyrightLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
    ])

    container.layoutSubtreeIfNeeded()
    let contentHeight = ceil(max(container.fittingSize.height, 1))
    effect.heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
    effect.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
    return effect
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
