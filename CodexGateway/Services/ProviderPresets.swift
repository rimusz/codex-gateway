import Foundation

/// Built-in OpenAI-compatible provider presets.
enum ProviderPreset: String, CaseIterable, Identifiable {
  case zai
  case kimi
  case qwen
  case xiaomiMiMo
  case clinePass
  case minimax
  case deepseek
  case xai
  case grokOAuth
  case cursor
  case openrouter
  case ollama

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .zai: return "Z.ai (GLM)"
    case .kimi: return "Kimi (Moonshot)"
    case .qwen: return "Qwen (DashScope)"
    case .xiaomiMiMo: return "Xiaomi MiMo"
    case .clinePass: return "Cline Pass"
    case .minimax: return "MiniMax"
    case .deepseek: return "DeepSeek"
    case .xai: return "xAI Grok (API)"
    case .grokOAuth: return "xAI Grok (OAuth)"
    case .cursor: return "Cursor"
    case .openrouter: return "OpenRouter"
    case .ollama: return "Ollama (local)"
    }
  }

  var providerID: String {
    switch self {
    case .zai: return "zai"
    case .kimi: return "kimi"
    case .qwen: return "qwen"
    case .xiaomiMiMo: return "xiaomi-mimo"
    case .clinePass: return "clinepass"
    case .minimax: return "minimax"
    case .deepseek: return "deepseek"
    case .xai: return "xai"
    case .grokOAuth: return "grok-oauth"
    case .cursor: return "cursor"
    case .openrouter: return "openrouter"
    case .ollama: return "ollama"
    }
  }

  var baseURL: String {
    switch self {
    case .zai: return "https://api.z.ai/api/coding/paas/v4"
    case .kimi: return "https://api.moonshot.ai/v1"
    case .qwen: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
    case .xiaomiMiMo: return "https://api.xiaomimimo.com/v1"
    case .clinePass: return "https://api.cline.bot/api/v1"
    case .minimax: return "https://api.minimax.io/v1"
    case .deepseek: return "https://api.deepseek.com"
    case .xai: return "https://api.x.ai/v1"
    case .grokOAuth: return GrokOAuthClient.defaultBaseURL
    case .cursor: return CursorBridge.managedEndpoint.baseURL
    case .openrouter: return "https://openrouter.ai/api/v1"
    case .ollama: return "http://localhost:11434/v1"
    }
  }

  var defaultAPIKey: String {
    switch self {
    case .ollama: return "ollama"
    case .cursor: return "local"
    case .grokOAuth: return ""
    default: return ""
    }
  }

  var requiresAPIKeyPrompt: Bool {
    switch self {
    case .ollama, .grokOAuth: return false
    default: return true
    }
  }

  var authKind: ProviderAuthKind {
    switch self {
    case .grokOAuth: return .grokOAuth
    case .cursor: return .cursorBridge
    default: return .apiKey
    }
  }

  /// True when this preset is the CodexGateway-managed Cursor sidecar (local secret + process lifecycle).
  var isManagedCursorBridge: Bool { self == .cursor }

  /// When true, install also upserts `catalogModels()` (no live `/models` fetch).
  var seedsSuggestedModelOnInstall: Bool {
    switch self {
    case .grokOAuth: return true
    default: return false
    }
  }

  var suggestedModel: String? {
    switch self {
    case .zai: return "glm-5.2"
    case .kimi: return "kimi-k2.6"
    case .qwen: return "qwen3.7-plus"
    case .xiaomiMiMo: return "mimo-v2.5-pro"
    case .minimax: return "minimax-m2.5"
    case .deepseek: return "deepseek-v4-pro"
    case .xai: return "grok-4"
    case .grokOAuth: return "grok-4.5"
    case .cursor: return "composer-2.5"
    case .openrouter: return "openrouter/auto"
    case .ollama: return "llama3.2"
    case .clinePass: return "cline-pass/glm-5.2"
    }
  }

  /// Whether CodexGateway can discover models via `GET {base_url}/models` with the provider API key.
  var supportsModelListingFetch: Bool {
    switch self {
    case .clinePass, .grokOAuth:
      return false
    default:
      return true
    }
  }

  /// Whether models come from Cline's public recommended-models feed (no API key).
  var supportsLiveCatalogRefresh: Bool {
    switch self {
    case .clinePass: return true
    default: return false
    }
  }

  /// Whether models come from the Grok CLI OAuth catalog (`GET …/models-v2` with `~/.grok` session).
  var supportsGrokOAuthModelCatalog: Bool {
    switch self {
    case .grokOAuth: return true
    default: return false
    }
  }

  /// True when the provider exposes a fetchable model list (OpenAI `/models`, Cline feed, or Grok OAuth catalog).
  var canFetchModels: Bool {
    supportsModelListingFetch || supportsLiveCatalogRefresh || supportsGrokOAuthModelCatalog
  }

  /// Static catalog fallback (no live fetch). Unused while every preset either fetches or has a suggested seed.
  var usesCatalogModels: Bool {
    !canFetchModels
  }

  var catalogDocumentationURL: URL? {
    switch self {
    case .clinePass: return ClinePassCatalog.documentationURL
    default: return nil
    }
  }

  func providerConfig(apiKey: String) -> ProviderConfig {
    if self == .cursor {
      return ProviderConfig(
        name: providerID,
        display_name: displayName,
        base_url: baseURL,
        api_key: "local",
        vision_model: nil,
        auth_kind: ProviderAuthKind.cursorBridge.rawValue
      )
    }
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return ProviderConfig(
      name: providerID,
      display_name: displayName,
      base_url: baseURL,
      api_key: key.isEmpty ? defaultAPIKey : key,
      vision_model: nil,
      auth_kind: authKind.rawValue
    )
  }

  func catalogModels() -> [CatalogModel] {
    guard let suggestedModel else { return [] }
    return [
      CatalogModel(
        slug: "\(providerID)/\(ProviderPreset.slugPart(from: suggestedModel))",
        model: suggestedModel,
        provider: providerID,
        backend_provider: providerID,
        display_name: defaultDisplayName(for: suggestedModel),
        visibility: "list",
        input_modalities: nil,
        vision_bridge_enabled: nil,
        context_window: nil
      )
    ]
  }

  private func defaultDisplayName(for model: String) -> String {
    switch self {
    case .zai: return "Z.ai GLM-5.2"
    case .kimi: return "Kimi K2.6"
    case .qwen: return "Qwen 3.7 Plus"
    case .xiaomiMiMo: return "Xiaomi MiMo V2.5 Pro"
    case .minimax: return "MiniMax M2.5"
    case .deepseek: return "DeepSeek V4 Pro"
    case .xai: return "xAI Grok 4 (API)"
    case .grokOAuth: return "xAI Grok 4.5 (OAuth)"
    case .cursor: return "Cursor Composer 2.5"
    case .openrouter: return "OpenRouter Auto"
    case .ollama: return "Ollama Llama 3.2"
    case .clinePass:
      return ClinePassCatalog.displayName(for: ClinePassCatalog.displayLabel(for: model))
    }
  }

  static func slugPart(from modelID: String) -> String {
    modelID
      .lowercased()
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "_", with: "-")
  }

  static func from(id: String) -> ProviderPreset? {
    ProviderPreset(rawValue: id)
  }

  static func matching(providerID: String) -> ProviderPreset? {
    allCases.first { $0.providerID == providerID }
  }

  /// Presets shown in Settings, sorted A–Z by display name.
  static var featuredMenuOrder: [ProviderPreset] {
    allCases.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }
}

