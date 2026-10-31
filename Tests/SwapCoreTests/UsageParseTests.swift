import XCTest
@testable import SwapCore

final class UsageParseTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    func testNullFiveHourMeansNoSessionLimit() {
        let stored = UsageFetcher.parse(json("""
        {"five_hour": null, "seven_day": {"utilization": 58.0, "resets_at": "2026-11-01T16:00:00+00:00"}}
        """))
        XCTAssertEqual(stored?["five_hour_unlimited"] as? Bool, true)
        let u = UsageParser.usage(stored, fetchedAt: nil)
        XCTAssertNil(u?.fiveHour)
        XCTAssertEqual(u?.sessionUnlimited, true)
        XCTAssertEqual(u?.sevenDay?.pct, 58)
    }

    func testIdleFiveHourIsStillALimit() {
        let stored = UsageFetcher.parse(json("""
        {"five_hour": {"utilization": 0, "resets_at": null}, "seven_day": {"utilization": 0, "resets_at": null}}
        """))
        let u = UsageParser.usage(stored, fetchedAt: nil)
        XCTAssertEqual(u?.fiveHour?.pct, 0)
        XCTAssertEqual(u?.sessionUnlimited, false)
    }

    func testMissingFiveHourIsUnknownNotUnlimited() {
        let stored = UsageFetcher.parse(json(#"{"seven_day": {"utilization": 10}}"#))
        XCTAssertEqual(UsageParser.usage(stored, fetchedAt: nil)?.sessionUnlimited, false)
    }

    func testPlanName() {
        XCTAssertEqual(UsageFetcher.planName(json(#"{"organization": {"plan_display_name": "Ultra", "organization_type": "claude_max"}}"#)), "Ultra")
        XCTAssertEqual(UsageFetcher.planName(json(#"{"organization": {"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"}}"#)), "Ultra")
        XCTAssertEqual(UsageFetcher.planName(json(#"{"organization": {"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"}}"#)), "Max")
        XCTAssertEqual(UsageFetcher.planName(json(#"{"organization": {"organization_type": "claude_pro"}}"#)), "Pro")
        XCTAssertNil(UsageFetcher.planName(json(#"{"organization": {"organization_type": "something_new"}}"#)))
    }
}
