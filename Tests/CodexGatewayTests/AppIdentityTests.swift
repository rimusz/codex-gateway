import XCTest
@testable import CodexGateway

final class AppIdentityTests: XCTestCase {
  func testProductNamesAndBundleId() {
    XCTAssertEqual(AppIdentity.productName, "CodexGateway")
    XCTAssertEqual(AppIdentity.legacyProductName, "CodexBar")
    XCTAssertEqual(AppIdentity.bundleIdentifier, "com.rimusz.CodexGateway")
    XCTAssertEqual(AppIdentity.legacyBundleIdentifier, "com.rimusz.CodexBar")
    XCTAssertEqual(AppIdentity.codexProviderID, "codexgateway")
    XCTAssertEqual(AppIdentity.legacyCodexProviderID, "codexbar")
    XCTAssertEqual(AppIdentity.appBundleName, "CodexGateway.app")
    XCTAssertEqual(AppIdentity.legacyAppBundleName, "CodexBar.app")
  }

  func testAppZipAssetNamesPreferNewThenLegacy() {
    XCTAssertEqual(
      AppIdentity.appZipAssetNames(tagName: "v0.2.0"),
      ["CodexGateway-v0.2.0.app.zip", "CodexBar-v0.2.0.app.zip"]
    )
  }

  func testInstallTargetMigratesLegacyBundlePath() {
    let legacy = URL(fileURLWithPath: "/Applications/CodexBar.app")
    let target = AppIdentity.installTargetURL(from: legacy)
    XCTAssertEqual(target.path, "/Applications/CodexGateway.app")
    XCTAssertEqual(
      AppIdentity.legacyBundleToRemove(currentBundleURL: legacy, targetURL: target)?.path,
      "/Applications/CodexBar.app"
    )
  }

  func testInstallTargetUnchangedForNewBundlePath() {
    let current = URL(fileURLWithPath: "/Applications/CodexGateway.app")
    let target = AppIdentity.installTargetURL(from: current)
    XCTAssertEqual(target.path, current.path)
    XCTAssertNil(AppIdentity.legacyBundleToRemove(currentBundleURL: current, targetURL: target))
  }

  func testShouldMigrateLegacyBundleOnlyWhenFolderIsCodexBarAndNameIsCodexGateway() {
    let legacy = URL(fileURLWithPath: "/Applications/CodexBar.app")
    let modern = URL(fileURLWithPath: "/Applications/CodexGateway.app")
    XCTAssertTrue(AppBundleMigration.shouldMigrateLegacyBundle(
      bundleURL: legacy,
      bundleName: "CodexGateway"
    ))
    XCTAssertFalse(AppBundleMigration.shouldMigrateLegacyBundle(
      bundleURL: legacy,
      bundleName: "CodexBar"
    ))
    XCTAssertFalse(AppBundleMigration.shouldMigrateLegacyBundle(
      bundleURL: modern,
      bundleName: "CodexGateway"
    ))
    XCTAssertEqual(
      AppBundleMigration.isLegacyBundleMigrationPending,
      AppBundleMigration.shouldMigrateLegacyBundle(
        bundleURL: Bundle.main.bundleURL,
        bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      )
    )
  }

  func testShellEscapeQuotesPathsForBash() {
    XCTAssertEqual(AppBundleMigration.shellEscape("/Applications/CodexBar.app"), "'/Applications/CodexBar.app'")
    XCTAssertEqual(AppBundleMigration.shellEscape("foo'bar"), "'foo'\\''bar'")
  }

  func testInstallHelperURLFindsExtensionlessResourceInBundle() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexGatewayHelperLookup-\(UUID().uuidString).app", isDirectory: true)
    let contents = root.appendingPathComponent("Contents", isDirectory: true)
    let resources = contents.appendingPathComponent("Resources", isDirectory: true)
    let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>com.rimusz.CodexGateway.test</string>
      <key>CFBundleName</key><string>CodexGateway</string>
      <key>CFBundleExecutable</key><string>CodexGateway</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """
    try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    try Data().write(to: macos.appendingPathComponent("CodexGateway"))
    let helper = resources.appendingPathComponent("codexgateway-install-update")
    try "#!/bin/bash\necho ok\n".write(to: helper, atomically: true, encoding: .utf8)

    guard let bundle = Bundle(url: root) else {
      XCTFail("Failed to load test bundle at \(root.path)")
      return
    }
    let found = AppUpdater.installHelperURL(bundle: bundle)
    XCTAssertEqual(found?.path, helper.path)
  }
}
