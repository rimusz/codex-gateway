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

  /// Shown when the Keychain item is absent and the fallback file has no session.
  static let signInMessage = """
    Gemini is not signed in. Run `agy` in a local terminal and complete Google sign-in. \
    The first time CodexGateway reads the login Keychain item, macOS may ask you to click Allow.
    """

  /// User canceled the prompt, or `errSecAuthFailed` came back too quickly to be a still-open dialog.
  static let accessDeniedMessage = """
    macOS denied access to the Gemini login Keychain item. \
    Open CodexGateway again and click Allow, or click Always Allow on the SecurityAgent prompt. \
    If you have not signed in yet, run `agy` in a local terminal.
    """

  /// A user-interaction prompt is still required or returned before the user finished it.
  static let promptPendingMessage = """
    macOS is still waiting for the login Keychain prompt for the Gemini item. \
    Enter your login keychain password and click Always Allow, then retry. \
    A prompt that is still on screen is not the same as being signed out.
    """

  static let thoughtSignatureMessage = "The cached Gemini thought signature is missing or expired. Send a new turn so Gemini can issue a fresh signature."

  /// Long enough for a person to type a login-keychain password and click Always Allow.
  static let defaultKeychainWaitSeconds: TimeInterval = 120
  static let keychainWaitEnvironmentKey = "GEMINI_AGY_KEYCHAIN_WAIT_SECONDS"
  /// `errSecAuthFailed` faster than this is treated as Deny. Slower matches a dialog that is still up.
  static let fastAuthFailureSeconds: TimeInterval = 2
  private static let keychainRetrySleep: TimeInterval = 0.25

  private static let refreshSkew: TimeInterval = 60
  private static let refreshTimeout: TimeInterval = 30

  struct Session: Equatable, Sendable {
    let accessToken: String
    let expiry: Date?
    let authMethod: String?
  }

  /// One `SecItemCopyMatching` result. `elapsed` is how long that call took.
  /// Tests set `elapsed` directly. A nil `elapsed` means the caller should measure wall time.
  struct KeychainItem: Equatable, Sendable {
    var status: OSStatus
    var data: Data?
    var elapsed: TimeInterval?
  }

  enum Access: String, Equatable, Sendable {
    case available
    case notSignedIn
    case accessDenied
    case promptPending
  }

  struct Status: Equatable, Sendable {
    var configured: Bool
    var source: String
    var setupHint: String?
    var access: Access = .notSignedIn
    var osStatus: OSStatus?
    var osStatusName: String?
  }

  struct KeychainResolution: Equatable, Sendable {
    var access: Access
    var session: Session?
    var source: String
    var osStatus: OSStatus?
    var osStatusName: String?
    var setupHint: String?
  }

  static func defaultFileURL(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home)
      .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
  }

  /// One Keychain lookup. Does not retry. A prompt-related status is `promptPending` immediately.
  static func status(
    readKeychain: () -> KeychainItem = { readKeychainItem() },
    fileURL: URL = defaultFileURL(),
    now: () -> Date = Date.init
  ) -> Status {
    let resolution = waitForKeychainAccess(
      waitSeconds: 0,
      readKeychain: readKeychain,
      fileURL: fileURL,
      sleep: { _ in },
      now: now
    )
    return Status(
      configured: resolution.access == .available,
      source: resolution.source,
      setupHint: resolution.setupHint,
      access: resolution.access,
      osStatus: resolution.osStatus,
      osStatusName: resolution.osStatusName
    )
  }

  /// Existing tests inject `() -> Data?`. Empty/nil means the item is not in the Keychain.
  static func status(
    readKeychain: () -> Data?,
    fileURL: URL = defaultFileURL()
  ) -> Status {
    status(readKeychain: { keychainItem(from: readKeychain()) }, fileURL: fileURL)
  }

  /// Prefer a parsable Keychain document, then the fallback file. Tokens are not logged.
  /// Prompt-pending and access-denied do not fall through to the file.
  static func readSession(
    readKeychain: () -> KeychainItem = { readKeychainItem() },
    fileURL: URL = defaultFileURL()
  ) -> Session? {
    let resolution = waitForKeychainAccess(waitSeconds: 0, readKeychain: readKeychain, fileURL: fileURL, sleep: { _ in })
    return resolution.session
  }

  static func readSession(
    readKeychain: () -> Data?,
    fileURL: URL = defaultFileURL()
  ) -> Session? {
    readSession(readKeychain: { keychainItem(from: readKeychain()) }, fileURL: fileURL)
  }

  static func keychainItem(from data: Data?) -> KeychainItem {
    if let data, !data.isEmpty {
      return KeychainItem(status: errSecSuccess, data: data, elapsed: 0)
    }
    return KeychainItem(status: errSecItemNotFound, data: nil, elapsed: 0)
  }

  static func keychainWaitSeconds(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TimeInterval {
    guard let raw = environment[keychainWaitEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
      return defaultKeychainWaitSeconds
    }
    guard let value = Double(raw), value.isFinite, value >= 0 else {
      return defaultKeychainWaitSeconds
    }
    return value
  }

  /// Repeats `SecItemCopyMatching` until success, a terminal status, or `waitSeconds`.
  /// `0` performs a single read (Settings and Doctor).
  static func waitForKeychainAccess(
    waitSeconds: TimeInterval? = nil,
    readKeychain: () -> KeychainItem = { readKeychainItem() },
    fileURL: URL = defaultFileURL(),
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    now: () -> Date = Date.init
  ) -> KeychainResolution {
    let budget = waitSeconds ?? keychainWaitSeconds()
    let start = now()
    let deadline = start.addingTimeInterval(budget)
    var stalled = 0
    while true {
      let wallStart = now()
      let item = readKeychain()
      let elapsed = item.elapsed ?? now().timeIntervalSince(wallStart)
      let decision = classify(status: item.status, elapsed: elapsed, data: item.data, fileURL: fileURL)
      switch decision {
      case .finished(let resolution):
        return resolution
      case .retry(let status):
        logKeychainWait(status)
        if budget <= 0 || now() >= deadline {
          return resolution(access: .promptPending, session: nil, source: keychainSource, status: status)
        }
        let remaining = deadline.timeIntervalSince(now())
        let pause = min(keychainRetrySleep, max(remaining, 0))
        let beforeSleep = now()
        if pause > 0 { sleep(pause) }
        if now() <= beforeSleep {
          stalled += 1
          if stalled >= 3 {
            return resolution(access: .promptPending, session: nil, source: keychainSource, status: status)
          }
        } else {
          stalled = 0
        }
      }
    }
  }

  /// zalando/go-keyring stores a string, not raw JSON. Read-only: never rewrite the item.
  static func unwrapStoredPayload(_ data: Data) -> Data? {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let suffix = storedSuffix(trimmed, prefix: "go-keyring-base64:") {
      guard let decoded = Data(base64Encoded: suffix) else {
        logUnwrap(kind: "base64", bytes: nil)
        return nil
      }
      logUnwrap(kind: "base64", bytes: decoded.count)
      return decoded
    }
    if let suffix = storedSuffix(trimmed, prefix: "go-keyring-encoded:") {
      guard let decoded = hexDecode(suffix) else {
        logUnwrap(kind: "hex", bytes: nil)
        return nil
      }
      logUnwrap(kind: "hex", bytes: decoded.count)
      return decoded
    }
    return data
  }

  private static func storedSuffix(_ text: String, prefix: String) -> String? {
    guard text.hasPrefix(prefix) else { return nil }
    return String(text.dropFirst(prefix.count))
  }

  private static func hexDecode(_ text: String) -> Data? {
    let chars = Array(text.utf8)
    guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    var index = 0
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
      default: return nil
      }
    }
    while index < chars.count {
      guard let hi = nibble(chars[index]), let lo = nibble(chars[index + 1]) else { return nil }
      out.append((hi << 4) | lo)
      index += 2
    }
    return out
  }

  private static func logUnwrap(kind: String, bytes: Int?) {
    let size = bytes.map(String.init) ?? "failed"
    fputs("Gemini Keychain unwrap kind=\(kind) bytes=\(size)\n", stderr)
  }

  static func parseSession(_ data: Data?) -> Session? {
    guard let data, !data.isEmpty,
          let payload = unwrapStoredPayload(data), !payload.isEmpty,
          let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
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
    case accessDenied
    case promptPending
    case refreshFailed

    var errorDescription: String? {
      switch self {
      case .notSignedIn, .refreshFailed:
        return GeminiAgySession.signInMessage
      case .accessDenied:
        return GeminiAgySession.accessDeniedMessage
      case .promptPending:
        return GeminiAgySession.promptPendingMessage
      }
    }
  }

  /// Usable access token. Runs `agy models` only when the item is readable but expired, or when
  /// there is no item and the fallback file also has no token. A Keychain prompt is not a refresh.
  static func ensureFreshAccessToken(
    force: Bool = false,
    now: Date = Date(),
    readKeychain: () -> KeychainItem = { readKeychainItem() },
    fileURL: URL = defaultFileURL(),
    refresh: (() throws -> String)? = nil,
    waitSeconds: TimeInterval? = nil,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    clock: () -> Date = Date.init
  ) throws -> String {
    let initial = waitForKeychainAccess(
      waitSeconds: waitSeconds,
      readKeychain: readKeychain,
      fileURL: fileURL,
      sleep: sleep,
      now: clock
    )
    switch initial.access {
    case .accessDenied:
      throw SessionError.accessDenied
    case .promptPending:
      throw SessionError.promptPending
    case .available, .notSignedIn:
      break
    }
    if !force, let session = initial.session, !isExpired(session, now: now) {
      return session.accessToken
    }
    // Readable-but-expired, or no item and no file session. Do not refresh a pending prompt.
    guard initial.access == .available || initial.access == .notSignedIn else {
      throw SessionError.promptPending
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

    let refreshed = waitForKeychainAccess(
      waitSeconds: waitSeconds,
      readKeychain: readKeychain,
      fileURL: fileURL,
      sleep: sleep,
      now: clock
    )
    switch refreshed.access {
    case .accessDenied:
      throw SessionError.accessDenied
    case .promptPending:
      throw SessionError.promptPending
    case .notSignedIn:
      throw SessionError.notSignedIn
    case .available:
      guard let session = refreshed.session else { throw SessionError.notSignedIn }
      if isExpired(session, now: now) {
        throw SessionError.refreshFailed
      }
      return session.accessToken
    }
  }

  static func ensureFreshAccessToken(
    force: Bool = false,
    now: Date = Date(),
    readKeychain: () -> Data?,
    fileURL: URL = defaultFileURL(),
    refresh: (() throws -> String)? = nil
  ) throws -> String {
    try ensureFreshAccessToken(
      force: force,
      now: now,
      readKeychain: { keychainItem(from: readKeychain()) },
      fileURL: fileURL,
      refresh: refresh,
      waitSeconds: 0,
      sleep: { _ in }
    )
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
  /// Keeps the `Data?` shape for older callers. Non-success, including a prompt, is nil here;
  /// use `readKeychainItem()` when the OSStatus matters.
  static func readKeychainData(
    service: String = keychainService,
    account: String = keychainAccount
  ) -> Data? {
    readKeychainItem(service: service, account: account).data
  }

  /// One `SecItemCopyMatching`. Logs the numeric OSStatus and its Security constant name.
  /// Never logs the item bytes.
  static func readKeychainItem(
    service: String = keychainService,
    account: String = keychainAccount
  ) -> KeychainItem {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let started = Date()
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    let elapsed = Date().timeIntervalSince(started)
    if status != errSecSuccess {
      let line = "Gemini Keychain read OSStatus=\(status) (\(osStatusName(status)))\n"
      fputs(line, stderr)
      return KeychainItem(status: status, data: nil, elapsed: elapsed)
    }
    guard let data = item as? Data, !data.isEmpty else {
      return KeychainItem(status: status, data: nil, elapsed: elapsed)
    }
    return KeychainItem(status: status, data: data, elapsed: elapsed)
  }

  static func osStatusName(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess: return "errSecSuccess"
    case errSecUserCanceled: return "errSecUserCanceled"
    case errSecAuthFailed: return "errSecAuthFailed"
    case errSecItemNotFound: return "errSecItemNotFound"
    case errSecInteractionNotAllowed: return "errSecInteractionNotAllowed"
    case errSecInteractionRequired: return "errSecInteractionRequired"
    case errSecInDarkWake: return "errSecInDarkWake"
    default: return "OSStatus_\(status)"
    }
  }

  private static var keychainSource: String { "keychain:\(keychainService)/\(keychainAccount)" }

  private enum ClassifyDecision {
    case finished(KeychainResolution)
    case retry(OSStatus)
  }

  private static func classify(
    status: OSStatus,
    elapsed: TimeInterval,
    data: Data?,
    fileURL: URL
  ) -> ClassifyDecision {
    if status == errSecSuccess {
      if let session = parseSession(data) {
        return .finished(resolution(access: .available, session: session, source: keychainSource, status: status))
      }
      if let session = parseSession(try? Data(contentsOf: fileURL)) {
        return .finished(resolution(access: .available, session: session, source: fileURL.path, status: status))
      }
      return .finished(resolution(access: .notSignedIn, session: nil, source: keychainSource, status: status))
    }
    if status == errSecItemNotFound {
      if let session = parseSession(try? Data(contentsOf: fileURL)) {
        return .finished(resolution(access: .available, session: session, source: fileURL.path, status: status))
      }
      return .finished(resolution(access: .notSignedIn, session: nil, source: keychainSource, status: status))
    }
    if status == errSecUserCanceled {
      return .finished(resolution(access: .accessDenied, session: nil, source: keychainSource, status: status))
    }
    if status == errSecAuthFailed {
      if elapsed < fastAuthFailureSeconds {
        return .finished(resolution(access: .accessDenied, session: nil, source: keychainSource, status: status))
      }
      return .retry(status)
    }
    if isPromptStatus(status) {
      return .retry(status)
    }
    return .finished(resolution(access: .accessDenied, session: nil, source: keychainSource, status: status))
  }

  private static func isPromptStatus(_ status: OSStatus) -> Bool {
    status == errSecInteractionNotAllowed
      || status == errSecInteractionRequired
      || status == errSecInDarkWake
  }

  private static func resolution(
    access: Access,
    session: Session?,
    source: String,
    status: OSStatus
  ) -> KeychainResolution {
    let hint: String?
    switch access {
    case .available:
      hint = nil
    case .notSignedIn:
      hint = signInMessage
    case .accessDenied:
      hint = accessDeniedMessage
    case .promptPending:
      hint = promptPendingMessage
    }
    return KeychainResolution(
      access: access,
      session: session,
      source: source,
      osStatus: status,
      osStatusName: osStatusName(status),
      setupHint: hint
    )
  }

  private static func logKeychainWait(_ status: OSStatus) {
    let line = "waiting for Keychain Allow, OSStatus=\(status) (\(osStatusName(status)))\n"
    fputs(line, stderr)
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
