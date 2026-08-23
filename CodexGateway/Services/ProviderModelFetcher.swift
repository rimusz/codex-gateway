import Foundation

/// A single model entry returned by an OpenAI-compatible provider `/models` endpoint.
struct FetchedModel: Identifiable, Hashable, Sendable, Codable {
  var id: String
  var ownedBy: String?

  enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "owned_by"
  }
}

enum ProviderModelFetcher {
  enum FetchError: LocalizedError {
    case invalidURL
    case unauthorized
    case claudeCodeSessionMissing
    case http(Int)
    case empty
    case transport(String)
    case decode

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "The base URL is not a valid endpoint."
      case .unauthorized: return "Unauthorized - check the API key for this provider."
      case .claudeCodeSessionMissing: return ClaudeCodeSession.missingSessionMessage()
      case .http(let code): return "The provider returned HTTP \(code)."
      case .empty: return "The provider returned no models."
      case .transport(let message): return message
      case .decode: return "Could not read the model list from the provider."
      }
    }
  }

  static func modelsURL(for baseURL: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    return URL(string: normalized + "/models")
  }

  static func parse(_ data: Data) -> [FetchedModel]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let rawList: [Any]
    // IDs to drop regardless of provider (e.g. Cursor's "default"/Auto meta-selector).
    let skipIDs: Set<String> = ["default", "auto", "auto-smart"]
    if let dict = object as? [String: Any], let list = dict["data"] as? [Any] {
      rawList = list
    } else if let dict = object as? [String: Any], let list = dict["items"] as? [Any] {
      // Cursor `/models` returns `{ "items": [ { "id", "displayName", "variants", ... } ] }`.
      // Variants are request-time params (effort/thinking/context/fast), not distinct model
      // IDs, so we keep only the top-level `id` per item to produce a flat list.
      rawList = list
    } else if let list = object as? [Any] {
      rawList = list
    } else {
      return nil
    }

    var seen = Set<String>()
    var models: [FetchedModel] = []
    for item in rawList {
      guard let entry = item as? [String: Any] else { continue }
      let identifier = (entry["id"] as? String) ?? (entry["model"] as? String)
      guard let id = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
        continue
      }
      guard !skipIDs.contains(id.lowercased()) else { continue }
      guard seen.insert(id).inserted else { continue }
      let ownedBy = (entry["owned_by"] as? String)
        ?? (entry["display_name"] as? String)
      models.append(FetchedModel(id: id, ownedBy: ownedBy))
    }
    return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  /// Builds `GET {base_url}/models` with provider auth. Exposed for unit tests (no network).
  static func modelsRequest(
    baseURL: String,
    apiKey: String,
    authKind: ProviderAuthKind = .apiKey
  ) -> URLRequest? {
    guard let url = modelsURL(for: baseURL) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    ProviderAuth.apply(to: &request, apiKey: key, kind: authKind)
    if !key.isEmpty, authKind != .anthropic, authKind != .claudeCode {
      request.setValue(key, forHTTPHeaderField: "api-key")
    }
    return request
  }

  static func fetch(
    baseURL: String,
    apiKey: String,
    authKind: ProviderAuthKind = .apiKey
  ) async throws -> [FetchedModel] {
    guard let request = modelsRequest(baseURL: baseURL, apiKey: apiKey, authKind: authKind) else {
      throw FetchError.invalidURL
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw FetchError.transport(error.localizedDescription)
    }

    if let http = response as? HTTPURLResponse {
      if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
      guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
    }

    guard let models = parse(data) else { throw FetchError.decode }
    guard !models.isEmpty else { throw FetchError.empty }
    return models
  }

  /// Fetches Cline Pass models from the public recommended-models feed (no API key).
  static func fetchClinePassRecommended(
    url: URL = ClinePassCatalog.recommendedModelsURL
  ) async throws -> [FetchedModel] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw FetchError.transport(error.localizedDescription)
    }

    if let http = response as? HTTPURLResponse {
      guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
    }

    guard let models = parseClinePassRecommended(data) else { throw FetchError.decode }
    guard !models.isEmpty else { throw FetchError.empty }
    return models
  }

  /// Parses `{ "clinePass": [{ "id": "cline-pass/…", "name": "…" }] }` from Cline's feed.
  static func parseClinePassRecommended(_ data: Data) -> [FetchedModel]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = object["clinePass"] as? [Any] else {
      return nil
    }

    var seen = Set<String>()
    var models: [FetchedModel] = []
    for item in list {
      guard let entry = item as? [String: Any] else { continue }
      let identifier = (entry["id"] as? String) ?? (entry["model"] as? String)
      guard let id = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty,
            id.hasPrefix("cline-pass/") else { continue }
      guard seen.insert(id).inserted else { continue }
      models.append(FetchedModel(id: id, ownedBy: ClinePassCatalog.displayLabel(for: id)))
    }
    return ClinePassCatalog.sortedAlphabetically(models)
  }

  /// Claude Code login failures should never ask the user to check an API key.
  static func remapClaudeCodeAuthFailure(_ error: FetchError) -> FetchError {
    if case .unauthorized = error { return .claudeCodeSessionMissing }
    return error
  }

  /// Fetches models for an installed provider, routing Cline Pass / Grok OAuth to their catalogs.
  static func fetch(for provider: ProviderConfig) async throws -> [FetchedModel] {
    if provider.usesGrokOAuth
      || ProviderPreset.matching(providerID: provider.name)?.supportsGrokOAuthModelCatalog == true {
      return try await fetchGrokOAuthModels(baseURL: provider.base_url)
    }
    if ProviderPreset.matching(providerID: provider.name)?.supportsLiveCatalogRefresh == true {
      return try await fetchClinePassRecommended()
    }
    if provider.usesClaudeCodeAuth {
      guard let token = ClaudeCodeSession.loadUsableSession()?.accessToken, !token.isEmpty else {
        throw FetchError.claudeCodeSessionMissing
      }
      do {
        return try await fetch(
          baseURL: provider.base_url.isEmpty ? ProviderPreset.claudeCode.baseURL : provider.base_url,
          apiKey: token,
          authKind: .claudeCode
        )
      } catch let error as FetchError {
        throw remapClaudeCodeAuthFailure(error)
      }
    }
    return try await fetch(
      baseURL: provider.base_url,
      apiKey: provider.api_key,
      authKind: provider.resolvedAuthKind
    )
  }

  /// Grok CLI OAuth catalog: `GET {base}/models-v2` with session from `~/.grok/auth.json`.
  static func fetchGrokOAuthModels(
    baseURL: String = GrokOAuthClient.defaultBaseURL,
    ensureToken: (_ force: Bool) throws -> String = { try GrokOAuthSession.ensureFreshAccessToken(force: $0) },
    perform: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
  ) async throws -> [FetchedModel] {
    let url = GrokOAuthClient.modelsV2URL(baseURL: baseURL.isEmpty ? GrokOAuthClient.defaultBaseURL : baseURL)

    func makeRequest(token: String) -> URLRequest {
      var request = URLRequest(url: url)
      request.timeoutInterval = 20
      for (key, value) in GrokOAuthClient.catalogHeaders(accessToken: token) {
        request.setValue(value, forHTTPHeaderField: key)
      }
      return request
    }

    let token: String
    do {
      token = try ensureToken(false)
    } catch {
      throw FetchError.unauthorized
    }

    var data: Data
    var response: URLResponse
    do {
      (data, response) = try await perform(makeRequest(token: token))
    } catch {
      throw FetchError.transport(error.localizedDescription)
    }

    var status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 {
      let refreshed: String
      do {
        refreshed = try ensureToken(true)
      } catch {
        throw FetchError.unauthorized
      }
      do {
        (data, response) = try await perform(makeRequest(token: refreshed))
      } catch {
        throw FetchError.transport(error.localizedDescription)
      }
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    if status == 401 || status == 403 { throw FetchError.unauthorized }
    guard (200..<300).contains(status) else { throw FetchError.http(status) }

    guard let models = parseGrokOAuthModels(data) else { throw FetchError.decode }
    guard !models.isEmpty else { throw FetchError.empty }
    return models
  }

  /// Parses OpenAI-style `models-v2` payloads; prefers the catalog `name` for display labels.
  static func parseGrokOAuthModels(_ data: Data) -> [FetchedModel]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = object["data"] as? [Any] else {
      return parse(data)
    }

    var seen = Set<String>()
    var models: [FetchedModel] = []
    for item in list {
      guard let entry = item as? [String: Any] else { continue }
      let identifier = (entry["id"] as? String)
        ?? (entry["model"] as? String)
      guard let id = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
        continue
      }
      guard seen.insert(id).inserted else { continue }
      let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let ownedBy = (name?.isEmpty == false ? name : nil)
        ?? (entry["owned_by"] as? String)
      models.append(FetchedModel(id: id, ownedBy: ownedBy))
    }
    return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }
}
