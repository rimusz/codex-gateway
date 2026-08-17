import Foundation
import Combine

@MainActor
final class SetupStore: ObservableObject {
  private struct ProviderSnapshot {
    var providerID: String
    var existingProvider: ProviderConfig?
    var fetchedModels: [FetchedModel]?
    var cursorAPIKey: String?
    var cursorWasEnabled: Bool
  }

  @Published var flow = SetupFlow()
  @Published var apiKey = ""
  @Published var customName = ""
  @Published var customDisplayName = ""
  @Published var customBaseURL = ""
  @Published var customAPIKey = ""
  @Published var isWorking = false
  @Published var isValidatingCursorKey = false
  @Published var cursorNodeProbe = CursorBridge.NodeRequirement.snapshot(binaryPath: nil, versionDisplay: "")
  @Published var cursorBridgeStatus = CursorBridgeRuntime.status
  @Published var grokStatus = GrokOAuthSession.status()

  let settings = SettingsStore()
  private(set) var installedProvider: ProviderConfig?
  private var availableCatalog: [CatalogModel] = []
  private var providerSnapshot: ProviderSnapshot?
  private var connectTask: Task<Void, Never>?
  private var fetchTask: Task<Void, Never>?

  var selectedPreset: ProviderPreset? {
    if case .preset(let preset) = flow.selection { return preset }
    return nil
  }

  var isCustomSelection: Bool {
    if case .custom = flow.selection { return true }
    return false
  }

  var canConnect: Bool {
    SetupConnectValidation.isReady(
      selection: flow.selection,
      apiKey: apiKey,
      customName: customName,
      customBaseURL: customBaseURL,
      cursorNodeMeetsMinimum: cursorNodeProbe.meetsMinimum
    )
  }

  func choose(_ selection: SetupSelection) {
    discardInstalledProvider()
    resetConnectFields()
    flow.select(selection)
    if case .preset(let preset) = selection {
      if preset.isManagedCursorBridge {
        refreshCursorNodeProbe()
      }
      if preset.authKind == .grokOAuth {
        refreshGrokStatus()
      }
    }
  }

  func goBack() {
    let leavingConnect = flow.step == .connect
    flow.goBack()
    if leavingConnect {
      discardInstalledProvider()
    }
  }

  func discardInstalledProvider() {
    connectTask?.cancel()
    fetchTask?.cancel()
    connectTask = nil
    fetchTask = nil
    flow.abandonInFlightFetch()
    isWorking = false
    isValidatingCursorKey = false

    guard let snapshot = providerSnapshot else {
      installedProvider = nil
      return
    }

    let cleanupAction = SetupSessionCleanup.action(
      hadExistingProvider: snapshot.existingProvider != nil,
      modelCount: ModelCatalog.shared.models(usingProvider: snapshot.providerID).count
    )
    switch cleanupAction {
    case .restoreExisting:
      guard let existing = snapshot.existingProvider else { break }
      try? ModelCatalog.shared.upsertProvider(existing)
      if let fetchedModels = snapshot.fetchedModels {
        try? FetchedModelsStore.shared.save(providerID: snapshot.providerID, models: fetchedModels)
      } else {
        try? FetchedModelsStore.shared.delete(providerID: snapshot.providerID)
      }
    case .deleteSessionProvider:
      try? ModelCatalog.shared.deleteProvider(name: snapshot.providerID)
      try? FetchedModelsStore.shared.delete(providerID: snapshot.providerID)
    case .keep:
      break
    }

    if snapshot.providerID == ProviderPreset.cursor.providerID {
      if let cursorAPIKey = snapshot.cursorAPIKey {
        try? CursorBridgeKeychain.save(cursorAPIKey)
      } else {
        try? CursorBridgeKeychain.delete()
      }
      CursorBridgeRuntime.isEnabled = snapshot.cursorWasEnabled
      if snapshot.cursorWasEnabled {
        Task { await CursorBridgeRuntime.startIfNeeded() }
      } else {
        CursorBridgeRuntime.stop()
      }
    }

    settings.reload()
    providerSnapshot = nil
    installedProvider = nil
  }

