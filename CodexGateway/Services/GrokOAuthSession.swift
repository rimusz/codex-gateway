import Foundation

/// Auth kinds for third-party providers. Default / omitted = API key Bearer.
enum ProviderAuthKind: String, Codable, Sendable {
  case apiKey = "api_key"
  case grokOAuth = "grok_oauth"
  case cursorBridge = "cursor_bridge"
}

/// Reads the official Grok CLI session (`~/.grok/auth.json`) and refreshes via `grok models`.
/// Patterns: GrokBuild `GrokAuthProbe` / `locateGrokCLI`, codex-router `grok-oauth-session.mjs`.
enum GrokOAuthSession {
  private static let refreshThresholdMs: TimeInterval = 5 * 60
  private static let refreshTimeout: TimeInterval = 30
  private static let authScopePrefix = "https://auth.x.ai::"

  static var defaultAuthURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
  }

  static let loginCommand = "grok login"

  /// AppleScript that opens Terminal and runs `grok login`.
  static func loginTerminalScript(command: String = loginCommand) -> String {
    CursorBridge.NodeRequirement.brewInstallTerminalScript(command: command)
  }

  struct Session: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
  }

  struct Status: Equatable, Sendable {
    let configured: Bool
    let authPath: String
    let setupHint: String?
  }

  /// GrokBuild-style presence probe for Settings UI (env API keys are ignored).
  static func hasCachedCredentials(
    at url: URL = defaultAuthURL,
    fileManager: FileManager = .default
  ) -> Bool {
    guard fileManager.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    return !obj.isEmpty
  }

  static func status(at url: URL = defaultAuthURL) -> Status {
    let path = url.path
    guard FileManager.default.fileExists(atPath: path) else {
      return Status(
        configured: false,
        authPath: path,
        setupHint: "Run `grok login` (or `grok login --oauth`) in Terminal"
      )
    }
    guard readSession(at: url) != nil else {
      return Status(
        configured: false,
        authPath: path,
        setupHint: "Run `grok login` again; the Grok session is incomplete"
      )
    }
    return Status(configured: true, authPath: path, setupHint: nil)
  }

  /// Parse the xAI OAuth entry from auth.json (codex-router `grokSessionEntry`).
  static func readSession(at url: URL = defaultAuthURL) -> Session? {
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    for (scope, value) in root {
      guard scope.hasPrefix(authScopePrefix),
            let entry = value as? [String: Any],
            let key = entry["key"] as? String,
            !key.isEmpty else { continue }
      let expiresAt = expirationDate(entry["expires_at"])
      return Session(accessToken: key, expiresAt: expiresAt)
    }
    return nil
  }

  static func expirationDate(_ value: Any?) -> Date? {
    if let number = value as? Double {
      // Seconds vs milliseconds heuristic (codex-router).
      let ms = number > 10_000_000_000 ? number : number * 1_000
      return Date(timeIntervalSince1970: ms / 1_000)
    }
    if let number = value as? Int {
      return expirationDate(Double(number))
    }
    if let string = value as? String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: string) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: string)
    }
    return nil
  }

  static func shouldRefresh(_ session: Session, now: Date = Date()) -> Bool {
    guard let expiresAt = session.expiresAt else { return false }
    return expiresAt.timeIntervalSince(now) <= refreshThresholdMs
  }

  static func isHardExpired(_ session: Session, now: Date = Date()) -> Bool {
    guard let expiresAt = session.expiresAt else { return false }
    return expiresAt <= now
  }

  /// Locate the `grok` binary (GrokBuild search order).
  static func locateGrokCLI(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    if let path = environment["GROK_CLI_PATH"], !path.isEmpty {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      if fileManager.isExecutableFile(atPath: url.path) { return url }
    }
    if let path = environment["GROK_CLI"], !path.isEmpty {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      if fileManager.isExecutableFile(atPath: url.path) { return url }
    }
    let home = NSHomeDirectory()
    for candidate in [
      "\(home)/.grok/bin/grok",
      "\(home)/bin/grok",
      "/opt/homebrew/bin/grok",
      "/usr/local/bin/grok",
    ] {
      if fileManager.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    if let path = environment["PATH"] {
      for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("grok").path
        if fileManager.isExecutableFile(atPath: candidate) {
          return URL(fileURLWithPath: candidate)
        }
      }
    }
    return nil
  }

  enum SessionError: LocalizedError {
    case unavailable
    case incomplete
    case refreshFailed

    var errorDescription: String? {
      switch self {
      case .unavailable:
        return "Grok OAuth session is unavailable; run `grok login`."
      case .incomplete:
        return "Grok OAuth session is incomplete; run `grok login`."
      case .refreshFailed:
        return "Grok OAuth could not be refreshed; run `grok login`."
      }
    }
  }

  /// Returns a usable access token, refreshing via `grok models` when near expiry.
  static func ensureFreshAccessToken(
    at url: URL = defaultAuthURL,
    force: Bool = false,
    now: Date = Date(),
    refresh: (() throws -> Void)? = nil
  ) throws -> String {
    guard let initial = readSession(at: url) else {
      throw hasCachedCredentials(at: url) ? SessionError.incomplete : SessionError.unavailable
    }
    if !force && !shouldRefresh(initial, now: now) {
      return initial.accessToken
    }

    let refreshFn = refresh ?? { try runGrokModelsRefresh() }
    do {
      try refreshFn()
    } catch {
      if !force && !isHardExpired(initial, now: now) {
        return initial.accessToken
      }
      throw SessionError.refreshFailed
    }

    guard let refreshed = readSession(at: url) else {
      throw SessionError.refreshFailed
    }
    if refreshed.accessToken == initial.accessToken {
      if !force && !isHardExpired(refreshed, now: now) {
        return refreshed.accessToken
      }
      throw SessionError.refreshFailed
    }
    return refreshed.accessToken
  }

  private static func runGrokModelsRefresh() throws {
    guard let cli = locateGrokCLI() else {
      throw SessionError.refreshFailed
    }
    let process = Process()
    process.executableURL = cli
    process.arguments = ["models"]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "XAI_API_KEY")
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()

    let deadline = Date().addingTimeInterval(refreshTimeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
      process.terminate()
      throw SessionError.refreshFailed
    }
    if process.terminationStatus != 0 {
      throw SessionError.refreshFailed
    }
  }
}

extension ProviderConfig {
  var resolvedAuthKind: ProviderAuthKind {
    if let raw = auth_kind?.trimmingCharacters(in: .whitespacesAndNewlines),
       let kind = ProviderAuthKind(rawValue: raw) {
      return kind
    }
    return .apiKey
  }

  var usesGrokOAuth: Bool { resolvedAuthKind == .grokOAuth }

  var usesCursorBridge: Bool {
    resolvedAuthKind == .cursorBridge || name == ProviderPreset.cursor.providerID
  }
}
