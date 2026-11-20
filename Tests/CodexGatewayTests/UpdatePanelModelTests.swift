import XCTest
@testable import CodexGateway

final class UpdatePanelModelTests: CodexGatewayTestCase {
  private func release(
    installed: String,
    latest: String,
    updateAvailable: Bool,
    downloadURL: URL? = URL(string: "https://example.com/CodexGateway-v1.0.0.app.zip")
  ) -> UpdateChecker.AppRelease {
    UpdateChecker.AppRelease(
      installedVersion: installed,
      latestVersion: latest,
      tagName: "v\(latest)",
      releaseURL: URL(string: "https://example.com/releases")!,
      downloadURL: downloadURL,
      publishedAt: nil,
      updateAvailable: updateAvailable
    )
  }

  func testShowsUpdateAppWhenInstallableUpdateAvailable() {
    let decision = UpdatePanelModel.decision(
      for: release(installed: "0.1.3", latest: "0.1.4", updateAvailable: true),
      shouldNotify: true
    )
    XCTAssertEqual(decision.statusLine, "Update Available")
    XCTAssertTrue(decision.showsInstallAction)
    XCTAssertTrue(decision.canInstallInApp)
    XCTAssertEqual(decision.primaryButtonTitleWhenIdle, "Update App")
    XCTAssertTrue(decision.showSkipButton)
  }

  func testStillShowsUpdateAppAfterSkipSoManualCheckCanInstall() {
    let decision = UpdatePanelModel.decision(
      for: release(installed: "0.1.3", latest: "0.1.4", updateAvailable: true),
      shouldNotify: false
    )
    XCTAssertEqual(decision.statusLine, "Update Available")
    XCTAssertTrue(decision.showsInstallAction)
    XCTAssertEqual(decision.primaryButtonTitleWhenIdle, "Update App")
    XCTAssertFalse(decision.showSkipButton)
  }

  func testOpenReleasePageWhenNoZipAsset() {
    let decision = UpdatePanelModel.decision(
      for: release(installed: "0.1.3", latest: "0.1.4", updateAvailable: true, downloadURL: nil),
      shouldNotify: true
    )
    XCTAssertEqual(decision.primaryButtonTitleWhenIdle, "Open Release Page")
    XCTAssertFalse(decision.canInstallInApp)
  }

  func testUpToDateHasNoPrimaryButton() {
    let decision = UpdatePanelModel.decision(
      for: release(installed: "0.1.4", latest: "0.1.4", updateAvailable: false),
      shouldNotify: false
    )
    XCTAssertEqual(decision.statusLine, "Everything Is Up to Date")
    XCTAssertFalse(decision.showsInstallAction)
    XCTAssertNil(decision.primaryButtonTitleWhenIdle)
  }
}
