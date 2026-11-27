import Foundation
import Security

/// Reads the unofficial Antigravity CLI (`agy`) session and refreshes it by running `agy models`.
///
/// Credential document (community `agy-auth` internals, unofficial): Keychain service `gemini`,
/// account `antigravity`, with the same JSON in `~/.gemini/antigravity-cli/antigravity-oauth-token`
/// when the keyring falls back to a file. This type never writes the Keychain or the file, and it
/// never embeds a Google OAuth client id or secret. Refresh goes through the official CLI.
enum GeminiAgySession {
  static let keychainService = "gemini"
  static let keychainAccount = "antigravity"
  static let loginCommand = "agy"

  /// Shown for a missing session, a failed CLI refresh, and HTTP 401/403.
  static let signInMessage = """
    Gemini is not signed in. Run `agy` in a local terminal and complete Google sign-in. \
    The first time CodexGateway reads the login Keychain item, macOS may ask you to click Allow.
    """

  static let thoughtSignatureMessage = "The cached Gemini thought signature is missing or expired. Send a new turn so Gemini can issue a fresh signature."

  private static let refreshSkew: TimeInterval = 60
  private static let refreshTimeout: TimeInterval = 30

  struct Session: Equatable, Sendable {
    let accessToken: String
    let expiry: Date?
    let authMethod: String?
  }

  struct Status: Equatable, Sendable {
    let configured: Bool
    let source: String
    let setupHint: String?
  }

  static func defaultFileURL(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home)
      .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
  }

  static func status(
    readKeychain: () -> Data? = { readKeychainData() },
    fileURL: URL = defaultFileURL()
  ) -> Status {
    if parseSession(readKeychain()) != nil {
      return Status(configured: true, source: "keychain:\(keychainService)/\(keychainAccount)", setupHint: nil)
    }
    if parseSession(try? Data(contentsOf: fileURL)) != nil {
      return Status(configured: true, source: fileURL.path, setupHint: nil)
    }
    return Status(configured: false, source: "keychain:\(keychainService)/\(keychainAccount)", setupHint: signInMessage)
  }

  /// Prefer a parsable Keychain document, then the fallback file. Tokens are not logged.
  static func readSession(
    readKeychain: () -> Data? = { readKeychainData() },
    fileURL: URL = defaultFileURL()
  ) -> Session? {
    if let session = parseSession(readKeychain()) { return session }
    return parseSession(try? Data(contentsOf: fileURL))
  }

  static func parseSession(_ data: Data?) -> Session? {
    guard let data, !data.isEmpty,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let token = root["token"] as? [String: Any] ?? root
    guard let access = (token["access_token"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !access.isEmpty else {
      return nil
    }
    let method = (root["auth_method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Session(
      accessToken: access,
      expiry: expirationDate(token["expiry"] ?? token["expires_at"]),
      authMethod: (method?.isEmpty == false) ? method : nil
    )
  }

  static func expirationDate(_ value: Any?) -> Date? {
    if let number = value as? Double {
      let seconds = number > 10_000_000_000 ? number / 1_000 : number
      return Date(timeIntervalSince1970: seconds)
    }
    if let number = value as? Int {
      return expirationDate(Double(number))
    }
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: trimmed) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
  }

  static func isExpired(_ session: Session, now: Date = Date()) -> Bool {
    guard let expiry = session.expiry else { return false }
    return expiry.timeIntervalSince(now) <= refreshSkew
  }

  enum SessionError: LocalizedError, Equatable {
    case notSignedIn
    case refreshFailed

    var errorDescription: String? {
      switch self {
      case .notSignedIn, .refreshFailed:
        return GeminiAgySession.signInMessage
      }
    }
  }

  /// Usable access token. Runs `agy models` when the token is missing or near expiry, then re-reads.
  static func ensureFreshAccessToken(
    force: Bool = false,
    now: Date = Date(),
    readKeychain: () -> Data? = { readKeychainData() },
    fileURL: URL = defaultFileURL(),
    refresh: (() throws -> String)? = nil
  ) throws -> String {
    let initial = readSession(readKeychain: readKeychain, fileURL: fileURL)
    if !force, let initial, !isExpired(initial, now: now) {
      return initial.accessToken
    }

    let refreshFn = refresh ?? { try runAgyModelsRefresh() }
    let output: String
    do {
      output = try refreshFn()
    } catch let error as SessionError {
      throw error
    } catch {
      throw SessionError.refreshFailed
    }
    if output.localizedCaseInsensitiveContains("please sign in") {
      throw SessionError.notSignedIn
    }

    guard let refreshed = readSession(readKeychain: readKeychain, fileURL: fileURL) else {
      throw SessionError.notSignedIn
    }
    if isExpired(refreshed, now: now) {
      throw SessionError.refreshFailed
    }
    return refreshed.accessToken
  }

  static func locateAgyCLI(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    home: String = NSHomeDirectory()
  ) -> URL? {
    for key in ["AGY_CLI_PATH", "AGY_CLI"] {
      if let path = environment[key], !path.isEmpty {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if fileManager.isExecutableFile(atPath: url.path) { return url }
      }
    }
    for candidate in [
      "\(home)/.local/bin/agy",
      "/opt/homebrew/bin/agy",
      "/usr/local/bin/agy",
    ] {
      if fileManager.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    if let path = environment["PATH"] {
      for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("agy").path
        if fileManager.isExecutableFile(atPath: candidate) {
          return URL(fileURLWithPath: candidate)
        }
      }
    }
    return nil
  }

  /// Read-only Keychain lookup. Tests inject a closure and must not call this.
  static func readKeychainData(
    service: String = keychainService,
    account: String = keychainAccount
  ) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else { return nil }
    return data
  }

  private static func runAgyModelsRefresh() throws -> String {
    guard let cli = locateAgyCLI() else {
      throw SessionError.notSignedIn
    }
    return try runCommand(executable: cli, arguments: ["models"], timeout: refreshTimeout)
  }

  static func runCommand(executable: URL, arguments: [String], timeout: TimeInterval) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      throw SessionError.refreshFailed
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 && text.localizedCaseInsensitiveContains("please sign in") {
      throw SessionError.notSignedIn
    }
    if process.terminationStatus != 0 {
      throw SessionError.refreshFailed
    }
    return text
  }
}
