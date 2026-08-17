import XCTest
@testable import CodexGateway

final class ModelCatalogTests: XCTestCase {
    func testProviderParsingRequiresNameAndBaseURL() {
        XCTAssertNil(ModelCatalog.provider(from: ["name": "x"]))
        XCTAssertNil(ModelCatalog.provider(from: ["base_url": "https://x/v1"]))
        let provider = ModelCatalog.provider(from: [
            "name": "minimax",
            "base_url": "https://api.minimax.io/v1",
            "api_key": "sk-test"
        ])
        XCTAssertEqual(provider?.name, "minimax")
        XCTAssertEqual(provider?.base_url, "https://api.minimax.io/v1")
        XCTAssertEqual(provider?.api_key, "sk-test")
    }

    func testProviderParsingTrimsWhitespace() {
        let provider = ModelCatalog.provider(from: [
            "name": "  minimax  ",
            "display_name": " MiniMax ",
            "base_url": " https://api.minimax.io/v1 "
        ])
        XCTAssertEqual(provider?.name, "minimax")
        XCTAssertEqual(provider?.display_name, "MiniMax")
        XCTAssertEqual(provider?.displayLabel, "MiniMax")
        XCTAssertEqual(provider?.base_url, "https://api.minimax.io/v1")
    }

    func testProviderDisplayLabelFallsBackToPresetName() {
        let provider = ProviderConfig(
            name: "clinepass",
            display_name: nil,
            base_url: "https://api.cline.bot/api/v1",
            api_key: "",
            vision_model: nil
        )
        XCTAssertEqual(provider.displayLabel, "Cline Pass")
    }

