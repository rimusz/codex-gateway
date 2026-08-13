import XCTest
@testable import CodexGateway

final class CustomProviderExampleTests: XCTestCase {
  func testSparkDeepSeekExampleConstants() {
    XCTAssertEqual(CustomProviderExample.sparkProviderID, "spark-deepseek")
    XCTAssertEqual(CustomProviderExample.sparkDisplayName, "Spark DeepSeek")
    XCTAssertEqual(CustomProviderExample.sparkBaseURL, "http://spark:8001/v1")
    XCTAssertEqual(CustomProviderExample.sparkAPIKey, "not-needed")
    XCTAssertEqual(CustomProviderExample.sparkSuggestedModel, "deepseek-v4-flash")
    XCTAssertFalse(CustomProviderExample.dummyKeyHelp.isEmpty)
    XCTAssertTrue(CustomProviderExample.sparkExampleSummary.contains("Spark"))
  }
}
