import XCTest
@testable import CodexGateway

final class DoctorReportTests: XCTestCase {
  private func healthyInputs() -> DoctorInputs {
    DoctorInputs(
      gatewayReachable: true,
      gatewayPort: 8765,
      configApplied: true,
      configInSync: true,
      configHasConflicts: false,
      signedIn: true,
      hasCustomModels: true,
      nodeFound: true,
      nodeVersionDisplay: "v22.14.0",
      nodeMeetsMinimum: true,
      cursorProviderInstalled: false,
      cursorKeyPresent: false,
      cursorBridgeReachable: false,
      grokOAuthInstalled: false,
      grokOAuthConfigured: false
    )
  }

  private func check(_ inputs: DoctorInputs, id: String) -> DoctorCheck {
    let match = DoctorReport.checks(from: inputs).first { $0.id == id }
    XCTAssertNotNil(match, "missing check \(id)")
    return match ?? DoctorCheck(id: id, title: "", detail: "", status: .info)
  }

  func testHealthyGatewayConfigAndOptionalProviders() {
    let inputs = healthyInputs()
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertNil(DoctorReport.primaryRemediation(inputs))
    XCTAssertEqual(check(inputs, id: "gateway").status, .ok)
    XCTAssertEqual(check(inputs, id: "config").status, .ok)
    XCTAssertEqual(check(inputs, id: "signin").status, .ok)
    XCTAssertEqual(check(inputs, id: "cursor").status, .info)
    XCTAssertEqual(check(inputs, id: "grok-oauth").status, .info)
    XCTAssertEqual(DoctorReport.checks(from: inputs).map(\.id), [
      "gateway", "config", "signin", "node", "cursor", "grok-oauth",
    ])
  }

