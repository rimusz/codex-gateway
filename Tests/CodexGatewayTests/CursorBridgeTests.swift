import XCTest
@testable import CodexGateway

final class CursorBridgeTests: XCTestCase {
  func testManagedEndpointUsesPort18788() {
    XCTAssertEqual(CursorBridge.managedEndpoint.port, 18788)
    XCTAssertEqual(CursorBridge.managedEndpoint.baseURL, "http://127.0.0.1:18788/v1")
    XCTAssertTrue(CursorBridge.isLoopback(CursorBridge.managedEndpoint.baseURL))
    XCTAssertEqual(CursorBridgeRuntime.managedPort, 18788)
    XCTAssertEqual(CursorBridgeRuntime.managedEndpoint, CursorBridge.managedEndpoint)
  }

  func testExcludedCatalogIDs() {
    XCTAssertEqual(CursorBridge.excludedCatalogIDs, ["default", "auto", "auto-smart"])
    XCTAssertTrue(CursorBridge.isExcludedCatalogID("default"))
    XCTAssertTrue(CursorBridge.isExcludedCatalogID("auto"))
    XCTAssertTrue(CursorBridge.isExcludedCatalogID("auto-smart"))
    XCTAssertTrue(CursorBridge.isExcludedCatalogID("AUTO"))
    XCTAssertFalse(CursorBridge.isExcludedCatalogID("composer-2.5"))
  }

  func testFilterCatalogDropsRoutingAliases() {
    let filtered = CursorBridge.filterCatalog([
      FetchedModel(id: "default"),
      FetchedModel(id: "auto-smart"),
      FetchedModel(id: "composer-2.5"),
      FetchedModel(id: "auto")
    ])
    XCTAssertEqual(filtered.map(\.id), ["composer-2.5"])
  }

  func testImportIDPrefixesCursorAndSanitizes() {
    XCTAssertEqual(CursorBridge.importID(for: "composer-2.5"), "cursor-composer-2.5")
    XCTAssertEqual(CursorBridge.importID(for: "grok-4.5-fast"), "cursor-grok-4.5-fast")
    XCTAssertEqual(CursorBridge.importID(for: "cursor-foo"), "cursor-foo")
  }

  func testDisplayNameMatchesClinePrefixStyle() {
    XCTAssertEqual(CursorBridge.displayName(for: "composer-2.5"), "Cursor Composer 2.5")
    XCTAssertEqual(CursorBridge.displayName(for: "grok-4.5-fast"), "Cursor Grok 4.5 Fast")
    XCTAssertEqual(CursorBridge.displayName(for: "Cursor Composer 2.5"), "Cursor Composer 2.5")
  }

  func testNodeRequirementParseAndMinimum() {
    XCTAssertEqual(CursorBridge.NodeRequirement.parseVersion("v22.13.0")?.major, 22)
    XCTAssertEqual(CursorBridge.NodeRequirement.parseVersion("v22.13.0")?.minor, 13)
    XCTAssertTrue(CursorBridge.NodeRequirement.meetsMinimum(versionString: "v22.13.0"))
    XCTAssertTrue(CursorBridge.NodeRequirement.meetsMinimum(versionString: "v23.0.0"))
    XCTAssertFalse(CursorBridge.NodeRequirement.meetsMinimum(versionString: "v20.11.0"))
    XCTAssertFalse(CursorBridge.NodeRequirement.meetsMinimum(versionString: "v22.12.0"))
    XCTAssertEqual(CursorBridge.NodeRequirement.homepageURL.absoluteString, "https://nodejs.org/")
    XCTAssertEqual(CursorBridge.NodeRequirement.brewInstallCommand, "brew install node")
    XCTAssertEqual(CursorBridge.NodeRequirement.minimumDisplay, "22.13")
    XCTAssertTrue(CursorBridge.NodeRequirement.installGuidance.contains("22.13"))
    XCTAssertTrue(CursorBridge.NodeRequirement.missingMessage.contains("Not found"))
    let missing = CursorBridge.NodeRequirement.detail(found: false, versionDisplay: "", meetsMinimum: false)
    XCTAssertTrue(missing.contains("Not found"))
    XCTAssertTrue(missing.contains("brew install node"))
    let ok = CursorBridge.NodeRequirement.snapshot(binaryPath: "/opt/homebrew/bin/node", versionDisplay: "v22.14.0")
    XCTAssertTrue(ok.meetsMinimum)
    XCTAssertTrue(ok.isFound)
    let old = CursorBridge.NodeRequirement.snapshot(binaryPath: "/usr/bin/node", versionDisplay: "v18.20.0")
    XCTAssertFalse(old.meetsMinimum)
    XCTAssertTrue(old.isFound)
  }

