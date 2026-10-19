import Foundation
import SwapCore

// Terminal harness for SwapCore; run without arguments for the command list.
let service = SwapService()
let args = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: claude-van-dam-cli <command>
  list                 accounts with cached usage (no network)
  refresh              fetch due usage, then list
  add                  save the login Claude Code has now
  switch <n>           make account n Claude Code's login
  rotate               switch to the next account
  best                 switch to the account with the most headroom
  auto [--threshold N] [--go]
                       what auto-switch would do now; --go actually switches
  remove <n>           delete account n's saved login
  export <file>        write every account (with its login) to a file
  import <file>        add accounts from an export
"""

func pct(_ w: UsageWindow?) -> String { w.map { "\(Int($0.pct.rounded()))%" } ?? "—" }

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func slot(_ i: Int) -> Int {
    guard args.count > i, let n = Int(args[i]) else { fail(usage) }
    return n
}

func file(_ i: Int) -> URL {
    guard args.count > i else { fail(usage) }
    return URL(fileURLWithPath: args[i])
}

do {
    switch args.first ?? "list" {
    case "list", "refresh":
        let snap = args.first == "refresh" ? try service.refresh() : try service.snapshot()
        for a in snap.accounts {
            let u = a.displayUsage
            let age = a.fetchedAt.map { "\(Int(Date().timeIntervalSince($0)))s" } ?? "-"
            print("\(a.active ? "*" : " ") \(a.number) \(a.email)  5h \(pct(u?.fiveHour))  7d \(pct(u?.sevenDay))  status=\(a.status.rawValue) stale=\(a.isStale) age=\(age)")
            if let w = u?.sevenDay {
                print("    7d expected=\(w.expectedPct.map { "\($0)" } ?? "-") ahead=\(w.aheadOfPace.map { "\($0)" } ?? "-") willLast=\(w.willLastToReset.map { "\($0)" } ?? "-") exhaust=\(w.projectedExhaustionAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
            }
        }
    case "switch":
        let r = try service.switchTo(slot(1))
        print("switched=\(r.switched) from=\(r.from.map(String.init) ?? "-") to=\(r.to.map(String.init) ?? "-") reason=\(r.reason)")
    case "export":
        print("exported \(try service.exportAccounts(to: file(1)))")
    case "import":
        let r = try service.importAccounts(from: file(1))
        print("imported=\(r.imported) replaced=\(r.replaced) skipped=\(r.skipped) liveReplaced=\(r.liveReplaced)")
    case "remove":
        print("removed \(try service.removeAccount(slot(1)))")
    case "auto":
        var policy = AutoSwitch.Policy()
        if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let v = Double(args[i + 1]) { policy.threshold = v }
        let r = try service.autoSwitch(AutoSwitchSession(), policy: policy, dryRun: !args.contains("--go"))
        print("decision=\(r.decision) burnRate=\(String(format: "%.4f", r.burnRate))%/s switched=\(r.switched) failure=\(r.failure ?? "-")")
    case "add":
        let r = try service.addCurrent()
        print("slot=\(r.number) email=\(r.email) created=\(r.created) credentialChanged=\(r.credentialChanged)")
    case "rotate":
        let r = try service.rotate()
        print("switched=\(r.switched) to=\(r.to.map(String.init) ?? "-") reason=\(r.reason)")
    case "best":
        let r = try service.best()
        print("switched=\(r.switched) to=\(r.to.map(String.init) ?? "-") reason=\(r.reason)")
    case "help", "-h", "--help":
        print(usage)
    default:
        fail(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
