import Foundation
import Combine

extension ProviderConfig: Identifiable {
  var id: String { name }
}

extension CatalogModel: Identifiable {
  var id: String { slug }
}

final class SettingsStore: ObservableObject {
  @Published private(set) var providers: [ProviderConfig] = []
  @Published private(set) var models: [CatalogModel] = []
  @Published private(set) var fetchedModels: [String: [FetchedModel]] = [:]
  @Published var statusMessage: String?
  @Published var errorMessage: String?
  /// True when providers/models changed and Codex Desktop must restart to pick them up.
  @Published private(set) var needsCodexRestart = false
  /// True when Codex's config already reflects CodexGateway's current models. When false,
  /// the gateway action is an "Update" (apply models) rather than a "Reset".
  @Published private(set) var gatewayConfigInSync = true
  /// True when the user is signed in to Codex Desktop. Codex only lists custom
  /// catalog models in its picker when signed in (a free account is enough), so
  /// when this is false and custom models exist we surface a hint.
  @Published private(set) var codexSignedIn = true

  var usableProviders: [ProviderConfig] {
    ModelCatalog.sortedProviders(providers.filter { !$0.name.isEmpty })
  }

  /// True when CodexGateway has custom (non-OpenAI) models but Codex is signed out, so
  /// those models won't appear in Codex's picker until the user signs in.
  var customModelsNeedSignIn: Bool {
    SettingsStore.customModelsHidden(signedIn: codexSignedIn, models: models)
  }

  /// Pure check: custom models are hidden from Codex's picker when the user is
  /// signed out and at least one non-OpenAI catalog model exists.
  static func customModelsHidden(signedIn: Bool, models: [CatalogModel]) -> Bool {
    guard !signedIn else { return false }
    return models.contains(where: isCustomModel)
  }

  private static func isCustomModel(_ model: CatalogModel) -> Bool {
    let provider = (model.backend_provider ?? model.provider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return !provider.isEmpty && provider != "openai"
  }

  func reload() {
    ModelCatalog.shared.normalizeDisplayNames()
    providers = ModelCatalog.sortedProviders(ModelCatalog.shared.loadProviders().providers)
    models = ModelCatalog.sortedCatalogModels(ModelCatalog.shared.loadCatalog().models)
    fetchedModels = FetchedModelsStore.shared.load()
    codexSignedIn = CodexConfig.isSignedIn()
    gatewayConfigInSync = SettingsStore.gatewayInSync(
      hasManagedBlock: CodexConfig.hasManagedBlock(),
      applied: ModelCatalog.shared.appliedCodexCustomSlugs(),
      desired: Set(models.map(\.slug))
    )
  }

  /// Codex config is in sync only when the managed block is present and the applied
  /// custom model set matches CodexGateway's current model set.
  static func gatewayInSync(hasManagedBlock: Bool, applied: Set<String>, desired: Set<String>) -> Bool {
    hasManagedBlock && applied == desired
  }

  /// The kinds of change that can flow to Codex. Providers/keys are read live by the
  /// gateway from `~/.codexgateway/providers.json`, so they never require a Codex restart.
  /// Only model catalog changes alter what Codex reads (`custom-providers.json`).
  enum CodexChange {
    case provider
    case model
  }

  /// Status shown after any model add/edit/delete. The models list drives Codex's
  /// picker, which only refreshes on restart.
  static let modelsChangedMessage = "Models list changed — restart Codex to apply."

  /// Whether a change requires restarting Codex Desktop to take effect.
  static func requiresCodexRestart(_ change: CodexChange) -> Bool {
    switch change {
    case .provider: return false
    case .model: return true
    }
  }

  func saveProvider(
    name: String,
    displayName: String,
    baseURL: String,
    apiKey: String,
    patchConfig: Bool = true
  ) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
      throw SettingsError.validation("Name and base URL are required.")
    }

