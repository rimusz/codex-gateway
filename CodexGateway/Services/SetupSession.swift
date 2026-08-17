import Foundation

/// In-memory first-run skip. Close or Skip hides setup until the next launch.
enum SetupSession {
  static var skippedThisLaunch = false
}