  func testBrewInstallTerminalScriptOpensTerminal() {
    let script = CursorBridge.NodeRequirement.brewInstallTerminalScript()
    XCTAssertTrue(script.contains("tell application \"Terminal\" to do script \"brew install node\""))
    XCTAssertTrue(script.contains("tell application \"Terminal\" to activate"))
    let quoted = CursorBridge.NodeRequirement.brewInstallTerminalScript(command: #"echo "hi""#)
    XCTAssertTrue(quoted.contains(#"echo \"hi\""#))
  }

  func testNodeTLSPathResolutionWithCodexGatewayOverride() {
    let override = "/custom/corp.pem"
    let wellKnown = "/Users/demo/IT-Certs/package-route.pem"
    XCTAssertEqual(
      CursorBridge.NodeTLS.resolvedExtraCACertsPath(
        environment: [CursorBridge.NodeTLS.overrideKey: override],
        home: "/Users/demo",
        fileExists: { $0 == override || $0 == wellKnown }
      ),
      override
    )
    XCTAssertEqual(
      CursorBridge.NodeTLS.resolvedExtraCACertsPath(
        environment: [:],
        home: "/Users/demo",
        fileExists: { $0 == wellKnown }
      ),
      wellKnown
    )
    XCTAssertEqual(CursorBridge.NodeTLS.overrideKey, "CODEXGATEWAY_NODE_EXTRA_CA_CERTS")
  }

  func testValidationResultExitCodes() {
    XCTAssertEqual(CursorBridge.validationResult(exitCode: 0, stderr: "").isValid, true)
    XCTAssertEqual(CursorBridge.validationResult(exitCode: 2, stderr: ""), CursorBridge.APIKeyValidation.missing)
    let rejected = CursorBridge.validationResult(exitCode: 1, stderr: "unauthorized\n")
    XCTAssertFalse(rejected.isValid)
    XCTAssertTrue(rejected.message.contains("unauthorized"))
  }

  func testRuntimeLocatorRequiresScript() {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("codexgateway-bridge-locator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    XCTAssertFalse(CursorBridgeRuntime.Locator.hasBridgeScript(at: temp))
    try? "print(1)".write(to: temp.appendingPathComponent("cursor-openai-bridge.mjs"), atomically: true, encoding: .utf8)
    XCTAssertTrue(CursorBridgeRuntime.Locator.hasBridgeScript(at: temp))
    XCTAssertFalse(CursorBridgeRuntime.Locator.hasNodeModules(at: temp))
  }

  func testShouldTreatAsRunningAndReattach() {
    XCTAssertTrue(CursorBridgeRuntime.shouldTreatAsRunning(status: .stopped, endpointOnline: true, hasAPIKey: true))
    XCTAssertTrue(CursorBridgeRuntime.shouldTreatAsRunning(status: .running, endpointOnline: false, hasAPIKey: true))
    XCTAssertFalse(CursorBridgeRuntime.shouldTreatAsRunning(status: .stopped, endpointOnline: true, hasAPIKey: false))
    XCTAssertTrue(CursorBridgeRuntime.mayReattachToLiveEndpoint(hasAPIKey: true, endpointOnline: true))
    XCTAssertFalse(CursorBridgeRuntime.mayReattachToLiveEndpoint(hasAPIKey: false, endpointOnline: true))
  }

  func testManagedEnabledSettingsKey() {
    XCTAssertEqual(CursorBridgeSettingsKeys.managedEnabled, "CodexGateway.cursorBridge.managedEnabled")
    let previous = CursorBridgeRuntime.isEnabled
    defer { CursorBridgeRuntime.isEnabled = previous }
    CursorBridgeRuntime.isEnabled = true
    XCTAssertTrue(UserDefaults.standard.bool(forKey: CursorBridgeSettingsKeys.managedEnabled))
    CursorBridgeRuntime.isEnabled = false
    XCTAssertFalse(UserDefaults.standard.bool(forKey: CursorBridgeSettingsKeys.managedEnabled))
  }

  func testCursorPresetFields() {
    let preset = ProviderPreset.cursor
    XCTAssertTrue(preset.isManagedCursorBridge)
    XCTAssertEqual(preset.providerID, "cursor")
    XCTAssertEqual(preset.displayName, "Cursor")
    XCTAssertEqual(preset.baseURL, "http://127.0.0.1:18788/v1")
    XCTAssertEqual(preset.defaultAPIKey, "local")
    XCTAssertTrue(preset.requiresAPIKeyPrompt)
    XCTAssertEqual(preset.authKind, .cursorBridge)
    XCTAssertTrue(preset.supportsModelListingFetch)
    XCTAssertFalse(preset.seedsSuggestedModelOnInstall)
    XCTAssertEqual(preset.suggestedModel, "composer-2.5")

    let config = preset.providerConfig(apiKey: "user-pasted-key-should-be-ignored")
    XCTAssertEqual(config.api_key, "local")
    XCTAssertEqual(config.auth_kind, ProviderAuthKind.cursorBridge.rawValue)
    XCTAssertTrue(config.usesCursorBridge)
    XCTAssertFalse(config.usesGrokOAuth)
  }

  func testCursorBridgeSecretFileURLIsUnderApplicationSupport() {
    let url = CursorBridgeKeychain.secretFileURL
    XCTAssertTrue(url.path.contains("Application Support/CodexGateway/Secrets"))
    XCTAssertEqual(url.lastPathComponent, "cursor-api-key")
    XCTAssertEqual(CursorBridgeKeychain.service, "com.rimusz.codexgateway.cursor-bridge")
  }

  func testBridgeModelsURLPreservesV1() {
    XCTAssertEqual(
      CursorBridge.modelsURL(for: "http://127.0.0.1:18788/v1")?.absoluteString,
      "http://127.0.0.1:18788/v1/models"
    )
  }
}
