import XCTest
@testable import CodexGateway

final class SetupPresentationTests: XCTestCase {
    private func provider(
        name: String,
        baseURL: String = "https://example.com/v1",
        apiKey: String = "key",
        displayName: String? = nil
    ) -> ProviderConfig {
        ProviderConfig(
            name: name,
            display_name: displayName,
            base_url: baseURL,
            api_key: apiKey
        )
    }

    func testShouldShowWhenCatalogEmpty() {
        XCTAssertTrue(
            SetupPresentation.shouldShow(
                providers: [],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false
            )
        )
    }

    func testShouldHideWhenSkippedThisLaunch() {
        XCTAssertFalse(
            SetupPresentation.shouldShow(
                providers: [],
                models: [],
                skippedThisLaunch: true,
                isMigrating: false
            )
        )
    }

    func testShouldHideWhileMigratingLegacyBundle() {
        XCTAssertFalse(
            SetupPresentation.shouldShow(
                providers: [],
                models: [],
                skippedThisLaunch: false,
                isMigrating: true
            )
        )
    }

    func testShouldHideWhenAnInstalledProviderExists() {
        XCTAssertFalse(
            SetupPresentation.shouldShow(
                providers: [provider(name: "ollama", apiKey: "ollama")],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false
            )
        )
    }

    func testShouldHideWhenModelsExist() {
        let model = CatalogModel(
            slug: "ollama/llama3.2",
            model: "llama3.2",
            provider: "ollama",
            backend_provider: "ollama",
            display_name: "Ollama Llama 3.2",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        XCTAssertFalse(
            SetupPresentation.shouldShow(
                providers: [],
                models: [model],
                skippedThisLaunch: false,
                isMigrating: false
            )
        )
    }

    func testEmptyNameAndDefaultSeedDoNotCountAsInstalled() {
        let empty = provider(name: "", baseURL: "", apiKey: "")
        let seed = provider(
            name: SetupPresentation.defaultSeedProviderID,
            baseURL: SetupPresentation.defaultSeedBaseURL,
            apiKey: ""
        )
        XCTAssertTrue(SetupPresentation.isPlaceholderProvider(empty))
        XCTAssertTrue(SetupPresentation.isPlaceholderProvider(seed))
        XCTAssertTrue(
            SetupPresentation.shouldShow(
                providers: [empty, seed],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false
            )
        )
    }

    func testCustomizedOpencodeProviderCountsAsInstalled() {
        let custom = provider(
            name: SetupPresentation.defaultSeedProviderID,
            baseURL: SetupPresentation.defaultSeedBaseURL,
            apiKey: "real-key"
        )
        XCTAssertFalse(SetupPresentation.isPlaceholderProvider(custom))
        XCTAssertFalse(
            SetupPresentation.shouldShow(
                providers: [custom],
                models: [],
                skippedThisLaunch: false,
                isMigrating: false
            )
        )
    }

    func testForceShowOnlyWithSetupArgument() {
        XCTAssertFalse(SetupPresentation.shouldForceShow(arguments: ["/app/CodexGateway"]))
        XCTAssertTrue(
            SetupPresentation.shouldForceShow(arguments: ["/app/CodexGateway", "--setup"])
        )
    }
}
