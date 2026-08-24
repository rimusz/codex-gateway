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

  static let envSourceLabel = "$CLAUDE_CODE_OAUTH_TOKEN"
  static let keychainSourceLabel = "keychain:Claude Code-credentials"

  struct Session: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let sourcePath: String

    init(accessToken: String, expiresAt: Date?, sourcePath: String = "") {
      self.accessToken = accessToken
      self.expiresAt = expiresAt
      self.sourcePath = sourcePath
    }

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

  static func isUsable(_ session: Session) -> Bool {
    !session.isExpired && session.looksLikeOAuthAccessToken
  }

  /// Local Claude Code sessions in priority order: env → credentials file → legacy file → Keychain.
  /// `stop` ends the walk early (hot path: stop after the first usable token so Keychain is skipped).
  static func loadSessions(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() },
    stop: (Session) -> Bool = { _ in false }
  ) -> [Session] {
    var sessions: [Session] = []
    func consider(_ session: Session) -> Bool {
      sessions.append(session)
      return stop(session)
    }
    if let env = environment["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !env.isEmpty {
      if consider(Session(accessToken: env, expiresAt: nil, sourcePath: envSourceLabel)) {
        return sessions
      }
    }
    for url in [credentialsURL, legacyURL] {
      if let data = try? Data(contentsOf: url), let parsed = parseCredentials(data) {
        let session = Session(
          accessToken: parsed.accessToken,
          expiresAt: parsed.expiresAt,
          sourcePath: url.path
        )
        if consider(session) { return sessions }
      }
    }
    if let data = readKeychain(), let parsed = parseCredentials(data) {
      _ = consider(
        Session(
          accessToken: parsed.accessToken,
          expiresAt: parsed.expiresAt,
          sourcePath: keychainSourceLabel
        )
      )
    }
    return sessions
  }

  /// Runtime probe: first source that parses (may be expired). Prefer `loadUsableSession()` for API calls.
  static func loadSession(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Session? {
    loadSessions(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain,
      stop: { _ in true }
    ).first
  }

  /// Live token for upstream calls. Skips expired / non-OAuth sources so a stale
  /// `~/.claude/.credentials.json` does not hide a refreshed Keychain login.
  /// Stops at the first usable source so a valid env/file token does not spawn `security`.
  static func loadUsableSession(
    credentialsURL: URL = defaultCredentialsURL,
    legacyURL: URL = legacyCredentialsURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readKeychain: () -> Data? = { readMacOSKeychain() }
  ) -> Session? {
    loadSessions(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain,
      stop: isUsable
    ).first(where: isUsable)
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
    let sessions = loadSessions(
      credentialsURL: credentialsURL,
      legacyURL: legacyURL,
      environment: environment,
      readKeychain: readKeychain,
      stop: isUsable
    )
    if let usable = sessions.first(where: isUsable) {
      let source = usable.sourcePath.isEmpty ? credentialsURL.path : usable.sourcePath
      return Status(configured: true, sourcePath: source, setupHint: nil)
    }
    guard let first = sessions.first else {
      return Status(
        configured: false,
        sourcePath: credentialsURL.path,
        setupHint: "Run `\(loginCommand)` (or Claude Code /login). Credentials stay in ~/.claude or the macOS Keychain — not in providers.json."
      )
    }
    let reportedSource = first.sourcePath.isEmpty ? credentialsURL.path : first.sourcePath
    if first.isExpired {
      return Status(
        configured: false,
        sourcePath: reportedSource,
        setupHint: "Claude Code login expired. Run `\(loginCommand)` in Terminal."
      )
    }
    if !first.looksLikeOAuthAccessToken {
      return Status(
        configured: false,
        sourcePath: reportedSource,
        setupHint: "The local credential is not a Claude Code OAuth token. Run `\(loginCommand)` — do not use an Anthropic Console API key here."
      )
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
