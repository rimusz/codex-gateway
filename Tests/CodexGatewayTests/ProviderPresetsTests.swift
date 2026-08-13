import XCTest
@testable import CodexGateway

final class ProviderPresetsTests: XCTestCase {
    func testZaiPresetDefinition() {
        let preset = ProviderPreset.zai
        XCTAssertEqual(preset.displayName, "Z.ai (GLM)")
        XCTAssertEqual(preset.providerID, "zai")
        XCTAssertEqual(preset.baseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(preset.suggestedModel, "glm-5.2")
    }

    func testClinePassUsesLiveCatalogRefresh() {
        let preset = ProviderPreset.clinePass
        XCTAssertEqual(preset.providerID, "clinepass")
        XCTAssertEqual(preset.baseURL, "https://api.cline.bot/api/v1")
        XCTAssertEqual(preset.suggestedModel, "cline-pass/glm-5.2")
        XCTAssertFalse(preset.supportsModelListingFetch)
        XCTAssertTrue(preset.supportsLiveCatalogRefresh)
        XCTAssertTrue(preset.canFetchModels)
        XCTAssertFalse(preset.usesCatalogModels)
        XCTAssertEqual(
            preset.catalogDocumentationURL?.absoluteString,
            ClinePassCatalog.documentationURL.absoluteString
        )
        XCTAssertEqual(
            ClinePassCatalog.recommendedModelsURL.absoluteString,
            "https://api.cline.bot/api/v1/ai/cline/recommended-models"
        )

        let models = preset.catalogModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.provider, "clinepass")
        XCTAssertEqual(models.first?.model, "cline-pass/glm-5.2")
        XCTAssertEqual(models.first?.display_name, "Cline GLM 5.2")
    }

    func testClinePassDisplayHelpers() {
        XCTAssertEqual(ClinePassCatalog.displayName(for: "Kimi K2.7 Code"), "Cline Kimi K2.7 Code")
        XCTAssertEqual(ClinePassCatalog.displayName(for: "Cline GLM-5.2"), "Cline GLM-5.2")
        XCTAssertEqual(ClinePassCatalog.displayLabel(for: "cline-pass/kimi-k3"), "Kimi K3")
        XCTAssertEqual(ClinePassCatalog.displayLabel(for: "cline-pass/glm-5.2"), "GLM 5.2")
        XCTAssertEqual(ClinePassCatalog.displayLabel(for: "cline-pass/kimi-k2.7-code"), "Kimi K2.7 Code")
    }

    func testXaiPresetDefinition() {
        let preset = ProviderPreset.xai
        XCTAssertEqual(preset.displayName, "xAI Grok (API)")
        XCTAssertEqual(preset.providerID, "xai")
        XCTAssertEqual(preset.baseURL, "https://api.x.ai/v1")
        XCTAssertEqual(preset.suggestedModel, "grok-4")
        XCTAssertTrue(preset.requiresAPIKeyPrompt)
        XCTAssertTrue(preset.supportsModelListingFetch)
        XCTAssertEqual(preset.authKind, .apiKey)
    }

    func testGrokOAuthPresetDefinition() {
        let preset = ProviderPreset.grokOAuth
        XCTAssertEqual(preset.displayName, "xAI Grok (OAuth)")
        XCTAssertEqual(preset.providerID, "grok-oauth")
        XCTAssertEqual(preset.baseURL, "https://cli-chat-proxy.grok.com/v1")
        XCTAssertEqual(preset.suggestedModel, "grok-4.5")
        XCTAssertFalse(preset.requiresAPIKeyPrompt)
        XCTAssertFalse(preset.supportsModelListingFetch)
        XCTAssertTrue(preset.supportsGrokOAuthModelCatalog)
        XCTAssertTrue(preset.canFetchModels)
        XCTAssertTrue(preset.seedsSuggestedModelOnInstall)
        XCTAssertEqual(preset.authKind, .grokOAuth)
        let config = preset.providerConfig(apiKey: "")
        XCTAssertEqual(config.auth_kind, "grok_oauth")
        XCTAssertEqual(config.api_key, "")
        let models = preset.catalogModels()
        XCTAssertEqual(models.first?.slug, "grok-oauth/grok-4.5")
        XCTAssertEqual(models.first?.display_name, "xAI Grok 4.5 (OAuth)")
    }

    func testCursorPresetDefinition() {
        let preset = ProviderPreset.cursor
        XCTAssertEqual(preset.displayName, "Cursor")
        XCTAssertEqual(preset.providerID, "cursor")
        XCTAssertEqual(preset.baseURL, "http://127.0.0.1:18788/v1")
        XCTAssertEqual(preset.defaultAPIKey, "local")
        XCTAssertTrue(preset.requiresAPIKeyPrompt)
        XCTAssertTrue(preset.isManagedCursorBridge)
        XCTAssertTrue(preset.supportsModelListingFetch)
        XCTAssertEqual(preset.authKind, .cursorBridge)
        let config = preset.providerConfig(apiKey: "key_should_not_persist")
        XCTAssertEqual(config.api_key, "local")
        XCTAssertEqual(config.auth_kind, "cursor_bridge")
        XCTAssertTrue(config.usesCursorBridge)
        XCTAssertEqual(preset.suggestedModel, "composer-2.5")
        XCTAssertEqual(preset.catalogModels().first?.display_name, "Cursor Composer 2.5")
    }

