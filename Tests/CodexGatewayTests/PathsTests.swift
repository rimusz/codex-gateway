import XCTest
@testable import CodexGateway

final class PathsTests: CodexGatewayTestCase {
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

  /// A nil override is the real home. The suite override is what writers use,
  /// and those writes leave the real home unchanged.
  func testOverrideRedirectsPathsAndLeavesRealHomeUntouched() throws {
    let fm = FileManager.default
    let realHome = fm.homeDirectoryForCurrentUser.path
    let suiteRoot = try XCTUnwrap(Paths.rootDirectoryOverride)

    XCTAssertEqual(Paths.homePath(rootedAt: nil), realHome)
    XCTAssertEqual(Paths.homePath(rootedAt: ""), realHome)
    XCTAssertEqual(Paths.homePath(rootedAt: " \n"), realHome)
    XCTAssertEqual(Paths.home, suiteRoot)
    XCTAssertNotEqual(suiteRoot, realHome)
    XCTAssertEqual(Paths.configDir, "\(suiteRoot)/.codexgateway")
    XCTAssertEqual(Paths.legacyConfigDir, "\(suiteRoot)/.codexbar")
    XCTAssertEqual(Paths.codexHome, "\(suiteRoot)/.codex")
    XCTAssertEqual(Paths.codexModelCatalogDir, "\(suiteRoot)/.codex/model-catalogs")
    XCTAssertEqual(Paths.codexModelCatalog, "\(suiteRoot)/.codex/model-catalogs/custom-providers.json")
    XCTAssertEqual(Paths.codexConfig, "\(suiteRoot)/.codex/config.toml")
    XCTAssertEqual(Paths.codexAuth, "\(suiteRoot)/.codex/auth.json")
    XCTAssertEqual(Paths.modelCatalog, "\(suiteRoot)/.codexgateway/custom_model_catalog.json")
    XCTAssertEqual(Paths.providersConfig, "\(suiteRoot)/.codexgateway/providers.json")
    XCTAssertEqual(Paths.fetchedModelsCache, "\(suiteRoot)/.codexgateway/fetched_models.json")
    XCTAssertEqual(Paths.toolCallExtraContentCache, "\(suiteRoot)/.codexgateway/tool_call_extra_content.json")
    guard Paths.home == suiteRoot, Paths.home != realHome else {
      XCTFail("suite override is not active")
      return
    }

    let realPaths = [
      "\(realHome)/.codexgateway",
      "\(realHome)/.codexgateway/fetched_models.json",
      "\(realHome)/.codexgateway/providers.json",
      "\(realHome)/.codexgateway/custom_model_catalog.json",
      "\(realHome)/.codexgateway/tool_call_extra_content.json",
      "\(realHome)/.codexbar",
      "\(realHome)/.codex",
      "\(realHome)/.codex/config.toml",
      "\(realHome)/.codex/auth.json",
      "\(realHome)/.codex/model-catalogs",
      "\(realHome)/.codex/model-catalogs/custom-providers.json",
    ]
    let before = realPaths.map { stamp($0) }

    let providersURL = URL(fileURLWithPath: Paths.providersConfig)
    let catalogURL = URL(fileURLWithPath: Paths.modelCatalog)
    let exportURL = URL(fileURLWithPath: Paths.codexModelCatalog)
    let extraURL = URL(fileURLWithPath: Paths.toolCallExtraContentCache)
    let providersBefore = try? Data(contentsOf: providersURL)
    let catalogBefore = try? Data(contentsOf: catalogURL)
    let exportBefore = try? Data(contentsOf: exportURL)
    let extraBefore = try? Data(contentsOf: extraURL)
    defer {
      restore(providersURL, providersBefore)
      restore(catalogURL, catalogBefore)
      restore(exportURL, exportBefore)
      restore(extraURL, extraBefore)
    }

    let settings = SettingsStore()
    settings.reload()
    settings.saveFetchedModels([FetchedModel(id: "iso")], for: "paths-isolation")
    XCTAssertNil(settings.errorMessage)
    XCTAssertEqual(settings.fetchedModels["paths-isolation"]?.map(\.id), ["iso"])
    XCTAssertTrue(fm.fileExists(atPath: Paths.fetchedModelsCache))
    try FetchedModelsStore.shared.delete(providerID: "paths-isolation")

    try ModelCatalog.shared.saveProviders(ProvidersFile(providers: [
      ProviderConfig(name: "paths-isolation", base_url: "http://127.0.0.1:9/v1", api_key: "test")
    ]))
    XCTAssertTrue(fm.fileExists(atPath: Paths.providersConfig))
    try ModelCatalog.shared.saveCatalog(ModelCatalogFile(models: []))
    XCTAssertTrue(fm.fileExists(atPath: Paths.modelCatalog))
    XCTAssertTrue(fm.fileExists(atPath: Paths.codexModelCatalog))

    let extra = ToolCallExtraContentStore(filePath: Paths.toolCallExtraContentCache)
    extra.remember(
      providerID: "gemini",
      callID: "paths-isolation",
      extraContent: ["google": ["thought_signature": "iso"]]
    )
    XCTAssertTrue(fm.fileExists(atPath: Paths.toolCallExtraContentCache))
    XCTAssertTrue(fm.fileExists(atPath: Paths.configDir))
    XCTAssertTrue(fm.fileExists(atPath: Paths.codexModelCatalogDir))

    let after = realPaths.map { stamp($0) }
    for index in realPaths.indices {
      XCTAssertEqual(after[index], before[index], realPaths[index])
    }
  }

  private struct PathStamp: Equatable {
    var exists: Bool
    var modified: Date?
    var size: Int?
  }

  private func stamp(_ path: String) -> PathStamp {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else {
      return PathStamp(exists: false, modified: nil, size: nil)
    }
    let attrs = try? fm.attributesOfItem(atPath: path)
    return PathStamp(
      exists: true,
      modified: attrs?[.modificationDate] as? Date,
      size: (attrs?[.size] as? NSNumber)?.intValue
    )
  }

  private func restore(_ url: URL, _ data: Data?) {
    if let data {
      try? data.write(to: url)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
