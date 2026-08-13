import Foundation

struct DoctorInputs: Equatable, Sendable {
  var gatewayReachable = false
  var gatewayPort = 8765
  var configApplied = false
  var configInSync = false
  var signedIn = false
  var hasCustomModels = false
  var nodeFound = false
  var nodeVersionDisplay = ""
  var nodeMeetsMinimum = false
  var cursorProviderInstalled = false
  var cursorKeyPresent = false
  var cursorBridgeReachable = false
  var grokOAuthInstalled = false
  var grokOAuthConfigured = false
}

struct DoctorCheck: Identifiable, Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    case ok
    case warning
    case error
    case info

    var symbolName: String {
      switch self {
      case .ok: return "checkmark.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .error: return "xmark.octagon.fill"
      case .info: return "info.circle.fill"
      }
    }
  }

  let id: String
  let title: String
  let detail: String
  let status: Status
}

enum DoctorReport {
  static func checks(from inputs: DoctorInputs) -> [DoctorCheck] {
    [
      gatewayCheck(inputs),
      configCheck(inputs),
      signInCheck(inputs),
      nodeCheck(inputs),
      cursorCheck(inputs),
      grokOAuthCheck(inputs),
    ]
  }

  static func isHealthy(_ inputs: DoctorInputs) -> Bool {
    guard inputs.gatewayReachable, inputs.configApplied, inputs.configInSync else {
      return false
    }
    if inputs.cursorProviderInstalled {
      guard inputs.nodeMeetsMinimum, inputs.cursorKeyPresent else { return false }
    }
    if inputs.grokOAuthInstalled {
      guard inputs.grokOAuthConfigured else { return false }
    }
    return true
  }

  static func primaryRemediation(_ inputs: DoctorInputs) -> String? {
    if !inputs.gatewayReachable {
      return "Gateway is not responding on \(Paths.gatewayHost):\(inputs.gatewayPort). Keep CodexGateway running until the menu bar shows Ready."
    }
    if inputs.cursorProviderInstalled, !inputs.nodeMeetsMinimum {
      return CursorBridge.NodeRequirement.installGuidance
    }
    if inputs.cursorProviderInstalled, !inputs.cursorKeyPresent {
      return "Add a Cursor API key in Settings (Cursor provider)."
    }
    if inputs.grokOAuthInstalled, !inputs.grokOAuthConfigured {
      return "Run grok login in Terminal, then re-run Doctor."
    }
    if !inputs.configApplied {
      return "Open Settings and click Update Gateway Config so Codex Desktop uses the local gateway."
    }
    if !inputs.configInSync {
      return "Gateway config is out of date. Open Settings and click Update Gateway Config."
    }
    if inputs.hasCustomModels, !inputs.signedIn {
      return "Sign in to Codex Desktop so custom models appear in the picker (a free account is enough)."
    }
    return nil
  }

  private static func gatewayCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    if inputs.gatewayReachable {
      return DoctorCheck(
        id: "gateway",
        title: "Gateway",
        detail: "Listening on \(Paths.gatewayHost):\(inputs.gatewayPort).",
        status: .ok
      )
    }
    return DoctorCheck(
      id: "gateway",
      title: "Gateway",
      detail: "Not responding on \(Paths.gatewayHost):\(inputs.gatewayPort).",
      status: .error
    )
  }

  private static func configCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    if inputs.configApplied, inputs.configInSync {
      return DoctorCheck(
        id: "config",
        title: "Codex config",
        detail: "Managed gateway block is present and up to date in ~/.codex/config.toml.",
        status: .ok
      )
    }
    if inputs.configApplied {
      return DoctorCheck(
        id: "config",
        title: "Codex config",
        detail: "Managed block is present but out of date. Update Gateway Config in Settings.",
        status: .warning
      )
    }
    return DoctorCheck(
      id: "config",
      title: "Codex config",
      detail: "Managed gateway block is missing from ~/.codex/config.toml.",
      status: .error
    )
  }

  private static func signInCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    if inputs.signedIn {
      return DoctorCheck(
        id: "signin",
        title: "Codex account",
        detail: "Signed in. Custom models can appear in the Codex picker.",
        status: .ok
      )
    }
    if inputs.hasCustomModels {
      return DoctorCheck(
        id: "signin",
        title: "Codex account",
        detail: "Signed out. Sign in to Codex Desktop so custom models appear in the picker.",
        status: .warning
      )
    }
    return DoctorCheck(
      id: "signin",
      title: "Codex account",
      detail: "Signed out. Custom models need a signed-in Codex account (free is enough).",
      status: .info
    )
  }

  private static func nodeCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    let cursorNeedsNode = inputs.cursorProviderInstalled
    if inputs.nodeMeetsMinimum {
      let version = inputs.nodeVersionDisplay.isEmpty ? "installed" : inputs.nodeVersionDisplay
      return DoctorCheck(
        id: "node",
        title: "Node.js",
        detail: "\(version) (meets \(CursorBridge.NodeRequirement.minimumDisplay)+).",
        status: .ok
      )
    }
    if inputs.nodeFound {
      let version = inputs.nodeVersionDisplay.isEmpty ? "too old" : inputs.nodeVersionDisplay
      return DoctorCheck(
        id: "node",
        title: "Node.js",
        detail: "\(version) is below \(CursorBridge.NodeRequirement.minimumDisplay). Cursor needs a newer Node.",
        status: cursorNeedsNode ? .error : .warning
      )
    }
    return DoctorCheck(
      id: "node",
      title: "Node.js",
      detail: CursorBridge.NodeRequirement.missingMessage,
      status: cursorNeedsNode ? .error : .warning
    )
  }

  private static func cursorCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    if !inputs.cursorProviderInstalled {
      return DoctorCheck(
        id: "cursor",
        title: "Cursor",
        detail: "Not added as a provider.",
        status: .info
      )
    }
    if !inputs.cursorKeyPresent {
      return DoctorCheck(
        id: "cursor",
        title: "Cursor",
        detail: "API key is missing. Add it in Settings.",
        status: .error
      )
    }
    if inputs.cursorBridgeReachable {
      return DoctorCheck(
        id: "cursor",
        title: "Cursor",
        detail: "Sidecar is reachable on \(Paths.gatewayHost):\(CursorBridge.managedEndpoint.port ?? 18788).",
        status: .ok
      )
    }
    return DoctorCheck(
      id: "cursor",
      title: "Cursor",
      detail: "API key is present. Sidecar is not running yet (it starts on the first Cursor request).",
      status: .warning
    )
  }

  private static func grokOAuthCheck(_ inputs: DoctorInputs) -> DoctorCheck {
    if !inputs.grokOAuthInstalled {
      return DoctorCheck(
        id: "grok-oauth",
        title: "Grok (OAuth)",
        detail: "Not added as a provider.",
        status: .info
      )
    }
    if inputs.grokOAuthConfigured {
      return DoctorCheck(
        id: "grok-oauth",
        title: "Grok (OAuth)",
        detail: "grok login is configured.",
        status: .ok
      )
    }
    return DoctorCheck(
      id: "grok-oauth",
      title: "Grok (OAuth)",
      detail: "Not connected. Run grok login in Terminal.",
      status: .warning
    )
  }
}
