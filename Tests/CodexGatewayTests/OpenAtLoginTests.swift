import XCTest
import ServiceManagement
@testable import CodexGateway

final class OpenAtLoginTests: CodexGatewayTestCase {
  func testMenuCopy() {
    XCTAssertEqual(OpenAtLoginMenuCopy.title, "Open at Login")
    XCTAssertTrue(OpenAtLoginMenuCopy.approvalMessage.contains("Login Items"))
    XCTAssertEqual(OpenAtLoginMenuCopy.openSettingsButton, "Open System Settings")
  }

  func testMapsSMAppServiceStatuses() {
    XCTAssertEqual(OpenAtLogin.map(.enabled), .enabled)
    XCTAssertEqual(OpenAtLogin.map(.notRegistered), .disabled)
    XCTAssertEqual(OpenAtLogin.map(.requiresApproval), .requiresApproval)
    XCTAssertEqual(OpenAtLogin.map(.notFound), .notFound)
  }

  func testToggleEnablesWhenCurrentlyDisabled() {
    var requested: Bool?
    var statuses: [OpenAtLogin.Status] = []
    var approvalCount = 0
    var failures = 0

    OpenAtLoginToggle.apply(
      currentlyEnabled: false,
      setEnabled: { enable in
        requested = enable
        return .enabled
      },
      onStatus: { statuses.append($0) },
      onRequiresApproval: { approvalCount += 1 },
      onFailure: { _ in failures += 1 }
    )

    XCTAssertEqual(requested, true)
    XCTAssertEqual(statuses, [.enabled])
    XCTAssertEqual(approvalCount, 0)
    XCTAssertEqual(failures, 0)
  }

  func testToggleDisablesWhenCurrentlyEnabled() {
    var requested: Bool?
    var statuses: [OpenAtLogin.Status] = []

    OpenAtLoginToggle.apply(
      currentlyEnabled: true,
      setEnabled: { enable in
        requested = enable
        return .disabled
      },
      onStatus: { statuses.append($0) },
      onRequiresApproval: {},
      onFailure: { _ in XCTFail("unexpected failure") }
    )

    XCTAssertEqual(requested, false)
    XCTAssertEqual(statuses, [.disabled])
  }

  func testTogglePresentsApprovalWhenRegistrationNeedsIt() {
    var approvalCount = 0

    OpenAtLoginToggle.apply(
      currentlyEnabled: false,
      setEnabled: { _ in .requiresApproval },
      onStatus: { XCTAssertEqual($0, .requiresApproval) },
      onRequiresApproval: { approvalCount += 1 },
      onFailure: { _ in XCTFail("unexpected failure") }
    )

    XCTAssertEqual(approvalCount, 1)
  }

  func testToggleDoesNotPresentApprovalWhenDisabling() {
    var approvalCount = 0

    OpenAtLoginToggle.apply(
      currentlyEnabled: true,
      setEnabled: { _ in .requiresApproval },
      onStatus: { _ in },
      onRequiresApproval: { approvalCount += 1 },
      onFailure: { _ in XCTFail("unexpected failure") }
    )

    XCTAssertEqual(approvalCount, 0)
  }

  func testToggleReportsFailures() {
    struct Boom: LocalizedError {
      var errorDescription: String? { "boom" }
    }

    var failureMessage: String?
    var statusUpdates = 0

    OpenAtLoginToggle.apply(
      currentlyEnabled: false,
      setEnabled: { _ in throw Boom() },
      onStatus: { _ in statusUpdates += 1 },
      onRequiresApproval: { XCTFail("unexpected approval") },
      onFailure: { failureMessage = $0.localizedDescription }
    )

    XCTAssertEqual(failureMessage, "boom")
    XCTAssertEqual(statusUpdates, 0)
    XCTAssertEqual(OpenAtLoginMenuCopy.failureMessage(Boom()), "boom")
  }
}
