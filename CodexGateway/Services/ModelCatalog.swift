import Foundation

struct CatalogModel: Codable {
  var slug: String
  var model: String?
  var provider: String?
  var backend_provider: String?
  var display_name: String?
  var visibility: String?
  var input_modalities: [String]?
  var vision_bridge_enabled: Bool?
  var context_window: Int?
}

struct ModelCatalogFile: Codable {
  var models: [CatalogModel]
}

enum ModelCatalogError: LocalizedError {
  case providerHasInstalledModels(name: String, count: Int)

  var errorDescription: String? {
    switch self {
    case .providerHasInstalledModels(let name, let count):
      let noun = count == 1 ? "model" : "models"
      return "Cannot delete provider \"\(name)\": remove its \(count) installed \(noun) first."
    }
  }
}

struct CodexCatalogModel: Codable {
  var slug: String
  var display_name: String
  var description: String
  var default_reasoning_level: String
  var supported_reasoning_levels: [CodexReasoningLevel]
  var base_instructions: String
  var model_messages: CodexModelMessages
  var supports_reasoning_summaries: Bool
  var default_reasoning_summary: String
  var support_verbosity: Bool
  var default_verbosity: String
  var apply_patch_tool_type: String
  var web_search_tool_type: String
  var truncation_policy: CodexTruncationPolicy
  var supports_parallel_tool_calls: Bool
  var supports_image_detail_original: Bool
  var context_window: Int
  var max_context_window: Int
  var effective_context_window_percent: Int
  var experimental_supported_tools: [String]
  var input_modalities: [String]
  var supports_search_tool: Bool
  var use_responses_lite: Bool
  var additional_speed_tiers: [String]
  var service_tiers: [CodexServiceTier]
  var visibility: String
  var supported_in_api: Bool
  var shell_type: String
  var priority: Int
}

struct CodexReasoningLevel: Codable {
  var effort: String
  var description: String
}

struct CodexModelMessages: Codable {
  var instructions_template: String
}

struct CodexTruncationPolicy: Codable {
  var mode: String
  var limit: Int
}

struct CodexServiceTier: Codable {
  var id: String
  var name: String
  var description: String
}

struct CodexCatalogFile: Codable {
  var models: [CodexCatalogModel]
}

struct ProviderConfig: Codable {
  var name: String
  var display_name: String?
  var base_url: String
  var api_key: String
  var vision_model: String?
  /// `"api_key"` (default) or `"grok_oauth"`. Omitted in older providers.json → API key.
  var auth_kind: String? = nil

  var displayLabel: String {
    let stored = (display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !stored.isEmpty { return stored }
    if let preset = ProviderPreset.matching(providerID: name) {
      return preset.displayName
    }
    return name
  }
}

struct ProvidersFile: Codable {
  var providers: [ProviderConfig]
}

final class ModelCatalog {
  static let shared = ModelCatalog()

  private init() {}

