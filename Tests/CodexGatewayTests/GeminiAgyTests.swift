import XCTest
@testable import CodexGateway

final class GeminiAgyTests: CodexGatewayTestCase {
  private func tokenJSON(access: String, expiry: String) -> Data {
    let raw = """
    {"token":{"access_token":"\(access)","token_type":"Bearer","refresh_token":"refresh-not-logged","expiry":"\(expiry)"},"auth_method":"consumer","id_token":"id-not-logged"}
    """
    return Data(raw.utf8)
  }

  func testParseValidExpiredMissingCorrupt() {
    let future = "2099-01-01T00:00:00Z"
    let session = GeminiAgySession.parseSession(tokenJSON(access: "access-a", expiry: future))
    XCTAssertEqual(session?.accessToken, "access-a")
    XCTAssertEqual(session?.authMethod, "consumer")
    XCTAssertFalse(GeminiAgySession.isExpired(session!, now: Date(timeIntervalSince1970: 1_700_000_000)))

    let expired = GeminiAgySession.parseSession(tokenJSON(access: "access-old", expiry: "2020-01-01T00:00:00Z"))
    XCTAssertTrue(GeminiAgySession.isExpired(expired!, now: Date()))

    XCTAssertNil(GeminiAgySession.parseSession(Data("{}".utf8)))
    XCTAssertNil(GeminiAgySession.parseSession(Data("not-json".utf8)))
    XCTAssertNil(GeminiAgySession.parseSession(nil))
  }

