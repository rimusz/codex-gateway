import XCTest
import AppKit
import SwiftUI
@testable import CodexGateway

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testGatewayConfigNotesDescribePickerSwap() {
        XCTAssertTrue(GatewayConfigCopy.updateNote.contains("Native Codex models are removed"))
        XCTAssertTrue(GatewayConfigCopy.updateNote.contains("restarts the Codex app and CLI daemon"))
        XCTAssertTrue(GatewayConfigCopy.resetNote.contains("native Codex models return"))
        XCTAssertTrue(GatewayConfigCopy.resetNote.contains("Custom models leave the picker"))
        XCTAssertTrue(GatewayConfigCopy.resetNote.contains("restarts the Codex app and CLI daemon"))
    }

    func testMakeWindowKeepsWindowAliveAfterClose() {
        let delegate = TestWindowDelegate()
        let hosting = NSHostingController(rootView: EmptyView())

        let window = SettingsWindowController.makeWindow(contentViewController: hosting, delegate: delegate)

        XCTAssertEqual(window.title, "CodexGateway Settings")
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

    func testDoctorWindowKeepsWindowAliveAfterClose() {
        let delegate = TestWindowDelegate()
        let hosting = NSHostingController(rootView: EmptyView())

        let window = DoctorWindowController.makeWindow(contentViewController: hosting, delegate: delegate)

        XCTAssertEqual(window.title, "CodexGateway Doctor")
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

    func testAboutWindowMatchesUpdatePanelChrome() {
        let delegate = TestWindowDelegate()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))

        let window = AboutWindowController.makeWindow(contentView: content, delegate: delegate)

        XCTAssertEqual(window.title, "")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.delegate === delegate)
        XCTAssertTrue(window.contentView === content)
    }

    func testAboutContentLinksToCanonicalRepository() {
        XCTAssertEqual(AboutContent.repositoryURL.absoluteString, "https://github.com/rimusz/codex-gateway")
        XCTAssertEqual(AboutContent.repositoryLabel, "github.com/rimusz/codex-gateway")
        XCTAssertEqual(AboutContent.copyright, "© 2026 CodexGateway")
        XCTAssertTrue(AboutContent.summary.contains("Codex Desktop"))
        XCTAssertTrue(AboutContent.summary.contains("Codex CLI"))
        XCTAssertTrue(AboutContent.versionLine.contains(AppVersion.display))
    }

    func testSettingsDisclosureDefaults() {
        XCTAssertFalse(SettingsDisclosureDefaults.addProviderExpanded)
        XCTAssertFalse(SettingsDisclosureDefaults.presetsExpanded)
        XCTAssertTrue(SettingsDisclosureDefaults.providersExpanded)
        XCTAssertTrue(SettingsDisclosureDefaults.modelsExpanded)
    }

    func testProvidersAndModelsExpansionIsRemembered() {
        let suite = "SettingsSectionExpansionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(
            SettingsSectionExpansion.storedExpanded(
                forKey: SettingsSectionExpansion.providersKey,
                defaultValue: true,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            SettingsSectionExpansion.storedExpanded(
                forKey: SettingsSectionExpansion.modelsKey,
                defaultValue: true,
                defaults: defaults
            )
        )

        SettingsSectionExpansion.storeExpanded(false, forKey: SettingsSectionExpansion.providersKey, defaults: defaults)
        SettingsSectionExpansion.storeExpanded(true, forKey: SettingsSectionExpansion.modelsKey, defaults: defaults)

        XCTAssertFalse(
            SettingsSectionExpansion.storedExpanded(
                forKey: SettingsSectionExpansion.providersKey,
                defaultValue: true,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            SettingsSectionExpansion.storedExpanded(
                forKey: SettingsSectionExpansion.modelsKey,
                defaultValue: false,
                defaults: defaults
            )
        )
    }
}

private final class TestWindowDelegate: NSObject, NSWindowDelegate {}
