import Foundation

struct SetupModelChoice: Equatable, Identifiable, Hashable {
  var slug: String
  var upstream: String
  var displayName: String

  var id: String { slug }
}

enum SetupStep: Equatable {
  case choose
  case connect
  case models
}

enum SetupSelection: Equatable {
  case preset(ProviderPreset)
  case custom
}

struct SetupFlow: Equatable {
  var step: SetupStep = .choose
  var selection: SetupSelection?
  var selectedSlugs: Set<String> = []
  var choices: [SetupModelChoice] = []
  var isFetching = false
  var allowsManualModel = false
  var manualSlug = ""
  var manualDisplayName = ""
  var errorMessage: String?
  private(set) var fetchGeneration = 0

  var canGoBack: Bool { step != .choose }

  var canFinish: Bool {
    guard step == .models else { return false }
    if !selectedSlugs.isEmpty { return true }
    if allowsManualModel {
      return !manualSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return false
  }

  var trimmedManualSlug: String {
    manualSlug.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func select(_ selection: SetupSelection) {
    abandonInFlightFetch()
    self.selection = selection
    step = .connect
    errorMessage = nil
  }

  mutating func goBack() {
    errorMessage = nil
    switch step {
    case .choose:
      break
    case .connect:
      step = .choose
    case .models:
      step = .connect
      abandonInFlightFetch()
    }
  }

  mutating func connectSucceeded(allowsManualModel: Bool = false) {
    abandonInFlightFetch()
    step = .models
    self.allowsManualModel = allowsManualModel
    isFetching = !allowsManualModel
    errorMessage = nil
    choices = []
    selectedSlugs = []
    manualSlug = ""
    manualDisplayName = ""
  }

  @discardableResult
  mutating func fetchStarted() -> Int {
    isFetching = true
    errorMessage = nil
    fetchGeneration += 1
    return fetchGeneration
  }

  mutating func abandonInFlightFetch() {
    fetchGeneration += 1
    isFetching = false
  }

  func isCurrentFetch(_ generation: Int) -> Bool {
    generation == fetchGeneration
  }

  mutating func applyFetchedChoices(_ choices: [SetupModelChoice], suggestedUpstream: String?) {
    self.choices = choices
    isFetching = false
    allowsManualModel = choices.isEmpty
    errorMessage = nil
    if let suggestedUpstream,
       let match = choices.first(where: { matchesSuggested($0, suggestedUpstream) }) {
      selectedSlugs = [match.slug]
    } else if choices.count == 1 {
      selectedSlugs = [choices[0].slug]
    } else {
      selectedSlugs = []
    }
  }

  mutating func fetchFailed(_ message: String, allowManual: Bool) {
    isFetching = false
    errorMessage = message
    allowsManualModel = allowManual
  }

  mutating func toggle(slug: String) {
    if selectedSlugs.contains(slug) {
      selectedSlugs.remove(slug)
    } else {
      selectedSlugs.insert(slug)
    }
  }

  mutating func setSelected(_ isSelected: Bool, slug: String) {
    if isSelected {
      selectedSlugs.insert(slug)
    } else {
      selectedSlugs.remove(slug)
    }
  }

  mutating func selectAll() {
    selectedSlugs = Set(choices.map(\.slug))
  }

  mutating func selectNone() {
    selectedSlugs = []
  }

  private func matchesSuggested(_ choice: SetupModelChoice, _ suggested: String) -> Bool {
    if choice.upstream == suggested { return true }
    return choice.slug.hasSuffix(ProviderPreset.slugPart(from: suggested))
  }
}

enum SetupConnectValidation {
  static func isReady(
    selection: SetupSelection?,
    apiKey: String,
    customName: String,
    customBaseURL: String,
    cursorNodeMeetsMinimum: Bool
  ) -> Bool {
    switch selection {
    case .preset(let preset):
      if preset.isManagedCursorBridge {
        return cursorNodeMeetsMinimum
          && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if preset.requiresAPIKeyPrompt {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return true
    case .custom:
      return !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .none:
      return false
    }
  }
}

enum SetupSessionCleanup {
  enum Action: Equatable {
    case restoreExisting
    case deleteSessionProvider
    case keep
  }

  static func action(hadExistingProvider: Bool, modelCount: Int) -> Action {
    if hadExistingProvider { return .restoreExisting }
    if modelCount == 0 { return .deleteSessionProvider }
    return .keep
  }

  /// Drop a Connect-only provider if Finish never wrote models for it.
  static func shouldDiscardInstalledProvider(modelCount: Int) -> Bool {
    action(hadExistingProvider: false, modelCount: modelCount) == .deleteSessionProvider
  }
}

enum SetupFinishTransaction {
  static func run<Snapshot>(
    snapshot: () -> Snapshot,
    persist: () throws -> Void,
    apply: () throws -> Void,
    rollback: (Snapshot) throws -> Void
  ) throws {
    let previous = snapshot()
    do {
      try persist()
      try apply()
    } catch {
      try? rollback(previous)
      throw error
    }
  }
}

enum SetupModelSelection {
  static func modelsToInstall(
    provider: ProviderConfig,
    available: [CatalogModel],
    selectedSlugs: Set<String>,
    allowsManualModel: Bool,
    manualSlug: String,
    manualDisplayName: String
  ) -> [CatalogModel] {
    let selected = available.filter { selectedSlugs.contains($0.slug) }
    if !selected.isEmpty { return selected }
    guard allowsManualModel else { return [] }
    let upstream = manualSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !upstream.isEmpty else { return [] }
    let display = manualDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      CatalogModel(
        slug: "\(provider.name)/\(ProviderPreset.slugPart(from: upstream))",
        model: upstream,
        provider: provider.name,
        backend_provider: provider.name,
        display_name: display.isEmpty
          ? ModelCatalog.prettyDisplayName(from: upstream, providerID: provider.name)
          : display,
        visibility: "list",
        input_modalities: nil,
        vision_bridge_enabled: nil,
        context_window: nil
      )
    ]
  }

  static func replacingModels(
    _ existing: [CatalogModel],
    forProvider providerName: String,
    with installed: [CatalogModel]
  ) -> [CatalogModel] {
    existing.filter { ($0.provider ?? $0.backend_provider ?? "") != providerName } + installed
  }
}

enum SetupCopy {
  static let windowTitle = "Set Up CodexGateway"
  static let summary = "Add a provider and models so Codex Desktop and the CLI can use them."
  static let stepChoose = "Choose"
  static let stepConnect = "Connect"
  static let stepModels = "Models"
  static let skip = "Skip"
  static let back = "Back"
  static let continueTitle = "Continue"
  static let install = "Install"
  static let finish = "Finish"
  static let addCustom = "Add custom provider"
  static let noAPIKeyNeeded = "No API key needed."
  static let selectAll = "Select all"
  static let selectNone = "Select none"
  static let fetching = "Fetching models…"
  static let finishNeedsModel = "Select at least one model to finish."
  static let chooseHelp = "Pick a provider. You can add more later in Settings."
  static let recheck = "Re-check"
}
