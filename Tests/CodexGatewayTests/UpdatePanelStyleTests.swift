import XCTest
@testable import CodexGateway

final class UpdatePanelStyleTests: XCTestCase {
  func testDockCornerRadiusMatchesMacOSIconRatio() {
    XCTAssertEqual(UpdatePanelStyle.dockCornerRadius(for: 64), 64 * 0.2237, accuracy: 0.0001)
    XCTAssertEqual(UpdatePanelStyle.dockCornerRadius(for: 128), 128 * 0.2237, accuracy: 0.0001)
  }

  func testIconReturnsDockSizedImage() throws {
    let icon = try XCTUnwrap(UpdatePanelStyle.icon())
    XCTAssertEqual(icon.size.width, UpdatePanelStyle.iconDisplaySize)
    XCTAssertEqual(icon.size.height, UpdatePanelStyle.iconDisplaySize)
  }
}