    func testCatalogModelsFromFetchedUsesProviderPrefixedSlug() {
        let provider = ProviderConfig(
            name: "ollama",
            display_name: "Ollama (local)",
            base_url: "http://localhost:11434/v1",
            api_key: "ollama"
        )
        let models = ModelCatalog.catalogModels(
            from: [FetchedModel(id: "llama3.2", ownedBy: "ollama")],
            for: provider
        )
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].slug, "ollama/llama3.2")
        XCTAssertEqual(models[0].model, "llama3.2")
        XCTAssertEqual(models[0].provider, "ollama")
    }

    func testProviderDisplayLabelPrefersStoredNameOverPreset() {
        let provider = ProviderConfig(
            name: "xai",
            display_name: "My xAI",
            base_url: "https://api.x.ai/v1",
            api_key: "k",
            vision_model: nil
        )
        XCTAssertEqual(provider.displayLabel, "My xAI")
        XCTAssertEqual(ProviderPreset.matching(providerID: "xai")?.displayName, "xAI Grok (API)")
    }

    func testCatalogModelParsingDefaults() {
        let model = ModelCatalog.catalogModel(from: [
            "slug": "minimax/m2.5",
            "provider": "minimax",
            "display_name": "MiniMax M2.5"
        ])
        XCTAssertEqual(model?.slug, "minimax/m2.5")
        XCTAssertEqual(model?.model, "minimax/m2.5")
        XCTAssertEqual(model?.provider, "minimax")
        XCTAssertEqual(model?.backend_provider, "minimax")
        XCTAssertEqual(model?.display_name, "MiniMax M2.5")
        XCTAssertEqual(model?.visibility, "list")
    }

    func testCatalogModelUsesExplicitUpstreamModel() {
        let model = ModelCatalog.catalogModel(from: [
            "slug": "minimax/m2.5",
            "provider": "minimax",
            "model": "MiniMax-M2.5"
        ])
        XCTAssertEqual(model?.model, "MiniMax-M2.5")
    }

    func testCatalogModelRequiresSlugAndProvider() {
        XCTAssertNil(ModelCatalog.catalogModel(from: ["slug": "only-slug"]))
        XCTAssertNil(ModelCatalog.catalogModel(from: ["provider": "minimax"]))
    }

    func testCodexCatalogExportOmitsRoutingFields() throws {
        let internalCatalog = ModelCatalogFile(models: [
            CatalogModel(
                slug: "minimax/minimax-m2.5",
                model: "minimax-m2.5",
                provider: "minimax",
                backend_provider: "minimax",
                display_name: "MiniMax M2.5",
                visibility: "list",
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            )
        ])

        let export = ModelCatalog.codexCatalog(from: internalCatalog)
        let custom = try XCTUnwrap(export.models.first { $0.slug == "minimax/minimax-m2.5" })
        XCTAssertEqual(custom.display_name, "MiniMax M2.5")
        XCTAssertEqual(custom.visibility, "list")
        XCTAssertEqual(custom.default_reasoning_level, "medium")
        XCTAssertEqual(custom.supported_reasoning_levels.map(\.effort), ["low", "medium", "high"])
        XCTAssertTrue(custom.base_instructions.contains("You are Codex"))
        XCTAssertEqual(custom.model_messages.instructions_template, custom.base_instructions)
        XCTAssertFalse(custom.supports_reasoning_summaries)
        XCTAssertEqual(custom.default_reasoning_summary, "none")
        XCTAssertEqual(custom.truncation_policy.mode, "tokens")
        XCTAssertEqual(custom.input_modalities, ["text"])
        XCTAssertEqual(custom.context_window, 128_000)
        XCTAssertTrue(custom.supported_in_api)
        XCTAssertEqual(custom.shell_type, "shell_command")

        let data = try JSONEncoder().encode(export)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        let customJSON = try XCTUnwrap(models.first { $0["slug"] as? String == "minimax/minimax-m2.5" })
        XCTAssertNil(customJSON["provider"])
        XCTAssertNil(customJSON["backend_provider"])
        XCTAssertNil(customJSON["model"])
    }

    func testCodexCatalogExportDefaultsDisplayAndVisibility() {
        let internalCatalog = ModelCatalogFile(models: [
            CatalogModel(
                slug: "custom/model",
                model: nil,
                provider: nil,
                backend_provider: nil,
                display_name: nil,
                visibility: nil,
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            )
        ])

        let export = ModelCatalog.codexCatalog(from: internalCatalog)
        let custom = export.models.first { $0.slug == "custom/model" }
        XCTAssertEqual(custom?.display_name, "custom/model")
        XCTAssertEqual(custom?.visibility, "list")
    }

    func testCodexCatalogIncludesNativeModelsWithCustomModels() throws {
        let internalCatalog = ModelCatalogFile(models: [
            CatalogModel(
                slug: "minimax/minimax-m2.5",
                model: "minimax-m2.5",
                provider: "minimax",
                backend_provider: "minimax",
                display_name: "MiniMax M2.5",
                visibility: "list",
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            )
        ])

        let export = ModelCatalog.codexCatalog(from: internalCatalog)
        XCTAssertEqual(export.models.first?.slug, "gpt-5.5")
        XCTAssertTrue(export.models.contains { $0.slug == "gpt-5.4" })
        XCTAssertTrue(export.models.contains { $0.slug == "gpt-5.3-codex" })
        XCTAssertTrue(export.models.contains { $0.slug == "minimax/minimax-m2.5" })
    }

    func testCodexCatalogIncludesNativeModelsWhenCustomCatalogIsEmpty() {
        let export = ModelCatalog.codexCatalog(from: ModelCatalogFile(models: []))
        XCTAssertFalse(export.models.isEmpty)
        XCTAssertEqual(export.models.first?.slug, "gpt-5.5")
    }

    func testCatalogModelsForProviderMatchesProviderOrBackendProvider() {
        let catalog = [
            CatalogModel(
                slug: "minimax-a",
                model: "MiniMax-M2.5",
                provider: "minimax",
                backend_provider: nil,
                display_name: nil,
                visibility: nil,
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            ),
            CatalogModel(
                slug: "other-b",
                model: "other",
                provider: nil,
                backend_provider: "ollama",
                display_name: nil,
                visibility: nil,
                input_modalities: nil,
                vision_bridge_enabled: nil,
                context_window: nil
            ),
        ]

        XCTAssertEqual(ModelCatalog.catalogModels(catalog, forProvider: "minimax").map(\.slug), ["minimax-a"])
        XCTAssertEqual(ModelCatalog.catalogModels(catalog, forProvider: "ollama").map(\.slug), ["other-b"])
        XCTAssertTrue(ModelCatalog.catalogModels(catalog, forProvider: "missing").isEmpty)
    }

    func testPrettyDisplayNameFormatsCommonModelIDs() {
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "composer-2.5"), "Composer 2.5")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "grok-4.3"), "Grok 4.3")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "qwen3.7-max"), "Qwen3.7 Max")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "minimax-m2.5"), "MiniMax M2.5")
    }

    func testPrettyDisplayNameDropsPathPrefixAndDoubledVendor() {
        // Path prefix dropped and the doubled "deepseek" collapsed to one.
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "deepseek/deepseek-chat-v3-0324"),
            "DeepSeek Chat V3 0324"
        )
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "openrouter/deepseek-deepseek-chat-v3-0324"),
            "DeepSeek Chat V3 0324"
        )
    }

    func testPrettyDisplayNamePrefixesProviderBrandClineStyle() {
        // Provider brand prefixed (Cline style), with parentheticals trimmed.
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "glm-5.2", providerID: "zai"),
            "Z.ai GLM 5.2"
        )
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "grok-4.3", providerID: "xai"),
            "xAI Grok 4.3 (API)"
        )
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "grok-4.3", providerID: "grok-oauth"),
            "xAI Grok 4.3 (OAuth)"
        )
        XCTAssertEqual(ModelCatalog.providerBrand(for: "xai"), "xAI")
        XCTAssertEqual(ModelCatalog.providerBrand(for: "grok-oauth"), "xAI")
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "deepseek/deepseek-chat-v3-0324", providerID: "openrouter"),
            "OpenRouter DeepSeek Chat V3 0324"
        )
    }

    func testSortedProvidersAndModelsAreAlphabetical() {
        let providers = [
            ProviderConfig(name: "xai", display_name: nil, base_url: "https://api.x.ai/v1", api_key: "k"),
            ProviderConfig(name: "clinepass", display_name: nil, base_url: "https://api.cline.bot/api/v1", api_key: "k"),
            ProviderConfig(name: "grok-oauth", display_name: nil, base_url: GrokOAuthClient.defaultBaseURL, api_key: "")
        ]
        XCTAssertEqual(
            ModelCatalog.sortedProviders(providers).map(\.displayLabel),
            ["Cline Pass", "xAI Grok (API)", "xAI Grok (OAuth)"]
        )

        let models = [
            CatalogModel(
                slug: "xai/grok-4.5", model: "grok-4.5", provider: "xai", backend_provider: "xai",
                display_name: "xAI Grok 4.5 (API)", visibility: "list",
                input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
            ),
            CatalogModel(
                slug: "clinepass/a", model: "a", provider: "clinepass", backend_provider: "clinepass",
                display_name: "Cline GLM-5.2", visibility: "list",
                input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
            ),
            CatalogModel(
                slug: "grok-oauth/grok-4.5", model: "grok-4.5", provider: "grok-oauth",
                backend_provider: "grok-oauth",
                display_name: "xAI Grok 4.5 (OAuth)", visibility: "list",
                input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
            )
        ]
        XCTAssertEqual(
            ModelCatalog.sortedCatalogModels(models).map { $0.display_name ?? "" },
            ["Cline GLM-5.2", "xAI Grok 4.5 (API)", "xAI Grok 4.5 (OAuth)"]
        )
    }

    func testPrettyDisplayNameAvoidsDoubleBrandWhenNameLeadsWithIt() {
        // deepseek provider + a deepseek-* model should not become "DeepSeek DeepSeek …".
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "deepseek-v4-pro", providerID: "deepseek"),
            "DeepSeek V4 Pro"
        )
    }

    func testNormalizeDisplayNamesLeavesCustomizedNamesAndBrandsAutoOnes() {
        // Raw id → branded name.
        let raw = CatalogModel(
            slug: "xai/grok-4.3", model: "grok-4.3",
            provider: "xai", backend_provider: "xai",
            display_name: "grok-4.3", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        // Previously auto-generated (unbranded) name → upgraded to branded.
        let unbranded = CatalogModel(
            slug: "xai/grok-4.3", model: "grok-4.3",
            provider: "xai", backend_provider: "xai",
            display_name: "Grok 4.3", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        // User-customized name → preserved.
        let customized = CatalogModel(
            slug: "xai/grok-4.3", model: "grok-4.3",
            provider: "xai", backend_provider: "xai",
            display_name: "My Grok", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        XCTAssertEqual(ModelCatalog.normalizedDisplayName(for: raw), "xAI Grok 4.3 (API)")
        XCTAssertEqual(ModelCatalog.normalizedDisplayName(for: unbranded), "xAI Grok 4.3 (API)")
        XCTAssertEqual(ModelCatalog.normalizedDisplayName(for: customized), "My Grok")

        let legacyBranded = CatalogModel(
            slug: "grok-oauth/grok-4.5", model: "grok-4.5",
            provider: "grok-oauth", backend_provider: "grok-oauth",
            display_name: "xAI Grok 4.5", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        XCTAssertEqual(
            ModelCatalog.normalizedDisplayName(for: legacyBranded),
            "xAI Grok 4.5 (OAuth)"
        )
    }

    func testProviderHasInstalledModelsErrorDescription() {
        let error = ModelCatalogError.providerHasInstalledModels(name: "minimax", count: 2)
        XCTAssertEqual(
            error.localizedDescription,
            "Cannot delete provider \"minimax\": remove its 2 installed models first."
        )
        let single = ModelCatalogError.providerHasInstalledModels(name: "ollama", count: 1)
        XCTAssertEqual(
            single.localizedDescription,
            "Cannot delete provider \"ollama\": remove its 1 installed model first."
        )
    }
}
