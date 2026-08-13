import Foundation

/// Fill-in examples for **Settings → Add custom provider** (not built-in presets).
enum CustomProviderExample {
  /// NVIDIA DGX Spark serving DeepSeek over Tailscale / LAN. Hostname is machine-specific,
  /// so this is an editor example rather than a `ProviderPreset`. Spark ignores the dummy key;
  /// Fetch still requires one because `http://spark:…` is not treated as loopback.
  static let sparkProviderID = "spark-deepseek"
  static let sparkDisplayName = "Spark DeepSeek"
  static let sparkBaseURL = "http://spark:8001/v1"
  static let sparkAPIKey = "not-needed"
  static let sparkSuggestedModel = "deepseek-v4-flash"

  static let dummyKeyHelp =
    "Use a dummy key. Fetch models skips the key only for loopback URLs (localhost, 127.0.0.1). LAN or Tailscale hosts like http://spark:… need a dummy key so Fetch is enabled. Spark ignores it."

  static let sparkExampleSummary =
    "Example — local NVIDIA DGX Spark (one model at a time). DeepSeek on :8001:"
}
