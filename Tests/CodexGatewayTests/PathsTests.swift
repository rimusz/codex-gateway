import XCTest
@testable import CodexGateway

final class PathsTests: XCTestCase {
  private var tempRoot: URL!

  override func setUpWithError() throws {
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexGatewayPathsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempRoot)
    tempRoot = nil
  }

  func testConfigPathsUseCodexgatewayDirectory() {
    XCTAssertTrue(Paths.configDir.hasSuffix("/.codexgateway"))
    XCTAssertTrue(Paths.legacyConfigDir.hasSuffix("/.codexbar"))
    XCTAssertTrue(Paths.modelCatalog.hasSuffix("/.codexgateway/custom_model_catalog.json"))
    XCTAssertTrue(Paths.providersConfig.hasSuffix("/.codexgateway/providers.json"))
    XCTAssertTrue(Paths.fetchedModelsCache.hasSuffix("/.codexgateway/fetched_models.json"))
    XCTAssertTrue(Paths.toolCallExtraContentCache.hasSuffix("/.codexgateway/tool_call_extra_content.json"))
  }

  func testCodexPathsPointAtCodexHome() {
    XCTAssertEqual(Paths.codexHome, "\(Paths.home)/.codex")
    XCTAssertTrue(Paths.codexConfig.hasSuffix("/.codex/config.toml"))
    XCTAssertTrue(Paths.codexAuth.hasSuffix("/.codex/auth.json"))
  }

  func testMigrateRenamesLegacyDirWhenCurrentMissing() throws {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let providers = legacy.appendingPathComponent("providers.json")
    try Data(#"{"providers":[]}"#.utf8).write(to: providers)

    XCTAssertTrue(Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("providers.json").path))
  }

  func testMigrateCopiesMissingFilesThenRemovesLegacy() throws {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

    try Data(#"{"providers":[{"name":"xai"}]}"#.utf8)
      .write(to: legacy.appendingPathComponent("providers.json"))
    try Data(#"{"models":[]}"#.utf8)
      .write(to: current.appendingPathComponent("custom_model_catalog.json"))

    XCTAssertTrue(Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    ))

    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    let providers = try String(contentsOf: current.appendingPathComponent("providers.json"), encoding: .utf8)
    XCTAssertTrue(providers.contains("xai"))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: current.appendingPathComponent("custom_model_catalog.json").path
    ))
  }

  func testMigrateDoesNotOverwriteExistingCurrentFiles() throws {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

    try Data("legacy".utf8).write(to: legacy.appendingPathComponent("providers.json"))
    try Data("current".utf8).write(to: current.appendingPathComponent("providers.json"))

    _ = Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    )

    let contents = try String(contentsOf: current.appendingPathComponent("providers.json"), encoding: .utf8)
    XCTAssertEqual(contents, "current")
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
  }

  func testMigrateReplacesEmptyCurrentFileFromLegacy() throws {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

    try Data(#"{"models":["a"]}"#.utf8).write(to: legacy.appendingPathComponent("fetched_models.json"))
    try Data().write(to: current.appendingPathComponent("fetched_models.json"))

    XCTAssertTrue(Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    ))

    let contents = try String(
      contentsOf: current.appendingPathComponent("fetched_models.json"),
      encoding: .utf8
    )
    XCTAssertTrue(contents.contains("models"))
  }

  func testMigrateNoopsWhenLegacyMissing() {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    XCTAssertFalse(Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    ))
  }

  /// When rename fails and no files can be copied, keep the legacy dir (avoid data loss).
  func testMigrateKeepsLegacyWhenCurrentPathBlockedAndNothingCopied() throws {
    let legacy = tempRoot.appendingPathComponent(".codexbar")
    let current = tempRoot.appendingPathComponent(".codexgateway")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data(#"{"providers":[{"name":"xai"}]}"#.utf8)
      .write(to: legacy.appendingPathComponent("providers.json"))
    // A file at the destination path blocks both rename and createDirectory.
    try Data("blocker".utf8).write(to: current)

    XCTAssertFalse(Paths.migrateLegacyConfigDirectory(
      legacyDir: legacy.path,
      currentDir: current.path
    ))

    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    let providers = try String(
      contentsOf: legacy.appendingPathComponent("providers.json"),
      encoding: .utf8
    )
    XCTAssertTrue(providers.contains("xai"))
  }
}