    let existing = providers.first { $0.name == trimmedName }
    try ModelCatalog.shared.upsertProvider(
      ProviderConfig(
        name: trimmedName,
        display_name: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName,
        base_url: trimmedURL,
        api_key: apiKey,
        vision_model: existing?.vision_model,
        auth_kind: existing?.auth_kind
      )
    )
    if patchConfig {
      CodexConfig.patchCodexConfig()
    }
    reload()
    announce("Provider saved — takes effect immediately, no Codex restart needed.", change: .provider)
  }

  func modelsUsing(provider name: String) -> [CatalogModel] {
    ModelCatalog.catalogModels(models, forProvider: name)
  }

  func deleteProvider(name: String) throws {
    let wasCursor = providers.first(where: { $0.name == name })?.usesCursorBridge == true
      || name == ProviderPreset.cursor.providerID
    try ModelCatalog.shared.deleteProvider(name: name)
    try? FetchedModelsStore.shared.delete(providerID: name)
    if wasCursor {
      CursorBridgeRuntime.isEnabled = false
      CursorBridgeRuntime.stop()
      try? CursorBridgeKeychain.delete()
    }
    CodexConfig.patchCodexConfig()
    reload()
    announce("Provider deleted.", change: .provider)
  }

  func saveFetchedModels(_ models: [FetchedModel], for providerID: String) {
    let trimmedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else { return }
    do {
      try FetchedModelsStore.shared.save(providerID: trimmedID, models: models)
      var updated = fetchedModels
      updated[trimmedID] = models
      fetchedModels = updated
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func saveModel(slug: String, provider: String, upstream: String, displayName: String) throws {
    let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSlug.isEmpty, !trimmedProvider.isEmpty else {
      throw SettingsError.validation("Slug and provider are required.")
    }

    let modelName = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

    try ModelCatalog.shared.upsertModel(
      CatalogModel(
        slug: trimmedSlug,
        model: modelName.isEmpty ? trimmedSlug : modelName,
        provider: trimmedProvider,
        backend_provider: trimmedProvider,
        display_name: label.isEmpty ? trimmedSlug : label,
        visibility: "list",
        input_modalities: nil,
        vision_bridge_enabled: nil,
        context_window: nil
      )
    )
    CodexConfig.patchCodexConfig()
    reload()
    announce(SettingsStore.modelsChangedMessage, change: .model)
  }

  func saveModel(_ model: CatalogModel) throws {
    let providerName = (model.provider ?? model.backend_provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !providerName.isEmpty else {
      throw SettingsError.validation("Slug and provider are required.")
    }
    try ModelCatalog.shared.upsertModel(model)
    CodexConfig.patchCodexConfig()
    reload()
    announce(SettingsStore.modelsChangedMessage, change: .model)
  }

  func deleteModel(slug: String) throws {
    try ModelCatalog.shared.deleteModel(slug: slug)
    CodexConfig.patchCodexConfig()
    reload()
    announce(SettingsStore.modelsChangedMessage, change: .model)
  }

  func installPreset(
    _ preset: ProviderPreset,
    apiKey: String,
    seedModels: Bool = true,
    patchConfig: Bool = true
  ) throws {
    let result = try PresetInstaller.install(
      preset,
      apiKey: apiKey,
      seedModels: seedModels,
      patchConfig: patchConfig ? { CodexConfig.patchCodexConfig() } : {}
    )
    reload()
    if preset.authKind == .grokOAuth {
      let status = GrokOAuthSession.status()
      let sessionNote = status.configured
        ? "Grok CLI session connected."
        : (status.setupHint ?? "Run `grok login` in Terminal.")
      if result.models.isEmpty {
        statusMessage = "Installed \(preset.displayName). \(sessionNote) Add models from the provider row."
      } else {
        announce(
          "Installed \(preset.displayName) with \(result.models.count) model. \(sessionNote)",
          change: .model
        )
      }
      return
    }
    if preset.isManagedCursorBridge {
      CursorBridgeRuntime.isEnabled = true
      statusMessage =
        "Installed \(preset.displayName). Starting local bridge on port \(CursorBridgeRuntime.managedPort) — add models from the provider row."
      Task { await CursorBridgeRuntime.startIfNeeded() }
      return
    }
    // Default presets install only the provider endpoint/key — no Codex restart needed.
    // Adding models from the provider row is what flags a restart.
    if result.models.isEmpty {
      statusMessage = "Installed \(preset.displayName) provider. Add models from the provider row."
    } else {
      announce(
        "Installed \(preset.displayName) with \(result.models.count) model\(result.models.count == 1 ? "" : "s").",
        change: .model
      )
    }
  }

  /// Saves a Cursor API key (Application Support) and installs/reinstalls the Cursor provider.
  /// Call only after `CursorBridgeRuntime.validateAPIKey` succeeds.
  func installCursorPreset(
    apiKey: String,
    seedModels: Bool = true,
    patchConfig: Bool = true
  ) throws {
    try CursorBridgeKeychain.save(apiKey)
    try installPreset(.cursor, apiKey: "local", seedModels: seedModels, patchConfig: patchConfig)
  }

  /// Updates the stored Cursor API key for an already-installed Cursor provider.
  func updateCursorAPIKey(_ apiKey: String) throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SettingsError.validation("A Cursor API key is required.")
    }
    try CursorBridgeKeychain.save(trimmed)
    CursorBridgeRuntime.isEnabled = true
    Task {
      CursorBridgeRuntime.stop()
      _ = await CursorBridgeRuntime.startIfNeeded()
    }
    statusMessage = "Cursor API key updated — bridge restarting."
  }

  /// Restarts Codex Desktop so it reloads the updated provider/model catalog.
  func restartCodex(restart: () -> Void = { CodexAppServer.shared.restartCodexDesktop() }) {
    restart()
    needsCodexRestart = false
    statusMessage = "Codex restart requested."
  }

  /// Resets only Codex's configuration (managed block + exported catalog). CodexGateway's
  /// providers and models are kept.
  func resetGatewayConfig(
    reset: () -> Void = { CodexConfig.resetToNative() },
    restart: () -> Void = { CodexAppServer.shared.restartCodexDesktop() }
  ) {
    reset()
    restart()
    reload()
    needsCodexRestart = false
    statusMessage = "Codex config reset — your providers and models are kept. Codex restart requested."
  }

  /// Writes the exported catalog and managed `config.toml` block. Does not restart Codex.
  /// Creates `~/.codex/config.toml` when it is missing so first-run setup can opt in.
  func applyGatewayConfig(
    ensureConfig: () throws -> Void = { try CodexConfig.ensureConfigFile() },
    sync: () throws -> Void = { try ModelCatalog.shared.syncCodexCatalogExport() },
    patch: () throws -> Void = { try CodexConfig.patchCodexConfigThrowing() }
  ) throws {
    try ensureConfig()
    try sync()
    try patch()
    reload()
    needsCodexRestart = true
    statusMessage = "Codex config updated with your models."
  }

  /// Applies CodexGateway's current providers and models to Codex's config (re-exports the
  /// catalog and patches config.toml), then restarts Codex.
  func updateGatewayConfig(
    ensureConfig: () throws -> Void = { try CodexConfig.ensureConfigFile() },
    sync: () throws -> Void = { try ModelCatalog.shared.syncCodexCatalogExport() },
    patch: () throws -> Void = { try CodexConfig.patchCodexConfigThrowing() },
    restart: () -> Void = { CodexAppServer.shared.restartCodexDesktop() }
  ) {
    do {
      try applyGatewayConfig(ensureConfig: ensureConfig, sync: sync, patch: patch)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    restart()
    needsCodexRestart = false
    statusMessage = "Codex config updated with your models. Codex restart requested."
  }

  func isPresetInstalled(_ preset: ProviderPreset) -> Bool {
    usableProviders.contains { $0.name == preset.providerID }
  }

  /// Records a success message after a change and flags a Codex restart only when the
  /// change kind requires it (model catalog changes do; provider/key changes don't).
  private func announce(_ message: String, change: CodexChange) {
    statusMessage = message
    if SettingsStore.requiresCodexRestart(change) {
      needsCodexRestart = true
    }
  }
}

enum SettingsError: LocalizedError {
  case validation(String)

  var errorDescription: String? {
    switch self {
    case .validation(let message): return message
    }
  }
}
