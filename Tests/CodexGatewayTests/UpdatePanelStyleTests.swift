import AppKit
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

  func testDockIconCornersAreTransparent() throws {
    let icon = try XCTUnwrap(UpdatePanelStyle.icon(side: 64))
    let rep = try XCTUnwrap(NSBitmapImageRep(data: icon.tiffRepresentation!))
    let corner = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
    let center = try XCTUnwrap(rep.colorAt(x: 32, y: 32))
    XCTAssertLessThan(corner.alphaComponent, 0.05)
    XCTAssertGreaterThan(center.alphaComponent, 0.9)
  }
}