    func testOpenRouterPresetDefinition() {
        let preset = ProviderPreset.openrouter
        XCTAssertEqual(preset.displayName, "OpenRouter")
        XCTAssertEqual(preset.providerID, "openrouter")
        XCTAssertEqual(preset.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(preset.suggestedModel, "openrouter/auto")
        let models = preset.catalogModels()
        XCTAssertEqual(models.first?.provider, "openrouter")
        XCTAssertEqual(models.first?.model, "openrouter/auto")
        XCTAssertEqual(models.first?.slug, "openrouter/openrouter-auto")
    }

    func testSlugPartSanitizesModelIDs() {
        XCTAssertEqual(ProviderPreset.slugPart(from: "cline-pass/glm-5.2"), "cline-pass-glm-5.2")
        XCTAssertEqual(ProviderPreset.slugPart(from: "kimi-k2.6"), "kimi-k2.6")
    }

    func testFeaturedMenuIncludesRequestedProviders() {
        let ids = Set(ProviderPreset.featuredMenuOrder.map(\.rawValue))
        XCTAssertTrue(ids.contains("zai"))
        XCTAssertTrue(ids.contains("kimi"))
        XCTAssertTrue(ids.contains("qwen"))
        XCTAssertTrue(ids.contains("xiaomiMiMo"))
        XCTAssertTrue(ids.contains("clinePass"))
        XCTAssertTrue(ids.contains("xai"))
        XCTAssertTrue(ids.contains("grokOAuth"))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("openrouter"))
    }

    func testFeaturedMenuIsAlphabeticalByDisplayName() {
        let names = ProviderPreset.featuredMenuOrder.map(\.displayName)
        XCTAssertEqual(names, names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
        XCTAssertTrue(names.firstIndex(of: "Cline Pass")! < names.firstIndex(of: "xAI Grok (API)")!)
        XCTAssertTrue(names.firstIndex(of: "xAI Grok (API)")! < names.firstIndex(of: "xAI Grok (OAuth)")!)
    }

    func testOllamaDoesNotRequireAPIKeyPrompt() {
        XCTAssertFalse(ProviderPreset.ollama.requiresAPIKeyPrompt)
        XCTAssertEqual(ProviderPreset.ollama.defaultAPIKey, "ollama")
    }

    func testPresetInstallOnlyAddsProvider() throws {
        var savedProvider: ProviderConfig?
        var didPatchConfig = false

        let result = try PresetInstaller.install(
            .minimax,
            apiKey: "sk-test",
            upsertProvider: { savedProvider = $0 },
            patchConfig: { didPatchConfig = true }
        )

        XCTAssertEqual(result.provider, "minimax")
        XCTAssertEqual(result.models, [])
        XCTAssertEqual(savedProvider?.name, "minimax")
        XCTAssertEqual(savedProvider?.display_name, "MiniMax")
        XCTAssertEqual(savedProvider?.api_key, "sk-test")
        XCTAssertTrue(didPatchConfig)
    }

    func testGrokOAuthInstallSeedsSuggestedModel() throws {
        var savedProvider: ProviderConfig?
        var savedModels: [CatalogModel] = []

        let result = try PresetInstaller.install(
            .grokOAuth,
            upsertProvider: { savedProvider = $0 },
            upsertModel: { savedModels.append($0) },
            patchConfig: {}
        )

        XCTAssertEqual(result.provider, "grok-oauth")
        XCTAssertEqual(result.models, ["grok-oauth/grok-4.5"])
        XCTAssertEqual(savedProvider?.auth_kind, "grok_oauth")
        XCTAssertEqual(savedModels.first?.model, "grok-4.5")
    }

    func testProviderConfigUsesGrokOAuthFlag() {
        let oauth = ProviderConfig(
            name: "grok-oauth",
            display_name: "xAI Grok (OAuth)",
            base_url: GrokOAuthClient.defaultBaseURL,
            api_key: "",
            vision_model: nil,
            auth_kind: "grok_oauth"
        )
        XCTAssertTrue(oauth.usesGrokOAuth)
        let api = ProviderConfig(
            name: "xai",
            display_name: nil,
            base_url: "https://api.x.ai/v1",
            api_key: "k",
            vision_model: nil,
            auth_kind: nil
        )
        XCTAssertFalse(api.usesGrokOAuth)
        XCTAssertEqual(api.resolvedAuthKind, .apiKey)
    }

    func testPresetMatchingUsesProviderID() {
        XCTAssertEqual(ProviderPreset.matching(providerID: "clinepass"), .clinePass)
        XCTAssertNil(ProviderPreset.matching(providerID: "custom"))
    }
}
