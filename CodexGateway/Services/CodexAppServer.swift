import Foundation

enum CodexBinary {
  static func resolve() -> String {
    let bundled = "/Applications/Codex.app/Contents/Resources/codex"
    if FileManager.default.fileExists(atPath: bundled) { return bundled }
    return "codex"
  }
}

enum CodexCLIDaemon {
  static let restartArguments = ["app-server", "daemon", "restart"]
  static let defaultCandidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
  ]

  static func resolve(
    fileManager: FileManager = .default,
    candidates: [String] = defaultCandidates,
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
  ) -> String? {
    let pathCandidates = path.split(separator: ":").map { "\($0)/codex" }
    return (candidates + pathCandidates).first { fileManager.isExecutableFile(atPath: $0) }
  }

  /// Reloads the long-lived CLI app-server. A new terminal attaches to that process,
  /// so restarting only Codex Desktop leaves the CLI on the previous model catalog.
  static func restart(
    executable: () -> String? = { resolve() },
    runner: (String, [String]) throws -> Void = run
  ) {
    guard let path = executable() else {
      GatewayLog.info("Codex CLI is not installed; skipped daemon restart")
      return
    }
    do {
      try runner(path, restartArguments)
    } catch {
      GatewayLog.error("Failed to restart Codex CLI daemon: \(error.localizedDescription)")
    }
  }

  private static func run(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = Paths.home
    process.environment = env
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "CodexCLIDaemon",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "codex app-server daemon restart exited \(process.terminationStatus)"]
      )
    }
  }
}

final class CodexAppServer {
  static let shared = CodexAppServer()

  private var process: Process?
  private var stdoutHandle: FileHandle?
  private var buffer = ""
  private var nextId = 1
  private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
  private let queue = DispatchQueue(label: "com.rimusz.CodexGateway.appserver")

  private init() {}

  func connect() throws {
    if process?.isRunning == true { return }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: CodexBinary.resolve())
    p.arguments = ["app-server", "--stdio"]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = Paths.home
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    p.standardInput = Pipe()

    try p.run()
    process = p
    stdoutHandle = pipe.fileHandleForReading
    stdoutHandle?.readabilityHandler = { [weak self] handle in
      self?.readOutput(handle.availableData)
    }

    _ = try call(method: "initialize", params: [
      "clientInfo": ["name": "codex-desktop", "title": "Codex Desktop", "version": "1.0.0"],
      "capabilities": ["experimentalApi": true, "requestAttestation": false]
    ])
    notify(method: "initialized")
  }

  func call(method: String, params: Any, timeout: TimeInterval = 30) throws -> Any {
    try connect()
    guard let stdin = process?.standardInput as? Pipe else {
      throw NSError(domain: "CodexAppServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No stdin"])
    }

    let id = nextId
    nextId += 1

    return try queue.sync {
      let sem = DispatchSemaphore(value: 0)
      var result: Result<Any, Error>!
      pending[id] = { r in result = r; sem.signal() }

      let payload: [String: Any] = ["id": id, "method": method, "params": params]
      let data = (try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8))
      stdin.fileHandleForWriting.write(data)

      if sem.wait(timeout: .now() + timeout) == .timedOut {
        pending.removeValue(forKey: id)
        throw NSError(domain: "CodexAppServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout: \(method)"])
      }
      pending.removeValue(forKey: id)
      switch result! {
      case .success(let value): return value
      case .failure(let error): throw error
      }
    }
  }

  func notify(method: String, params: Any? = nil) {
    guard let stdin = process?.standardInput as? Pipe else { return }
    var payload: [String: Any] = ["method": method]
    if let params { payload["params"] = params }
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      stdin.fileHandleForWriting.write(data + Data("\n".utf8))
    }
  }

  func restartCodexDesktop() {
    // Re-sync the managed config first so `requires_openai_auth` reflects the
    // current Codex sign-in state before Codex reloads config.toml on relaunch.
    // Guarded so a restart never re-injects into a native Codex (and so a reset
    // isn't immediately undone).
    CodexConfig.refreshManagedConfigIfApplied()
    CodexCLIDaemon.restart()
    let script = """
    tell application "Codex" to quit
  delay 1
  tell application "Codex" to activate
  """
    if let appleScript = NSAppleScript(source: script) {
      var error: NSDictionary?
      appleScript.executeAndReturnError(&error)
    }
  }

  private func readOutput(_ data: Data) {
    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
    buffer += chunk
    while let range = buffer.range(of: "\n") {
      let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      buffer = String(buffer[range.upperBound...])
      guard !line.isEmpty, let jsonData = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let id = json["id"] as? Int else { continue }
      guard let completion = pending.removeValue(forKey: id) else { continue }
      if let error = json["error"] as? [String: Any] {
        let message = error["message"] as? String ?? "Unknown error"
        completion(.failure(NSError(domain: "CodexAppServer", code: 3, userInfo: [NSLocalizedDescriptionKey: message])))
      } else {
        completion(.success(json["result"] ?? [:]))
      }
    }
  }
}

import AppKit
