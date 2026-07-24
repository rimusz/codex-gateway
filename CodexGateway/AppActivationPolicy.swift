import AppKit

/// Menu-bar apps briefly switch to `.regular` while showing windows/alerts,
/// then must return to `.accessory` when no user-facing windows remain.
enum AppActivationPolicy {
  /// Pure decision helper for tests: restore accessory unless another
  /// non-closing user window is still visible.
  static func shouldRestoreAccessory(
    hasOtherVisibleWindow: Bool
  ) -> Bool {
    !hasOtherVisibleWindow
  }

  /// Pure classifier for tests / `isUserFacingWindow(_:)`.
  ///
  /// Status items keep an always-visible synthetic window (`Item-N` /
  /// `NSStatusBarWindow`) that must not block returning to accessory mode.
  static func isUserFacingWindow(
    title: String,
    className: String,
    styleIncludesTitled: Bool
  ) -> Bool {
    if className.contains("NSStatusBar") { return false }
    if title.hasPrefix("Item-") { return false }
    return styleIncludesTitled
  }

  static func isUserFacingWindow(_ window: NSWindow) -> Bool {
    isUserFacingWindow(
      title: window.title,
      className: NSStringFromClass(type(of: window)),
      styleIncludesTitled: window.styleMask.contains(.titled)
    )
  }

  /// Restore `.accessory` when every remaining user-facing window is either
  /// hidden or the one currently closing (so dismiss paths don't leave a Dock
  /// icon behind).
  @MainActor
  static func restoreAccessoryIfNoVisibleWindows(excluding closing: NSWindow? = nil) {
    let hasOtherVisibleWindow = NSApp.windows.contains { candidate in
      candidate !== closing
        && candidate.isVisible
        && isUserFacingWindow(candidate)
    }
    if shouldRestoreAccessory(hasOtherVisibleWindow: hasOtherVisibleWindow) {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
