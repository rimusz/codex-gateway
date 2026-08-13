import Darwin
import Foundation

/// UserDefaults keys for the CodexGateway-managed Cursor bridge sidecar.
enum CursorBridgeSettingsKeys {
  /// When true, CodexGateway starts the bundled OpenAI `/v1` sidecar on launch (if an API key is set).
  /// Set automatically when the Cursor provider is installed; cleared when that provider is removed.
  static let managedEnabled = "CodexGateway.cursorBridge.managedEnabled"
}

/// Lifecycle for the optional embedded Cursor OpenAI bridge.
///
/// Starts a Node `@cursor/sdk` script on loopback port `18788` when enabled and a
/// `CURSOR_API_KEY` is stored locally (Application Support).
enum CursorBridgeRuntime {
  static let managedPort = 18788

  static var managedEndpoint: CursorBridge.Endpoint { CursorBridge.managedEndpoint }

  enum Status: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    var isRunning: Bool {
      if case .running = self { return true }
      return false
    }

    var summary: String {
      switch self {
      case .stopped: return "Stopped"
      case .starting: return "Starting…"
      case .running: return "Running on 127.0.0.1:\(CursorBridgeRuntime.managedPort)"
      case .failed(let message): return message
      }
    }
  }

  private static let queue = DispatchQueue(label: "com.rimusz.codexgateway.cursor-bridge-runtime")
  private static var process: Process?
  private static var statusValue: Status = .stopped
  private static var stderrPipe: Pipe?
  private static var intentionalStop = false

  static let statusDidChange = Notification.Name.codexGatewayCursorBridgeRuntimeStatusDidChange

  static var status: Status {
    queue.sync { statusValue }
  }

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: CursorBridgeSettingsKeys.managedEnabled) }
    set { UserDefaults.standard.set(newValue, forKey: CursorBridgeSettingsKeys.managedEnabled) }
  }

  static var isRunning: Bool { status.isRunning }

  static func shouldTreatAsRunning(status: Status, endpointOnline: Bool, hasAPIKey: Bool) -> Bool {
    guard hasAPIKey else { return false }
    return status.isRunning || endpointOnline
  }

  static func mayReattachToLiveEndpoint(hasAPIKey: Bool, endpointOnline: Bool) -> Bool {
    hasAPIKey && endpointOnline
  }

  private static let missingAPIKeyMessage = "Add a Cursor API key to start the managed bridge."

  enum Locator {
    static func nodeURL(fileManager: FileManager = .default, pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
      let candidates = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "\(NSHomeDirectory())/.local/bin/node",
        "\(NSHomeDirectory())/bin/node"
      ]
      for path in candidates where fileManager.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
      guard let pathEnv else { return nil }
      for dir in pathEnv.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("node")
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate
        }
      }
      return nil
    }

    static func bridgeDirectory(
      bundle: Bundle = .main,
      fileManager: FileManager = .default,
      env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
      if let override = env["CODEXGATEWAY_CURSOR_BRIDGE_DIR"], !override.isEmpty {
        let url = URL(fileURLWithPath: override, isDirectory: true)
        if hasBridgeScript(at: url, fileManager: fileManager) { return url }
      }
      if let resources = bundle.resourceURL {
        let bundled = resources.appendingPathComponent("CursorBridge", isDirectory: true)
        if hasBridgeScript(at: bundled, fileManager: fileManager) { return bundled }
      }
      if let exec = bundle.executableURL {
        let candidates = [
          exec.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CursorBridge", isDirectory: true),
          exec.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexGateway/Resources/CursorBridge", isDirectory: true)
        ]
        for url in candidates where hasBridgeScript(at: url, fileManager: fileManager) {
          return url
        }
      }
      return nil
    }

    static func hasBridgeScript(at directory: URL, fileManager: FileManager = .default) -> Bool {
      fileManager.fileExists(atPath: directory.appendingPathComponent("cursor-openai-bridge.mjs").path)
    }

    static func hasValidateScript(at directory: URL, fileManager: FileManager = .default) -> Bool {
      fileManager.fileExists(atPath: directory.appendingPathComponent("cursor-validate-key.mjs").path)
    }

    static func hasNodeModules(at directory: URL, fileManager: FileManager = .default) -> Bool {
      fileManager.fileExists(atPath: directory.appendingPathComponent("node_modules/@cursor/sdk").path)
    }
  }

  static func nodeChildEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory(),
    fileExists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
  ) -> [String: String] {
    var environment = base
    CursorBridge.NodeTLS.apply(to: &environment, home: home, fileExists: fileExists)
    return environment
  }

  static func validateAPIKey(_ apiKey: String) async -> CursorBridge.APIKeyValidation {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .missing }
    guard CursorBridge.looksLikeAPIKey(trimmed) else {
      return .rejected("Key looks too short or invalid. Paste the full key from Cursor Integrations.")
    }

    let nodeProbe = probeNode()
    guard nodeProbe.meetsMinimum, let nodePath = nodeProbe.binaryPath else {
      return CursorBridge.APIKeyValidation(isValid: false, message: nodeProbe.detail)
    }
    guard let bridgeDir = Locator.bridgeDirectory() else {
      return CursorBridge.APIKeyValidation(
        isValid: false,
        message: "Cursor bridge script is missing from the app bundle. Rebuild with make run / make app."
      )
    }
    guard Locator.hasValidateScript(at: bridgeDir), Locator.hasNodeModules(at: bridgeDir) else {
      return CursorBridge.APIKeyValidation(
        isValid: false,
        message: "Cursor bridge dependencies missing. Rebuild the app (npm install runs during packaging)."
      )
    }

    let script = bridgeDir.appendingPathComponent("cursor-validate-key.mjs")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: nodePath)
    proc.arguments = [script.path]
    proc.currentDirectoryURL = bridgeDir
    var environment = nodeChildEnvironment()
    environment["CURSOR_API_KEY"] = trimmed
    proc.environment = environment
    let err = Pipe()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = err

    do {
      try proc.run()
    } catch {
      return CursorBridge.APIKeyValidation(
        isValid: false,
        message: "Could not validate Cursor API key: \(error.localizedDescription)"
      )
    }

    let deadline = Date().addingTimeInterval(45)
    while proc.isRunning, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning {
      proc.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
      }
      return CursorBridge.APIKeyValidation(
        isValid: false,
        message: "Timed out validating the Cursor API key. Check your network and try again."
      )
    }
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CursorBridge.validationResult(exitCode: proc.terminationStatus, stderr: stderr)
  }

  static func probeNode() -> CursorBridge.NodeRequirement.Snapshot {
    guard let node = Locator.nodeURL() else {
      return CursorBridge.NodeRequirement.snapshot(binaryPath: nil, versionDisplay: "")
    }
    let process = Process()
    process.executableURL = node
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return CursorBridge.NodeRequirement.snapshot(binaryPath: node.path, versionDisplay: raw)
    } catch {
      return CursorBridge.NodeRequirement.snapshot(binaryPath: node.path, versionDisplay: "")
    }
  }

  @discardableResult
  static func startIfNeeded() async -> Status {
    guard isEnabled else {
      stop()
      return status
    }

    guard let apiKey = CursorBridgeKeychain.load(), !apiKey.isEmpty else {
      await stopForMissingAPIKey()
      return status
    }

    if isRunning { return status }

    setStatus(.starting)
    let keyCheck = await validateAPIKey(apiKey)
    guard keyCheck.isValid else {
      stop()
      setStatus(.failed(keyCheck.message))
      return status
    }

    if await endpointIsOnline() {
      setStatus(.running)
      return status
    }

    let nodeProbe = probeNode()
    guard nodeProbe.meetsMinimum, let nodePath = nodeProbe.binaryPath else {
      setStatus(.failed(nodeProbe.detail))
      return status
    }
    let node = URL(fileURLWithPath: nodePath)
    guard let bridgeDir = Locator.bridgeDirectory() else {
      setStatus(.failed("Cursor bridge script is missing from the app bundle. Rebuild with make run / make app."))
      return status
    }
    if !Locator.hasNodeModules(at: bridgeDir) {
      setStatus(.failed("Cursor bridge dependencies missing. Rebuild the app (npm install runs during packaging)."))
      return status
    }

    queue.sync { intentionalStop = false }

    let script = bridgeDir.appendingPathComponent("cursor-openai-bridge.mjs")
    let cwd = workspaceDirectory()
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    let proc = Process()
    proc.executableURL = node
    proc.arguments = [script.path]
    proc.currentDirectoryURL = bridgeDir

    var environment = nodeChildEnvironment()
    environment["CURSOR_API_KEY"] = apiKey
    environment["CURSOR_BRIDGE_HOST"] = "127.0.0.1"
    environment["CURSOR_BRIDGE_PORT"] = "\(managedPort)"
    environment["CURSOR_BRIDGE_CWD"] = cwd.path
    proc.environment = environment

    let err = Pipe()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = err
    proc.terminationHandler = { finished in
      handleTermination(finished)
    }

    do {
      try proc.run()
    } catch {
      if await endpointIsOnline() {
        setStatus(.running)
        return status
      }
      setStatus(.failed("Failed to start Node bridge: \(error.localizedDescription)"))
      return status
    }

    queue.sync {
      process = proc
      stderrPipe = err
    }

    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if !proc.isRunning {
        if await endpointIsOnline() {
          cleanupProcess()
          setStatus(.running)
          return status
        }
        let message = readStderrSnippet(from: err) ?? "Bridge process exited early."
        setStatus(.failed(message))
        cleanupProcess()
        return status
      }
      let probe = await CursorBridge.probe(managedEndpoint, timeout: 1.5)
      if probe.isOnline {
        setStatus(.running)
        return status
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }

    if proc.isRunning {
      setStatus(.running)
      return status
    }
    if await endpointIsOnline() {
      cleanupProcess()
      setStatus(.running)
      return status
    }
    setStatus(.failed(readStderrSnippet(from: err) ?? "Bridge failed to become ready."))
    cleanupProcess()
    return status
  }

  @discardableResult
  static func reconcile() async -> Status {
    guard CursorBridgeKeychain.hasAPIKey() else {
      await stopForMissingAPIKey()
      return status
    }
    if await endpointIsOnline() {
      if !isRunning { setStatus(.running) }
      return status
    }
    let ownedRunning = queue.sync { process?.isRunning == true }
    if case .running = status, !ownedRunning {
      setStatus(.stopped)
    }
    return status
  }

  static func handleAPIKeyCleared() {
    stop()
    if isEnabled {
      setStatus(.failed(missingAPIKeyMessage))
    }
  }

  private static func stopForMissingAPIKey() async {
    let online = await endpointIsOnline()
    let ownedRunning = queue.sync { process?.isRunning == true }
    if online || ownedRunning || isRunning {
      stop()
    }
    if isEnabled {
      setStatus(.failed(missingAPIKeyMessage))
    } else {
      setStatus(.stopped)
    }
  }

  static func stop() {
    let proc: Process? = queue.sync {
      intentionalStop = true
      let current = process
      process = nil
      stderrPipe = nil
      return current
    }
    if let proc, proc.isRunning {
      proc.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        if proc.isRunning {
          kill(proc.processIdentifier, SIGKILL)
        }
      }
    }
    terminateOrphanListeners()
    setStatus(.stopped)
    queue.sync { intentionalStop = false }
  }

  static func setEnabled(_ enabled: Bool) async {
    isEnabled = enabled
    if enabled {
      _ = await startIfNeeded()
    } else {
      stop()
    }
  }

  private static func workspaceDirectory() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("CodexGateway", isDirectory: true)
      .appendingPathComponent("cursor-bridge-workspace", isDirectory: true)
    return support
  }

  private static func setStatus(_ next: Status) {
    let changed: Bool = queue.sync {
      let didChange = statusValue != next
      statusValue = next
      return didChange
    }
    guard changed else { return }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: statusDidChange, object: nil)
    }
  }

  private static func cleanupProcess() {
    queue.sync {
      process = nil
      stderrPipe = nil
    }
  }

  private static func endpointIsOnline() async -> Bool {
    let probe = await CursorBridge.probe(managedEndpoint, timeout: 1.5)
    return probe.isOnline
  }

  private static func terminateOrphanListeners() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-tiTCP:\(managedPort)", "-sTCP:LISTEN"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
      task.waitUntilExit()
    } catch {
      return
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return }
    for line in text.split(whereSeparator: { $0.isNewline }) {
      guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
      kill(pid, SIGTERM)
    }
  }

  private static func handleTermination(_ finished: Process) {
    let snapshot: (current: Process?, pipe: Pipe?, status: Status, intentional: Bool) = queue.sync {
      (process, stderrPipe, statusValue, intentionalStop)
    }
    guard snapshot.current === finished else { return }
    queue.sync {
      if process === finished {
        process = nil
        stderrPipe = nil
      }
    }
    if snapshot.intentional { return }
    if case .starting = snapshot.status {
      setStatus(.failed(readStderrSnippet(from: snapshot.pipe) ?? "Bridge process exited early."))
    } else if case .running = snapshot.status {
      Task {
        if CursorBridgeKeychain.hasAPIKey(), await endpointIsOnline() {
          setStatus(.running)
        } else if !CursorBridgeKeychain.hasAPIKey() {
          await stopForMissingAPIKey()
        } else {
          setStatus(.failed("Bridge process exited unexpectedly."))
        }
      }
    }
  }

  private static func readStderrSnippet(from pipe: Pipe?) -> String? {
    guard let pipe else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lines = trimmed.split(separator: "\n").suffix(4).joined(separator: " ")
    return String(lines.prefix(280))
  }
}
