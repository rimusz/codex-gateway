import XCTest
@testable import CodexGateway

final class UpdateCheckerTests: CodexGatewayTestCase {
    func testNormalizedVersionStripsLeadingV() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("v0.1.3"), "0.1.3")
        XCTAssertEqual(UpdateChecker.normalizedVersion("V1.2.0"), "1.2.0")
    }

    func testCompareVersionsOrdersSemverComponents() {
        XCTAssertEqual(UpdateChecker.compareVersions("0.1.3", "0.1.2"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("0.1.2", "0.1.3"), .orderedAscending)
        XCTAssertEqual(UpdateChecker.compareVersions("0.1.3", "0.1.3"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("v0.2.0", "0.1.10"), .orderedDescending)
    }

    func testCompareVersionsIgnoresNonNumericSuffixes() {
        XCTAssertEqual(UpdateChecker.compareVersions("0.2.60-beta", "0.2.60"), .orderedSame)
    }

    func testPreferredAppZipAssetNameUsesTag() {
        XCTAssertEqual(
            UpdateChecker.preferredAppZipAssetName(tagName: "v0.2.0"),
            "CodexGateway-v0.2.0.app.zip"
        )
    }

    func testSelectDownloadAssetPrefersExactMatch() {
        let assets = [
            UpdateChecker.GitHubReleaseAsset(
                name: "CodexGateway-v0.2.0-macOS.dmg",
                browserDownloadURL: URL(string: "https://example.com/a.dmg")!
            ),
            UpdateChecker.GitHubReleaseAsset(
                name: "CodexGateway-v0.2.0.app.zip",
                browserDownloadURL: URL(string: "https://example.com/a.zip")!
            ),
        ]

        let selected = UpdateChecker.selectDownloadAsset(from: assets, tagName: "v0.2.0")
        XCTAssertEqual(selected?.absoluteString, "https://example.com/a.zip")
    }

    func testSelectDownloadAssetFallsBackToLegacyCodexBarZip() {
        let assets = [
            UpdateChecker.GitHubReleaseAsset(
                name: "CodexBar-v0.2.0-macOS.dmg",
                browserDownloadURL: URL(string: "https://example.com/legacy.dmg")!
            ),
            UpdateChecker.GitHubReleaseAsset(
                name: "CodexBar-v0.2.0.app.zip",
                browserDownloadURL: URL(string: "https://example.com/legacy.zip")!
            ),
        ]

        let selected = UpdateChecker.selectDownloadAsset(from: assets, tagName: "v0.2.0")
        XCTAssertEqual(selected?.absoluteString, "https://example.com/legacy.zip")
    }

    func testIsNotarizedReleaseDetectsReleaseTitle() {
        XCTAssertTrue(UpdateChecker.isNotarizedRelease(
            name: "v0.1.10 (Notarized)",
            body: nil
        ))
        XCTAssertFalse(UpdateChecker.isNotarizedRelease(
            name: "v0.1.11 (Unsigned)",
            body: nil
        ))
    }

    func testLatestNotarizedReleaseSkipsUnsignedLatest() {
        let unsigned = UpdateChecker.GitHubReleaseSummary(
            tagName: "v0.1.11",
            name: "v0.1.11 (Unsigned)",
            body: "Unsigned build",
            htmlURL: URL(string: "https://example.com/unsigned")!,
            publishedAt: Date(),
            draft: false,
            assets: []
        )
        let notarized = UpdateChecker.GitHubReleaseSummary(
            tagName: "v0.1.10",
            name: "v0.1.10 (Notarized)",
            body: "This version is properly code-signed and notarized.",
            htmlURL: URL(string: "https://example.com/notarized")!,
            publishedAt: Date().addingTimeInterval(-86_400),
            draft: false,
            assets: []
        )

        XCTAssertEqual(
            UpdateChecker.latestNotarizedRelease(from: [unsigned, notarized])?.tagName,
            "v0.1.10"
        )
    }

    func testPreferredNotarizedReleasePicksNewestAcrossRepos() {
        let older = UpdateChecker.GitHubReleaseSummary(
            tagName: "v0.1.6",
            name: "v0.1.6 (Notarized)",
            body: nil,
            htmlURL: URL(string: "https://github.com/rimusz/codex-bar/releases/tag/v0.1.6")!,
            publishedAt: Date().addingTimeInterval(-86_400),
            draft: false,
            assets: []
        )
        let newer = UpdateChecker.GitHubReleaseSummary(
            tagName: "v0.1.8",
            name: "v0.1.8 (Notarized)",
            body: nil,
            htmlURL: URL(string: "https://github.com/rimusz/codex-gateway/releases/tag/v0.1.8")!,
            publishedAt: Date(),
            draft: false,
            assets: []
        )
        let unsigned = UpdateChecker.GitHubReleaseSummary(
            tagName: "v0.1.9",
            name: "v0.1.9 (Unsigned)",
            body: nil,
            htmlURL: URL(string: "https://example.com/unsigned")!,
            publishedAt: Date(),
            draft: false,
            assets: []
        )

        XCTAssertEqual(
            UpdateChecker.preferredNotarizedRelease(from: [older, unsigned, newer])?.tagName,
            "v0.1.8"
        )
        XCTAssertEqual(UpdateChecker.releasesRepo, "rimusz/codex-gateway")
        XCTAssertEqual(UpdateChecker.legacyReleasesRepo, "rimusz/codex-bar")
        XCTAssertEqual(UpdateChecker.releasesRepos, ["rimusz/codex-gateway", "rimusz/codex-bar"])
    }
}
