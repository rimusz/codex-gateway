import XCTest
@testable import CodexGateway

/// Points `Paths` at one temporary directory for the whole test bundle.
///
/// Test classes must subclass this. `class setUp` installs the directory before
/// any test in that class runs. The directory stays in place until XCTest's
/// bundle tearDown (`testBundleDidFinish`) so a store that resolved `Paths`
/// mid-suite cannot fall back to the real home between classes.
///
/// Per-test files that a case creates itself are still removed in that case's
/// `tearDown`.
class CodexGatewayTestCase: XCTestCase {
  private static let lock = NSLock()
  private static var root: URL?
  private static var observer: PathsIsolationObserver?

  override class func setUp() {
    super.setUp()
    installIsolation()
  }

  fileprivate static func installIsolation() {
    lock.lock()
    defer { lock.unlock() }
    if root == nil {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexGatewayTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      root = url
      Paths.rootDirectoryOverride = url.path
    }
    if observer == nil {
      let created = PathsIsolationObserver()
      XCTestObservationCenter.shared.addTestObserver(created)
      observer = created
    }
  }

  /// Removes the suite directory. Safe to call more than once.
  static func tearDownIsolation() {
    lock.lock()
    let url = root
    root = nil
    Paths.rootDirectoryOverride = nil
    lock.unlock()
    if let url {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

final class PathsIsolationObserver: NSObject, XCTestObservation {
  func testBundleDidFinish(_ testBundle: Bundle) {
    CodexGatewayTestCase.tearDownIsolation()
  }
}
