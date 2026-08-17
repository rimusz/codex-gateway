import Foundation

enum CodexConfig {
  private static let managedStart = AppIdentity.managedStart
  private static let managedEnd = AppIdentity.managedEnd
  private static let providerID = AppIdentity.codexProviderID

  /// Strips both current and legacy managed blocks from Codex config.
  static func stripManagedBlocks(_ content: String) -> String {
    func blockPattern(start: String, end: String) -> String {
      let s = NSRegularExpression.escapedPattern(for: start)
      let e = NSRegularExpression.escapedPattern(for: end)
      return "\(s)[\\s\\S]*?\(e)\\n?"
    }
    let patterns = [
      blockPattern(start: AppIdentity.managedStart, end: AppIdentity.managedEnd),
      blockPattern(start: AppIdentity.legacyManagedStart, end: AppIdentity.legacyManagedEnd),
    ]
    var result = content
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        continue
      }
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Removes gateway routing left outside managed markers (for example after another
  /// config writer re-serializes managed values). Keeping those entries would create
  /// duplicate TOML keys/tables when the managed blocks are written again.
  static func stripConflictingGatewayEntries(_ content: String) -> String {
    let managedRootKeys = ["model_provider", "model_catalog_json", "openai_base_url"]
    let managedProviderTables = [
      "model_providers.\(AppIdentity.codexProviderID)",
      "model_providers.\(AppIdentity.legacyCodexProviderID)",
    ]
    var currentTable: String?
    var skipsCurrentTable = false
    var lines: [String] = []

    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("["),
         let closingBracket = trimmed.firstIndex(of: "]") {
        let startsArrayTable = trimmed.hasPrefix("[[")
        let nameStart = trimmed.index(
          trimmed.startIndex,
          offsetBy: startsArrayTable ? 2 : 1
        )
        var tableName = String(trimmed[nameStart..<closingBracket])
        if startsArrayTable, tableName.hasSuffix("]") {
          tableName.removeLast()
        }
        currentTable = tableName.trimmingCharacters(in: .whitespaces)
        skipsCurrentTable = managedProviderTables.contains(currentTable ?? "")
        if skipsCurrentTable { continue }
      }

      if skipsCurrentTable { continue }
      let assignmentKey = trimmed.split(separator: "=", maxSplits: 1)
        .first?
        .trimmingCharacters(in: .whitespaces)
      if currentTable == nil, assignmentKey.map(managedRootKeys.contains) == true {
        continue
      }
      lines.append(line)
    }

    return lines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Detects gateway routing that escaped the managed markers and would conflict
  /// with the managed keys/tables in the same TOML document.
  static func hasConflictingGatewayEntries(_ content: String) -> Bool {
    let unmanaged = stripManagedBlocks(content)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripConflictingGatewayEntries(unmanaged) != unmanaged
  }

  /// Creates `~/.codex` and an empty `config.toml` when missing so an explicit
  /// apply (Settings Update / first-run Finish) can write the managed block.
  static func ensureConfigFile(
    at path: String = Paths.codexConfig,
    fileManager: FileManager = .default
  ) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: path) {
      try Data().write(to: URL(fileURLWithPath: path))
    }
  }

  static func patchCodexConfig() {
    do {
      try patchCodexConfigThrowing()
    } catch {
      GatewayLog.error("Failed to patch config.toml: \(error.localizedDescription)")
    }
  }

  /// Throwing variant used by explicit Apply/Finish flows so they can report a failed write.
  static func patchCodexConfigThrowing(
    at path: String = Paths.codexConfig
  ) throws {
    Paths.ensureConfigDir()
    guard FileManager.default.fileExists(atPath: path) else {
      throw CocoaError(.fileNoSuchFile)
    }

    let content = try String(contentsOfFile: path, encoding: .utf8)
    let stripped = stripConflictingGatewayEntries(stripManagedBlocks(content))

    // Only require ChatGPT/OpenAI sign-in when the user is actually signed in
    // to Codex. Otherwise (e.g. local-only Ollama use) skip the login screen so
    // Codex works without an account. When signed in, native GPT/ChatGPT
    // pass-through keeps working; custom providers work in both cases because
    // the gateway supplies their keys from ~/.codexgateway/providers.json.
    let requiresOpenAIAuth = isSignedIn()
    let managedTop = managedTopBlock() + "\n\n"
    let managedProvider = "\n\n" + managedProviderBlock(requiresOpenAIAuth: requiresOpenAIAuth)

    let patched = managedTop + stripped + managedProvider + "\n"
    try patched.write(toFile: path, atomically: true, encoding: .utf8)
    GatewayLog.info("Patched ~/.codex/config.toml with gateway provider (requires_openai_auth=\(requiresOpenAIAuth))")
  }

  /// Builds the managed top-level keys. `model_provider = "codexgateway"` makes Codex
  /// actually use the gateway provider below (so its `requires_openai_auth` takes
  /// effect); without it Codex falls back to the built-in `openai` provider, which
  /// always requires sign-in.
  static func managedTopBlock() -> String {
    """
    \(managedStart)
    model_provider = "\(providerID)"
    model_catalog_json = "\(Paths.codexModelCatalog)"
    openai_base_url = "http://\(Paths.gatewayHost):\(Paths.gatewayPort)/v1"
    \(managedEnd)
    """
  }

  /// Builds the managed `[model_providers.codexgateway]` section. `requiresOpenAIAuth`
  /// controls whether Codex shows the sign-in screen for the gateway provider.
  static func managedProviderBlock(requiresOpenAIAuth: Bool) -> String {
    """
    \(managedStart)
    [model_providers.\(providerID)]
    name = "\(AppIdentity.productName)"
    base_url = "http://\(Paths.gatewayHost):\(Paths.gatewayPort)/v1"
    wire_api = "responses"
    requires_openai_auth = \(requiresOpenAIAuth)
    experimental_bearer_token = "dummy"
    request_max_retries = 3
    stream_max_retries = 3
    stream_idle_timeout_ms = 600000
    \(managedEnd)
    """
  }

  /// Resets only Codex's own configuration so it stops routing through CodexGateway:
  /// strips the managed block from `config.toml` and removes the exported picker
  /// catalog under `~/.codex`. CodexGateway's own providers/models/fetch cache in
  /// `~/.codexgateway` are intentionally preserved so the user can re-apply later.
  static func resetToNative() {
    guard FileManager.default.fileExists(atPath: Paths.codexConfig) else { return }
    do {
      let content = try String(contentsOfFile: Paths.codexConfig, encoding: .utf8)
      let cleaned = stripConflictingGatewayEntries(stripManagedBlocks(content)) + "\n"
      try cleaned.write(toFile: Paths.codexConfig, atomically: true, encoding: .utf8)
      try? FileManager.default.removeItem(atPath: Paths.codexModelCatalog)
      GatewayLog.info("Reset Codex config to native state (CodexGateway data preserved)")
    } catch {
      GatewayLog.error("Reset failed: \(error.localizedDescription)")
    }
  }

  /// Re-applies the managed config ONLY if CodexGateway was already applied to Codex
  /// (managed block present — current or legacy markers). Used by automatic callers
  /// (startup, auth watcher, restart) so CodexGateway never silently injects itself
  /// into a fresh/native Codex.
  static func refreshManagedConfigIfApplied() {
    guard hasManagedBlock() else { return }
    patchCodexConfig()
  }

  /// True when `config.toml` currently contains a managed gateway block (new or legacy).
  static func hasManagedBlock() -> Bool {
    guard let content = try? String(contentsOfFile: Paths.codexConfig, encoding: .utf8) else {
      return false
    }
    return containsManagedBlock(content)
  }

  /// Pure check for managed markers (testable without disk).
  static func containsManagedBlock(_ content: String) -> Bool {
    content.contains(AppIdentity.managedStart) || content.contains(AppIdentity.legacyManagedStart)
  }

  static func loadAuthToken() -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.codexAuth)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = json["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else {
      return nil
    }
    return token
  }

  /// True when the user has signed in to Codex Desktop (ChatGPT token or API key
  /// present in `~/.codex/auth.json`).
  static func isSignedIn() -> Bool {
    let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.codexAuth))
    return signedIn(fromAuthData: data)
  }

  /// Pure sign-in detection over raw `auth.json` bytes (testable without disk).
  static func signedIn(fromAuthData data: Data?) -> Bool {
    guard let data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    if let tokens = json["tokens"] as? [String: Any],
       let token = tokens["access_token"] as? String,
       !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    if let apiKey = json["OPENAI_API_KEY"] as? String,
       !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    return false
  }
}
