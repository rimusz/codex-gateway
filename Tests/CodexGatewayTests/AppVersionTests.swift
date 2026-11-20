import XCTest
import AppKit
@testable import CodexGateway

final class AppVersionTests: CodexGatewayTestCase {
    func testShortVersionIsNonEmpty() {
        XCTAssertFalse(AppVersion.short.isEmpty)
    }

    func testDisplayMatchesShort() {
        XCTAssertEqual(AppVersion.display, AppVersion.short)
    }

    func testShortVersionLooksLikeSemver() {
        let version = AppVersion.short
        let parts = version.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "expected semver-like version, got \(version)")
        for part in parts.prefix(3) {
            XCTAssertNotNil(Int(part), "expected numeric semver component in \(version)")
        }
    }

    /// Packaged apps must report Info.plist, not a nearby checkout's VERSION file.
    /// When Bundle.main has CFBundleShortVersionString, AppVersion must match it.
    func testShortPrefersBundleShortVersionWhenPresent() {
        guard let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return
        }
        let trimmed = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        XCTAssertEqual(AppVersion.short, trimmed)
    }

    func testAppIconLoadsFromProjectResources() {
        let image = AppIconProvider.image()
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size, NSSize(width: 128, height: 128))
    }
}
