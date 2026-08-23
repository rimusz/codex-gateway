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
        // Preset base already includes /v1; fetcher appends /models only (not /v1/models).
        XCTAssertEqual(
            ProviderModelFetcher.modelsURL(for: "https://api.anthropic.com/v1")?.absoluteString,
            "https://api.anthropic.com/v1/models"
        )
    }

    func testModelsRequestUsesAnthropicAuthHeaders() throws {
        let request = try XCTUnwrap(
            ProviderModelFetcher.modelsRequest(
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "sk-ant-fake",
                authKind: .anthropic
            )
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-fake")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-fake")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))

        let bearer = try XCTUnwrap(
            ProviderModelFetcher.modelsRequest(
                baseURL: "https://api.deepseek.com",
                apiKey: "sk-test",
                authKind: .apiKey
            )
        )
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "api-key"), "sk-test")
        XCTAssertNil(bearer.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(bearer.value(forHTTPHeaderField: "anthropic-version"))

        let oauth = try XCTUnwrap(
            ProviderModelFetcher.modelsRequest(
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "sk-ant-oat-fake",
                authKind: .claudeCode
            )
        )
        XCTAssertEqual(oauth.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-fake")
        XCTAssertNil(oauth.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(oauth.value(forHTTPHeaderField: "api-key"))
    }

    func testFetchErrorClaudeCodeSessionMissingUsesLoginHint() {
        XCTAssertEqual(
            ProviderModelFetcher.FetchError.claudeCodeSessionMissing.errorDescription,
            ClaudeCodeSession.missingSessionMessage()
        )
        XCTAssertTrue(
            ProviderModelFetcher.FetchError.claudeCodeSessionMissing.errorDescription?
                .contains("claude auth login") == true
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

    func testParseAnthropicModelsListUsesDisplayName() throws {
        let data = """
        {
          "data": [
            {
              "type": "model",
              "id": "claude-sonnet-5",
              "display_name": "Claude Sonnet 5",
              "created_at": "2026-01-01T00:00:00Z"
            },
            {
              "type": "model",
              "id": "claude-haiku-4-5",
              "display_name": "Claude Haiku 4.5"
            },
            {
              "id": "claude-sonnet-5"
            }
          ],
          "has_more": false
        }
        """.data(using: .utf8)!

        let models = try XCTUnwrap(ProviderModelFetcher.parse(data))
        XCTAssertEqual(models.map(\.id), ["claude-haiku-4-5", "claude-sonnet-5"])
        XCTAssertEqual(models.first?.ownedBy, "Claude Haiku 4.5")
        XCTAssertEqual(models.last?.ownedBy, "Claude Sonnet 5")
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
