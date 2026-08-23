import Foundation

/// Reads the local Claude Code / Claude CLI login (macOS Keychain, `~/.claude`, or
/// `CLAUDE_CODE_OAUTH_TOKEN`) at request time. Tokens are never written to
/// `providers.json` or the repo.
enum ClaudeCodeSession {
  static let loginCommand = "claude auth login"
  static let keychainService = "Claude Code-credentials"
  static let oatPrefix = "sk-ant-oat"

  static var defaultCredentialsURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
  }

  static var legacyCredentialsURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
  }

  static func loginTerminalScript(command: String = loginCommand) -> String {
    CursorBridge.NodeRequirement.brewInstallTerminalScript(command: command)
  }

  struct Session: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?

    var looksLikeOAuthAccessToken: Bool {
      ClaudeCodeSession.looksLikeOAuthAccessToken(accessToken)
    }

    var isExpired: Bool {
      guard let expiresAt else { return false }
      return expiresAt <= Date()
    }
  }

  struct Status: Equatable, Sendable {
    let configured: Bool
    let sourcePath: String
    let setupHint: String?

    static func idle(sourcePath: String = ClaudeCodeSession.defaultCredentialsURL.path) -> Status {
      Status(configured: false, sourcePath: sourcePath, setupHint: nil)
    }
  }

  /// Keychain/file probe is only needed when Claude Code is installed or the user opens that sheet.
  static func shouldProbeStatus(providers: [ProviderConfig], force: Bool) -> Bool {
    force || providers.contains { $0.usesClaudeCodeAuth }
  }

  static func looksLikeOAuthAccessToken(_ token: String) -> Bool {
    token.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .hasPrefix(oatPrefix)
  }

  static func parseCredentials(_ data: Data) -> Session? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return session(from: object)
  }

  static func session(from object: [String: Any]) -> Session? {
    let oauth = (object["claudeAiOauth"] as? [String: Any])
      ?? (object["claude_ai_oauth"] as? [String: Any])
      ?? object
    let raw = (oauth["accessToken"] as? String)
      ?? (oauth["access_token"] as? String)
      ?? ""
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }
    return Session(accessToken: token, expiresAt: expirationDate(oauth["expiresAt"] ?? oauth["expires_at"]))
  }

  static func expirationDate(_ raw: Any?) -> Date? {
    let value: Double
    if let number = raw as? Double {
      value = number
    } else if let number = raw as? Int {
      value = Double(number)
    } else if let text = raw as? String, let number = Double(text) {
      value = number
    } else {
      return nil
    }
    let seconds = value > 10_000_000_000 ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
  }

  /// Runtime probe: env, `~/.claude/.credentials.json`, `~/.claude.json`, then macOS Keychain.
  static func loadSession(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Session? {
    if let env = environment["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !env.isEmpty {
      return Session(accessToken: env, expiresAt: nil)
    }
    for url in [credentialsURL, legacyURL] {
      if let data = try? Data(contentsOf: url), let session = parseCredentials(data) {
        return session
      }
    }
    if let data = readKeychain(), let session = parseCredentials(data) {
      return session
    }
    return nil
  }

  /// Live token for upstream calls. Expired sessions are treated as missing.
  static func loadUsableSession(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Session? {
    guard let session = loadSession(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain
    ), !session.isExpired else {
      return nil
    }
    return session
  }

  static func hasCachedCredentials(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Bool {
    loadSession(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain
    ) != nil
  }

  static func status(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Status {
    let session = loadSession(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain
    )
    if let session, session.isExpired {
      return Status(
        configured: false,
        sourcePath: credentialsURL.path,
        setupHint: "Claude Code login expired. Run `\(loginCommand)` in Terminal."
      )
    }
    if session != nil {
      return Status(configured: true, sourcePath: credentialsURL.path, setupHint: nil)
    }
    return Status(
      configured: false,
      sourcePath: credentialsURL.path,
      setupHint: "Run `\(loginCommand)` (or Claude Code /login). Credentials stay in ~/.claude or the macOS Keychain — not in providers.json."
    )
  }

  static func missingSessionMessage() -> String {
    "Claude Code is not signed in. Run `\(loginCommand)` in Terminal, then try again."
  }

  /// Console API-key field must not accept a Claude Code / claude.ai OAuth token.
  static func consoleKeyRejectionMessage(for key: String) -> String? {
    guard looksLikeOAuthAccessToken(key) else { return nil }
    return "That looks like a Claude Code login token. Install Anthropic (Claude Code) instead — do not paste an OAuth token into the Console API key field."
  }

  /// Only the Anthropic Console-key preset rejects `sk-ant-oat…` keys.
  static func consoleKeyRejectionMessage(for preset: ProviderPreset, key: String) -> String? {
    guard preset == .anthropic else { return nil }
    return consoleKeyRejectionMessage(for: key)
  }

  /// macOS-only; returns nil on Linux / when `security` cannot read the item.
  static func readMacOSKeychain(
    service: String = keychainService,
    account: String = NSUserName()
  ) -> Data? {
    #if os(macOS)
    func run(_ arguments: [String]) -> Data? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return nil
      }
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return data.isEmpty ? nil : data
    }
    if let data = run(["find-generic-password", "-s", service, "-a", account, "-w"]) {
      return data
    }
    return run(["find-generic-password", "-s", service, "-w"])
    #else
    return nil
    #endif
  }
}
