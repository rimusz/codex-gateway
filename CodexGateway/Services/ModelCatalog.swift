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
  /// `"api_key"` (default), `"grok_oauth"`, `"cursor_bridge"`, `"anthropic"`, or `"claude_code"`.
  /// Omitted in older providers.json → API key Bearer.
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

private final class BundledSlugOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data?

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  func get() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
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
    Self.findModel(requested: slug, in: loadCatalog().models)
  }

  /// Extracts a model id from a Responses / Chat Completions body.
  /// New Codex Desktop may send `model` as a string, an object (`id`/`slug`/`model`),
  /// or only `model_id`.
  static func requestedModelID(from body: [String: Any]) -> String {
    if let value = stringID(body["model"]) { return value }
    if let object = body["model"] as? [String: Any] {
      for key in ["id", "slug", "model"] {
        if let value = stringID(object[key]) { return value }
      }
    }
    return stringID(body["model_id"]) ?? ""
  }

  /// Exact catalog slug first; then a unique unprefixed match on upstream id or
  /// `provider/model` suffix. Native Codex slugs, including ones shipped after
  /// the built-in GPT-5 list, never match a custom alias.
  static func findModel(requested: String, in models: [CatalogModel]) -> CatalogModel? {
    let needle = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    if let exact = models.first(where: { $0.slug == needle }) {
      return exact
    }
    if isNativeCodexSlug(needle) { return nil }
    let matches = models.filter { entry in
      if let upstream = entry.model, upstream == needle { return true }
      return entry.slug.hasSuffix("/\(needle)")
    }
    return matches.count == 1 ? matches[0] : nil
  }

  static func isNativeCodexSlug(_ slug: String) -> Bool {
    nativeCodexSlugs.contains(slug) || bundledNativeSlugs().contains(slug)
  }

  /// Slugs from `codex debug models --bundled`. Cached after the first read.
  /// A stuck CLI cannot block longer than `bundledSlugCommandTimeout`. These
  /// slugs are not added to the custom picker.
  static func bundledNativeSlugs(
    load: () -> Set<String> = loadBundledNativeSlugs
  ) -> Set<String> {
    bundledSlugLock.lock()
    defer { bundledSlugLock.unlock() }
    if let cachedBundledNativeSlugs { return cachedBundledNativeSlugs }
    let loaded = load()
    cachedBundledNativeSlugs = loaded
    return loaded
  }

  static func resetBundledNativeSlugs() {
    bundledSlugLock.lock()
    cachedBundledNativeSlugs = nil
    bundledSlugLock.unlock()
  }

  static func nativeSlugs(fromBundledJSON data: Data) -> Set<String> {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = root["models"] as? [[String: Any]] else {
      return []
    }
    return Set(models.compactMap { model in
      let slug = (model["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return slug?.isEmpty == false ? slug : nil
    })
  }

  static let bundledSlugCommandTimeout: TimeInterval = 5

  static func runBundledSlugCommand(
    _ executable: String,
    arguments: [String] = ["debug", "models", "--bundled"],
    timeout: TimeInterval = bundledSlugCommandTimeout
  ) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = Paths.home
    process.environment = env
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    let output = BundledSlugOutput()
    DispatchQueue.global(qos: .userInitiated).async {
      output.set(stdout.fileHandleForReading.readDataToEndOfFile())
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 1)
      }
      throw NSError(
        domain: "CodexBundledSlugs",
        code: Int(SIGTERM),
        userInfo: [NSLocalizedDescriptionKey: "codex debug models --bundled timed out after \(timeout)s"]
      )
    }
    let deadline = Date().addingTimeInterval(1)
    while output.get() == nil, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard process.terminationStatus == 0, let data = output.get() else {
      throw NSError(
        domain: "CodexBundledSlugs",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "codex debug models --bundled exited \(process.terminationStatus)"]
      )
    }
    return data
  }

  private static let bundledSlugLock = NSLock()
  private static var cachedBundledNativeSlugs: Set<String>?

  private static func loadBundledNativeSlugs() -> Set<String> {
    guard let executable = CodexCLIDaemon.resolve() else { return [] }
    guard let data = try? runBundledSlugCommand(executable) else { return [] }
    return nativeSlugs(fromBundledJSON: data)
  }

  private static func stringID(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
    // Earlier auto names used a space ("4 5"), a hyphen ("4-5"), or dropped the minor ("5").
    let spacedBranded = formattedDisplayName(from: raw, providerID: providerID, versionJoin: .space)
    let spacedPlain = formattedDisplayName(from: raw, providerID: nil, versionJoin: .space)
    let spacedBase = strippingAuthKindSuffix(spacedBranded)
    let hyphenBranded = formattedDisplayName(from: raw, providerID: providerID, versionJoin: .hyphen)
    let hyphenPlain = formattedDisplayName(from: raw, providerID: nil, versionJoin: .hyphen)
    let hyphenBase = strippingAuthKindSuffix(hyphenBranded)
    let autoGenerated: Set<String> = [
      "", model.slug, raw, plain, branded, brandedBase,
      brandedBase + " (API)",
      brandedBase + " (OAuth)",
      spacedPlain, spacedBranded, spacedBase,
      spacedBase + " (API)",
      spacedBase + " (OAuth)",
      hyphenPlain, hyphenBranded, hyphenBase,
      hyphenBase + " (API)",
      hyphenBase + " (OAuth)"
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
  /// Version numbers are shown with a dot, the way providers write them
  /// (`claude-haiku-4-5` → "Claude Haiku 4.5", `claude-opus-5-5` → "Claude Opus 5.5").
  /// A dot already in the id stays (`composer-2.5`, `gemini-2.5-flash`). A `p`
  /// standing in for a decimal (`glm-5p3-flash`) is shown as a dot. The same rules
  /// apply to every provider, including Cursor and Cline. xAI API vs OAuth models
  /// get a trailing `(API)` / `(OAuth)`.
  static func prettyDisplayName(from rawID: String, providerID: String? = nil) -> String {
    formattedDisplayName(from: rawID, providerID: providerID, versionJoin: .dot)
  }

  /// How two adjacent version numbers from a hyphenated id are written.
  private enum VersionJoin {
    /// Provider style: `4-5` → `4.5`.
    case dot
    /// Previous auto names: `4-5` → `4-5`.
    case hyphen
    /// Oldest auto names: `4-5` → `4 5`, and `5-5` collapsed to `5`.
    case space
  }

  private static func formattedDisplayName(
    from rawID: String,
    providerID: String?,
    versionJoin: VersionJoin
  ) -> String {
    var base = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return rawID }
    if let slash = base.range(of: "/", options: .backwards) {
      base = String(base[slash.upperBound...])
    }
    let tokens = modelNameTokens(from: base, versionJoin: versionJoin)
    let pretty = joinedPrettyTokens(tokens, versionJoin: versionJoin)
    let name = pretty.isEmpty ? rawID : pretty
    let branded = applyingBrand(to: name, providerID: providerID)
    return applyingAuthKindSuffix(to: branded, providerID: providerID)
  }

  private struct ModelNameToken {
    var text: String
    var hyphenBefore: Bool
  }

  /// Splits on `-`, `_`, and spaces. Consecutive duplicate words are dropped
  /// (doubled vendor ids). A repeated version number such as `5-5` is kept unless
  /// `versionJoin` is `.space`, and `hyphenBefore` records a `-` boundary.
  private static func modelNameTokens(from base: String, versionJoin: VersionJoin) -> [ModelNameToken] {
    var tokens: [ModelNameToken] = []
    var current = ""
    var hyphenBeforeCurrent = false

    func commit(nextBoundaryIsHyphen: Bool?) {
      if !current.isEmpty {
        let text = restoringDecimalPoint(current)
        current = ""
        let duplicate = tokens.last?.text.lowercased() == text.lowercased()
        let keepDuplicateVersion = versionJoin != .space
          && duplicate
          && isVersionToken(text)
          && tokens.last.map { isVersionToken($0.text) } == true
        if !duplicate || keepDuplicateVersion {
          tokens.append(ModelNameToken(text: text, hyphenBefore: hyphenBeforeCurrent))
        }
      }
      if let nextBoundaryIsHyphen {
        hyphenBeforeCurrent = nextBoundaryIsHyphen
      }
    }

    for character in base {
      if character == "-" || character == "_" || character == " " {
        commit(nextBoundaryIsHyphen: character == "-")
      } else {
        current.append(character)
      }
    }
    commit(nextBoundaryIsHyphen: nil)
    return tokens
  }

  private static func joinedPrettyTokens(_ tokens: [ModelNameToken], versionJoin: VersionJoin) -> String {
    var result = ""
    for (index, token) in tokens.enumerated() {
      let pretty = prettyToken(token.text)
      if index == 0 {
        result = pretty
        continue
      }
      let previous = tokens[index - 1]
      let versionPair = token.hyphenBefore
        && isVersionToken(previous.text)
        && isVersionToken(token.text)
      let separator: String
      if versionPair, versionJoin == .dot {
        separator = "."
      } else if versionPair, versionJoin == .hyphen {
        separator = "-"
      } else {
        separator = " "
      }
      result += separator + pretty
    }
    return result
  }

  /// Cursor (and some gateways) encode a decimal as `p` so `5.3` arrives as `5p3`.
  private static func restoringDecimalPoint(_ token: String) -> String {
    guard let marker = token.firstIndex(where: { $0 == "p" || $0 == "P" }) else { return token }
    let head = token[..<marker]
    let tail = token[token.index(after: marker)...]
    guard !head.isEmpty, !tail.isEmpty,
          head.allSatisfy(\.isNumber), tail.allSatisfy(\.isNumber) else { return token }
    return String(head) + "." + String(tail)
  }

  /// A numeric version piece (`4`, `5`, `2.5`), not a word that merely contains digits (`120b`, `v3`).
  private static func isVersionToken(_ token: String) -> Bool {
    !token.isEmpty && token.contains(where: \.isNumber) && token.allSatisfy { $0.isNumber || $0 == "." }
  }

  /// Distinguishes parallel xAI Grok providers in Codex / Settings pickers.
  static func applyingAuthKindSuffix(to name: String, providerID: String?) -> String {
    let id = (providerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let base = strippingAuthKindSuffix(name)
    if id == ProviderPreset.xai.providerID || id == ProviderPreset.anthropic.providerID {
      return base.hasSuffix(" (API)") ? base : "\(base) (API)"
    }
    if id == ProviderPreset.grokOAuth.providerID || id == ProviderPreset.claudeCode.providerID {
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
    if id == ProviderPreset.anthropic.providerID || id == ProviderPreset.claudeCode.providerID {
      return "Anthropic"
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

  /// Models still available to add: drops rows already saved for this provider.
  /// A match is the same slug, or the same upstream model id (so a renamed slug still hides it).
  static func excludingInstalled(
    _ candidates: [CatalogModel],
    installed: [CatalogModel],
    providerID: String
  ) -> [CatalogModel] {
    let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty else { return candidates }
    let owned = installed.filter { belongs($0, to: provider) }
    let slugs = Set(owned.map { normalizedIdentity($0.slug) })
    let upstreams = Set(owned.compactMap(upstreamIdentity))
    return candidates.filter { candidate in
      if slugs.contains(normalizedIdentity(candidate.slug)) { return false }
      if let upstream = upstreamIdentity(candidate), upstreams.contains(upstream) { return false }
      return true
    }
  }

  private static func belongs(_ model: CatalogModel, to providerID: String) -> Bool {
    let name = (model.provider ?? model.backend_provider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name == providerID
  }

  private static func upstreamIdentity(_ model: CatalogModel) -> String? {
    let raw = (model.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    return raw.lowercased()
  }

  private static func normalizedIdentity(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

  /// Custom models only. Native Codex models stay on Codex's own picker: once this
  /// file is installed, every listed model is sent through the gateway, and ChatGPT
  /// rejects native model ids on that path.
  static func codexPickerModels(from catalog: ModelCatalogFile) -> [CodexCatalogModel] {
    codexCustomModels(from: catalog)
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

  /// Slugs that must stay ChatGPT pass-through even if a custom upstream id matches them.
  private static let nativeCodexSlugs: Set<String> = [
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.2-codex",
    "gpt-5.2",
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