  func testGatewayDownIsErrorAndBlocksHealthy() {
    var inputs = healthyInputs()
    inputs.gatewayReachable = false
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "gateway").status, .error)
    let remediation = DoctorReport.primaryRemediation(inputs)
    XCTAssertTrue(remediation?.contains("8765") == true)
  }

  func testMissingConfigIsError() {
    var inputs = healthyInputs()
    inputs.configApplied = false
    inputs.configInSync = false
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "config").status, .error)
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("Update Gateway Config") == true)
  }

  func testOutOfDateConfigIsWarning() {
    var inputs = healthyInputs()
    inputs.configInSync = false
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "config").status, .warning)
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("out of date") == true)
  }

  func testConflictingConfigIsErrorWithRepairRemediation() {
    var inputs = healthyInputs()
    inputs.configHasConflicts = true

    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "config").status, .error)
    XCTAssertTrue(check(inputs, id: "config").detail.contains("invalid"))
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("Repair") == true)
  }

  func testSignedOutWithCustomModelsIsWarningNotUnhealthy() {
    var inputs = healthyInputs()
    inputs.signedIn = false
    inputs.hasCustomModels = true
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "signin").status, .warning)
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("Sign in to Codex Desktop") == true)
  }

  func testSignedOutWithoutCustomModelsIsInfo() {
    var inputs = healthyInputs()
    inputs.signedIn = false
    inputs.hasCustomModels = false
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "signin").status, .info)
    XCTAssertNil(DoctorReport.primaryRemediation(inputs))
  }

  func testMissingNodeIsWarningUnlessCursorInstalled() {
    var inputs = healthyInputs()
    inputs.nodeFound = false
    inputs.nodeMeetsMinimum = false
    inputs.nodeVersionDisplay = ""
    XCTAssertEqual(check(inputs, id: "node").status, .warning)
    XCTAssertTrue(DoctorReport.isHealthy(inputs))

    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = true
    XCTAssertEqual(check(inputs, id: "node").status, .error)
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(
      DoctorReport.primaryRemediation(inputs),
      CursorBridge.NodeRequirement.installGuidance
    )
  }

  func testOldNodeIsErrorWhenCursorInstalled() {
    var inputs = healthyInputs()
    inputs.nodeFound = true
    inputs.nodeMeetsMinimum = false
    inputs.nodeVersionDisplay = "v18.20.0"
    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = true
    XCTAssertEqual(check(inputs, id: "node").status, .error)
    XCTAssertTrue(check(inputs, id: "node").detail.contains("v18.20.0"))
  }

  func testCursorMissingKeyIsError() {
    var inputs = healthyInputs()
    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = false
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "cursor").status, .error)
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("Cursor API key") == true)
  }

  func testCursorKeyWithoutSidecarIsWarningStillHealthy() {
    var inputs = healthyInputs()
    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = true
    inputs.cursorBridgeReachable = false
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "cursor").status, .warning)
    XCTAssertTrue(check(inputs, id: "cursor").detail.contains("not running yet"))
  }

  func testCursorSidecarReachableIsOk() {
    var inputs = healthyInputs()
    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = true
    inputs.cursorBridgeReachable = true
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "cursor").status, .ok)
    XCTAssertTrue(check(inputs, id: "cursor").detail.contains("18788"))
  }

  func testGrokOAuthNotConfiguredIsWarningAndUnhealthy() {
    var inputs = healthyInputs()
    inputs.grokOAuthInstalled = true
    inputs.grokOAuthConfigured = false
    XCTAssertFalse(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "grok-oauth").status, .warning)
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("grok login") == true)
  }

  func testGrokOAuthConfiguredIsOk() {
    var inputs = healthyInputs()
    inputs.grokOAuthInstalled = true
    inputs.grokOAuthConfigured = true
    XCTAssertTrue(DoctorReport.isHealthy(inputs))
    XCTAssertEqual(check(inputs, id: "grok-oauth").status, .ok)
  }

  func testPrimaryRemediationPrefersGatewayOverLaterIssues() {
    var inputs = healthyInputs()
    inputs.gatewayReachable = false
    inputs.configApplied = false
    inputs.cursorProviderInstalled = true
    inputs.cursorKeyPresent = false
    inputs.grokOAuthInstalled = true
    inputs.grokOAuthConfigured = false
    XCTAssertTrue(DoctorReport.primaryRemediation(inputs)?.contains("Gateway") == true)
  }

  func testShouldBeginRunSkipsOverlappingCollect() {
    XCTAssertTrue(DoctorReport.shouldBeginRun(isRunning: false))
    XCTAssertFalse(DoctorReport.shouldBeginRun(isRunning: true))
  }

  @MainActor
  func testConfigRepairAppliesInOrderAndRestartsOnlyAfterSuccess() throws {
    var calls: [String] = []
    try DoctorConfigRepair.run(
      ensureConfig: { calls.append("ensure") },
      syncCatalog: { calls.append("sync") },
      patchConfig: { calls.append("patch") },
      restartCodex: { calls.append("restart") }
    )
    XCTAssertEqual(calls, ["ensure", "sync", "patch", "restart"])

    calls = []
    XCTAssertThrowsError(
      try DoctorConfigRepair.run(
        ensureConfig: { calls.append("ensure") },
        syncCatalog: { calls.append("sync") },
        patchConfig: {
          calls.append("patch")
          throw CocoaError(.fileWriteUnknown)
        },
        restartCodex: { calls.append("restart") }
      )
    )
    XCTAssertEqual(calls, ["ensure", "sync", "patch"])
  }

  func testStatusSymbols() {
    XCTAssertEqual(DoctorCheck.Status.ok.symbolName, "checkmark.circle.fill")
    XCTAssertEqual(DoctorCheck.Status.warning.symbolName, "exclamationmark.triangle.fill")
    XCTAssertEqual(DoctorCheck.Status.error.symbolName, "xmark.octagon.fill")
    XCTAssertEqual(DoctorCheck.Status.info.symbolName, "info.circle.fill")
  }
}
