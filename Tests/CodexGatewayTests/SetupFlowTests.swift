import XCTest
@testable import CodexGateway

final class SetupFlowTests: XCTestCase {
    func testChooseAdvancesToConnect() {
        var flow = SetupFlow()
        XCTAssertEqual(flow.step, .choose)
        XCTAssertFalse(flow.canGoBack)
        XCTAssertFalse(flow.canFinish)

        flow.select(.preset(.ollama))

        XCTAssertEqual(flow.step, .connect)
        XCTAssertEqual(flow.selection, .preset(.ollama))
        XCTAssertTrue(flow.canGoBack)
        XCTAssertFalse(flow.canFinish)
    }

    func testBackFromConnectReturnsToChoose() {
        var flow = SetupFlow()
        flow.select(.custom)
        flow.goBack()
        XCTAssertEqual(flow.step, .choose)
        XCTAssertEqual(flow.selection, .custom)
    }

    func testConnectSucceededStartsModelFetch() {
        var flow = SetupFlow()
        flow.select(.preset(.deepseek))
        flow.connectSucceeded()

        XCTAssertEqual(flow.step, .models)
        XCTAssertTrue(flow.isFetching)
        XCTAssertFalse(flow.canFinish)
    }

    func testSuggestedModelIsPrecheckedWhenPresent() {
        var flow = SetupFlow()
        flow.select(.preset(.ollama))
        flow.connectSucceeded()
        flow.applyFetchedChoices(
            [
                SetupModelChoice(slug: "ollama/other", upstream: "other", displayName: "Other"),
                SetupModelChoice(slug: "ollama/llama3-2", upstream: "llama3.2", displayName: "Llama"),
            ],
            suggestedUpstream: "llama3.2"
        )

        XCTAssertFalse(flow.isFetching)
        XCTAssertEqual(flow.selectedSlugs, ["ollama/llama3-2"])
        XCTAssertTrue(flow.canFinish)
    }

    func testSingleFetchedModelIsPrechecked() {
        var flow = SetupFlow()
        flow.connectSucceeded()
        flow.applyFetchedChoices(
            [SetupModelChoice(slug: "only/one", upstream: "one", displayName: "One")],
            suggestedUpstream: nil
        )
        XCTAssertEqual(flow.selectedSlugs, ["only/one"])
    }

    func testEmptyFetchedListEnablesManualModelEntry() {
        var flow = SetupFlow()
        flow.connectSucceeded()
        flow.applyFetchedChoices([], suggestedUpstream: nil)

        XCTAssertFalse(flow.isFetching)
        XCTAssertTrue(flow.allowsManualModel)
        flow.manualSlug = "manual-model"
        XCTAssertTrue(flow.canFinish)
    }

    func testFinishRequiresASelectedOrManualModel() {
        var flow = SetupFlow()
        flow.connectSucceeded()
        flow.applyFetchedChoices(
            [
                SetupModelChoice(slug: "a/one", upstream: "one", displayName: "One"),
                SetupModelChoice(slug: "a/two", upstream: "two", displayName: "Two"),
            ],
            suggestedUpstream: nil
        )
        XCTAssertFalse(flow.canFinish)

        flow.toggle(slug: "a/two")
        XCTAssertTrue(flow.canFinish)

        flow.selectNone()
        XCTAssertFalse(flow.canFinish)

        flow.selectAll()
        XCTAssertEqual(flow.selectedSlugs, ["a/one", "a/two"])
        XCTAssertTrue(flow.canFinish)
    }

    func testManualModelAllowsFinishWithoutCheckboxes() {
        var flow = SetupFlow()
        flow.connectSucceeded(allowsManualModel: true)
        XCTAssertFalse(flow.isFetching)
        XCTAssertFalse(flow.canFinish)

        flow.manualSlug = "  deepseek-v4-flash  "
        XCTAssertTrue(flow.canFinish)
    }

    func testFetchFailedStaysOnModelsWithRetryState() {
        var flow = SetupFlow()
        flow.connectSucceeded()
        flow.fetchFailed("The provider returned HTTP 401.", allowManual: true)

        XCTAssertEqual(flow.step, .models)
        XCTAssertFalse(flow.isFetching)
        XCTAssertEqual(flow.errorMessage, "The provider returned HTTP 401.")
        XCTAssertTrue(flow.allowsManualModel)
    }

    func testBackFromModelsReturnsToConnectAndClearsFetch() {
        var flow = SetupFlow()
        flow.select(.preset(.ollama))
        flow.connectSucceeded()
        flow.applyFetchedChoices(
            [SetupModelChoice(slug: "ollama/llama3-2", upstream: "llama3.2", displayName: "Llama")],
            suggestedUpstream: "llama3.2"
        )
        flow.goBack()

        XCTAssertEqual(flow.step, .connect)
        XCTAssertFalse(flow.isFetching)
        XCTAssertNil(flow.errorMessage)
    }

