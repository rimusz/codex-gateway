import AppKit
import SwiftUI

struct DoctorView: View {
  @State private var inputs = DoctorInputs()
  @State private var isRunning = false

  private var checks: [DoctorCheck] { DoctorReport.checks(from: inputs) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      if let remediation = DoctorReport.primaryRemediation(inputs) {
        remediationBanner(remediation)
      }

      VStack(spacing: 0) {
        ForEach(checks) { check in
          row(check)
          if check.id != checks.last?.id { Divider() }
        }
      }
      .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
    .padding(22)
    .frame(width: 520)
    .task { await run() }
    .onReceive(NotificationCenter.default.publisher(for: .codexGatewayDoctorRerunRequested)) { _ in
      Task { await run() }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "stethoscope")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.blue)
        .frame(width: 44, height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.12)))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Doctor")
          .font(.title3.weight(.semibold))
        Text("Checks the local gateway, Codex config, and optional Cursor / Grok setup.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await run() }
      } label: {
        Label(isRunning ? "Checking…" : "Re-run checks", systemImage: "arrow.clockwise")
      }
      .disabled(isRunning)
    }
  }

  private func remediationBanner(_ remediation: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "wrench.and.screwdriver.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 6) {
        Text(remediation)
          .font(.callout.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          if needsNodeInstall {
            Button("Install with Homebrew…") { openNodeBrewInstallInTerminal() }
              .controlSize(.small)
            Button("nodejs.org…") {
              NSWorkspace.shared.open(CursorBridge.NodeRequirement.homepageURL)
            }
            .buttonStyle(.link)
            .controlSize(.small)
          } else if needsGrokLogin {
            Button("Open Terminal…") { openGrokLoginInTerminal() }
              .controlSize(.small)
          } else if needsSettings {
            Button("Open Settings") {
              SettingsWindowController.shared.show()
            }
            .controlSize(.small)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
  }

  private var needsNodeInstall: Bool {
    inputs.gatewayReachable && inputs.cursorProviderInstalled && !inputs.nodeMeetsMinimum
  }

  private var needsGrokLogin: Bool {
    inputs.gatewayReachable
      && !(inputs.cursorProviderInstalled && !inputs.nodeMeetsMinimum)
      && !(inputs.cursorProviderInstalled && !inputs.cursorKeyPresent)
      && inputs.grokOAuthInstalled
      && !inputs.grokOAuthConfigured
  }

  private var needsSettings: Bool {
    inputs.gatewayReachable
      && !needsNodeInstall
      && !needsGrokLogin
      && (
        (inputs.cursorProviderInstalled && !inputs.cursorKeyPresent)
          || !inputs.configApplied
          || !inputs.configInSync
      )
  }

  private func row(_ check: DoctorCheck) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: check.status.symbolName)
        .foregroundStyle(color(for: check.status))
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 6) {
        Text(check.title)
          .font(.callout.weight(.medium))
        Text(check.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if check.id == "node", check.status == .warning || check.status == .error {
          HStack(spacing: 10) {
            Button("Install with Homebrew…") { openNodeBrewInstallInTerminal() }
              .controlSize(.small)
            Button("nodejs.org…") {
              NSWorkspace.shared.open(CursorBridge.NodeRequirement.homepageURL)
            }
            .buttonStyle(.link)
            .controlSize(.small)
          }
        }
        if check.id == "grok-oauth", check.status == .warning {
          Button("Open Terminal…") { openGrokLoginInTerminal() }
            .controlSize(.small)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func color(for status: DoctorCheck.Status) -> Color {
    switch status {
    case .ok: return .green
    case .warning: return .orange
    case .error: return .red
    case .info: return .secondary
    }
  }

  @MainActor
  private func run() async {
    isRunning = true
    defer { isRunning = false }
    inputs = await DoctorCollector.collect()
  }

  private func openNodeBrewInstallInTerminal() {
    runAppleScript(CursorBridge.NodeRequirement.brewInstallTerminalScript())
  }

  private func openGrokLoginInTerminal() {
    runAppleScript(GrokOAuthSession.loginTerminalScript())
  }

  private func runAppleScript(_ source: String) {
    if let apple = NSAppleScript(source: source) {
      var err: NSDictionary?
      apple.executeAndReturnError(&err)
    }
  }
}