  func refreshCursorNodeProbe() {
    Task {
      cursorNodeProbe = await CursorBridgeRuntime.probeNodeAsync()
    }
  }

  func refreshGrokStatus() {
    grokStatus = GrokOAuthSession.status()
  }

  func connectPrimaryTitle() -> String {
    switch flow.selection {
    case .preset(let preset):
      if preset.requiresAPIKeyPrompt || preset.isManagedCursorBridge {
        return SetupCopy.install
      }
      return SetupCopy.continueTitle
    case .custom:
      return SetupCopy.install
    case .none:
      return SetupCopy.continueTitle
    }
  }

  func connectAndContinue() {
    guard !isWorking, canConnect else { return }
    captureProviderSnapshot()
    isWorking = true
    connectTask = Task { [weak self] in
      guard let self else { return }
      await self.performConnect()
      self.connectTask = nil
    }
  }

  func retryFetch() {
    guard let provider = installedProvider else { return }
    startFetch(for: provider)
  }

  func finish(
    confirmRestart: () -> Bool = RestartCodexConfirmation.confirm,
    restart: () -> Void = { CodexAppServer.shared.restartCodexDesktop() },
    onFinished: () -> Void
  ) {
    guard flow.canFinish else { return }
    do {
      try SetupFinishTransaction.run(
        snapshot: { ModelCatalog.shared.loadCatalog() },
        persist: { try self.persistSelectedModels() },
        apply: { try self.settings.applyGatewayConfig() },
        rollback: { try ModelCatalog.shared.saveCatalog($0) }
      )
      providerSnapshot = nil
      onFinished()
      if confirmRestart() {
        restart()
      }
    } catch {
      settings.reload()
      flow.errorMessage = error.localizedDescription
    }
  }

  func applySparkExample() {
    customName = CustomProviderExample.sparkProviderID
    customDisplayName = CustomProviderExample.sparkDisplayName
    customBaseURL = CustomProviderExample.sparkBaseURL
    customAPIKey = CustomProviderExample.sparkAPIKey
  }

  // MARK: - Connect

  private func performConnect() async {
    defer { isWorking = false }
    do {
      try Task.checkCancellation()
      let provider = try await installSelection()
      try Task.checkCancellation()
      installedProvider = provider
      let canFetch = canFetchModels(provider)
      flow.connectSucceeded(allowsManualModel: !canFetch)
      if canFetch {
        startFetch(for: provider)
      } else if let preset = selectedPreset {
        applyCatalog(preset.catalogModels(), suggested: preset.suggestedModel)
      }
    } catch is CancellationError {
      return
    } catch {
      flow.errorMessage = error.localizedDescription
    }
  }

  private func installSelection() async throws -> ProviderConfig {
    switch flow.selection {
    case .preset(let preset):
      try await installPreset(preset)
      return try loadedProvider(id: preset.providerID)
    case .custom:
      try settings.saveProvider(
        name: customName,
        displayName: customDisplayName,
        baseURL: customBaseURL,
        apiKey: customAPIKey,
        patchConfig: false
      )
      return try loadedProvider(id: customName.trimmingCharacters(in: .whitespacesAndNewlines))
    case .none:
      throw SettingsError.validation("Choose a provider first.")
    }
  }