    func testStaleFetchGenerationIsIgnoredAfterBackOrReselect() {
        var flow = SetupFlow()
        flow.select(.preset(.ollama))
        flow.connectSucceeded()
        let first = flow.fetchStarted()
        XCTAssertTrue(flow.isCurrentFetch(first))

        flow.goBack()
        XCTAssertFalse(flow.isCurrentFetch(first))
        XCTAssertFalse(flow.isFetching)

        flow.select(.preset(.deepseek))
        flow.connectSucceeded()
        let second = flow.fetchStarted()
        XCTAssertTrue(flow.isCurrentFetch(second))
        XCTAssertFalse(flow.isCurrentFetch(first))
    }

    func testModelsToInstallUsesSelectionAndDropsUnchecked() {
        let provider = ProviderConfig(name: "grok-oauth", base_url: "https://example.com/v1", api_key: "")
        let seed = CatalogModel(
            slug: "grok-oauth/grok-4.5",
            model: "grok-4.5",
            provider: "grok-oauth",
            backend_provider: "grok-oauth",
            display_name: "Grok 4.5",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        let other = CatalogModel(
            slug: "grok-oauth/grok-4",
            model: "grok-4",
            provider: "grok-oauth",
            backend_provider: "grok-oauth",
            display_name: "Grok 4",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )

        let installed = SetupModelSelection.modelsToInstall(
            provider: provider,
            available: [seed, other],
            selectedSlugs: ["grok-oauth/grok-4"],
            allowsManualModel: false,
            manualSlug: "",
            manualDisplayName: ""
        )
        XCTAssertEqual(installed.map(\.slug), ["grok-oauth/grok-4"])

        let replaced = SetupModelSelection.replacingModels(
            [seed, CatalogModel(
                slug: "ollama/llama3.2",
                model: "llama3.2",
                provider: "ollama",
                backend_provider: "ollama",
                display_name: "Llama",
                visibility: "list",
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            )],
            forProvider: "grok-oauth",
            with: installed
        )
        XCTAssertEqual(replaced.map(\.slug), ["ollama/llama3.2", "grok-oauth/grok-4"])
    }

    func testConnectIsDisabledUntilRequiredFieldsAreFilled() {
        XCTAssertFalse(
            SetupConnectValidation.isReady(
                selection: .preset(.deepseek),
                apiKey: "  ",
                customName: "",
                customBaseURL: "",
                cursorNodeMeetsMinimum: true
            )
        )
        XCTAssertTrue(
            SetupConnectValidation.isReady(
                selection: .preset(.deepseek),
                apiKey: "sk-test",
                customName: "",
                customBaseURL: "",
                cursorNodeMeetsMinimum: true
            )
        )
        XCTAssertTrue(
            SetupConnectValidation.isReady(
                selection: .preset(.ollama),
                apiKey: "",
                customName: "",
                customBaseURL: "",
                cursorNodeMeetsMinimum: false
            )
        )
        XCTAssertFalse(
            SetupConnectValidation.isReady(
                selection: .preset(.cursor),
                apiKey: "key_test",
                customName: "",
                customBaseURL: "",
                cursorNodeMeetsMinimum: false
            )
        )
        XCTAssertFalse(
            SetupConnectValidation.isReady(
                selection: .custom,
                apiKey: "",
                customName: "spark",
                customBaseURL: "  ",
                cursorNodeMeetsMinimum: true
            )
        )
        XCTAssertTrue(
            SetupConnectValidation.isReady(
                selection: .custom,
                apiKey: "",
                customName: "spark",
                customBaseURL: "http://spark:8001/v1",
                cursorNodeMeetsMinimum: true
            )
        )
    }

    func testUnfinishedProviderIsDiscardedWhenItHasNoModels() {
        XCTAssertTrue(SetupSessionCleanup.shouldDiscardInstalledProvider(modelCount: 0))
        XCTAssertFalse(SetupSessionCleanup.shouldDiscardInstalledProvider(modelCount: 1))
        XCTAssertEqual(
            SetupSessionCleanup.action(hadExistingProvider: true, modelCount: 0),
            .restoreExisting
        )
        XCTAssertEqual(
            SetupSessionCleanup.action(hadExistingProvider: false, modelCount: 0),
            .deleteSessionProvider
        )
    }

    func testFinishTransactionRollsBackWhenApplyFails() {
        enum TestError: Error { case applyFailed }
        var value = "before"

        XCTAssertThrowsError(
            try SetupFinishTransaction.run(
                snapshot: { value },
                persist: { value = "persisted" },
                apply: { throw TestError.applyFailed },
                rollback: { value = $0 }
            )
        )
        XCTAssertEqual(value, "before")
    }

    func testManualModelInstallWhenFetchListIsEmpty() {
        let provider = ProviderConfig(name: "custom", base_url: "https://example.com/v1", api_key: "k")
        let installed = SetupModelSelection.modelsToInstall(
            provider: provider,
            available: [],
            selectedSlugs: [],
            allowsManualModel: true,
            manualSlug: "  my-model  ",
            manualDisplayName: "My Model"
        )
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed[0].slug, "custom/my-model")
        XCTAssertEqual(installed[0].model, "my-model")
        XCTAssertEqual(installed[0].display_name, "My Model")
    }
}
