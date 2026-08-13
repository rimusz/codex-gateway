import XCTest
@testable import CodexGateway

final class ProviderModelFetcherTests: XCTestCase {
    func testModelsURLPreservesVersionPath() {
        XCTAssertEqual(
            ProviderModelFetcher.modelsURL(for: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")?.absoluteString,
            "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models"
        )
        XCTAssertEqual(
            ProviderModelFetcher.modelsURL(for: "https://api.deepseek.com/")?.absoluteString,
            "https://api.deepseek.com/models"
        )
    }

    func testParseOpenAIStyleModelsResponse() throws {
        let data = """
        {
          "object": "list",
          "data": [
            { "id": "z-model", "owned_by": "provider" },
            { "id": "a-model" },
            { "id": "z-model" }
          ]
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parse(data))
        XCTAssertEqual(models.map(\.id), ["a-model", "z-model"])
        XCTAssertEqual(models.last?.ownedBy, "provider")
    }

    func testParseBareArrayAndModelFallback() throws {
        let data = """
        [
          { "model": "mimo-v2.5-pro" },
          { "id": "mimo-v2.5" }
        ]
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parse(data))
        XCTAssertEqual(models.map(\.id), ["mimo-v2.5", "mimo-v2.5-pro"])
    }

    func testParseCursorItemsResponseFlattensToTopLevelIDs() throws {
        let data = """
        {
          "items": [
            {
              "id": "default",
              "displayName": "Auto",
              "aliases": ["auto"],
              "variants": [{ "params": [], "displayName": "Auto", "isDefault": true }]
            },
            {
              "id": "gpt-5.5",
              "displayName": "GPT-5.5",
              "parameters": [
                { "id": "reasoning", "values": [{ "value": "low" }, { "value": "high" }] }
              ],
              "variants": [
                { "params": [{ "id": "reasoning", "value": "low" }], "displayName": "GPT-5.5" },
                { "params": [{ "id": "reasoning", "value": "high" }], "displayName": "GPT-5.5", "isDefault": true }
              ]
            },
            {
              "id": "claude-opus-4-8",
              "displayName": "Opus 4.8",
              "variants": [
                { "params": [{ "id": "effort", "value": "low" }], "displayName": "Opus 4.8" },
                { "params": [{ "id": "effort", "value": "high" }], "displayName": "Opus 4.8" }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parse(data))
        // Only top-level IDs, deduped and sorted; variants collapsed; "default" (Auto) dropped.
        XCTAssertEqual(models.map(\.id), ["claude-opus-4-8", "gpt-5.5"])
    }

    func testParseSkipsAutoAndAutoSmartRoutingAliases() throws {
        let data = """
        {
          "object": "list",
          "data": [
            { "id": "default" },
            { "id": "auto" },
            { "id": "auto-smart" },
            { "id": "composer-2.5" }
          ]
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parse(data))
        XCTAssertEqual(models.map(\.id), ["composer-2.5"])
    }

    func testParseClinePassRecommendedSortsAlphabeticallyAndSkipsNonPass() throws {
        let data = """
        {
          "recommended": [],
          "clinePass": [
            {"id": "cline-pass/glm-5.2", "name": "cline-pass/glm-5.2"},
            {"id": "cline-pass/kimi-k3", "name": "cline-pass/kimi-k3"},
            {"id": "other/skip-me", "name": "skip"},
            {"id": "cline-pass/deepseek-v4-pro", "name": "cline-pass/deepseek-v4-pro"},
            {"id": "cline-pass/kimi-k2.6", "name": "cline-pass/kimi-k2.6"},
            {"id": "cline-pass/glm-5.2", "name": "duplicate"}
          ]
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parseClinePassRecommended(data))
        XCTAssertEqual(
            models.map(\.id),
            [
                "cline-pass/deepseek-v4-pro",
                "cline-pass/glm-5.2",
                "cline-pass/kimi-k2.6",
                "cline-pass/kimi-k3"
            ]
        )
        XCTAssertEqual(models.first?.ownedBy, "Deepseek V4 Pro")
        XCTAssertEqual(models[1].ownedBy, "GLM 5.2")
    }

    func testClinePassSortedAlphabeticallyByDisplayLabel() {
        let input = [
            FetchedModel(id: "cline-pass/kimi-k3", ownedBy: "Kimi K3"),
            FetchedModel(id: "cline-pass/glm-5.2", ownedBy: "GLM 5.2"),
            FetchedModel(id: "cline-pass/kimi-k2.6", ownedBy: "Kimi K2.6"),
            FetchedModel(id: "cline-pass/deepseek-v4-flash", ownedBy: "Deepseek V4 Flash")
        ]
        XCTAssertEqual(
            ClinePassCatalog.sortedAlphabetically(input).map(\.id),
            [
                "cline-pass/deepseek-v4-flash",
                "cline-pass/glm-5.2",
                "cline-pass/kimi-k2.6",
                "cline-pass/kimi-k3"
            ]
        )
    }

    func testParseClinePassRecommendedRejectsBadPayload() {
        XCTAssertNil(ProviderModelFetcher.parseClinePassRecommended(Data("not json".utf8)))
        XCTAssertNil(ProviderModelFetcher.parseClinePassRecommended(Data(#"{"recommended":[]}"#.utf8)))
    }

    func testParseGrokOAuthModelsPrefersCatalogName() throws {
        let data = """
        {
          "object": "list",
          "data": [
            {
              "id": "grok-4.5",
              "model": "grok-4.5",
              "name": "Grok 4.5",
              "owned_by": "xAI"
            },
            {
              "id": "grok-code-fast-1",
              "name": "Grok Code Fast 1",
              "owned_by": "xAI"
            }
          ]
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parseGrokOAuthModels(data))
        XCTAssertEqual(models.map(\.id), ["grok-4.5", "grok-code-fast-1"])
        XCTAssertEqual(models.first?.ownedBy, "Grok 4.5")
        XCTAssertEqual(models.last?.ownedBy, "Grok Code Fast 1")
    }

    func testFetchGrokOAuthModelsRetriesOnceOn401() async throws {
        var tokenCalls: [Bool] = []
        var statuses = [401, 200]
        let okBody = Data(#"{"object":"list","data":[{"id":"grok-4.5","name":"Grok 4.5"}]}"#.utf8)

        let models = try await ProviderModelFetcher.fetchGrokOAuthModels(
            baseURL: "https://cli-chat-proxy.grok.com/v1",
            ensureToken: { force in
                tokenCalls.append(force)
                return force ? "new" : "old"
            },
            perform: { request in
                XCTAssertTrue(request.url?.absoluteString.hasSuffix("/models-v2") == true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-grok-session-id"))
                let status = statuses.removeFirst()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                if status == 401 {
                    return (Data("unauthorized".utf8), response)
                }
                return (okBody, response)
            }
        )

        XCTAssertEqual(models.map(\.id), ["grok-4.5"])
        XCTAssertEqual(tokenCalls, [false, true])
    }

    func testGrokOAuthCatalogURL() {
        XCTAssertEqual(
            GrokOAuthClient.modelsV2URL().absoluteString,
            "https://cli-chat-proxy.grok.com/v1/models-v2"
        )
    }
}
