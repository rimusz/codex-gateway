import AppKit
import Foundation

/// Product naming and upgrade-safe identity for CodexGateway.
enum AppIdentity {
  static let productName = "CodexGateway"
  static let legacyProductName = "CodexBar"
  static let bundleIdentifier = "com.rimusz.CodexGateway"
  static let legacyBundleIdentifier = "com.rimusz.CodexBar"
  /// Provider id written into `~/.codex/config.toml`.
  static let codexProviderID = "codexgateway"
  static let legacyCodexProviderID = "codexbar"
  static let legacyAppBundleName = "\(legacyProductName).app"
  static let appBundleName = "\(productName).app"
  static let installHelperResourceName = "codexgateway-install-update"
  static let legacyInstallHelperResourceName = "codexbar-install-update"

  static let managedStart = "# >>> codexgateway managed >>>"
  static let managedEnd = "# <<< codexgateway managed <<<"
  static let legacyManagedStart = "# >>> codexbar managed >>>"
  static let legacyManagedEnd = "# <<< codexbar managed <<<"

  /// Preferred + legacy GitHub release zip names for a tag (`v1.2.3`).
  static func appZipAssetNames(tagName: String) -> [String] {
    [
      "\(productName)-\(tagName).app.zip",
      "\(legacyProductName)-\(tagName).app.zip",
    ]
  }

  /// Where an in-app update should land. Migrates `…/CodexBar.app` → `…/CodexGateway.app`.
  static func installTargetURL(from currentBundleURL: URL = Bundle.main.bundleURL) -> URL {
    if currentBundleURL.lastPathComponent == legacyAppBundleName {
      return currentBundleURL
        .deletingLastPathComponent()
        .appendingPathComponent(appBundleName, isDirectory: true)
    }
    return currentBundleURL
  }

  /// Optional legacy bundle to delete after installing at a renamed path.
  static func legacyBundleToRemove(currentBundleURL: URL, targetURL: URL) -> URL? {
    guard currentBundleURL.path != targetURL.path,
          currentBundleURL.lastPathComponent == legacyAppBundleName else {
      return nil
    }
    return currentBundleURL
  }
}

/// One-shot migration when a post-rename binary is still running from `CodexBar.app`.
///
/// Older CodexBar updaters install into `/Applications/CodexBar.app`. After that update
/// lands the CodexGateway binary, this renames the folder to `CodexGateway.app` and relaunches.
enum AppBundleMigration {
  /// Pure decision helper (testable): true when the running bundle folder is still
  /// `CodexBar.app` but Info.plist already identifies as CodexGateway.
  static func shouldMigrateLegacyBundle(
    bundleURL: URL,
    bundleName: String?
  ) -> Bool {
    bundleURL.lastPathComponent == AppIdentity.legacyAppBundleName
      && bundleName == AppIdentity.productName
  }

  /// True when this process is still running from `CodexBar.app` and should quit to rename.
  static var isLegacyBundleMigrationPending: Bool {
    shouldMigrateLegacyBundle(
      bundleURL: Bundle.main.bundleURL,
      bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    )
  }

  /// - Returns: `true` when a rename helper was launched (caller should stop normal startup).
  @MainActor
  @discardableResult
  static func migrateLegacyBundleIfNeeded() -> Bool {
    let current = Bundle.main.bundleURL
    let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    guard shouldMigrateLegacyBundle(bundleURL: current, bundleName: bundleName) else {
      return false
    }

    let target = AppIdentity.installTargetURL(from: current)
    guard current.path != target.path else { return false }

    // Check writability of the destination parent / replaceability of the source bundle.
    guard AppUpdater.isInstallTargetWritable(target) || AppUpdater.isInstallTargetWritable(current) else {
      GatewayLog.error(
        "Legacy bundle migration skipped: not writable at \(current.path) → \(target.path)"
      )
      return false
    }

    // Always use a /tmp script — do not depend on Bundle resource lookup.
    // Older CodexBar updaters `ditto` without deleting first, which can leave a stale
    // MacOS/CodexBar binary and/or an old helper that doesn't support --rename-from.
    let scriptURL = URL(fileURLWithPath: "/tmp/codexgateway-rename-bundle.sh")
    let logURL = URL(fileURLWithPath: "/tmp/codexgateway_migrate.log")
    let script = """
    #!/bin/bash
    set -euo pipefail
    FROM=\(shellEscape(current.path))
    TO=\(shellEscape(target.path))
    PID=\(getpid())
    LOG=\(shellEscape(logURL.path))
    exec >>"$LOG" 2>&1
    echo "rename: waiting for pid $PID"
    for _ in $(seq 1 120); do
      if ! kill -0 "$PID" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "rename: timed out waiting for pid $PID"
      exit 1
    fi
    if [[ ! -d "$FROM" ]]; then
      echo "rename: source missing: $FROM"
      exit 1
    fi
    rm -rf "$TO"
    mv "$FROM" "$TO"
    xattr -cr "$TO" 2>/dev/null || true
    echo "rename: $FROM -> $TO"
    open "$TO"
    """

    do {
      try script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
      )
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    } catch {
      GatewayLog.error("Legacy bundle migration could not write rename script: \(error.localizedDescription)")
      return false
    }

    GatewayLog.info("Migrating app bundle \(current.path) → \(target.path) via /tmp rename script")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      GatewayLog.error("Legacy bundle migration failed to launch rename script: \(error.localizedDescription)")
      return false
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      NSApp.terminate(nil)
    }
    return true
  }

  /// Single-quote escape for embedding a path in a bash script.
  static func shellEscape(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
