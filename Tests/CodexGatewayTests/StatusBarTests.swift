import XCTest
@testable import CodexGateway

final class StatusBarTests: XCTestCase {
    func testAppStatusAccessibilityLabels() {
        XCTAssertEqual(AppStatus.idle.accessibilityLabel, "Ready")
        XCTAssertEqual(AppStatus.loading.accessibilityLabel, "Loading")
        XCTAssertEqual(AppStatus.error.accessibilityLabel, "Error")
        XCTAssertEqual(AppStatus.offline.accessibilityLabel, "Offline")
    }

    func testRestartCodexRequiresConfirmation() {
        var restartCount = 0

        RestartCodexGate.restartIfConfirmed(confirm: { false }, restart: { restartCount += 1 })
        XCTAssertEqual(restartCount, 0)

        RestartCodexGate.restartIfConfirmed(confirm: { true }, restart: { restartCount += 1 })
        XCTAssertEqual(restartCount, 1)
    }

    func testRestartConfirmationCopyMentionsCodexDesktop() {
        XCTAssertEqual(RestartCodexConfirmation.title, "Restart Codex?")
        XCTAssertTrue(RestartCodexConfirmation.message.contains("Codex Desktop"))
        XCTAssertTrue(RestartCodexConfirmation.message.contains("CLI daemon"))
        XCTAssertTrue(RestartCodexConfirmation.message.contains("provider and model configuration"))
    }

    func testCLIDaemonRestartUsesResolvedCodexBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cli-daemon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("codex")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertEqual(
            CodexCLIDaemon.resolve(candidates: [binary.path], path: ""),
            binary.path
        )
        XCTAssertNil(CodexCLIDaemon.resolve(candidates: [root.appendingPathComponent("missing").path], path: ""))

        var launched: (String, [String])?
        CodexCLIDaemon.restart(
            executable: { binary.path },
            runner: { launched = ($0, $1) }
        )
        XCTAssertEqual(launched?.0, binary.path)
        XCTAssertEqual(launched?.1, CodexCLIDaemon.restartArguments)

        var didRun = false
        CodexCLIDaemon.restart(
            executable: { nil },
            runner: { _, _ in didRun = true }
        )
        XCTAssertFalse(didRun)

        CodexCLIDaemon.restart(
            executable: { binary.path },
            runner: { _, _ in throw CocoaError(.fileNoSuchFile) }
        )
    }

    func testUpdateMenuTitleReflectsActionableUpdate() {
        XCTAssertEqual(StatusBarMenuCopy.updateMenuTitle(hasActionableUpdate: false), "Check for Updates…")
        XCTAssertEqual(StatusBarMenuCopy.updateMenuTitle(hasActionableUpdate: true), "Upgrade Available…")
    }

    func testDoctorMenuTitle() {
        XCTAssertEqual(StatusBarMenuCopy.doctorTitle, "Doctor…")
    }

    func testGatewayStateLabelForEachStatus() {
        XCTAssertEqual(StatusBarMenuCopy.gatewayStateLabel(.idle), "Running")
        XCTAssertEqual(StatusBarMenuCopy.gatewayStateLabel(.loading), "Starting…")
        XCTAssertEqual(StatusBarMenuCopy.gatewayStateLabel(.error), "Error")
        XCTAssertEqual(StatusBarMenuCopy.gatewayStateLabel(.offline), "Offline")
    }

    func testGatewayStatusTitleIncludesStateAndAddress() {
        XCTAssertEqual(
            StatusBarMenuCopy.gatewayStatusTitle(.idle, host: "127.0.0.1", port: 8765),
            "Running · 127.0.0.1:8765"
        )
        XCTAssertEqual(
            StatusBarMenuCopy.gatewayStatusTitle(.offline, host: "127.0.0.1", port: 8765),
            "Offline · 127.0.0.1:8765"
        )
    }

    func testGatewayStatusTitleDefaultsToConfiguredAddress() {
        let title = StatusBarMenuCopy.gatewayStatusTitle(.idle)
        XCTAssertTrue(title.contains("\(Paths.gatewayHost):\(Paths.gatewayPort)"))
    }

    func testCursorBridgeStatusTitleHiddenWhenNotEnabled() {
        XCTAssertNil(
            StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: false, status: .running)
        )
        XCTAssertNil(
            StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: false, status: .stopped)
        )
    }

    func testCursorBridgeStatusTitleWhenEnabled() {
        XCTAssertEqual(
            StatusBarMenuCopy.cursorBridgeStatusTitle(
                isEnabled: true,
                status: .running,
                host: "127.0.0.1",
                port: 18788
            ),
            "Cursor Bridge · 127.0.0.1:18788"
        )
        XCTAssertEqual(
            StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: true, status: .starting),
            "Cursor Bridge · Starting…"
        )
        XCTAssertEqual(
            StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: true, status: .stopped),
            "Cursor Bridge · Stopped"
        )
        XCTAssertEqual(
            StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: true, status: .failed("boom")),
            "Cursor Bridge · Error"
        )
    }

    func testCursorBridgeStatusTitleDefaultsToManagedAddress() {
        let title = StatusBarMenuCopy.cursorBridgeStatusTitle(isEnabled: true, status: .running)
        XCTAssertEqual(
            title,
            "Cursor Bridge · \(Paths.gatewayHost):\(CursorBridgeRuntime.managedPort)"
        )
    }
}
