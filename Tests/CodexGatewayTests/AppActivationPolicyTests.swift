import XCTest
@testable import CodexGateway

final class AppActivationPolicyTests: XCTestCase {
  func testShouldRestoreAccessoryWhenNoOtherVisibleWindows() {
    XCTAssertTrue(AppActivationPolicy.shouldRestoreAccessory(hasOtherVisibleWindow: false))
  }

  func testShouldKeepRegularWhenAnotherWindowIsVisible() {
    XCTAssertFalse(AppActivationPolicy.shouldRestoreAccessory(hasOtherVisibleWindow: true))
  }

  func testStatusItemWindowIsNotUserFacing() {
    XCTAssertFalse(
      AppActivationPolicy.isUserFacingWindow(
        title: "Item-0",
        className: "NSStatusBarWindow",
        styleIncludesTitled: false
      )
    )
  }

  func testAboutAndSettingsWindowsAreUserFacing() {
    XCTAssertTrue(
      AppActivationPolicy.isUserFacingWindow(
        title: "About CodexGateway",
        className: "NSWindow",
        styleIncludesTitled: true
      )
    )
    XCTAssertTrue(
      AppActivationPolicy.isUserFacingWindow(
        title: "CodexGateway Settings",
        className: "NSWindow",
        styleIncludesTitled: true
      )
    )
  }

  func testTitledUpdatePanelIsUserFacing() {
    XCTAssertTrue(
      AppActivationPolicy.isUserFacingWindow(
        title: "",
        className: "NSPanel",
        styleIncludesTitled: true
      )
    )
  }
}
