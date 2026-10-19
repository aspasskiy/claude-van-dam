import Foundation

/// Made-up accounts for screenshots (`--demo`): no Keychain, files or network.
public enum Demo {
    public static func snapshot(now: Date = Date()) -> Snapshot {
        func window(_ pct: Double, resetsIn hours: Double, name: String? = nil) -> UsageWindow {
            UsageWindow(name: name, pct: pct, resetsAt: now.addingTimeInterval(hours * 3600),
                        expectedPct: nil, aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil)
        }
        func usage(_ five: Double, _ fiveIn: Double, _ week: Double, _ weekIn: Double) -> Usage {
            Usage(fiveHour: window(five, resetsIn: fiveIn), sevenDay: window(week, resetsIn: weekIn), scoped: [], spend: nil)
        }
        func account(_ n: Int, _ email: String, active: Bool = false, _ u: Usage?,
                     status: UsageStatus = .ok, disabled: Bool = false) -> Account {
            Account(number: n, email: email, organizationName: "", organizationUuid: "demo-\(n)", alias: nil,
                    disabled: disabled, active: active, status: status, usage: u, lastGoodUsage: u,
                    fetchedAt: now.addingTimeInterval(-90))
        }
        return Snapshot(accounts: [
            account(1, "work@example.com", active: true, usage(62, 2.3, 71, 52)),
            account(2, "personal@example.com", usage(8, 4.6, 34, 101)),
            account(3, "side@example.com", usage(100, 1.2, 88, 19)),
        ])
    }
}
