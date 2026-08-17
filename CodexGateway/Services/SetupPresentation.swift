import Foundation

enum SetupPresentation {
  static let forceShowArgument = "--setup"
  static let defaultSeedProviderID = "opencode"
  static let defaultSeedBaseURL = "https://opencode.ai/zen/go/v1"

  static func isPlaceholderProvider(_ provider: ProviderConfig) -> Bool {
    let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return true }
    let display = (provider.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return name == defaultSeedProviderID
      && provider.api_key.isEmpty
      && display.isEmpty
      && provider.base_url == defaultSeedBaseURL
  }

  static func installedProviders(from providers: [ProviderConfig]) -> [ProviderConfig] {
    providers.filter { !isPlaceholderProvider($0) }
  }

  static func shouldShow(
    providers: [ProviderConfig],
    models: [CatalogModel],
    skippedThisLaunch: Bool,
    isMigrating: Bool
  ) -> Bool {
    guard !isMigrating, !skippedThisLaunch else { return false }
    return installedProviders(from: providers).isEmpty && models.isEmpty
  }

  static func shouldForceShow(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
    arguments.contains(forceShowArgument)
  }
}