  func testGoKeyringWrappedPayloadParsesAndInvalidWrapperIsNil() {
    let future = "2099-01-01T00:00:00Z"
    let json = """
    { "auth_method": "google", "token": { "access_token": "access-a", "expiry": "\(future)" } }
    """
    let raw = Data(json.utf8)
    let base64 = Data(("go-keyring-base64:" + raw.base64EncodedString()).utf8)
    let hex = Data(("go-keyring-encoded:" + raw.map { String(format: "%02x", $0) }.joined()).utf8)

    let fromBase64 = GeminiAgySession.parseSession(base64)
    XCTAssertEqual(fromBase64?.accessToken, "access-a")
    XCTAssertEqual(fromBase64?.authMethod, "google")
    XCTAssertFalse(GeminiAgySession.isExpired(fromBase64!, now: Date(timeIntervalSince1970: 1_700_000_000)))

    let wrappedStatus = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecSuccess, data: base64, elapsed: 0)
    }, fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"))
    XCTAssertEqual(wrappedStatus.access, .available)

    let fromHex = GeminiAgySession.parseSession(hex)
    XCTAssertEqual(fromHex?.accessToken, "access-a")
    XCTAssertEqual(fromHex?.authMethod, "google")

    XCTAssertEqual(GeminiAgySession.parseSession(raw)?.accessToken, "access-a")
    XCTAssertNil(GeminiAgySession.parseSession(Data("go-keyring-base64:!!!!".utf8)))
    XCTAssertNil(GeminiAgySession.parseSession(Data("go-keyring-encoded:zz".utf8)))
    XCTAssertNil(GeminiAgySession.parseSession(Data("go-keyring-encoded:abc".utf8)))

    let bad = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecSuccess, data: Data("go-keyring-base64:!!!!".utf8), elapsed: 0)
    }, fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"))
    XCTAssertEqual(bad.access, .notSignedIn)
  }

  func testFileSourceAndRefreshViaFakeAgyModels() throws {
    let dir = URL(fileURLWithPath: Paths.configDir).appendingPathComponent("agy-test")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("token.json")
    try tokenJSON(access: "stale", expiry: "2020-01-01T00:00:00Z").write(to: file)

    var reads = 0
    let fresh = try GeminiAgySession.ensureFreshAccessToken(
      now: Date(),
      readKeychain: { nil },
      fileURL: file,
      refresh: {
        reads += 1
        try self.tokenJSON(access: "fresh-token", expiry: "2099-01-01T00:00:00Z").write(to: file)
        return "models listed"
      }
    )
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(fresh, "fresh-token")
  }

  func testKeychainPreferredOverFile() {
    let keychain = tokenJSON(access: "from-keychain", expiry: "2099-01-01T00:00:00Z")
    let file = tokenJSON(access: "from-file", expiry: "2099-01-01T00:00:00Z")
    let url = URL(fileURLWithPath: Paths.configDir).appendingPathComponent("ignored.json")
    try? file.write(to: url)
    let session = GeminiAgySession.readSession(readKeychain: { keychain }, fileURL: url)
    XCTAssertEqual(session?.accessToken, "from-keychain")
  }

  func testUnsignedRefreshDoesNotInventAToken() {
    XCTAssertThrowsError(try GeminiAgySession.ensureFreshAccessToken(
      readKeychain: { nil },
      fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"),
      refresh: { "Please sign in" }
    )) { error in
      XCTAssertEqual(error as? GeminiAgySession.SessionError, .notSignedIn)
    }
  }

  func testKeychainSuccessParsesAndNotFoundIsNotSignedIn() {
    let data = tokenJSON(access: "access-a", expiry: "2099-01-01T00:00:00Z")
    let ok = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecSuccess, data: data, elapsed: 0)
    }, fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"))
    XCTAssertEqual(ok.access, .available)
    XCTAssertTrue(ok.configured)
    XCTAssertEqual(ok.osStatus, errSecSuccess)
    XCTAssertEqual(ok.osStatusName, "errSecSuccess")
    XCTAssertNil(ok.setupHint)

    let missing = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecItemNotFound, data: nil, elapsed: 0)
    }, fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"))
    XCTAssertEqual(missing.access, .notSignedIn)
    XCTAssertFalse(missing.configured)
    XCTAssertEqual(missing.osStatus, errSecItemNotFound)
    XCTAssertEqual(missing.osStatusName, "errSecItemNotFound")
    XCTAssertEqual(missing.setupHint, GeminiAgySession.signInMessage)
    XCTAssertFalse(missing.setupHint?.contains("access-a") ?? true)
  }

  func testUserCanceledAndFastAuthFailedAreDenied() {
    let canceled = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecUserCanceled, data: nil, elapsed: 0.1)
    })
    XCTAssertEqual(canceled.access, .accessDenied)
    XCTAssertEqual(canceled.osStatusName, "errSecUserCanceled")
    XCTAssertEqual(canceled.setupHint, GeminiAgySession.accessDeniedMessage)

    let fast = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecAuthFailed, data: nil, elapsed: 0.4)
    })
    XCTAssertEqual(fast.access, .accessDenied)
    XCTAssertEqual(fast.osStatus, errSecAuthFailed)
    XCTAssertEqual(fast.osStatusName, "errSecAuthFailed")
    XCTAssertFalse(fast.setupHint?.contains("access_token") ?? true)
  }

  func testSingleStatusCallReportsPromptPendingWithoutRetrying() {
    var reads = 0
    let status = GeminiAgySession.status(readKeychain: {
      reads += 1
      return GeminiAgySession.KeychainItem(status: errSecInteractionRequired, data: nil, elapsed: 0)
    })
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(status.access, .promptPending)
    XCTAssertFalse(status.configured)
    XCTAssertEqual(status.osStatus, errSecInteractionRequired)
    XCTAssertEqual(status.osStatusName, "errSecInteractionRequired")
    XCTAssertEqual(status.setupHint, GeminiAgySession.promptPendingMessage)
    XCTAssertTrue(status.setupHint?.contains("Always Allow") ?? false)

    let slow = GeminiAgySession.status(readKeychain: {
      GeminiAgySession.KeychainItem(status: errSecAuthFailed, data: nil, elapsed: 9.951)
    })
    XCTAssertEqual(slow.access, .promptPending)
    XCTAssertEqual(slow.osStatusName, "errSecAuthFailed")
  }

  func testWaitRetriesSlowAuthFailedThenSucceeds() {
    let secret = tokenJSON(access: "from-keychain", expiry: "2099-01-01T00:00:00Z")
    var reads = 0
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    let resolution = GeminiAgySession.waitForKeychainAccess(
      waitSeconds: 30,
      readKeychain: {
        reads += 1
        if reads == 1 {
          return GeminiAgySession.KeychainItem(status: errSecAuthFailed, data: nil, elapsed: 10)
        }
        return GeminiAgySession.KeychainItem(status: errSecSuccess, data: secret, elapsed: 0.01)
      },
      fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"),
      sleep: { clock = clock.addingTimeInterval($0) },
      now: { clock }
    )
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(resolution.access, .available)
    XCTAssertEqual(resolution.session?.accessToken, "from-keychain")
    XCTAssertEqual(resolution.osStatusName, "errSecSuccess")
    XCTAssertNil(resolution.setupHint)
  }

  func testEnsureFreshDoesNotRefreshWhenPromptPendingOrDenied() {
    var refreshes = 0
    let refresh: () throws -> String = {
      refreshes += 1
      return "should-not-run"
    }
    XCTAssertThrowsError(try GeminiAgySession.ensureFreshAccessToken(
      readKeychain: {
        GeminiAgySession.KeychainItem(status: errSecAuthFailed, data: nil, elapsed: 10)
      },
      fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"),
      refresh: refresh,
      waitSeconds: 0,
      sleep: { _ in }
    )) { error in
      XCTAssertEqual(error as? GeminiAgySession.SessionError, .promptPending)
    }
    XCTAssertThrowsError(try GeminiAgySession.ensureFreshAccessToken(
      readKeychain: {
        GeminiAgySession.KeychainItem(status: errSecUserCanceled, data: nil, elapsed: 0.2)
      },
      fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-agy-token"),
      refresh: refresh,
      waitSeconds: 0,
      sleep: { _ in }
    )) { error in
      XCTAssertEqual(error as? GeminiAgySession.SessionError, .accessDenied)
    }
    XCTAssertEqual(refreshes, 0)
    let denied = GeminiAgySession.accessDeniedMessage
    let pending = GeminiAgySession.promptPendingMessage
    XCTAssertFalse(denied.contains("from-keychain"))
    XCTAssertFalse(pending.contains("from-keychain"))
    XCTAssertFalse(denied.contains("refresh_token"))
    XCTAssertFalse(pending.contains("ya29"))
  }

  func testKeychainWaitSecondsEnv() {
    XCTAssertEqual(GeminiAgySession.keychainWaitSeconds(environment: [:]), 120)
    XCTAssertEqual(GeminiAgySession.keychainWaitSeconds(environment: ["GEMINI_AGY_KEYCHAIN_WAIT_SECONDS": "0"]), 0)
    XCTAssertEqual(GeminiAgySession.keychainWaitSeconds(environment: ["GEMINI_AGY_KEYCHAIN_WAIT_SECONDS": "nope"]), 120)
    XCTAssertEqual(GeminiAgySession.osStatusName(errSecInteractionNotAllowed), "errSecInteractionNotAllowed")
    XCTAssertEqual(GeminiAgySession.osStatusName(errSecInDarkWake), "errSecInDarkWake")
  }

  func testLocateAgyHonorsEnvAndDoesNotUseAMissingPath() {
    let missing = GeminiAgySession.locateAgyCLI(
      environment: ["AGY_CLI_PATH": "/no/such/agy", "PATH": ""],
      home: "/no/home"
    )
    XCTAssertNil(missing)
    let dir = URL(fileURLWithPath: Paths.configDir).appendingPathComponent("bin")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("agy")
    FileManager.default.createFile(atPath: binary.path, contents: Data())
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let found = GeminiAgySession.locateAgyCLI(
      environment: ["AGY_CLI_PATH": binary.path, "PATH": ""],
      home: "/no/home"
    )
    XCTAssertEqual(found?.path, binary.path)
  }

  func testPreferredModelPicksFlashWithoutInventingAnID() {
    let models = [
      FetchedModel(id: "gemini-4-hydrogen", ownedBy: "Hydrogen"),
      FetchedModel(id: "gemini-3.8-flash", ownedBy: "Gemini 3.8 Flash"),
    ]
    XCTAssertEqual(GeminiAgyClient.preferredModelID(from: models), "gemini-3.8-flash")
    XCTAssertNil(GeminiAgyClient.preferredModelID(from: []))
  }

  func testModelListParsingAndHostOverride() throws {
    let json = """
    {"models":{"gemini-3.8-flash":{"displayName":"Gemini 3.8 Flash"},"tab_internal":{"displayName":"Skip","disabled":true}}}
    """.data(using: .utf8)!
    let models = try XCTUnwrap(GeminiAgyClient.parseAvailableModels(json))
    XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash"])
    XCTAssertEqual(models.first?.ownedBy, "Gemini 3.8 Flash")
    XCTAssertEqual(
      GeminiAgyClient.resolvedHost(configured: "https://generativelanguage.googleapis.com/v1beta/openai", environment: [:]),
      GeminiAgyClient.defaultHost
    )
    XCTAssertEqual(
      GeminiAgyClient.resolvedHost(configured: GeminiAgyClient.defaultHost, environment: ["CLOUD_CODE_URL": "https://cloudcode-pa.googleapis.com"]),
      "https://cloudcode-pa.googleapis.com"
    )
  }

  func testRequestTranslationAndThoughtSignatureRoundTrip() throws {
    let chat: [String: Any] = [
      "model": "gemini-3.8-flash",
      "messages": [
        ["role": "system", "content": "be brief"],
        ["role": "user", "content": "list files"],
        [
          "role": "assistant",
          "content": NSNull(),
          "tool_calls": [[
            "id": "call_1",
            "type": "function",
            "function": ["name": "shell", "arguments": "{\"cmd\":\"ls\"}"],
            "extra_content": ["google": ["thought_signature": "sig-1"]],
          ]],
        ],
        ["role": "tool", "tool_call_id": "call_1", "content": "a.txt"],
      ],
      "tools": [[
        "type": "function",
        "function": ["name": "shell", "description": "run", "parameters": ["type": "object"]],
      ]],
    ]
    let body = try GeminiAgyClient.chatToGenerateContent(chat, project: "p")
    XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash")
    XCTAssertEqual(body["project"] as? String, "p")
    let request = try XCTUnwrap(body["request"] as? [String: Any])
    let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
    let modelTurn = contents[1]
    let parts = try XCTUnwrap(modelTurn["parts"] as? [[String: Any]])
    let call = try XCTUnwrap(parts[0]["functionCall"] as? [String: Any])
    XCTAssertEqual(call["name"] as? String, "shell")
    XCTAssertEqual(parts[0]["thoughtSignature"] as? String, "sig-1")

    let response = """
    {"response":{"candidates":[{"content":{"role":"model","parts":[{"text":"done","thoughtSignature":"parent-sig"},{"functionCall":{"name":"shell","id":"call_2","args":{"cmd":"pwd"}}}]}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4,"totalTokenCount":7}}}
    """.data(using: .utf8)!
    let completion = try XCTUnwrap(GeminiAgyClient.cloudCodeToChatCompletion(response, model: "gemini-3.8-flash"))
    let message = try XCTUnwrap(((completion["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])
    XCTAssertEqual(message["content"] as? String, "done")
    let tools = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
    let extra = try XCTUnwrap(tools[0]["extra_content"] as? [String: Any])
    let google = try XCTUnwrap(extra["google"] as? [String: Any])
    XCTAssertEqual(google["thought_signature"] as? String, "parent-sig")
  }

  func testSignatureOnParentDeltaIsCopiedOntoFunctionCall() throws {
    let sse = """
    data: {"response":{"candidates":[{"content":{"thought_signature":"delta-sig","parts":[{"functionCall":{"name":"shell","args":{}}}]}}]}}

    """
    let completion = try XCTUnwrap(GeminiAgyClient.cloudCodeToChatCompletion(Data(sse.utf8), model: "m"))
    let message = try XCTUnwrap(((completion["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])
    let tools = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
    let google = try XCTUnwrap((tools[0]["extra_content"] as? [String: Any])?["google"] as? [String: Any])
    XCTAssertEqual(google["thought_signature"] as? String, "delta-sig")
  }

  func testMissingSignatureRefusesBeforeSend() {
    let chat: [String: Any] = [
      "model": "gemini-3.8-flash",
      "stream": false,
      "messages": [[
        "role": "assistant",
        "tool_calls": [[
          "id": "call_x",
          "type": "function",
          "function": ["name": "shell", "arguments": "{}"],
        ]],
      ]],
    ]
    var calls = 0
    XCTAssertThrowsError(try GeminiAgyClient.forwardChat(
      chatBody: chat,
      environment: [:],
      userAgent: "antigravity/cli/test",
      ensureToken: { _ in "token" },
      loadProject: false,
      perform: { _ in
        calls += 1
        return (200, [:], Data("{}".utf8))
      }
    )) { error in
      XCTAssertEqual(error as? GeminiAgyClient.ClientError, .thoughtSignature)
    }
    XCTAssertEqual(calls, 0)
  }

  func testUnsignedDoesNotSend() {
    var calls = 0
    XCTAssertThrowsError(try GeminiAgyClient.forwardChat(
      chatBody: ["model": "gemini-3.8-flash", "messages": [["role": "user", "content": "hi"]], "stream": false],
      environment: [:],
      ensureToken: { _ in throw GeminiAgySession.SessionError.notSignedIn },
      loadProject: false,
      perform: { _ in
        calls += 1
        return (200, [:], Data())
      }
    )) { error in
      XCTAssertEqual(error as? GeminiAgyClient.ClientError, .notSignedIn)
    }
    XCTAssertEqual(calls, 0)
  }

  func testClassifiedErrorsAndNoAPIKeyHeader() throws {
    XCTAssertEqual(
      GeminiAgyClient.classify(status: 401, data: Data(), headers: [:], model: "m"),
      .notSignedIn
    )
    XCTAssertEqual(
      GeminiAgyClient.classify(status: 403, data: Data("denied".utf8), headers: [:], model: "m"),
      .notSignedIn
    )
    XCTAssertEqual(
      GeminiAgyClient.classify(status: 429, data: Data(), headers: ["Retry-After": "12"], model: "m"),
      .rateLimited(retryAfter: "12")
    )
    XCTAssertEqual(
      GeminiAgyClient.classify(status: 404, data: Data("model not found".utf8), headers: [:], model: "gemini-3.8-flash"),
      .modelNotFound("gemini-3.8-flash")
    )
    XCTAssertEqual(
      GeminiAgyClient.classify(status: 400, data: Data("missing thought_signature".utf8), headers: [:], model: "m"),
      .thoughtSignature
    )

    let response = """
    {"response":{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}}
    """.data(using: .utf8)!
    var captured: URLRequest?
    let result = try GeminiAgyClient.forwardChat(
      chatBody: ["model": "gemini-3.8-flash", "stream": false, "messages": [["role": "user", "content": "hi"]]],
      baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
      environment: [:],
      userAgent: "antigravity/cli/1.5.18",
      ensureToken: { _ in "access-token" },
      loadProject: false,
      perform: { request in
        captured = request
        return (200, [:], response)
      }
    )
    let request = try XCTUnwrap(captured)
    XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity/cli/1.5.18")
    XCTAssertEqual(request.url?.absoluteString, "https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent")
    XCTAssertFalse(result.isStream)
  }

  func testFetcherUsesCloudCodeNotAPIKeyHeader() async throws {
    let provider = ProviderPreset.gemini.providerConfig(apiKey: "nope")
    let payload = #"{"models":{"gemini-3.8-flash":{"displayName":"Gemini 3.8 Flash"}}}"#.data(using: .utf8)!
    var sawAPIKey = false
    let models = try await ProviderModelFetcher.fetchGeminiAgyModels(
      baseURL: provider.base_url,
      ensureToken: { _ in "access-token" },
      perform: { request in
        if request.value(forHTTPHeaderField: "api-key") != nil { sawAPIKey = true }
        return (200, [:], payload)
      }
    )
    XCTAssertFalse(sawAPIKey)
    XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash"])
  }
}