  private func installPreset(_ preset: ProviderPreset) async throws {
    if preset.isManagedCursorBridge {
      let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        throw SettingsError.validation(CursorBridge.APIKeyValidation.missing.message)
      }
      guard cursorNodeProbe.meetsMinimum else {
        throw SettingsError.validation(cursorNodeProbe.detail)
      }
      isValidatingCursorKey = true
      defer { isValidatingCursorKey = false }
      let validation = await CursorBridgeRuntime.validateAPIKey(key)
      try Task.checkCancellation()
      guard validation.isValid else {
        throw SettingsError.validation(validation.message)
      }
      try settings.installCursorPreset(apiKey: key, seedModels: false, patchConfig: false)
      return
    }
    if preset.authKind == .grokOAuth {
      try settings.installPreset(preset, apiKey: "", seedModels: false, patchConfig: false)
      return
    }
    if preset.requiresAPIKeyPrompt {
      let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        throw SettingsError.validation("An API key is required for \(preset.displayName).")
      }
      try settings.installPreset(preset, apiKey: key, seedModels: false, patchConfig: false)
      return
    }
    try settings.installPreset(preset, apiKey: preset.defaultAPIKey, seedModels: false, patchConfig: false)
  }

  private func loadedProvider(id: String) throws -> ProviderConfig {
    let name = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if let provider = ModelCatalog.shared.loadProviders().providers.first(where: { $0.name == name }) {
      return provider
    }
    throw SettingsError.validation("Provider \"\(name)\" was not saved.")
  }

  // MARK: - Fetch

  private func startFetch(for provider: ProviderConfig) {
    fetchTask?.cancel()
    let generation = flow.fetchStarted()
    fetchTask = Task {
      do {
        if provider.usesCursorBridge {
          _ = await CursorBridgeRuntime.startIfNeeded()
          try Task.checkCancellation()
          cursorBridgeStatus = CursorBridgeRuntime.status
        }
        var fetched = try await ProviderModelFetcher.fetch(for: provider)
        try Task.checkCancellation()
        if provider.usesCursorBridge {
          fetched = CursorBridge.filterCatalog(fetched)
        }
        guard flow.isCurrentFetch(generation) else { return }
        settings.saveFetchedModels(fetched, for: provider.name)
        let catalog = ModelCatalog.catalogModels(from: fetched, for: provider)
        applyCatalog(catalog, suggested: selectedPreset?.suggestedModel)
      } catch is CancellationError {
        return
      } catch {
        guard flow.isCurrentFetch(generation) else { return }
        let message = (error as? ProviderModelFetcher.FetchError)?.errorDescription
          ?? error.localizedDescription
        flow.fetchFailed(message, allowManual: true)
      }
    }
  }

  private func applyCatalog(_ catalog: [CatalogModel], suggested: String?) {
    availableCatalog = catalog
    let choices = catalog.map {
      SetupModelChoice(
        slug: $0.slug,
        upstream: $0.model ?? $0.slug,
        displayName: $0.display_name ?? $0.slug
      )
    }
    flow.applyFetchedChoices(choices, suggestedUpstream: suggested)
  }

  private func canFetchModels(_ provider: ProviderConfig) -> Bool {
    ProviderPreset.matching(providerID: provider.name)?.canFetchModels ?? true
  }

  private func captureProviderSnapshot() {
    guard providerSnapshot == nil else { return }
    let providerID: String
    switch flow.selection {
    case .preset(let preset):
      providerID = preset.providerID
    case .custom:
      providerID = customName.trimmingCharacters(in: .whitespacesAndNewlines)
    case .none:
      return
    }
    let existing = ModelCatalog.shared.loadProviders().providers.first { $0.name == providerID }
    providerSnapshot = ProviderSnapshot(
      providerID: providerID,
      existingProvider: existing,
      fetchedModels: FetchedModelsStore.shared.load()[providerID],
      cursorAPIKey: providerID == ProviderPreset.cursor.providerID ? CursorBridgeKeychain.load() : nil,
      cursorWasEnabled: providerID == ProviderPreset.cursor.providerID && CursorBridgeRuntime.isEnabled
    )
  }

  private func persistSelectedModels() throws {
    guard let provider = installedProvider else {
      throw SettingsError.validation("Install a provider before finishing.")
    }
    let models = SetupModelSelection.modelsToInstall(
      provider: provider,
      available: availableCatalog,
      selectedSlugs: flow.selectedSlugs,
      allowsManualModel: flow.allowsManualModel,
      manualSlug: flow.manualSlug,
      manualDisplayName: flow.manualDisplayName
    )
    guard !models.isEmpty else {
      throw SettingsError.validation(SetupCopy.finishNeedsModel)
    }
    try ModelCatalog.shared.replaceModels(forProvider: provider.name, with: models)
  }

  private func resetConnectFields() {
    apiKey = ""
    customName = ""
    customDisplayName = ""
    customBaseURL = ""
    customAPIKey = ""
    installedProvider = nil
    availableCatalog = []
    isValidatingCursorKey = false
    flow.errorMessage = nil
  }
}
