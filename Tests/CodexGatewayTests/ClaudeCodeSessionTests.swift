import XCTest
@testable import CodexGateway

final class ClaudeCodeSessionTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-code-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func credsURL(_ name: String = "credentials.json") -> URL {
    tempDir.appendingPathComponent(name)
  }

  func testParseClaudeAiOauthFixture() {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-fake","expiresAt":1893456000000}}"#.utf8)
    let session = ClaudeCodeSession.parseCredentials(data)
    XCTAssertEqual(session?.accessToken, "sk-ant-oat-fake")
    XCTAssertEqual(session?.expiresAt?.timeIntervalSince1970, 1_893_456_000)
    XCTAssertTrue(session?.looksLikeOAuthAccessToken == true)
  }

  func testParseSnakeCaseAccessToken() {
    let data = Data(#"{"claude_ai_oauth":{"access_token":"sk-ant-oat-fake","expires_at":1893456000}}"#.utf8)
    XCTAssertEqual(ClaudeCodeSession.parseCredentials(data)?.accessToken, "sk-ant-oat-fake")
  }

  func testParseRejectsEmptyObject() {
    XCTAssertNil(ClaudeCodeSession.parseCredentials(Data("{}".utf8)))
    XCTAssertNil(ClaudeCodeSession.parseCredentials(Data("not-json".utf8)))
  }

  func testLoadSessionPrefersEnvThenFile() throws {
    let missing = credsURL("missing.json")
    let file = credsURL()
    try Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-file"}}"#.utf8).write(to: file)

    let fromFile = ClaudeCodeSession.loadSession(
      credentialsURL: file,
      legacyURL: missing,
      environment: [:],
      readKeychain: { nil }
    )
    XCTAssertEqual(fromFile?.accessToken, "sk-ant-oat-file")

    let fromEnv = ClaudeCodeSession.loadSession(
      credentialsURL: file,
      legacyURL: missing,
      environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-env"],
      readKeychain: { Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-keychain"}}"#.utf8) }
    )
    XCTAssertEqual(fromEnv?.accessToken, "sk-ant-oat-env")
  }

  func testLoadSessionReadsKeychainFixtureWhenFilesMissing() {
    let missing = credsURL("missing.json")
    let session = ClaudeCodeSession.loadSession(
      credentialsURL: missing,
      legacyURL: missing,
      environment: [:],
      readKeychain: { Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-keychain"}}"#.utf8) }
    )
    XCTAssertEqual(session?.accessToken, "sk-ant-oat-keychain")
  }

  func testStatusExpiredSession() throws {
    let expired = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000
    let file = credsURL()
    try Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-fake","expiresAt":\#(expired)}}"#.utf8).write(to: file)
    let status = ClaudeCodeSession.status(
      credentialsURL: file,
      legacyURL: credsURL("legacy.json"),
      environment: [:],
      readKeychain: { nil }
    )
    XCTAssertFalse(status.configured)
    XCTAssertTrue(status.setupHint?.contains("expired") == true)
  }

  func testLooksLikeOAuthAccessToken() {
    XCTAssertTrue(ClaudeCodeSession.looksLikeOAuthAccessToken("sk-ant-oat-fake"))
    XCTAssertTrue(ClaudeCodeSession.looksLikeOAuthAccessToken("  SK-ANT-OAT01-fake  "))
    XCTAssertFalse(ClaudeCodeSession.looksLikeOAuthAccessToken("sk-ant-test"))
    XCTAssertFalse(ClaudeCodeSession.looksLikeOAuthAccessToken(""))
  }

  func testConsoleKeyRejectionKeepsModesSeparate() {
    XCTAssertNil(ClaudeCodeSession.consoleKeyRejectionMessage(for: "sk-ant-test"))
    XCTAssertNil(ClaudeCodeSession.consoleKeyRejectionMessage(for: ""))
    let message = ClaudeCodeSession.consoleKeyRejectionMessage(for: "sk-ant-oat-fake")
    XCTAssertTrue(message?.contains("Anthropic (Claude Code)") == true)
    XCTAssertTrue(message?.contains("do not paste") == true)
  }
}
