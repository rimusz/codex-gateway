import Foundation

enum Paths {
  /// Real user home. Cached so production path strings stay stable.
  private static let userHome = FileManager.default.homeDirectoryForCurrentUser.path

  /// When set, every path below is rooted here instead of the user home.
  /// The app leaves this nil. Tests set a temporary directory before they
  /// read or write these files, and clear it when the bundle finishes.
  static var rootDirectoryOverride: String?

  /// `override` nil or blank uses the real user home. A non-empty value is the root.
  static func homePath(rootedAt override: String?) -> String {
    if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
      return override
    }
    return userHome
  }

  static var home: String {
    homePath(rootedAt: rootDirectoryOverride)
  }

  /// Canonical CodexGateway config directory.
  static var configDir: String { "\(home)/.codexgateway" }
  /// Pre-rename config directory; migrated once into `configDir` on launch.
  static var legacyConfigDir: String { "\(home)/.codexbar" }
  static var codexHome: String { "\(home)/.codex" }
  static var codexModelCatalogDir: String { "\(codexHome)/model-catalogs" }
  static var codexModelCatalog: String { "\(codexModelCatalogDir)/custom-providers.json" }
  static var codexConfig: String { "\(codexHome)/config.toml" }
  static var codexAuth: String { "\(codexHome)/auth.json" }
  static var modelCatalog: String { "\(configDir)/custom_model_catalog.json" }
  static var providersConfig: String { "\(configDir)/providers.json" }
  static var fetchedModelsCache: String { "\(configDir)/fetched_models.json" }
  /// Gemini `tool_calls[].extra_content`, keyed by provider id and call id.
  static var toolCallExtraContentCache: String { "\(configDir)/tool_call_extra_content.json" }
  static let gatewayPort: UInt16 = 8765
  static let gatewayHost = "127.0.0.1"

  /// Known files moved from `~/.codexbar` → `~/.codexgateway`.
  static let configFilenames = [
    "providers.json",
    "custom_model_catalog.json",
    "fetched_models.json",
  ]

  static func prepare() {
    migrateLegacyConfigDirectory()
    ensureConfigDir()
  }

  static func ensureConfigDir() {
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: codexModelCatalogDir, withIntermediateDirectories: true)
  }

  /// Moves `~/.codexbar` → `~/.codexgateway` when needed so upgrades keep providers/keys.
  ///
  /// - If only the legacy dir exists: rename it.
  /// - If both exist: copy any missing known files into the new dir, then remove legacy.
  /// - If only the new dir exists: no-op.
  /// - If rename fails and nothing could be copied into a pre-existing current dir,
  ///   leave the legacy dir in place (do not delete the only copy of user config).
  @discardableResult
  static func migrateLegacyConfigDirectory(
    legacyDir: String = Paths.legacyConfigDir,
    currentDir: String = Paths.configDir,
    fileManager: FileManager = .default
  ) -> Bool {
    var isLegacyDir: ObjCBool = false
    guard fileManager.fileExists(atPath: legacyDir, isDirectory: &isLegacyDir), isLegacyDir.boolValue else {
      return false
    }

    var isCurrentDir: ObjCBool = false
    let currentExists = fileManager.fileExists(atPath: currentDir, isDirectory: &isCurrentDir)
      && isCurrentDir.boolValue

    if !currentExists {
      do {
        try fileManager.moveItem(atPath: legacyDir, toPath: currentDir)
        GatewayLog.info("Migrated config directory \(legacyDir) → \(currentDir)")
        return true
      } catch {
        GatewayLog.error("Failed to migrate config directory: \(error.localizedDescription)")
        // Fall through: try copy+remove so a partial failure can still recover.
      }
    }

    try? fileManager.createDirectory(atPath: currentDir, withIntermediateDirectories: true)
    var copiedAny = false
    for name in configFilenames {
      let src = (legacyDir as NSString).appendingPathComponent(name)
      let dst = (currentDir as NSString).appendingPathComponent(name)
      guard fileManager.fileExists(atPath: src) else { continue }
      if fileManager.fileExists(atPath: dst) {
        // Keep existing current files unless they're empty and legacy has content.
        let dstSize = (try? fileManager.attributesOfItem(atPath: dst)[.size] as? NSNumber)?.intValue ?? 0
        let srcSize = (try? fileManager.attributesOfItem(atPath: src)[.size] as? NSNumber)?.intValue ?? 0
        guard dstSize == 0, srcSize > 0 else { continue }
        try? fileManager.removeItem(atPath: dst)
      }
      do {
        try fileManager.copyItem(atPath: src, toPath: dst)
        copiedAny = true
      } catch {
        GatewayLog.error("Failed to copy \(name) during config migration: \(error.localizedDescription)")
      }
    }

    // Never delete the only copy of user config: if the current dir did not already
    // exist and no known files were copied, leave `~/.codexbar` in place.
    guard currentExists || copiedAny else {
      GatewayLog.error(
        "Leaving legacy config at \(legacyDir); could not migrate into \(currentDir)"
      )
      return false
    }

    do {
      try fileManager.removeItem(atPath: legacyDir)
      GatewayLog.info(
        copiedAny
          ? "Merged legacy config from \(legacyDir) into \(currentDir) and removed legacy dir"
          : "Removed leftover legacy config directory \(legacyDir)"
      )
      return true
    } catch {
      GatewayLog.error("Could not remove legacy config directory \(legacyDir): \(error.localizedDescription)")
      return copiedAny
    }
  }
}