  func loadCatalog() -> ModelCatalogFile {
    Paths.ensureConfigDir()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.modelCatalog)),
          let catalog = try? JSONDecoder().decode(ModelCatalogFile.self, from: data) else {
      return ModelCatalogFile(models: [])
    }
    return catalog
  }

  func saveCatalog(_ catalog: ModelCatalogFile) throws {
    Paths.ensureConfigDir()
    let data = try Self.encoder.encode(catalog)
    try data.write(to: URL(fileURLWithPath: Paths.modelCatalog))
    try saveCodexCatalogExport(catalog)
  }

  func syncCodexCatalogExport() throws {
    try saveCodexCatalogExport(loadCatalog())
  }

  /// Slugs of custom models currently applied to Codex's exported picker catalog
  /// (`~/.codex/model-catalogs/custom-providers.json`). Native models (priority < 100)
  /// are excluded so this reflects only CodexGateway-managed entries.
  func appliedCodexCustomSlugs() -> Set<String> {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.codexModelCatalog)),
          let file = try? JSONDecoder().decode(CodexCatalogFile.self, from: data) else {
      return []
    }
    return Set(file.models.filter { $0.priority >= 100 }.map(\.slug))
  }

  func saveCodexCatalogExport(_ catalog: ModelCatalogFile) throws {
    Paths.ensureConfigDir()
    let export = Self.codexCatalog(from: catalog)
    let data = try Self.encoder.encode(export)
    try data.write(to: URL(fileURLWithPath: Paths.codexModelCatalog))
  }

  func loadProviders() -> ProvidersFile {
    Paths.ensureConfigDir()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.providersConfig)),
          let providers = try? JSONDecoder().decode(ProvidersFile.self, from: data) else {
      return ProvidersFile(providers: [
        ProviderConfig(name: "", base_url: "", api_key: ""),
        ProviderConfig(name: "opencode", base_url: "https://opencode.ai/zen/go/v1", api_key: "", vision_model: "mimo-v2.5")
      ])
    }
    return providers
  }

  func saveProviders(_ providers: ProvidersFile) throws {
    Paths.ensureConfigDir()
    let data = try Self.encoder.encode(providers)
    try data.write(to: URL(fileURLWithPath: Paths.providersConfig))
  }

  func findModel(slug: String) -> CatalogModel? {
    loadCatalog().models.first { $0.slug == slug }
  }

  /// Upgrades custom model display names that are still raw ids (e.g. "composer-2.5",
  /// "deepseek/deepseek-chat-v3-0324") into friendly names ("Composer 2.5", "DeepSeek
  /// Chat V3 0324"). Leaves user-customized names untouched. Persists + re-exports when
  /// anything changed. Returns whether it changed anything.
  @discardableResult
  func normalizeDisplayNames() -> Bool {
    var file = loadCatalog()
    var changed = false
    for index in file.models.indices {
      let normalized = Self.normalizedDisplayName(for: file.models[index])
      if normalized != (file.models[index].display_name ?? "") {
        file.models[index].display_name = normalized
        changed = true
      }
    }
    if changed { try? saveCatalog(file) }
    return changed
  }

  /// The display name a model should have: keeps a user-customized name, otherwise
  /// (re)generates the friendly, brand-prefixed name. Pure (no disk) so it is
  /// unit-testable. Auto-generated names — the raw id/slug, the plain pretty name, or
  /// the branded pretty name — are all treated as safe to (re)write.
  static func normalizedDisplayName(for model: CatalogModel) -> String {
    let current = (model.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = model.model ?? model.slug
    let providerID = model.provider ?? model.backend_provider
    let branded = prettyDisplayName(from: raw, providerID: providerID)
    let plain = prettyDisplayName(from: raw, providerID: nil)
    let brandedBase = strippingAuthKindSuffix(branded)
    let autoGenerated: Set<String> = [
      "", model.slug, raw, plain, branded, brandedBase,
      brandedBase + " (API)",
      brandedBase + " (OAuth)"
    ]
    guard autoGenerated.contains(current) else { return current }
    return branded
  }

  /// Maps a fetched provider model list into catalog entries (same slugs/names Settings uses).
  static func catalogModels(from fetched: [FetchedModel], for provider: ProviderConfig) -> [CatalogModel] {
    let preset = ProviderPreset.matching(providerID: provider.name)
    let liveCline = preset?.supportsLiveCatalogRefresh == true
    let isCursor = provider.usesCursorBridge || preset?.isManagedCursorBridge == true
    let models = isCursor ? CursorBridge.filterCatalog(fetched) : fetched
    return models.map { fetchedModel in
      let displayName: String
      if liveCline {
        let label = fetchedModel.ownedBy?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (label?.isEmpty == false ? label! : ClinePassCatalog.displayLabel(for: fetchedModel.id))
        displayName = ClinePassCatalog.displayName(for: base)
      } else if isCursor {
        displayName = CursorBridge.displayName(for: fetchedModel.id)
      } else {
        displayName = prettyDisplayName(from: fetchedModel.id, providerID: provider.name)
      }
      return CatalogModel(
        slug: "\(provider.name)/\(ProviderPreset.slugPart(from: fetchedModel.id))",
        model: fetchedModel.id,
        provider: provider.name,
        backend_provider: provider.name,
        display_name: displayName,
        visibility: "list",
        input_modalities: nil,
        vision_bridge_enabled: nil,
        context_window: nil
      )
    }
  }

  /// Human-friendly display name derived from a model id. Drops any `vendor/model`
  /// path prefix, collapses doubled vendor tokens ("deepseek/deepseek-chat" → one),
  /// applies title-case with known brand casing, and prefixes the provider brand
  /// (Cline style, e.g. "Cursor Composer 2.5") unless the name already leads with it.
  /// xAI API vs OAuth models get a trailing `(API)` / `(OAuth)` so pickers stay unambiguous.
  static func prettyDisplayName(from rawID: String, providerID: String? = nil) -> String {
    var base = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return rawID }
    if let slash = base.range(of: "/", options: .backwards) {
      base = String(base[slash.upperBound...])
    }
    let rawTokens = base
      .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
      .map(String.init)
      .filter { !$0.isEmpty }
    var tokens: [String] = []
    for token in rawTokens where tokens.last?.lowercased() != token.lowercased() {
      tokens.append(token)
    }
    let pretty = tokens.map(prettyToken).joined(separator: " ")
    let name = pretty.isEmpty ? rawID : pretty
    let branded = applyingBrand(to: name, providerID: providerID)
    return applyingAuthKindSuffix(to: branded, providerID: providerID)
  }

  /// Distinguishes parallel xAI Grok providers in Codex / Settings pickers.
  static func applyingAuthKindSuffix(to name: String, providerID: String?) -> String {
    let id = (providerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let base = strippingAuthKindSuffix(name)
    if id == ProviderPreset.xai.providerID {
      return base.hasSuffix(" (API)") ? base : "\(base) (API)"
    }
    if id == ProviderPreset.grokOAuth.providerID {
      return base.hasSuffix(" (OAuth)") ? base : "\(base) (OAuth)"
    }
    return name
  }

  static func strippingAuthKindSuffix(_ name: String) -> String {
    for suffix in [" (API)", " (OAuth)"] where name.hasSuffix(suffix) {
      return String(name.dropLast(suffix.count))
    }
    return name
  }

  /// Prefixes the provider brand unless the name already starts with it.
  private static func applyingBrand(to name: String, providerID: String?) -> String {
    guard let providerID, let brand = providerBrand(for: providerID), !brand.isEmpty else {
      return name
    }
    let nameFirst = name.split(separator: " ").first.map { String($0).lowercased() }
    let brandFirst = brand.split(separator: " ").first.map { String($0).lowercased() }
    if name.lowercased() == brand.lowercased()
      || name.lowercased().hasPrefix(brand.lowercased() + " ")
      || (nameFirst != nil && nameFirst == brandFirst) {
      return name
    }
    return "\(brand) \(name)"
  }

  /// Clean brand label for a provider (preset display name or configured label with
  /// parentheticals / " Pass" trimmed): "xAI Grok (API)" → "xAI", "Cline Pass" → "Cline".
  static func providerBrand(for providerID: String) -> String? {
    let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return nil }
    // xAI presets share one short brand so model names stay "xAI Grok …", not "xAI Grok Grok …".
    if id == ProviderPreset.xai.providerID || id == ProviderPreset.grokOAuth.providerID {
      return "xAI"
    }
    let label: String
    if let preset = ProviderPreset.matching(providerID: id) {
      label = preset.displayName
    } else if let config = shared.loadProviders().providers.first(where: { $0.name == id }) {
      label = config.displayLabel
    } else {
      label = id
    }
    var brand = label
    if let paren = brand.range(of: " (") { brand = String(brand[..<paren.lowerBound]) }
    brand = brand.trimmingCharacters(in: .whitespaces)
    if brand.lowercased().hasSuffix(" pass") {
      brand = String(brand.dropLast(5)).trimmingCharacters(in: .whitespaces)
    }
    return brand.isEmpty ? nil : brand
  }

  /// Known vendor/acronym tokens that need specific casing.
  private static let brandTokens: [String: String] = [
    "deepseek": "DeepSeek", "gpt": "GPT", "glm": "GLM", "mimo": "MiMo",
    "xai": "xAI", "minimax": "MiniMax", "openrouter": "OpenRouter",
    "ai": "AI", "llm": "LLM", "vl": "VL", "oss": "OSS", "moe": "MoE"
  ]

  private static func prettyToken(_ token: String) -> String {
    if let brand = brandTokens[token.lowercased()] { return brand }
    guard let first = token.first else { return token }
    return first.uppercased() + token.dropFirst()
  }

  func isCustomModel(_ slug: String) -> Bool {
    guard let entry = findModel(slug: slug) else { return false }
    return entry.backend_provider != nil || (entry.provider != nil && entry.provider != "openai")
  }

  func resolveUpstream(slug: String) -> (provider: ProviderConfig, upstreamModel: String)? {
    guard let entry = findModel(slug: slug) else { return nil }
    let providers = loadProviders().providers
    let providerName = entry.backend_provider ?? entry.provider ?? ""
    guard let provider = providers.first(where: { $0.name == providerName }) else { return nil }
    let upstream = entry.model ?? slug
    return (provider, upstream)
  }

  func upsertProvider(_ provider: ProviderConfig) throws {
    var file = loadProviders()
    if let index = file.providers.firstIndex(where: { $0.name == provider.name }) {
      var updated = provider
      if provider.api_key.isEmpty {
        updated.api_key = file.providers[index].api_key
      }
      if (provider.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        updated.display_name = file.providers[index].display_name
      }
      if provider.auth_kind == nil {
        updated.auth_kind = file.providers[index].auth_kind
      }
      file.providers[index] = updated
    } else {
      file.providers.append(provider)
    }
    file.providers.removeAll { $0.name.isEmpty && $0.base_url.isEmpty }
    try saveProviders(file)
  }

  func deleteProvider(name: String) throws {
    let installed = models(usingProvider: name)
    guard installed.isEmpty else {
      throw ModelCatalogError.providerHasInstalledModels(name: name, count: installed.count)
    }
    var file = loadProviders()
    file.providers.removeAll { $0.name == name }
    try saveProviders(file)
  }

  func models(usingProvider providerName: String) -> [CatalogModel] {
    Self.catalogModels(loadCatalog().models, forProvider: providerName)
  }

  static func catalogModels(_ catalog: [CatalogModel], forProvider providerName: String) -> [CatalogModel] {
    catalog.filter { ($0.provider ?? $0.backend_provider ?? "") == providerName }
  }

  func upsertModel(_ model: CatalogModel) throws {
    var file = loadCatalog()
    if let index = file.models.firstIndex(where: { $0.slug == model.slug }) {
      file.models[index] = model
    } else {
      file.models.append(model)
    }
    try saveCatalog(file)
  }

  /// Replaces every catalog row for `providerName` with `models` (other providers are kept).
  func replaceModels(forProvider providerName: String, with models: [CatalogModel]) throws {
    var file = loadCatalog()
    file.models = SetupModelSelection.replacingModels(
      file.models,
      forProvider: providerName,
      with: models
    )
    try saveCatalog(file)
  }

  func deleteModel(slug: String) throws {
    var file = loadCatalog()
    file.models.removeAll { $0.slug == slug }
    try saveCatalog(file)
  }

  static func provider(from dict: [String: Any]) -> ProviderConfig? {
    let name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let baseURL = (dict["base_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !baseURL.isEmpty else { return nil }
    let displayName = (dict["display_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let authKind = (dict["auth_kind"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return ProviderConfig(
      name: name,
      display_name: displayName.isEmpty ? nil : displayName,
      base_url: baseURL,
      api_key: dict["api_key"] as? String ?? "",
      vision_model: (dict["vision_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      auth_kind: authKind.isEmpty ? nil : authKind
    )
  }

  static func catalogModel(from dict: [String: Any]) -> CatalogModel? {
    let slug = (dict["slug"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let providerName = (dict["provider"] as? String ?? dict["backend_provider"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !slug.isEmpty, !providerName.isEmpty else { return nil }

    let upstream = (dict["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = (dict["display_name"] as? String ?? slug).trimmingCharacters(in: .whitespacesAndNewlines)
    let visibility = (dict["visibility"] as? String ?? "list").trimmingCharacters(in: .whitespacesAndNewlines)

    return CatalogModel(
      slug: slug,
      model: upstream.isEmpty ? slug : upstream,
      provider: providerName,
      backend_provider: providerName,
      display_name: displayName,
      visibility: visibility.isEmpty ? "list" : visibility,
      input_modalities: nil,
      vision_bridge_enabled: nil,
      context_window: nil
    )
  }

  static func codexCatalog(from catalog: ModelCatalogFile) -> CodexCatalogFile {
    CodexCatalogFile(models: codexPickerModels(from: catalog))
  }

  static func codexPickerModels(from catalog: ModelCatalogFile) -> [CodexCatalogModel] {
    let customModels = codexCustomModels(from: catalog)
    let customSlugs = Set(customModels.map(\.slug))
    return nativeCodexModels.filter { !customSlugs.contains($0.slug) } + customModels
  }

  private static func codexCustomModels(from catalog: ModelCatalogFile) -> [CodexCatalogModel] {
    sortedCatalogModels(catalog.models).enumerated().map { index, model in
      let displayName = (model.display_name ?? model.slug).trimmingCharacters(in: .whitespacesAndNewlines)
      let providerName = (model.provider ?? model.backend_provider ?? "custom")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return codexModel(
        slug: model.slug,
        displayName: displayName.isEmpty ? model.slug : displayName,
        description: "Custom model routed through the \(providerName.isEmpty ? "custom" : providerName) provider.",
        contextWindow: model.context_window ?? 128_000,
        inputModalities: model.input_modalities ?? ["text"],
        visibility: model.visibility?.isEmpty == false ? model.visibility! : "list",
        priority: 100 + index
      )
    }
  }

  /// Alphabetical by display name, then slug (Settings list + Codex picker custom block).
  static func sortedCatalogModels(_ models: [CatalogModel]) -> [CatalogModel] {
    models.sorted { lhs, rhs in
      let left = (lhs.display_name ?? lhs.slug).trimmingCharacters(in: .whitespacesAndNewlines)
      let right = (rhs.display_name ?? rhs.slug).trimmingCharacters(in: .whitespacesAndNewlines)
      let order = left.localizedCaseInsensitiveCompare(right)
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.slug.localizedCaseInsensitiveCompare(rhs.slug) == .orderedAscending
    }
  }

  /// Alphabetical by display label, then provider id.
  static func sortedProviders(_ providers: [ProviderConfig]) -> [ProviderConfig] {
    providers.sorted { lhs, rhs in
      let order = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let defaultReasoningLevels = [
    CodexReasoningLevel(effort: "low", description: "Fast responses with lighter reasoning"),
    CodexReasoningLevel(effort: "medium", description: "Balances speed and reasoning depth for everyday tasks"),
    CodexReasoningLevel(effort: "high", description: "Greater reasoning depth for complex problems")
  ]

  private static let defaultBaseInstructions = "You are Codex, a coding agent. Follow the user's instructions, use available tools carefully, and keep working until the user's software engineering task is complete."

  private static let nativeCodexModels: [CodexCatalogModel] = [
    codexModel(slug: "gpt-5.5", displayName: "GPT-5.5", description: "Native ChatGPT model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 0),
    codexModel(slug: "gpt-5.4", displayName: "GPT-5.4", description: "Native ChatGPT model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 1),
    codexModel(slug: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", description: "Native ChatGPT model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 2),
    codexModel(slug: "gpt-5.3-codex", displayName: "GPT-5.3 Codex", description: "Native ChatGPT coding model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 3),
    codexModel(slug: "gpt-5.2-codex", displayName: "GPT-5.2 Codex", description: "Native ChatGPT coding model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 4),
    codexModel(slug: "gpt-5.2", displayName: "GPT-5.2", description: "Native ChatGPT model routed through Codex/OpenAI.", contextWindow: 272_000, priority: 5)
  ]

  private static func codexModel(
    slug: String,
    displayName: String,
    description: String,
    contextWindow: Int,
    inputModalities: [String] = ["text", "image"],
    visibility: String = "list",
    priority: Int
  ) -> CodexCatalogModel {
    CodexCatalogModel(
      slug: slug,
      display_name: displayName,
      description: description,
      default_reasoning_level: "medium",
      supported_reasoning_levels: Self.defaultReasoningLevels,
      base_instructions: Self.defaultBaseInstructions,
      model_messages: CodexModelMessages(instructions_template: Self.defaultBaseInstructions),
      supports_reasoning_summaries: false,
      default_reasoning_summary: "none",
      support_verbosity: false,
      default_verbosity: "low",
      apply_patch_tool_type: "freeform",
      web_search_tool_type: "text_and_image",
      truncation_policy: CodexTruncationPolicy(mode: "tokens", limit: 10000),
      supports_parallel_tool_calls: true,
      supports_image_detail_original: false,
      context_window: contextWindow,
      max_context_window: contextWindow,
      effective_context_window_percent: 100,
      experimental_supported_tools: [],
      input_modalities: inputModalities,
      supports_search_tool: false,
      use_responses_lite: false,
      additional_speed_tiers: [],
      service_tiers: [],
      visibility: visibility,
      supported_in_api: true,
      shell_type: "shell_command",
      priority: priority
    )
  }
}
