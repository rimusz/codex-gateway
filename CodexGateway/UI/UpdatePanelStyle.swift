import AppKit

enum UpdatePanelStyle {
  static let iconDisplaySize: CGFloat = 64

  /// Fraction of icon side used by macOS Dock / Big Sur app-icon corner radius.
  static let dockCornerRadiusRatio: CGFloat = 0.2237

  static var appNameFont: NSFont {
    .boldSystemFont(ofSize: NSFont.systemFontSize)
  }

  static var bodyFont: NSFont {
    .systemFont(ofSize: NSFont.smallSystemFontSize)
  }

  static func dockCornerRadius(for side: CGFloat) -> CGFloat {
    side * dockCornerRadiusRatio
  }

  /// App icon scaled for About / Check for Updates, clipped to Dock-like rounded corners.
  static func icon(side: CGFloat = iconDisplaySize) -> NSImage? {
    guard let source = AppIconProvider.image() else { return nil }
    let size = NSSize(width: side, height: side)
    let rect = NSRect(origin: .zero, size: size)
    let radius = dockCornerRadius(for: side)

    let output = NSImage(size: size, flipped: false) { _ in
      NSGraphicsContext.current?.imageInterpolation = .high
      let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
      path.addClip()
      source.draw(
        in: rect,
        from: NSRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      return true
    }
    return output
  }
}
