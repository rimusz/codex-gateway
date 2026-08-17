import AppKit
import SwiftUI

enum SettingsDisclosureDefaults {
  static let addProviderExpanded = false
  static let presetsExpanded = false
  static let providersExpanded = true
  static let modelsExpanded = true
}

struct SettingsView: View {
  @ObservedObject var store: SettingsStore

  @State private var showingProviderEditor = false
  @State private var editingProvider: ProviderConfig?
  @State private var providerName = ""
  @State private var providerDisplayName = ""
  @State private var providerBaseURL = ""
  @State private var providerAPIKey = ""

  @State private var showingModelEditor = false
  @State private var editingModel: CatalogModel?
  @State private var modelSlug = ""
  @State private var modelProvider = ""
  @State private var modelUpstream = ""
  @State private var modelDisplayName = ""
  @State private var modelContextWindow = ""
  @State private var modelSupportsImageInput = false
  @State private var modelCatalogOptions: [CatalogModel] = []
  @State private var selectedCatalogModelSlug = ""
  @State private var fetchingProviderID: String?
  @State private var loadingModelChoices = false
  @State private var fetchErrorProviderID: String?
  @State private var fetchErrorMessage: String?

  @State private var providerPendingDeletion: ProviderConfig?
  @State private var modelPendingDeletion: CatalogModel?
  @State private var showingResetConfirmation = false

