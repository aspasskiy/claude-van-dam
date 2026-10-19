import XCTest
@testable import SwapCore

final class AutoSwitchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func c(_ n: Int, _ b: Double?, eligible: Bool = true, week: TimeInterval? = nil) -> AutoSwitch.Candidate {
        AutoSwitch.Candidate(number: n, email: "a\(n)@x.io", binding: b,
                             weekResetsAt: week.map { now.addingTimeInterval($0) }, eligible: eligible)
    }
    func decide(_ active: AutoSwitch.Candidate, _ others: [AutoSwitch.Candidate], rate: Double = 0,
                threshold: Double = 95, lastSwitch: Date? = nil) -> AutoSwitch.Decision {
        AutoSwitch.decide(active: active, others: others, burnRate: rate,
                          policy: AutoSwitch.Policy(threshold: threshold), lastSwitch: lastSwitch, now: now)
    }

    func testStaysBelowThreshold() {
        XCTAssertEqual(decide(c(1, 80), [c(2, 0)]), .stay)
    }
    func testUnknownActiveUsageStays() {
        XCTAssertEqual(decide(c(1, nil), [c(2, 0)]), .stay)
    }
    func testSwitchesToMostHeadroom() {
        XCTAssertEqual(decide(c(1, 95), [c(2, 60), c(3, 20), c(4, 40)]),
                       .switchTo(3, email: "a3@x.io", fromBinding: 95, projected: false))
    }
    func testTargetMustClearHysteresis() {
        // 86 > 95 - 10: switching there would just re-trigger.
        XCTAssertEqual(decide(c(1, 96), [c(2, 86)]), .exhausted(recovery: nil))
        XCTAssertEqual(decide(c(1, 96), [c(2, 85)]), .switchTo(2, email: "a2@x.io", fromBinding: 96, projected: false))
    }
    func testSkipsIneligibleAndUnknown() {
        XCTAssertEqual(decide(c(1, 97), [c(2, 0, eligible: false), c(3, nil), c(4, 50)]),
                       .switchTo(4, email: "a4@x.io", fromBinding: 97, projected: false))
    }
    func testTieGoesToSoonestWeeklyReset() {
        XCTAssertEqual(decide(c(1, 95), [c(2, 30, week: 5 * 86400), c(3, 30, week: 86400)]),
                       .switchTo(3, email: "a3@x.io", fromBinding: 95, projected: false))
    }
    func testBurnRateTriggersEarly() {
        // 88% rising 0.1%/s → 103% within the 150 s lookahead.
        XCTAssertEqual(decide(c(1, 88), [c(2, 10)], rate: 0.1),
                       .switchTo(2, email: "a2@x.io", fromBinding: 88, projected: true))
        // Same speed but far from the threshold: wait.
        XCTAssertEqual(decide(c(1, 70), [c(2, 10)], rate: 0.1), .stay)
    }
    func testCooldownUnlessAtHardLimit() {
        let recent = now.addingTimeInterval(-60)
        XCTAssertEqual(decide(c(1, 96), [c(2, 10)], lastSwitch: recent), .cooldown)
        XCTAssertEqual(decide(c(1, 100), [c(2, 10)], lastSwitch: recent),
                       .switchTo(2, email: "a2@x.io", fromBinding: 100, projected: false))
    }
    func testAtHardLimitTakesAnyRoom() {
        XCTAssertEqual(decide(c(1, 100), [c(2, 92)]), .switchTo(2, email: "a2@x.io", fromBinding: 100, projected: false))
        XCTAssertEqual(decide(c(1, 100), [c(2, 100)]), .exhausted(recovery: nil))
    }
    func testNinetyNineThreshold() {
        XCTAssertEqual(decide(c(1, 98), [c(2, 10)], threshold: 99), .stay)
        XCTAssertEqual(decide(c(1, 99), [c(2, 10)], threshold: 99),
                       .switchTo(2, email: "a2@x.io", fromBinding: 99, projected: false))
    }
}