/// Helpers for Cline Pass model listing (live feed + display labels).
///
/// Docs: [ClinePass — Models](https://docs.cline.bot/getting-started/clinepass#models).
/// Shared with GrokBuild Desktop's recommended-models fetch path.
enum ClinePassCatalog {
  static let documentationURL = URL(string: "https://docs.cline.bot/getting-started/clinepass#models")!

  /// Public Cline recommended-models feed (includes a `clinePass` array; no API key required).
  static let recommendedModelsURL = URL(
    string: "https://api.cline.bot/api/v1/ai/cline/recommended-models"
  )!

  /// Human-readable label derived from a Cline Pass model id slug.
  static func displayLabel(for modelID: String) -> String {
    let slug = modelID.split(separator: "/").last.map(String.init) ?? modelID
    let acronyms: Set<String> = ["glm", "gpt"]
    return slug
      .split(separator: "-")
      .map { part -> String in
        let token = String(part)
        if token.allSatisfy({ $0.isNumber || $0 == "." }) { return token }
        let lower = token.lowercased()
        if acronyms.contains(lower) { return lower.uppercased() }
        return token.prefix(1).uppercased() + token.dropFirst()
      }
      .joined(separator: " ")
  }

  /// Display name written to the catalog (e.g. "Cline Kimi K2.7 Code").
  static func displayName(for catalogName: String) -> String {
    let trimmed = catalogName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.lowercased().hasPrefix("cline ") { return trimmed }
    return "Cline \(trimmed)"
  }

  /// Sorts models A–Z by display label (falls back to id), so related names stay adjacent.
  static func sortedAlphabetically(_ models: [FetchedModel]) -> [FetchedModel] {
    models.sorted { lhs, rhs in
      let left = (lhs.ownedBy?.isEmpty == false ? lhs.ownedBy! : lhs.id)
      let right = (rhs.ownedBy?.isEmpty == false ? rhs.ownedBy! : rhs.id)
      let labelOrder = left.localizedCaseInsensitiveCompare(right)
      if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
      return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }
  }
}

enum PresetInstaller {
  @discardableResult
  static func install(
    _ preset: ProviderPreset,
    apiKey: String = "",
    upsertProvider: (ProviderConfig) throws -> Void = { try ModelCatalog.shared.upsertProvider($0) },
    upsertModel: (CatalogModel) throws -> Void = { try ModelCatalog.shared.upsertModel($0) },
    patchConfig: () -> Void = { CodexConfig.patchCodexConfig() }
  ) throws -> (provider: String, models: [String]) {
    try upsertProvider(preset.providerConfig(apiKey: apiKey))
    var seeded: [String] = []
    if preset.seedsSuggestedModelOnInstall {
      for model in preset.catalogModels() {
        try upsertModel(model)
        seeded.append(model.slug)
      }
    }
    patchConfig()
    return (preset.providerID, seeded)
  }
}
