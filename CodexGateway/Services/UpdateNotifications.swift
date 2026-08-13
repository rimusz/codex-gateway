import Foundation

extension Notification.Name {
  static let codexGatewayUpdateAvailable = Notification.Name("CodexGatewayUpdateAvailable")
  static let codexGatewayUpdateStateChanged = Notification.Name("CodexGatewayUpdateStateChanged")
  static let codexGatewayUpdaterPhaseChanged = Notification.Name("CodexGatewayUpdaterPhaseChanged")
  static let codexGatewayPrepareForShutdown = Notification.Name("CodexGatewayPrepareForShutdown")
  static let codexGatewayStatusChanged = Notification.Name("CodexGatewayStatusChanged")
  static let codexGatewayCursorBridgeRuntimeStatusDidChange =
    Notification.Name("CodexGateway.cursorBridgeRuntimeStatusDidChange")
}
