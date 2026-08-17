import Foundation

enum DoctorCollector {
  @MainActor
  static func collect() async -> DoctorInputs {
    async let gateway = probeGateway()
    async let cursorBridge = CursorBridge.probeManaged(timeout: 1.5)

    let providers = ModelCatalog.shared.loadProviders().providers
    let models = ModelCatalog.shared.loadCatalog().models
    let cursorInstalled = providers.contains { $0.usesCursorBridge }
    let grokInstalled = providers.contains { $0.usesGrokOAuth }
    let configApplied = CodexConfig.hasManagedBlock()
    let configContent = try? String(contentsOfFile: Paths.codexConfig, encoding: .utf8)

    var inputs = DoctorInputs()
    inputs.gatewayReachable = await gateway
    inputs.gatewayPort = Int(Paths.gatewayPort)
    inputs.configApplied = configApplied
    inputs.configInSync = SettingsStore.gatewayInSync(
      hasManagedBlock: configApplied,
      applied: ModelCatalog.shared.appliedCodexCustomSlugs(),
      desired: Set(models.map(\.slug))
    )
    inputs.configHasConflicts = configApplied
      && (configContent.map(CodexConfig.hasConflictingGatewayEntries) ?? false)
    inputs.signedIn = CodexConfig.isSignedIn()
    inputs.hasCustomModels = SettingsStore.customModelsHidden(signedIn: false, models: models)

    let nodeStatus = await CursorBridgeRuntime.probeNodeAsync()
    inputs.nodeFound = nodeStatus.isFound
    inputs.nodeVersionDisplay = nodeStatus.versionDisplay
    inputs.nodeMeetsMinimum = nodeStatus.meetsMinimum

    let cursorProbe = await cursorBridge
    inputs.cursorProviderInstalled = cursorInstalled
    inputs.cursorKeyPresent = CursorBridgeKeychain.hasAPIKey()
    inputs.cursorBridgeReachable = cursorInstalled && cursorProbe.isOnline

    inputs.grokOAuthInstalled = grokInstalled
    inputs.grokOAuthConfigured = GrokOAuthSession.status().configured
    return inputs
  }

  private static func probeGateway() async -> Bool {
    let url = URL(string: "http://\(Paths.gatewayHost):\(Paths.gatewayPort)/health")
    guard let url else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }
}

enum DoctorConfigRepair {
  static func run(
    ensureConfig: @escaping @Sendable () throws -> Void = { try CodexConfig.ensureConfigFile() },
    syncCatalog: @escaping @Sendable () throws -> Void = {
      try ModelCatalog.shared.syncCodexCatalogExport()
    },
    patchConfig: @escaping @Sendable () throws -> Void = {
      try CodexConfig.patchCodexConfigThrowing()
    },
    restartCodex: @escaping @Sendable () -> Void = {
      CodexAppServer.shared.restartCodexDesktop()
    }
  ) async throws {
    try await Task.detached(priority: .userInitiated) {
      try ensureConfig()
      try syncCatalog()
      try patchConfig()
      restartCodex()
    }.value
  }
}
