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

        let anthropic = ModelCatalog.provider(from: [
            "name": "anthropic",
            "display_name": "Anthropic (Claude)",
            "base_url": "https://api.anthropic.com/v1",
            "api_key": "sk-ant-test",
            "auth_kind": "anthropic"
        ])
        XCTAssertEqual(anthropic?.auth_kind, "anthropic")
        XCTAssertEqual(anthropic?.resolvedAuthKind, .anthropic)
        XCTAssertTrue(anthropic?.usesAnthropicAuth == true)
        XCTAssertFalse(anthropic?.usesClaudeCodeAuth == true)

        let claudeCode = ModelCatalog.provider(from: [
            "name": "claude-code",
            "display_name": "Anthropic (Claude Code)",
            "base_url": "https://api.anthropic.com/v1",
            "api_key": "",
            "auth_kind": "claude_code"
        ])
        XCTAssertEqual(claudeCode?.auth_kind, "claude_code")
        XCTAssertEqual(claudeCode?.resolvedAuthKind, .claudeCode)
        XCTAssertTrue(claudeCode?.usesClaudeCodeAuth == true)
        XCTAssertFalse(claudeCode?.usesAnthropicAuth == true)
        XCTAssertEqual(claudeCode?.api_key, "")
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

    func testCatalogModelsFromFetchedAnthropicUsesBrandAndSlug() {
        let provider = ProviderConfig(
            name: "anthropic",
            display_name: "Anthropic (Claude)",
            base_url: "https://api.anthropic.com/v1",
            api_key: "sk-ant-test",
            vision_model: nil,
            auth_kind: "anthropic"
        )
        let models = ModelCatalog.catalogModels(
            from: [FetchedModel(id: "claude-sonnet-5", ownedBy: "Claude Sonnet 5")],
            for: provider
        )
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].slug, "anthropic/claude-sonnet-5")
        XCTAssertEqual(models[0].model, "claude-sonnet-5")
        XCTAssertEqual(models[0].provider, "anthropic")
        XCTAssertEqual(models[0].display_name, "Anthropic Claude Sonnet 5 (API)")
    }

    func testCatalogModelsFromFetchedClaudeCodeUsesOAuthSuffix() {
        let provider = ProviderConfig(
            name: "claude-code",
            display_name: "Anthropic (Claude Code)",
            base_url: "https://api.anthropic.com/v1",
            api_key: "",
            vision_model: nil,
            auth_kind: "claude_code"
        )
        let models = ModelCatalog.catalogModels(
            from: [FetchedModel(id: "claude-sonnet-5", ownedBy: "Claude Sonnet 5")],
            for: provider
        )
        XCTAssertEqual(models[0].slug, "claude-code/claude-sonnet-5")
        XCTAssertEqual(models[0].provider, "claude-code")
        XCTAssertEqual(models[0].display_name, "Anthropic Claude Sonnet 5 (OAuth)")
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

    func testCodexCatalogExportsOnlyCustomModels() throws {
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
        XCTAssertEqual(export.models.map(\.slug), ["minimax/minimax-m2.5"])
        XCTAssertFalse(export.models.contains { $0.slug.hasPrefix("gpt-") })
    }

    func testCodexCatalogIsEmptyWhenNoCustomModelsAreInstalled() {
        let export = ModelCatalog.codexCatalog(from: ModelCatalogFile(models: []))
        XCTAssertTrue(export.models.isEmpty)
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

    func testExcludingInstalledHidesSavedSlugAndUpstreamForThatProvider() {
        func model(slug: String, upstream: String, provider: String) -> CatalogModel {
            CatalogModel(
                slug: slug, model: upstream, provider: provider, backend_provider: provider,
                display_name: slug, visibility: "list",
                input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
            )
        }
        let candidates = [
            model(slug: "cursor/grok-4.7", upstream: "grok-4.7", provider: "cursor"),
            model(slug: "cursor/composer-2.5", upstream: "composer-2.5", provider: "cursor"),
            model(slug: "cursor/renamed", upstream: "claude-haiku-4-5", provider: "cursor")
        ]
        let installed = [
            model(slug: "cursor/grok-4.7", upstream: "grok-4.7", provider: "cursor"),
            model(slug: "cursor/custom-haiku", upstream: "claude-haiku-4-5", provider: "cursor"),
            model(slug: "jfrog/grok-4.7", upstream: "grok-4.7", provider: "jfrog")
        ]
        XCTAssertEqual(
            ModelCatalog.excludingInstalled(candidates, installed: installed, providerID: "cursor").map(\.slug),
            ["cursor/composer-2.5"]
        )
        XCTAssertEqual(
            ModelCatalog.excludingInstalled(candidates, installed: [], providerID: "cursor").map(\.slug),
            ["cursor/grok-4.7", "cursor/composer-2.5", "cursor/renamed"]
        )
    }

    func testPrettyDisplayNameUsesDotsForHyphenatedVersions() {
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "claude-opus-4-5"), "Claude Opus 4.5")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "claude-opus-5"), "Claude Opus 5")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "claude-sonnet-5-5"), "Claude Sonnet 5.5")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "glm-5-3"), "GLM 5.3")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "gemini-2.5-flash-lite"), "Gemini 2.5 Flash Lite")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "glm-5p3-flash"), "GLM 5.3 Flash")
        XCTAssertEqual(ModelCatalog.prettyDisplayName(from: "gpt-5.4-mini"), "GPT 5.4 Mini")
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "claude-opus-4-8", providerID: "anthropic"),
            "Anthropic Claude Opus 4.8 (API)"
        )
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
        XCTAssertEqual(ModelCatalog.providerBrand(for: "anthropic"), "Anthropic")
        XCTAssertEqual(ModelCatalog.providerBrand(for: "claude-code"), "Anthropic")
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "claude-sonnet-5", providerID: "anthropic"),
            "Anthropic Claude Sonnet 5 (API)"
        )
        XCTAssertEqual(
            ModelCatalog.prettyDisplayName(from: "claude-sonnet-5", providerID: "claude-code"),
            "Anthropic Claude Sonnet 5 (OAuth)"
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

        let spacedVersion = CatalogModel(
            slug: "jfrog/claude-opus-4-5", model: "claude-opus-4-5",
            provider: nil, backend_provider: nil,
            display_name: "Claude Opus 4 5", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        XCTAssertEqual(ModelCatalog.normalizedDisplayName(for: spacedVersion), "Claude Opus 4.5")

        let collapsedMinor = CatalogModel(
            slug: "jfrog/claude-opus-5-5", model: "claude-opus-5-5",
            provider: nil, backend_provider: nil,
            display_name: "Claude Opus 5", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        XCTAssertEqual(ModelCatalog.normalizedDisplayName(for: collapsedMinor), "Claude Opus 5.5")

        let hyphenatedVersion = CatalogModel(
            slug: "cursor/claude-haiku-4-5", model: "claude-haiku-4-5",
            provider: "cursor", backend_provider: "cursor",
            display_name: "Cursor Claude Haiku 4-5", visibility: "list",
            input_modalities: nil, vision_bridge_enabled: nil, context_window: nil
        )
        XCTAssertEqual(
            ModelCatalog.normalizedDisplayName(for: hyphenatedVersion),
            "Cursor Claude Haiku 4.5"
        )
    }

    func testRequestedModelIDReadsStringObjectAndModelID() {
        XCTAssertEqual(ModelCatalog.requestedModelID(from: ["model": "openrouter/minimax-m2.5"]), "openrouter/minimax-m2.5")
        XCTAssertEqual(ModelCatalog.requestedModelID(from: ["model": "  minimax-m2.5  "]), "minimax-m2.5")
        XCTAssertEqual(
            ModelCatalog.requestedModelID(from: ["model": ["id": "minimax-m2.5", "name": "OpenRouter MiniMax"]]),
            "minimax-m2.5"
        )
        XCTAssertEqual(
            ModelCatalog.requestedModelID(from: ["model": ["slug": "openrouter/minimax-m2.5"]]),
            "openrouter/minimax-m2.5"
        )
        XCTAssertEqual(ModelCatalog.requestedModelID(from: ["model_id": "minimax-m2.5"]), "minimax-m2.5")
        XCTAssertEqual(ModelCatalog.requestedModelID(from: [:]), "")
        XCTAssertEqual(ModelCatalog.requestedModelID(from: ["model": "   "]), "")
    }

    func testFindModelMatchesExactSlugThenUniqueUnprefixedId() {
        let routed = CatalogModel(
            slug: "openrouter/minimax-m2.5",
            model: "minimax-m2.5",
            provider: "openrouter",
            backend_provider: "openrouter",
            display_name: "OpenRouter MiniMax M2.5",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        let claudeAPI = CatalogModel(
            slug: "anthropic/claude-sonnet-5",
            model: "claude-sonnet-5",
            provider: "anthropic",
            backend_provider: "anthropic",
            display_name: "Anthropic Claude Sonnet 5 (API)",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        let claudeOAuth = CatalogModel(
            slug: "claude-code/claude-sonnet-5",
            model: "claude-sonnet-5",
            provider: "claude-code",
            backend_provider: "claude-code",
            display_name: "Anthropic Claude Sonnet 5 (OAuth)",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        let models = [routed, claudeAPI, claudeOAuth]

        XCTAssertEqual(
            ModelCatalog.findModel(requested: "openrouter/minimax-m2.5", in: models)?.slug,
            "openrouter/minimax-m2.5"
        )
        XCTAssertEqual(
            ModelCatalog.findModel(requested: "minimax-m2.5", in: models)?.slug,
            "openrouter/minimax-m2.5"
        )
        XCTAssertNil(ModelCatalog.findModel(requested: "claude-sonnet-5", in: models))
        XCTAssertEqual(
            ModelCatalog.findModel(requested: "anthropic/claude-sonnet-5", in: models)?.slug,
            "anthropic/claude-sonnet-5"
        )
        XCTAssertNil(ModelCatalog.findModel(requested: "gpt-5.5", in: models))
        XCTAssertNil(ModelCatalog.findModel(requested: "", in: models))
        XCTAssertTrue(ModelCatalog.isNativeCodexSlug("gpt-5.5"))
        XCTAssertFalse(ModelCatalog.isNativeCodexSlug("minimax-m2.5"))
    }

    func testBundledCatalogProtectsFutureNativeSlugsFromCustomAlias() {
        ModelCatalog.resetBundledNativeSlugs()
        defer { ModelCatalog.resetBundledNativeSlugs() }
        let slugs = ModelCatalog.nativeSlugs(fromBundledJSON: Data("""
        {"models":[{"slug":"gpt-6-astra"},{"slug":"  "},{"slug":""}]}
        """.utf8))
        XCTAssertEqual(slugs, ["gpt-6-astra"])
        XCTAssertEqual(ModelCatalog.bundledNativeSlugs(load: { slugs }), ["gpt-6-astra"])
        XCTAssertTrue(ModelCatalog.isNativeCodexSlug("gpt-6-astra"))
        XCTAssertTrue(ModelCatalog.isNativeCodexSlug("gpt-5.5"))

        let colliding = CatalogModel(
            slug: "openrouter/gpt-6-astra",
            model: "gpt-6-astra",
            provider: "openrouter",
            backend_provider: "openrouter",
            display_name: "OpenRouter GPT 6 Astra",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        XCTAssertNil(ModelCatalog.findModel(requested: "gpt-6-astra", in: [colliding]))
        XCTAssertEqual(
            ModelCatalog.findModel(requested: "openrouter/gpt-6-astra", in: [colliding])?.slug,
            "openrouter/gpt-6-astra"
        )
    }

    func testBundledSlugCommandTimesOutInsteadOfWaiting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-slug-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("hang.sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let started = Date()
        XCTAssertThrowsError(
            try ModelCatalog.runBundledSlugCommand(script.path, arguments: [], timeout: 0.3)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testFindModelDoesNotStealNativeSlugEvenIfCustomUpstreamMatches() {
        let colliding = CatalogModel(
            slug: "openrouter/gpt-5.5",
            model: "gpt-5.5",
            provider: "openrouter",
            backend_provider: "openrouter",
            display_name: "OpenRouter GPT 5.5",
            visibility: "list",
            input_modalities: nil,
            vision_bridge_enabled: nil,
            context_window: nil
        )
        XCTAssertNil(ModelCatalog.findModel(requested: "gpt-5.5", in: [colliding]))
        XCTAssertEqual(
            ModelCatalog.findModel(requested: "openrouter/gpt-5.5", in: [colliding])?.slug,
            "openrouter/gpt-5.5"
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
