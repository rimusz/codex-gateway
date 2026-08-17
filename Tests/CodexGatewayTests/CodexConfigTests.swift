import XCTest
@testable import CodexGateway

final class CodexConfigTests: XCTestCase {
    func testStripManagedBlocksRemovesManagedSections() {
        let input = """
        [cli]
        foo = true

        # >>> codexgateway managed >>>
        model_catalog_json = "/tmp/catalog.json"
        # <<< codexgateway managed <<<

        [ui]
        bar = false
        """

        let stripped = CodexConfig.stripManagedBlocks(input)

        XCTAssertTrue(stripped.contains("[cli]"))
        XCTAssertTrue(stripped.contains("foo = true"))
        XCTAssertTrue(stripped.contains("[ui]"))
        XCTAssertTrue(stripped.contains("bar = false"))
        XCTAssertFalse(stripped.contains("codexgateway managed"))
        XCTAssertFalse(stripped.contains("model_catalog_json"))
    }

    func testStripManagedBlocksRemovesLegacyAndCurrentMarkers() {
        let input = """
        # >>> codexbar managed >>>
        [model_providers.codexbar]
        name = "CodexBar"
        # <<< codexbar managed <<<

        # >>> codexgateway managed >>>
        [model_providers.codexgateway]
        name = "CodexGateway"
        # <<< codexgateway managed <<<
        """

        let stripped = CodexConfig.stripManagedBlocks(input)
        XCTAssertTrue(stripped.isEmpty)
        XCTAssertFalse(stripped.contains("codexbar"))
        XCTAssertFalse(stripped.contains("codexgateway managed"))
    }

    func testContainsManagedBlockDetectsCurrentAndLegacyMarkers() {
        XCTAssertTrue(CodexConfig.containsManagedBlock("# >>> codexgateway managed >>>\nfoo\n# <<< codexgateway managed <<<"))
        XCTAssertTrue(CodexConfig.containsManagedBlock("# >>> codexbar managed >>>\nfoo\n# <<< codexbar managed <<<"))
        XCTAssertFalse(CodexConfig.containsManagedBlock("[cli]\nfoo = true"))
    }

    func testManagedTopBlockSelectsCodexgatewayProvider() {
        let top = CodexConfig.managedTopBlock()
        XCTAssertTrue(top.contains("model_provider = \"codexgateway\""))
        XCTAssertTrue(top.contains("# >>> codexgateway managed >>>"))
        XCTAssertTrue(top.contains("model_catalog_json = "))
        XCTAssertTrue(top.contains("openai_base_url = "))
    }

    func testManagedProviderBlockReflectsAuthRequirement() {
        let signedOut = CodexConfig.managedProviderBlock(requiresOpenAIAuth: false)
        XCTAssertTrue(signedOut.contains("requires_openai_auth = false"))
        XCTAssertTrue(signedOut.contains("[model_providers.codexgateway]"))
        XCTAssertTrue(signedOut.contains("name = \"CodexGateway\""))
        XCTAssertTrue(signedOut.contains("wire_api = \"responses\""))

        let signedIn = CodexConfig.managedProviderBlock(requiresOpenAIAuth: true)
        XCTAssertTrue(signedIn.contains("requires_openai_auth = true"))
    }

    func testSignedInDetectionFromAuthData() {
        XCTAssertFalse(CodexConfig.signedIn(fromAuthData: nil))
        XCTAssertFalse(CodexConfig.signedIn(fromAuthData: Data("not json".utf8)))

        let emptyToken = #"{ "tokens": { "access_token": "" } }"#
        XCTAssertFalse(CodexConfig.signedIn(fromAuthData: Data(emptyToken.utf8)))

        let chatgpt = #"{ "tokens": { "access_token": "abc123" } }"#
        XCTAssertTrue(CodexConfig.signedIn(fromAuthData: Data(chatgpt.utf8)))

        let apiKey = #"{ "OPENAI_API_KEY": "sk-test" }"#
        XCTAssertTrue(CodexConfig.signedIn(fromAuthData: Data(apiKey.utf8)))
    }

    func testEnsureConfigFileCreatesMissingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexgateway-ensure-\(UUID().uuidString)")
        let path = root.appendingPathComponent("config.toml").path
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try CodexConfig.ensureConfigFile(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        try "keep".write(toFile: path, atomically: true, encoding: .utf8)
        try CodexConfig.ensureConfigFile(at: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep")
    }

    func testThrowingPatchReportsMissingFileAndWritesManagedBlock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexgateway-patch-\(UUID().uuidString)")
        let path = root.appendingPathComponent("config.toml").path
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try CodexConfig.patchCodexConfigThrowing(at: path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[ui]\nnotifications = true\n".write(toFile: path, atomically: true, encoding: .utf8)
        try CodexConfig.patchCodexConfigThrowing(at: path)

        let patched = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(patched.contains(AppIdentity.managedStart))
        XCTAssertTrue(patched.contains("[ui]"))
        XCTAssertTrue(patched.contains("notifications = true"))
    }
}
