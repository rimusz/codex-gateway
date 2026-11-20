import XCTest
@testable import CodexGateway

@MainActor
final class UpdateSettingsStoreTests: CodexGatewayTestCase {
    private let autoCheckKey = UpdateSettingsKeys.autoCheckEnabled
    private let dismissedKey = UpdateSettingsKeys.dismissedVersion

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: autoCheckKey)
        UserDefaults.standard.removeObject(forKey: dismissedKey)
        super.tearDown()
    }

    func testShouldNotifyWhenUpdateAvailableAndNotDismissed() {
        let release = UpdateChecker.AppRelease(
            installedVersion: "0.1.0",
            latestVersion: "0.2.0",
            tagName: "v0.2.0",
            releaseURL: URL(string: "https://example.com")!,
            downloadURL: nil,
            publishedAt: nil,
            updateAvailable: true
        )

        XCTAssertTrue(UpdateSettingsStore.shouldNotify(for: release))

        UpdateSettingsStore.skipVersion("0.2.0")
        XCTAssertFalse(UpdateSettingsStore.shouldNotify(for: release))
    }
}
