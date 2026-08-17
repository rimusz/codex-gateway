import XCTest
import AppKit
import SwiftUI
@testable import CodexGateway

@MainActor
final class SetupWindowControllerTests: XCTestCase {
    func testSetupWindowKeepsWindowAliveAfterClose() {
        let delegate = SetupWindowTestDelegate()
        let hosting = NSHostingController(rootView: EmptyView())

        let window = SetupWindowController.makeWindow(contentViewController: hosting, delegate: delegate)

        XCTAssertEqual(window.title, SetupCopy.windowTitle)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.delegate === delegate)
        XCTAssertTrue(window.contentViewController === hosting)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true)
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isHidden ?? true)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)
    }

    func testSetupShouldPresentHonorsForceArgumentAndEmptyCatalog() {
        let existing = ProviderConfig(
            name: "ollama",
            base_url: "http://localhost:11434/v1",
            api_key: "ollama"
        )
        #if DEBUG
        XCTAssertTrue(
            SetupWindowController.shouldPresent(
                providers: [existing],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false,
                arguments: ["/app", "--setup"]
            )
        )
        #else
        XCTAssertFalse(
            SetupWindowController.shouldPresent(
                providers: [existing],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false,
                arguments: ["/app", "--setup"]
            )
        )
        #endif
        XCTAssertFalse(
            SetupWindowController.shouldPresent(
                providers: [],
                models: [],
                skippedThisLaunch: true,
                isMigrating: false,
                arguments: ["/app"]
            )
        )
    }

    func testSetupShouldPresentIsFalseWhileMigratingEvenWithSetupFlag() {
        XCTAssertFalse(
            SetupWindowController.shouldPresent(
                providers: [],
                models: [],
                skippedThisLaunch: false,
                isMigrating: true,
                arguments: ["/app", "--setup"]
            )
        )
    }
}

private final class SetupWindowTestDelegate: NSObject, NSWindowDelegate {}
