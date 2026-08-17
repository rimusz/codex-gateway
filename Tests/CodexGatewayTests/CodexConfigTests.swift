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

    func testStripConflictingGatewayEntriesRemovesUnmanagedRoutingAndProviderTables() {
        let input = """
        model = "gpt-5.5"
        model_provider = "codexgateway"
        model_catalog_json = "/tmp/custom-providers.json"
        openai_base_url = "http://127.0.0.1:8765/v1"
        notify = ["done"]

        [desktop]
        followUpQueueMode = "queue"

        [model_providers.codexgateway]
        name = "CodexGateway"
        base_url = "http://127.0.0.1:8765/v1"

        [plugins.browser]
        enabled = true

        [model_providers.codexbar]
        name = "CodexBar"

        [projects.example]
        trust_level = "trusted"
        """

        let stripped = CodexConfig.stripConflictingGatewayEntries(input)

        XCTAssertTrue(stripped.contains("model = \"gpt-5.5\""))
        XCTAssertTrue(stripped.contains("notify = [\"done\"]"))
        XCTAssertTrue(stripped.contains("[desktop]"))
        XCTAssertTrue(stripped.contains("[plugins.browser]"))
        XCTAssertTrue(stripped.contains("enabled = true"))
        XCTAssertTrue(stripped.contains("[projects.example]"))
        XCTAssertFalse(stripped.contains("model_provider ="))
        XCTAssertFalse(stripped.contains("model_catalog_json ="))
        XCTAssertFalse(stripped.contains("openai_base_url ="))
        XCTAssertFalse(stripped.contains("[model_providers.codexgateway]"))
        XCTAssertFalse(stripped.contains("[model_providers.codexbar]"))
        XCTAssertFalse(stripped.contains("name = \"CodexGateway\""))
        XCTAssertFalse(stripped.contains("name = \"CodexBar\""))
    }

    func testDetectsGatewayEntriesOutsideManagedMarkers() {
        let valid = """
        # >>> codexgateway managed >>>
        model_provider = "codexgateway"
        # <<< codexgateway managed <<<

        model = "gpt-5.5"

        # >>> codexgateway managed >>>
        [model_providers.codexgateway]
        name = "CodexGateway"
        # <<< codexgateway managed <<<
        """
        XCTAssertFalse(CodexConfig.hasConflictingGatewayEntries(valid))

        let conflicting = valid + """

        model_provider = "codexgateway"

        [model_providers.codexgateway]
        name = "CodexGateway"
        """
        XCTAssertTrue(CodexConfig.hasConflictingGatewayEntries(conflicting))
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

    func testThrowingPatchReplacesUnmanagedGatewayEntriesWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexgateway-repatch-\(UUID().uuidString)")
        let path = root.appendingPathComponent("config.toml").path
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = """
        model = "gpt-5.5"
        model_provider = "codexgateway"
        model_catalog_json = "/tmp/old.json"
        openai_base_url = "http://127.0.0.1:8765/v1"

        [desktop]
        followUpQueueMode = "queue"

        [model_providers.codexgateway]
        name = "CodexGateway"
        base_url = "http://127.0.0.1:8765/v1"
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try stale.write(toFile: path, atomically: true, encoding: .utf8)

        try CodexConfig.patchCodexConfigThrowing(at: path)

        let patched = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(patched.components(separatedBy: "model_provider =").count - 1, 1)
        XCTAssertEqual(patched.components(separatedBy: "model_catalog_json =").count - 1, 1)
        XCTAssertEqual(patched.components(separatedBy: "openai_base_url =").count - 1, 1)
        XCTAssertEqual(patched.components(separatedBy: "[model_providers.codexgateway]").count - 1, 1)
        XCTAssertTrue(patched.contains("model = \"gpt-5.5\""))
        XCTAssertTrue(patched.contains("[desktop]"))
    }
}
