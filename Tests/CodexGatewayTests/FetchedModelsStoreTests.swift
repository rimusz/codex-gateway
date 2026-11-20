import XCTest
@testable import CodexGateway

final class FetchedModelsStoreTests: CodexGatewayTestCase {
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetched-models-\(UUID().uuidString).json")
            .path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    func testSaveLoadAndReplaceProviderModels() throws {
        let store = FetchedModelsStore(filePath: tempPath)
        let first = [FetchedModel(id: "model-a", ownedBy: "vendor")]
        let second = [FetchedModel(id: "model-b"), FetchedModel(id: "model-c")]

        try store.save(providerID: "minimax", models: first)
        XCTAssertEqual(store.load()["minimax"]?.map(\.id), ["model-a"])

        try store.save(providerID: "minimax", models: second)
        XCTAssertEqual(store.load()["minimax"]?.map(\.id), ["model-b", "model-c"])
    }

    func testDeleteProviderRemovesCachedModels() throws {
        let store = FetchedModelsStore(filePath: tempPath)
        try store.save(providerID: "minimax", models: [FetchedModel(id: "m1")])
        try store.save(providerID: "ollama", models: [FetchedModel(id: "m2")])

        try store.delete(providerID: "minimax")

        let loaded = store.load()
        XCTAssertNil(loaded["minimax"])
        XCTAssertEqual(loaded["ollama"]?.map(\.id), ["m2"])
    }

    func testResetClearsAllProviders() throws {
        let store = FetchedModelsStore(filePath: tempPath)
        try store.save(providerID: "minimax", models: [FetchedModel(id: "m1")])

        try store.reset()

        XCTAssertTrue(store.load().isEmpty)
    }
}