  @State private var installingPreset: ProviderPreset?
  @State private var presetAPIKey = ""
  @State private var isAddProviderSectionExpanded = SettingsDisclosureDefaults.addProviderExpanded
  @State private var isPresetSectionExpanded = SettingsDisclosureDefaults.presetsExpanded
  @State private var isProvidersSectionExpanded = SettingsDisclosureDefaults.providersExpanded
  @State private var isModelsSectionExpanded = SettingsDisclosureDefaults.modelsExpanded
  @State private var isValidatingCursorKey = false
  @State private var cursorNodeProbe = CursorBridge.NodeRequirement.snapshot(binaryPath: nil, versionDisplay: "")
  @State private var cursorBridgeStatus = CursorBridgeRuntime.status

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Providers & Models")
            .font(.title3.weight(.semibold))
          Text("Manage OpenAI-compatible providers and catalog models for Codex Desktop.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      }

      signInHintSection
      addProviderSection
      providersSection
      modelsSection
      resetSection
    }
    .formStyle(.grouped)
    .frame(minWidth: 620, minHeight: 520)
    .navigationTitle("CodexGateway Settings")
    .toolbar { toolbar }
    .onAppear {
      store.reload()
      refreshCursorNodeProbe()
      Task {
        cursorBridgeStatus = await CursorBridgeRuntime.reconcile()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .codexGatewayCursorBridgeRuntimeStatusDidChange)) { _ in
      cursorBridgeStatus = CursorBridgeRuntime.status
    }
    .safeAreaInset(edge: .bottom) { statusBar }
    .sheet(isPresented: $showingProviderEditor) {
      providerEditorSheet
        .id(editingProvider?.name ?? providerName)
    }
    .sheet(isPresented: $showingModelEditor) { modelEditorSheet }
    .sheet(item: $installingPreset) { preset in presetKeySheet(preset) }
    .alert("Error", isPresented: errorBinding) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
    .confirmationDialog(
      "Delete provider “\(providerPendingDeletion?.displayLabel ?? "")”?",
      isPresented: providerDeleteBinding,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let provider = providerPendingDeletion { deleteProvider(provider) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the provider from ~/.codexgateway/providers.json.")
    }
    .confirmationDialog(
      "Delete model “\(modelPendingDeletion?.display_name ?? modelPendingDeletion?.slug ?? "")”?",
      isPresented: modelDeleteBinding,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let model = modelPendingDeletion { deleteModel(model) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the model from the Codex catalog.")
    }
    .confirmationDialog(
      store.gatewayConfigInSync ? "Reset Codex configuration?" : "Update Codex configuration?",
      isPresented: $showingResetConfirmation,
      titleVisibility: .visible
    ) {
      if store.gatewayConfigInSync {
        Button("Reset and Restart Codex", role: .destructive) {
          store.resetGatewayConfig()
        }
      } else {
        Button("Update and Restart Codex") {
          store.updateGatewayConfig()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(store.gatewayConfigInSync
        ? "Removes CodexGateway's managed settings from Codex's own config so Codex returns to its native configuration, then restarts Codex. Your CodexGateway providers and models are not deleted."
        : "Writes your current CodexGateway providers and models into Codex's config, then restarts Codex.")
    }
  }

  // MARK: - Toolbar & status

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem {
      Button {
        DoctorWindowController.shared.show()
      } label: {
        Label("Doctor", systemImage: "stethoscope")
      }
      .help("Check gateway, Codex config, Node.js, and Cursor / Grok setup")
    }
    ToolbarItem {
      Button {
        store.reload()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Reload providers and models from disk")
    }
  }

  @ViewBuilder
  private var statusBar: some View {
    if store.statusMessage != nil || store.needsCodexRestart {
      HStack(spacing: 10) {
        if let status = store.statusMessage {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text(status)
            .font(.callout)
        }
        Spacer()
        if store.needsCodexRestart {
          Button {
            store.restartCodex()
          } label: {
            Label("Restart Codex", systemImage: "arrow.clockwise.circle")
          }
          .controlSize(.small)
          .buttonStyle(.borderedProminent)
          .help("Restart Codex Desktop so it reloads the updated providers and models")
        }
        if store.statusMessage != nil {
          Button {
            store.statusMessage = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial)
      .overlay(Divider(), alignment: .top)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  // MARK: - Sign-in hint

  @ViewBuilder
  private var signInHintSection: some View {
    if store.customModelsNeedSignIn {
      Section {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "person.crop.circle.badge.exclamationmark")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 3) {
            Text("Sign in to Codex to use custom models")
              .font(.callout.weight(.semibold))
            Text("Codex only lists custom models in its picker when you're signed in — a free account is enough. Native GPT models require an OpenAI/ChatGPT account.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  // MARK: - Add provider

  private var addProviderSection: some View {
    Section {
      collapsibleHeader(
        title: "Add Provider",
        systemImage: "plus.circle",
        isExpanded: $isAddProviderSectionExpanded
      )
      if isAddProviderSectionExpanded {
        presetPicker
        Text("Most presets add only the provider endpoint and key — add models from the provider row. Cursor runs a local Node bridge (port \(CursorBridgeRuntime.managedPort)). xAI Grok (OAuth) seeds a suggested model and uses your Grok CLI login.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          beginAddingProvider()
        } label: {
          Label("Add custom provider", systemImage: "plus")
        }
      }
    }
  }

  private var presetPicker: some View {
    DisclosureGroup(isExpanded: $isPresetSectionExpanded) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
        ForEach(ProviderPreset.featuredMenuOrder) { preset in
          presetTile(preset)
        }
      }
      .padding(.top, 10)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "puzzlepiece.extension")
          .foregroundStyle(.secondary)
        Text("Install a provider preset")
          .font(.headline)
        Spacer()
        Text("\(ProviderPreset.featuredMenuOrder.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .padding(.vertical, 4)
  }

  private func presetTile(_ preset: ProviderPreset) -> some View {
    let installed = store.isPresetInstalled(preset)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(preset.displayName)
          .font(.headline)
        Spacer()
        if installed {
          Label("Installed", systemImage: "checkmark.circle.fill")
            .labelStyle(.iconOnly)
            .foregroundStyle(.green)
            .help("Already installed")
        }
      }
      Text(preset.baseURL)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
      Text(presetFetchCaption(preset))
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button(installed ? "Reinstall" : "Install") {
        installPreset(preset)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(installed ? Color.green.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  // MARK: - Providers section

  private var providersSection: some View {
    Section {
      collapsibleHeader(
        title: "Providers",
        systemImage: "server.rack",
        count: store.usableProviders.count,
        isExpanded: $isProvidersSectionExpanded
      )
      if isProvidersSectionExpanded {
        if store.usableProviders.isEmpty {
          Text("No providers yet. Install a preset or add a custom provider above.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.usableProviders) { provider in
            providerRow(provider)
          }
        }
      }
    }
  }

  private func presetFetchCaption(_ preset: ProviderPreset) -> String {
    if preset.isManagedCursorBridge {
      return "Local Cursor bridge · port \(CursorBridgeRuntime.managedPort) · Cursor API key"
    }
    if preset.authKind == .grokOAuth {
      let status = GrokOAuthSession.status()
      let auth = status.configured ? "Connected" : "Not signed in"
      return "Grok CLI OAuth · \(auth) · fetches model catalog"
    }
    if preset.supportsLiveCatalogRefresh {
      return "Fetches live Cline Pass catalog"
    }
    if preset.supportsModelListingFetch {
      return "Fetches model list"
    }
    let count = preset.catalogModels().count
    return "\(count) available model\(count == 1 ? "" : "s")"
  }

  private func providerCanFetchModels(_ provider: ProviderConfig) -> Bool {
    ProviderPreset.matching(providerID: provider.name)?.canFetchModels ?? true
  }

  private func fetchHelp(for provider: ProviderConfig, highlight: Bool) -> String {
    if provider.usesGrokOAuth
      || ProviderPreset.matching(providerID: provider.name)?.supportsGrokOAuthModelCatalog == true {
      return highlight
        ? "Fetch models from your Grok CLI OAuth session before adding a model."
        : "Refresh the Grok CLI OAuth model catalog."
    }
    if ProviderPreset.matching(providerID: provider.name)?.supportsLiveCatalogRefresh == true {
      return highlight
        ? "Fetch the Cline Pass model list before adding a model (no API key required)."
        : "Refresh the Cline Pass model list (no API key required)."
    }
    return highlight
      ? "Fetch the provider's model list before adding a model."
      : "Refresh the provider's model list."
  }

  private func providerRow(_ provider: ProviderConfig) -> some View {
    let choices = modelCatalogChoices(for: provider)
    let preset = ProviderPreset.matching(providerID: provider.name)
    let canFetch = providerCanFetchModels(provider)
    let canAdd = !choices.isEmpty || canFetch || preset?.usesCatalogModels == true
    let isFetching = fetchingProviderID == provider.name
    let addedCount = store.models.filter {
      ($0.provider ?? $0.backend_provider ?? "") == provider.name
    }.count
    let highlightFetch = canFetch && choices.isEmpty
    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(provider.displayLabel)
            .font(.headline)
          providerKeyBadge(for: provider)
          if addedCount > 0 {
            Text("\(addedCount) model\(addedCount == 1 ? "" : "s")")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if !choices.isEmpty {
            Text("\(choices.count) available")
              .font(.caption2)
              .foregroundStyle(.green)
          } else if canFetch {
            Text("Fetch models first")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
        Text(provider.base_url)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
        if provider.usesCursorBridge {
          Text(cursorNodeProbe.detail)
            .font(.caption2)
            .foregroundStyle(cursorNodeProbe.meetsMinimum ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        }
      if fetchErrorProviderID == provider.name, let message = fetchErrorMessage {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 6) {
          Button("Add model") { beginAddingModel(for: provider) }
            .controlSize(.small)
            .disabled(!canAdd || isFetching || loadingModelChoices)
            .help(
              canAdd
                ? (choices.isEmpty ? "Fetches this provider's model list, then opens the picker" : "Choose one model from this provider")
                : "Fetch this provider's model list first"
            )
          Button("Edit") { beginEditingProvider(provider) }
            .controlSize(.small)
          Button("Remove", role: .destructive) { providerPendingDeletion = provider }
            .controlSize(.small)
            .disabled(addedCount > 0)
            .help(
              addedCount > 0
                ? "Remove its \(addedCount) model\(addedCount == 1 ? "" : "s") first before removing this provider."
                : "Remove this provider."
            )
        }
        if canFetch {
          providerFetchButton(provider, isFetching: isFetching, highlight: highlightFetch)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func providerFetchButton(_ provider: ProviderConfig, isFetching: Bool, highlight: Bool) -> some View {
    if highlight {
      Button {
        fetchModels(for: provider)
      } label: {
        providerFetchButtonLabel(isFetching: isFetching, highlighted: true)
      }
      .controlSize(.small)
      .buttonStyle(.borderedProminent)
      .disabled(isFetching)
      .help(fetchHelp(for: provider, highlight: true))
    } else {
      Button {
        fetchModels(for: provider)
      } label: {
        providerFetchButtonLabel(isFetching: isFetching, highlighted: false)
      }
      .controlSize(.small)
      .buttonStyle(.borderless)
      .disabled(isFetching)
      .help(fetchHelp(for: provider, highlight: false))
    }
  }

  @ViewBuilder
  private func providerFetchButtonLabel(isFetching: Bool, highlighted: Bool) -> some View {
    if isFetching {
      HStack(spacing: 5) {
        ProgressView().controlSize(.small)
        Text("Fetching...")
      }
    } else {
      Label("Fetch models", systemImage: highlighted ? "arrow.down.circle.fill" : "arrow.down.circle")
    }
  }

  @ViewBuilder
  private func providerKeyBadge(for provider: ProviderConfig) -> some View {
    if provider.usesGrokOAuth {
      let status = GrokOAuthSession.status()
      if status.configured {
        Label("OAuth", systemImage: "person.badge.key.fill")
          .font(.caption2)
          .foregroundStyle(.green)
          .help("Grok CLI session at \(status.authPath)")
      } else {
        Label("Sign in", systemImage: "person.badge.key")
          .font(.caption2)
          .foregroundStyle(.orange)
          .help(status.setupHint ?? "Run `grok login` in Terminal")
      }
    } else if provider.usesCursorBridge {
      if CursorBridgeKeychain.hasAPIKey() {
        Label(cursorBridgeStatus.isRunning ? "Bridge on" : "Key saved", systemImage: "key.fill")
          .font(.caption2)
          .foregroundStyle(cursorBridgeStatus.isRunning ? .green : .secondary)
          .help(cursorBridgeStatus.summary)
      } else {
        Label("Add key", systemImage: "key.slash")
          .font(.caption2)
          .foregroundStyle(.orange)
          .help("Paste a Cursor API key from cursor.com/dashboard → Integrations")
      }
    } else if provider.api_key.isEmpty {
      Label("No key", systemImage: "key.slash")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      Label("Key saved", systemImage: "key.fill")
        .font(.caption2)
        .foregroundStyle(.green)
    }
  }

  private func providerDisplayLabel(for providerID: String) -> String {
    guard !providerID.isEmpty else { return "—" }
    return store.usableProviders.first { $0.name == providerID }?.displayLabel ?? providerID
  }

  // MARK: - Models section

  private var modelsSection: some View {
    Section {
      collapsibleHeader(
        title: "Models",
        systemImage: "cpu",
        count: store.models.count,
        isExpanded: $isModelsSectionExpanded
      )
      if isModelsSectionExpanded {
        if store.models.isEmpty {
          Text("No catalog models yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.models) { model in
            modelRow(model)
          }
        }
      }
    } footer: {
      Text("Add models from a provider row — Add model fetches the list automatically when needed.")
    }
  }

  private func collapsibleHeader(
    title: String,
    systemImage: String,
    count: Int? = nil,
    isExpanded: Binding<Bool>
  ) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) {
        isExpanded.wrappedValue.toggle()
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
        Spacer()
        if let count {
          Text("\(count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows or hides the \(title.lowercased()) list")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var resetSection: some View {
    Section {
      if store.gatewayConfigInSync {
        Button(role: .destructive) {
          showingResetConfirmation = true
        } label: {
          Label("Reset Gateway Config", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        }
        .help("Reset only Codex's config so it stops routing through CodexGateway. Your CodexGateway providers and models are kept.")
      } else {
        Button {
          showingResetConfirmation = true
        } label: {
          Label("Update Gateway Config", systemImage: "arrow.triangle.2.circlepath")
        }
        .help("Apply your CodexGateway providers and models to Codex's config and restart Codex.")
      }
    } footer: {
      Text(store.gatewayConfigInSync
        ? "Resets only Codex's configuration so it stops routing through CodexGateway. Your CodexGateway providers and models stay saved. Codex will restart."
        : "Codex's config is out of date with your CodexGateway models. Update writes your current providers and models into Codex's config. Codex will restart.")
    }
  }

  private func modelRow(_ model: CatalogModel) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "cpu")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.display_name ?? model.slug)
          .font(.headline)
        Text(model.slug)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text("Provider: \(providerDisplayLabel(for: model.provider ?? model.backend_provider ?? ""))  ·  Upstream: \(model.model ?? model.slug)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Edit") { beginEditingModel(model) }
      Button("Delete", role: .destructive) { modelPendingDeletion = model }
    }
    .padding(.vertical, 2)
  }

  // MARK: - Editor sheets

  private var providerEditorSheet: some View {
    let isGrokOAuth = editingProvider?.usesGrokOAuth == true
      || providerName == ProviderPreset.grokOAuth.providerID
    let isCursor = isCursorProviderEditor
    let isCustomNew = editingProvider == nil && !isCursor && !isGrokOAuth
    return VStack(alignment: .leading, spacing: 0) {
      sheetHeader(
        icon: "server.rack",
        title: editingProvider == nil ? "Add provider" : "Edit provider",
        subtitle: providerEditorSubtitle(isGrokOAuth: isGrokOAuth, isCursor: isCursor)
      )

      Form {
        if isCustomNew {
          sparkExampleSection
        }

        TextField("Name (id)", text: $providerName)
          .disabled(editingProvider != nil)
        Text("Lowercase identifier, e.g. \"minimax\". Used to link models to this provider.")
          .font(.caption)
          .foregroundStyle(.secondary)

        TextField("Display name", text: $providerDisplayName)
        Text("Shown in Settings, e.g. \"MiniMax\" or \"Cline Pass\".")
          .font(.caption)
          .foregroundStyle(.secondary)

        TextField("Base URL", text: $providerBaseURL)
          .disabled(isCursor)
        Text(
          isGrokOAuth
            ? "CLI chat proxy base, e.g. https://cli-chat-proxy.grok.com/v1"
            : (isCursor
              ? "Managed local bridge (port \(CursorBridgeRuntime.managedPort))."
              : "e.g. https://api.minimax.io/v1")
        )
          .font(.caption)
          .foregroundStyle(.secondary)

        if isGrokOAuth {
          let status = GrokOAuthSession.status()
          Text(status.configured ? "Grok CLI session connected" : (status.setupHint ?? "Not signed in"))
            .foregroundStyle(status.configured ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
          Text("No API key is stored in providers.json for this provider.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if isCursor {
          cursorCredentialFields(
            keyHint: CursorBridgeKeychain.hasAPIKey()
              ? "Cursor API key (leave blank to keep current)"
              : "Cursor API key (key_…)"
          )
        } else {
          SecureField(
            editingProvider?.api_key.isEmpty == false ? "API key (leave blank to keep current)" : "API key",
            text: $providerAPIKey
          )
        }
      }
      .formStyle(.grouped)

      sheetButtons(save: {
        if isCursor {
          saveCursorProviderEdits()
        } else {
          saveProvider()
        }
      }) { showingProviderEditor = false }
    }
    .frame(width: 460)
    .id(isCursor ? "cursor-editor" : (editingProvider?.name ?? "new-provider"))
    .onAppear {
      refreshCursorNodeProbe()
      cursorBridgeStatus = CursorBridgeRuntime.status
    }
  }

  private var isCursorProviderEditor: Bool {
    editingProvider?.usesCursorBridge == true
      || ProviderPreset.matching(providerID: providerName)?.isManagedCursorBridge == true
      || providerName == ProviderPreset.cursor.providerID
  }

  private func providerEditorSubtitle(isGrokOAuth: Bool, isCursor: Bool) -> String {
    if isGrokOAuth {
      return "Uses the official Grok CLI session (~/.grok/auth.json)."
    }
    if isCursor {
      return "Managed Cursor OpenAI bridge — key stored under Application Support."
    }
    return "OpenAI-compatible endpoint and API key."
  }

  @ViewBuilder
  private var sparkExampleSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Text(CustomProviderExample.sparkExampleSummary)
          .font(.caption.weight(.semibold))
        Text(CustomProviderExample.dummyKeyHelp)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          "\(CustomProviderExample.sparkProviderID)  ·  \(CustomProviderExample.sparkDisplayName)  ·  \(CustomProviderExample.sparkBaseURL)"
        )
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        Button("Fill Spark example") {
          applySparkCustomProviderExample()
        }
        .controlSize(.small)
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private var cursorNodeStatusSection: some View {
    if !cursorNodeProbe.meetsMinimum {
      cursorNodeInstallBanner
    }
  }

  private var cursorNodeInstallBanner: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 6) {
        Text(cursorNodeProbe.isFound ? "Node.js is too old" : "Node.js is required")
          .font(.caption.weight(.semibold))
        Text(cursorNodeProbe.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Button("Install with Homebrew…") { openNodeBrewInstallInTerminal() }
            .controlSize(.small)
          Button("nodejs.org…") {
            NSWorkspace.shared.open(CursorBridge.NodeRequirement.homepageURL)
          }
          .buttonStyle(.link)
          .controlSize(.small)
          Button("Re-check") {
            refreshCursorNodeProbe()
          }
          .controlSize(.small)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
  }

  private func refreshCursorNodeProbe() {
    Task {
      cursorNodeProbe = await CursorBridgeRuntime.probeNodeAsync()
    }
  }

  private func openNodeBrewInstallInTerminal() {
    let script = CursorBridge.NodeRequirement.brewInstallTerminalScript()
    if let apple = NSAppleScript(source: script) {
      var err: NSDictionary?
      apple.executeAndReturnError(&err)
    }
  }

  @ViewBuilder
  private func cursorCredentialFields(keyHint: String) -> some View {
    cursorNodeStatusSection
    if cursorNodeProbe.meetsMinimum {
      Text(cursorNodeProbe.detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    SecureField(keyHint, text: $providerAPIKey)
    Text("Paste from cursor.com/dashboard → Integrations. Stored only for the local bridge (not in providers.json).")
      .font(.caption)
      .foregroundStyle(.secondary)
    Text("Bridge: \(cursorBridgeStatus.summary)")
      .font(.caption2)
      .foregroundStyle(.secondary)
    if isValidatingCursorKey {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Validating Cursor API key…")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var modelEditorSheet: some View {
    VStack(alignment: .leading, spacing: 0) {
      sheetHeader(
        icon: "cpu",
        title: editingModel == nil ? "Add model" : "Edit model",
        subtitle: "Catalog entry shown in the Codex model picker."
      )

      Form {
        Picker("Provider", selection: $modelProvider) {
          ForEach(store.usableProviders) { provider in
            Text(provider.displayLabel).tag(provider.name)
          }
        }
        .disabled(!modelCatalogOptions.isEmpty)
        .onChange(of: modelProvider) { _, _ in
          refreshModelCatalogOptionsForSelectedProvider()
        }

        if loadingModelChoices {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Fetching models for \(providerDisplayLabel(for: modelProvider))…")
              .foregroundStyle(.secondary)
          }
        } else if !modelCatalogOptions.isEmpty {
          Picker("Choose model", selection: $selectedCatalogModelSlug) {
            ForEach(modelCatalogOptions) { model in
              Text(model.display_name ?? model.slug).tag(model.slug)
            }
          }
          .onChange(of: selectedCatalogModelSlug) { _, newValue in
            applySelectedCatalogModel(slug: newValue)
          }
          Text("\(modelCatalogOptions.count) models available for \(providerDisplayLabel(for: modelProvider)).")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if editingModel == nil {
          Text("No models available yet. Use Fetch models on the provider row, then try again.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        TextField("Slug (Codex id)", text: $modelSlug)
          .disabled(editingModel != nil || !modelCatalogOptions.isEmpty || loadingModelChoices)
        Text(modelCatalogOptions.isEmpty
          ? "The id Codex uses, e.g. \"minimax/minimax-m2.5\"."
          : "Generated from the selected provider model.")
          .font(.caption)
          .foregroundStyle(.secondary)

        TextField("Upstream model name", text: $modelUpstream)
          .disabled(!modelCatalogOptions.isEmpty || loadingModelChoices)
        Text("Model name sent to the provider. Defaults to the slug.")
          .font(.caption)
          .foregroundStyle(.secondary)

        TextField("Display name", text: $modelDisplayName)

        Section("Model metadata") {
          TextField("Context window", text: $modelContextWindow)
          Text("Optional token limit. Leave blank if unknown.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Toggle("Supports image input", isOn: $modelSupportsImageInput)
        }
      }
      .formStyle(.grouped)

      sheetButtons(
        save: saveModel,
        cancel: {
          loadingModelChoices = false
          showingModelEditor = false
        },
        saveDisabled: loadingModelChoices || (editingModel == nil && modelCatalogOptions.isEmpty)
      )
    }
    .frame(width: 460)
    .onAppear {
      refreshModelCatalogOptionsForSelectedProvider()
    }
    .onChange(of: store.fetchedModels.count) { _, _ in
      refreshModelCatalogOptionsForSelectedProvider()
    }
  }

  private func sheetHeader(icon: String, title: String, subtitle: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private func sheetButtons(
    save: @escaping () -> Void,
    cancel: @escaping () -> Void,
    saveDisabled: Bool = false
  ) -> some View {
    HStack {
      Spacer()
      Button("Cancel", role: .cancel, action: cancel)
        .keyboardShortcut(.cancelAction)
      Button("Save", action: save)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(saveDisabled)
    }
    .padding(20)
  }

  // MARK: - Bindings

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.errorMessage = nil } }
    )
  }

  private var providerDeleteBinding: Binding<Bool> {
    Binding(
      get: { providerPendingDeletion != nil },
      set: { if !$0 { providerPendingDeletion = nil } }
    )
  }

  private var modelDeleteBinding: Binding<Bool> {
    Binding(
      get: { modelPendingDeletion != nil },
      set: { if !$0 { modelPendingDeletion = nil } }
    )
  }

  // MARK: - Actions

  private func installPreset(_ preset: ProviderPreset) {
    isAddProviderSectionExpanded = true
    if preset.requiresAPIKeyPrompt || preset.authKind == .grokOAuth {
      presetAPIKey = ""
      installingPreset = preset
    } else {
      performInstall(preset, apiKey: preset.defaultAPIKey)
    }
  }

  private func performInstall(_ preset: ProviderPreset, apiKey: String) {
    do {
      try store.installPreset(preset, apiKey: apiKey)
      isProvidersSectionExpanded = true
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }

  private func presetKeySheet(_ preset: ProviderPreset) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      sheetHeader(
        icon: "key.fill",
        title: "Install \(preset.displayName)",
        subtitle: preset.baseURL
      )

      Form {
        if preset.authKind == .grokOAuth {
          let status = GrokOAuthSession.status()
          Text(status.configured ? "Grok CLI session connected." : (status.setupHint ?? "Not signed in"))
            .foregroundStyle(status.configured ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
          Text("Install @xai-official/grok and run `grok login` (or `grok login --oauth`). Credentials stay in ~/.grok/auth.json.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if preset.isManagedCursorBridge {
          cursorCredentialFields(keyHint: "Cursor API key (key_…)")
          Text("Inference-only bridge: Codex keeps tool calling; Cursor returns assistant text via the local sidecar.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          SecureField("API key", text: $presetAPIKey)
          Text("Your key is stored locally in ~/.codexgateway/providers.json.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          installingPreset = nil
          isValidatingCursorKey = false
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isValidatingCursorKey)
        Button(isValidatingCursorKey ? "Validating…" : "Install") {
          if preset.isManagedCursorBridge {
            performCursorInstall()
            return
          }
          installingPreset = nil
          if preset.authKind == .grokOAuth {
            performInstall(preset, apiKey: "")
            return
          }
          let key = presetAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !key.isEmpty else {
            store.errorMessage = "An API key is required for \(preset.displayName)."
            return
          }
          performInstall(preset, apiKey: key)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(isValidatingCursorKey || (preset.isManagedCursorBridge && !cursorNodeProbe.meetsMinimum))
      }
      .padding(20)
    }
    .frame(width: 460)
    .onAppear {
      if preset.isManagedCursorBridge {
        presetAPIKey = ""
        providerAPIKey = ""
        refreshCursorNodeProbe()
        cursorBridgeStatus = CursorBridgeRuntime.status
      }
    }
  }

  private func beginAddingProvider() {
    isAddProviderSectionExpanded = true
    isProvidersSectionExpanded = true
    editingProvider = nil
    providerName = ""
    providerDisplayName = ""
    providerBaseURL = ""
    providerAPIKey = ""
    DispatchQueue.main.async {
      showingProviderEditor = true
    }
  }

  private func applySparkCustomProviderExample() {
    providerName = CustomProviderExample.sparkProviderID
    providerDisplayName = CustomProviderExample.sparkDisplayName
    providerBaseURL = CustomProviderExample.sparkBaseURL
    providerAPIKey = CustomProviderExample.sparkAPIKey
  }

  private func beginEditingProvider(_ provider: ProviderConfig) {
    editingProvider = provider
    providerName = provider.name
    providerDisplayName = provider.display_name ?? provider.displayLabel
    providerBaseURL = provider.base_url
    providerAPIKey = ""
    DispatchQueue.main.async {
      showingProviderEditor = true
    }
  }

  private func saveProvider() {
    do {
      try store.saveProvider(
        name: providerName,
        displayName: providerDisplayName,
        baseURL: providerBaseURL,
        apiKey: providerAPIKey
      )
      isProvidersSectionExpanded = true
      showingProviderEditor = false
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }

  private func saveCursorProviderEdits() {
    let key = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
      // Keep existing secret; still allow display-name edits via saveProvider with blank key.
      do {
        try store.saveProvider(
          name: providerName,
          displayName: providerDisplayName,
          baseURL: ProviderPreset.cursor.baseURL,
          apiKey: ""
        )
        isProvidersSectionExpanded = true
        showingProviderEditor = false
      } catch {
        store.errorMessage = error.localizedDescription
      }
      return
    }
    isValidatingCursorKey = true
    Task {
      let validation = await CursorBridgeRuntime.validateAPIKey(key)
      await MainActor.run {
        isValidatingCursorKey = false
        guard validation.isValid else {
          store.errorMessage = validation.message
          return
        }
        do {
          try store.updateCursorAPIKey(key)
          try store.saveProvider(
            name: providerName,
            displayName: providerDisplayName,
            baseURL: ProviderPreset.cursor.baseURL,
            apiKey: ""
          )
          isProvidersSectionExpanded = true
          providerAPIKey = ""
          showingProviderEditor = false
          cursorBridgeStatus = CursorBridgeRuntime.status
        } catch {
          store.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func performCursorInstall() {
    let key = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? presetAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
      : providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      store.errorMessage = CursorBridge.APIKeyValidation.missing.message
      return
    }
    isValidatingCursorKey = true
    Task {
      let validation = await CursorBridgeRuntime.validateAPIKey(key)
      await MainActor.run {
        isValidatingCursorKey = false
        guard validation.isValid else {
          store.errorMessage = validation.message
          return
        }
        do {
          try store.installCursorPreset(apiKey: key)
          isProvidersSectionExpanded = true
          installingPreset = nil
          presetAPIKey = ""
          providerAPIKey = ""
          cursorBridgeStatus = CursorBridgeRuntime.status
        } catch {
          store.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func deleteProvider(_ provider: ProviderConfig) {
    do {
      try store.deleteProvider(name: provider.name)
      if provider.usesCursorBridge {
        cursorBridgeStatus = CursorBridgeRuntime.status
      }
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }

  private func beginAddingModel(for provider: ProviderConfig) {
    isModelsSectionExpanded = true
    let choices = modelCatalogChoices(for: provider)
    if !choices.isEmpty {
      openModelEditorForAdd(provider: provider, options: choices)
      return
    }

    let preset = ProviderPreset.matching(providerID: provider.name)
    if preset?.usesCatalogModels == true, let preset {
      let catalog = preset.catalogModels()
      if !catalog.isEmpty {
        openModelEditorForAdd(provider: provider, options: catalog)
        return
      }
    }

    let canFetch = providerCanFetchModels(provider)
    if canFetch {
      loadingModelChoices = true
      fetchModels(for: provider) { models in
        loadingModelChoices = false
        let options = catalogModels(from: models, for: provider)
        guard !options.isEmpty else { return }
        openModelEditorForAdd(provider: provider, options: options)
      } onFailure: {
        loadingModelChoices = false
      }
      return
    }

    openModelEditorForAdd(provider: provider, options: [])
  }

  private func openModelEditorForAdd(provider: ProviderConfig, options: [CatalogModel]) {
    let resolved = options.isEmpty ? modelCatalogChoices(for: provider) : options
    editingModel = nil
    modelCatalogOptions = resolved
    modelProvider = provider.name
    modelContextWindow = ""
    modelSupportsImageInput = false
    if let first = resolved.first {
      selectedCatalogModelSlug = first.slug
      applySelectedCatalogModel(slug: first.slug)
    } else {
      selectedCatalogModelSlug = ""
      modelSlug = ""
      modelUpstream = ""
      modelDisplayName = ""
    }
    showingModelEditor = true
  }

  private func refreshModelCatalogOptionsForSelectedProvider() {
    guard editingModel == nil, !loadingModelChoices else { return }
    guard let provider = store.usableProviders.first(where: { $0.name == modelProvider }) else {
      modelCatalogOptions = []
      return
    }
    let options = modelCatalogChoices(for: provider)
    modelCatalogOptions = options
    if let first = options.first {
      selectedCatalogModelSlug = first.slug
      applySelectedCatalogModel(slug: first.slug)
    } else {
      selectedCatalogModelSlug = ""
      modelSlug = ""
      modelUpstream = ""
      modelDisplayName = ""
    }
  }

  private func beginEditingModel(_ model: CatalogModel) {
    editingModel = model
    modelCatalogOptions = []
    selectedCatalogModelSlug = ""
    modelSlug = model.slug
    modelProvider = model.provider ?? model.backend_provider ?? ""
    modelUpstream = model.model ?? model.slug
    modelDisplayName = model.display_name ?? model.slug
    modelContextWindow = model.context_window.map(String.init) ?? ""
    modelSupportsImageInput = model.input_modalities?.contains("image") ?? false
    showingModelEditor = true
  }

  private func saveModel() {
    do {
      let contextWindow = Int(modelContextWindow.filter(\.isNumber))
      let inputModalities = modelSupportsImageInput ? ["text", "image"] : nil
      let displayName = modelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
      let upstream = modelUpstream.trimmingCharacters(in: .whitespacesAndNewlines)
      let slug = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
      let provider = modelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
      try store.saveModel(CatalogModel(
        slug: slug,
        model: upstream.isEmpty ? slug : upstream,
        provider: provider,
        backend_provider: provider,
        display_name: displayName.isEmpty ? slug : displayName,
        visibility: "list",
        input_modalities: inputModalities,
        vision_bridge_enabled: modelSupportsImageInput ? true : nil,
        context_window: contextWindow
      ))
      isModelsSectionExpanded = true
      showingModelEditor = false
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }

  private func modelCatalogChoices(for provider: ProviderConfig) -> [CatalogModel] {
    if let fetched = store.fetchedModels[provider.name] {
      return catalogModels(from: fetched, for: provider)
    }

    guard let preset = ProviderPreset.matching(providerID: provider.name), preset.usesCatalogModels else {
      return []
    }
    return preset.catalogModels()
  }

  private func catalogModels(from fetched: [FetchedModel], for provider: ProviderConfig) -> [CatalogModel] {
    ModelCatalog.catalogModels(from: fetched, for: provider)
  }

  private func applySelectedCatalogModel(slug: String) {
    guard let selected = modelCatalogOptions.first(where: { $0.slug == slug }) else { return }
    modelSlug = selected.slug
    modelProvider = selected.provider ?? selected.backend_provider ?? modelProvider
    modelUpstream = selected.model ?? selected.slug
    modelDisplayName = selected.display_name ?? selected.slug
  }

  private func fetchModels(
    for provider: ProviderConfig,
    onSuccess: (([FetchedModel]) -> Void)? = nil,
    onFailure: (() -> Void)? = nil
  ) {
    fetchingProviderID = provider.name
    fetchErrorProviderID = nil
    fetchErrorMessage = nil
    Task {
      do {
        if provider.usesCursorBridge {
          _ = await CursorBridgeRuntime.startIfNeeded()
          await MainActor.run { cursorBridgeStatus = CursorBridgeRuntime.status }
        }
        var models = try await ProviderModelFetcher.fetch(for: provider)
        if provider.usesCursorBridge {
          models = CursorBridge.filterCatalog(models)
        }
        await MainActor.run {
          store.saveFetchedModels(models, for: provider.name)
          fetchingProviderID = nil
          onSuccess?(models)
        }
      } catch {
        await MainActor.run {
          fetchingProviderID = nil
          fetchErrorProviderID = provider.name
          fetchErrorMessage = (error as? ProviderModelFetcher.FetchError)?.errorDescription
            ?? error.localizedDescription
          onFailure?()
        }
      }
    }
  }

  private func deleteModel(_ model: CatalogModel) {
    do {
      try store.deleteModel(slug: model.slug)
    } catch {
      store.errorMessage = error.localizedDescription
    }
  }
}
