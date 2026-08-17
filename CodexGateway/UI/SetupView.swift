import AppKit
import SwiftUI

struct SetupView: View {
  @ObservedObject var store: SetupStore
  var onSkip: () -> Void
  var onFinished: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      Group {
        switch store.flow.step {
        case .choose:
          chooseStep
        case .connect:
          connectStep
        case .models:
          modelsStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
    }
    .frame(width: 560, height: 560)
    .onAppear {
      store.refreshCursorNodeProbe()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(SetupCopy.windowTitle)
        .font(.title3.weight(.semibold))
      Text(SetupCopy.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      stepIndicator
    }
    .padding(20)
  }

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      stepLabel(SetupCopy.stepChoose, active: store.flow.step == .choose, done: store.flow.step != .choose)
      Text("·").foregroundStyle(.secondary)
      stepLabel(
        SetupCopy.stepConnect,
        active: store.flow.step == .connect,
        done: store.flow.step == .models
      )
      Text("·").foregroundStyle(.secondary)
      stepLabel(SetupCopy.stepModels, active: store.flow.step == .models, done: false)
    }
    .font(.caption.weight(.semibold))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(stepNumber) of 3")
  }

  private var stepNumber: Int {
    switch store.flow.step {
    case .choose: return 1
    case .connect: return 2
    case .models: return 3
    }
  }

  private func stepLabel(_ title: String, active: Bool, done: Bool) -> some View {
    Text(title)
      .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .opacity(done || active ? 1 : 0.7)
  }

  // MARK: - Choose

  private var chooseStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(SetupCopy.chooseHelp)
          .font(.caption)
          .foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
          ForEach(ProviderPreset.featuredMenuOrder) { preset in
            chooseTile(title: preset.displayName, caption: preset.setupCaption) {
              store.choose(.preset(preset))
            }
          }
          chooseTile(title: SetupCopy.addCustom, caption: "Your own OpenAI-compatible endpoint") {
            store.choose(.custom)
          }
        }
      }
      .padding(20)
    }
  }

  private func chooseTile(title: String, caption: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Connect

  private var connectStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let preset = store.selectedPreset {
          presetConnect(preset)
        } else if store.isCustomSelection {
          customConnect
        }
        if let message = store.flow.errorMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(20)
    }
  }

  @ViewBuilder
  private func presetConnect(_ preset: ProviderPreset) -> some View {
    Text(preset.displayName)
      .font(.headline)
    Text(preset.baseURL)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(.secondary)
      .textSelection(.enabled)

    if preset.authKind == .grokOAuth {
      Text(store.grokStatus.configured ? "Grok CLI session connected." : (store.grokStatus.setupHint ?? "Not signed in"))
        .foregroundStyle(store.grokStatus.configured ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
      Text("Install @xai-official/grok and run `grok login`. Credentials stay in ~/.grok/auth.json.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Button("Open Terminal…") { openGrokLogin() }
          .controlSize(.small)
        Button(SetupCopy.recheck) { store.refreshGrokStatus() }
          .controlSize(.small)
      }
    } else if preset.isManagedCursorBridge {
      cursorConnect
    } else if preset.requiresAPIKeyPrompt {
      SecureField("API key", text: $store.apiKey)
      Text("Your key is stored locally in ~/.codexgateway/providers.json.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text(SetupCopy.noAPIKeyNeeded)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var cursorConnect: some View {
    if !store.cursorNodeProbe.meetsMinimum {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 6) {
          Text(store.cursorNodeProbe.isFound ? "Node.js is too old" : "Node.js is required")
            .font(.caption.weight(.semibold))
          Text(store.cursorNodeProbe.detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
          HStack(spacing: 10) {
            Button("Install with Homebrew…") { openNodeBrewInstall() }
              .controlSize(.small)
            Button("nodejs.org…") {
              NSWorkspace.shared.open(CursorBridge.NodeRequirement.homepageURL)
            }
            .buttonStyle(.link)
            .controlSize(.small)
            Button(SetupCopy.recheck) { store.refreshCursorNodeProbe() }
              .controlSize(.small)
          }
        }
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    } else {
      Text(store.cursorNodeProbe.detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    SecureField("Cursor API key (key_…)", text: $store.apiKey)
    Text("Paste from cursor.com/dashboard → Integrations. Stored only for the local bridge.")
      .font(.caption)
      .foregroundStyle(.secondary)
    if store.isValidatingCursorKey {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Validating Cursor API key…")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var customConnect: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(CustomProviderExample.sparkExampleSummary)
        .font(.caption.weight(.semibold))
      Text(CustomProviderExample.dummyKeyHelp)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Fill Spark example") { store.applySparkExample() }
        .controlSize(.small)
      TextField("Name (id)", text: $store.customName)
      TextField("Display name", text: $store.customDisplayName)
      TextField("Base URL", text: $store.customBaseURL)
      SecureField("API key", text: $store.customAPIKey)
    }
  }

  // MARK: - Models

  private var modelsStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.flow.isFetching {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(SetupCopy.fetching)
            .foregroundStyle(.secondary)
        }
      } else if !store.flow.choices.isEmpty {
        HStack {
          Button(SetupCopy.selectAll) { store.flow.selectAll() }
            .controlSize(.small)
          Button(SetupCopy.selectNone) { store.flow.selectNone() }
            .controlSize(.small)
          Spacer()
          Text("\(store.flow.selectedSlugs.count) selected")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        List {
          ForEach(store.flow.choices) { choice in
            Toggle(isOn: binding(for: choice.slug)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(choice.displayName)
                Text(choice.upstream)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
      }

      if store.flow.allowsManualModel {
        TextField("Model id", text: $store.flow.manualSlug)
        TextField("Display name (optional)", text: $store.flow.manualDisplayName)
        Text("Used when the provider list is empty or fetch failed.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let message = store.flow.errorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Retry") { store.retryFetch() }
          .controlSize(.small)
      }

      if !store.flow.canFinish, !store.flow.isFetching {
        Text(SetupCopy.finishNeedsModel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  private func binding(for slug: String) -> Binding<Bool> {
    Binding(
      get: { store.flow.selectedSlugs.contains(slug) },
      set: { _ in store.flow.toggle(slug: slug) }
    )
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Button(SetupCopy.skip, action: onSkip)
        .keyboardShortcut(.cancelAction)
      Spacer()
      if store.flow.canGoBack {
        Button(SetupCopy.back) { store.goBack() }
          .disabled(store.isWorking)
      }
      if store.flow.step != .choose {
        Button(primaryTitle) { primaryAction() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(primaryDisabled)
      }
    }
    .padding(16)
  }

  private var primaryTitle: String {
    switch store.flow.step {
    case .choose:
      return SetupCopy.continueTitle
    case .connect:
      return store.isWorking ? "Working…" : store.connectPrimaryTitle()
    case .models:
      return SetupCopy.finish
    }
  }

  private var primaryDisabled: Bool {
    switch store.flow.step {
    case .choose:
      return true
    case .connect:
      if store.isWorking || store.isValidatingCursorKey { return true }
      return !store.canConnect
    case .models:
      return !store.flow.canFinish || store.flow.isFetching
    }
  }

  private func primaryAction() {
    switch store.flow.step {
    case .choose:
      break
    case .connect:
      store.connectAndContinue()
    case .models:
      store.finish(onFinished: onFinished)
    }
  }

  private func openNodeBrewInstall() {
    runAppleScript(CursorBridge.NodeRequirement.brewInstallTerminalScript())
  }

  private func openGrokLogin() {
    runAppleScript(GrokOAuthSession.loginTerminalScript())
  }

  private func runAppleScript(_ source: String) {
    if let apple = NSAppleScript(source: source) {
      var err: NSDictionary?
      apple.executeAndReturnError(&err)
    }
  }
}

extension ProviderPreset {
  var setupCaption: String {
    switch self {
    case .cursor:
      return "Local Cursor bridge · Cursor API key"
    case .grokOAuth:
      return "Uses grok login · no API key stored"
    case .xai:
      return "API key against api.x.ai"
    case .ollama:
      return "Local · no API key"
    case .clinePass:
      return "Fetches Cline Pass catalog"
    default:
      return "OpenAI-compatible API key"
    }
  }
}
