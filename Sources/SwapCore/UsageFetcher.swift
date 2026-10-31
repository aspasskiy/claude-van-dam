import Foundation

/// Usage collection through the shared usage store (reserve → fetch → record). Inactive slots with an expired
/// token are refreshed through the consume gate; the active
/// slot never is (Claude Code owns it), but its rotated token is copied into
/// the slot backup once its owner is proven.
struct UsageFetcher {
    let paths: Paths
    var creds: Credentials { Credentials(paths: paths) }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let claimLease: Double = 90
    /// How long a plan name from the profile endpoint is trusted.
    static let planTTL: Double = 12 * 3600

    enum Outcome {
        case success([String: Any]?, plan: String? = nil)
        case failure(kind: String, retryAfter: Double?, struckFp: String? = nil)
    }

    /// Refresh failures that carry their own kind and skip the usage call
    static let deterministicRefreshErrors: Set<String> = ["store-unmirrored", "invalid_client", "consume-busy", "stash-unreadable"]
    static let permanentAuthErrors: Set<String> = ["invalid_grant", "no_refresh_token"]

    /// One collection pass: claims eligible rows, fetches them, records results.
    func collect() {
        guard paths.unsupportedEnvironment == nil, let roster = try? Roster.load(paths) else { return }
        let liveSlot = roster.slot(for: LiveIdentity.load(paths))
        let wanted = roster.sequence.filter { roster.entries[$0].map { $0.kind == "oauth" } ?? false }
        guard let claims = reserve(wanted, roster: roster), !claims.isEmpty else { return }
        let rows = UsageRow.loadAll(paths)
        let now = Date().timeIntervalSince1970

        var outcomes: [Int: Outcome] = [:]
        for (i, n) in claims.keys.sorted().enumerated() {
            guard let e = roster.entries[n] else { continue }
            if i > 0 { usleep(250_000) } // stagger
            let wantPlan = rows[n].map { now - ($0.planFetchedAt ?? 0) > Self.planTTL } ?? true
            if n == liveSlot {
                guard let cred = creds.readLive().string, let token = Credentials.accessToken(cred), !token.isEmpty,
                      !Credentials.isExpired(cred) else {
                    continue // sentinel-only: release the claim without touching the row
                }
                let outcome = fetch(token: token, withPlan: wantPlan)
                outcomes[n] = outcome
                if case .success = outcome { resyncBackup(n, e, live: cred) }
            } else {
                guard let cred = creds.readSlot(n, e.email).string else { continue }
                outcomes[n] = fetchInactive(n, e, cred, withPlan: wantPlan)
            }
        }
        record(claims: claims, outcomes: outcomes, roster: roster, liveSlot: liveSlot)
    }

    /// `try_fetch_usage_for_account` for an inactive slot.
    private func fetchInactive(_ n: Int, _ e: Roster.Entry, _ cred: String, withPlan: Bool) -> Outcome? {
        let refresher = TokenRefresher(paths: paths)
        var working = cred
        let hasRefreshToken = !((Credentials.oauthObject(cred)?["refreshToken"] as? String) ?? "").isEmpty
        if hasRefreshToken, Credentials.isExpired(working) {
            let r = refresher.consume(n, email: e.email, snapshot: working)
            if let c = r.credential {
                working = c
            } else if let err = r.error {
                if Self.permanentAuthErrors.contains(err) {
                    return .failure(kind: err, retryAfter: nil, struckFp: r.consumedFp ?? Credentials.fingerprint(working))
                }
                if err == "active" { return nil }
                if Self.deterministicRefreshErrors.contains(err) { return .failure(kind: err, retryAfter: nil) }
                // transient: try the expired token anyway
            }
        }
        guard let token = Credentials.accessToken(working), !token.isEmpty else {
            return .failure(kind: "no-access-token", retryAfter: nil)
        }
        let first = fetch(token: token, withPlan: withPlan)
        guard case .failure("http-401", _, _) = first, hasRefreshToken else { return first }

        let r = refresher.consume(n, email: e.email, snapshot: working)
        guard let c = r.credential else {
            let err = r.error ?? "refresh-failed"
            if Self.permanentAuthErrors.contains(err) {
                return .failure(kind: err, retryAfter: nil, struckFp: r.consumedFp ?? Credentials.fingerprint(working))
            }
            if err == "active" { return nil }
            return .failure(kind: Self.deterministicRefreshErrors.contains(err) ? err : "refresh-failed", retryAfter: nil)
        }
        guard let fresh = Credentials.accessToken(c), !fresh.isEmpty else { return .failure(kind: "refresh-failed", retryAfter: nil) }
        return fetch(token: fresh, withPlan: withPlan)
    }

    static func expiresAt(_ credential: String) -> Double {
        (Credentials.oauthObject(credential)?["expiresAt"] as? NSNumber)?.doubleValue ?? 0
    }

    /// `_resync_rotated_backup`: Claude Code rotated the
    /// active token, so the slot backup holds a retired generation. Copy the live
    /// one over once the profile endpoint proves it is this slot's account.
    private func resyncBackup(_ n: Int, _ e: Roster.Entry, live: String) {
        guard case .value(let backup) = creds.readSlot(n, e.email),
              let liveFp = Credentials.fingerprint(live), liveFp != Credentials.fingerprint(backup),
              // Only ever forward: a plaintext-file fallback may hold an older generation.
              Self.expiresAt(live) > Self.expiresAt(backup),
              let token = Credentials.accessToken(live),
              Adder.owns(token: token, email: e.email, organizationUuid: e.organizationUuid, accountUuid: e.uuid) == true
        else { return }
        guard let lock = try? FileLock(paths.globalLock) else { return }
        defer { lock.release() }
        // Nothing may have moved while we were on the network.
        guard let roster = try? Roster.load(paths), roster.slot(for: LiveIdentity.load(paths)) == n,
              let liveNow = creds.readLive().string, Credentials.fingerprint(liveNow) == liveFp,
              case .value(let backupNow) = creds.readSlot(n, e.email),
              Credentials.fingerprint(backupNow) == Credentials.fingerprint(backup) else { return }
        try? creds.writeSlot(n, e.email, liveNow)
    }

    // MARK: Network

    /// `withPlan` also reads the plan name from the profile endpoint (same token),
    /// only after the usage call succeeds.
    func fetch(token: String, withPlan: Bool = false) -> Outcome {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let response = HTTP.send(req)
        if let error = response.error {
            return .failure(kind: error.code == .timedOut ? "timeout" : "network", retryAfter: nil)
        }
        guard let http = response.http else { return .failure(kind: "network", retryAfter: nil) }
        guard http.statusCode == 200 else {
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .failure(kind: "http-\(http.statusCode)", retryAfter: ra)
        }
        guard let json = response.json else { return .failure(kind: "bad-response", retryAfter: nil) }
        let plan = withPlan ? Adder.fetchProfileJSON(token).flatMap(Self.planName) : nil
        return .success(Self.parse(json), plan: plan)
    }

    /// `/api/oauth/profile` → "Ultra", "Max", "Pro", …: `plan_display_name` when the
    /// server sends it, else derived from the org type and rate-limit tier
    /// (Max 20x was renamed Ultra and Max 5x Max on 2026-10-30).
    static func planName(_ profile: [String: Any]) -> String? {
        guard let org = profile["organization"] as? [String: Any] else { return nil }
        if let name = (org["plan_display_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        let type = (org["organization_type"] as? String ?? "").lowercased()
        let tier = (org["rate_limit_tier"] as? String ?? "").lowercased()
        switch type {
        case "claude_max": return tier.contains("20x") ? "Ultra" : "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }

    /// API response → the stored usage dict.
    static func parse(_ r: [String: Any]) -> [String: Any]? {
        var out: [String: Any] = [:]
        func window(_ any: Any?) -> [String: Any]? {
            guard let w = any as? [String: Any], !w.isEmpty, let pct = UsageParser.number(w["utilization"]) else { return nil }
            var d: [String: Any] = ["pct": pct]
            if let reset = w["resets_at"] as? String {
                d["resets_at"] = reset
                if let date = ISODate.parse(reset) {
                    d["countdown"] = StoredTime.countdown(date)
                    d["clock"] = StoredTime.clock(date)
                }
            }
            return d
        }
        if let w = window(r["five_hour"]) {
            out["five_hour"] = w
        } else if r["five_hour"] is NSNull, r["seven_day"] is [String: Any] {
            // An idle account still gets a five_hour object (utilization 0, no reset);
            // an explicit null means the account has no 5-hour limit (verified Ultra).
            out["five_hour_unlimited"] = true
        }
        if let w = window(r["seven_day"]) { out["seven_day"] = w }
        if let x = r["extra_usage"] as? [String: Any], x["is_enabled"] as? Bool == true,
           let used = UsageParser.number(x["used_credits"]), let limit = UsageParser.number(x["monthly_limit"]),
           let pct = UsageParser.number(x["utilization"]) {
            var s: [String: Any] = ["used": used / 100, "limit": limit / 100, "pct": pct,
                                    "currency": x["currency"] as? String ?? "USD"]
            if let reset = x["resets_at"] as? String { s["resets_at"] = reset }
            out["spend"] = s
        }
        var scoped: [[String: Any]] = []
        for item in r["limits"] as? [[String: Any]] ?? [] {
            guard let name = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let pct = UsageParser.number(item["percent"]) else { continue }
            var d: [String: Any] = ["name": name, "pct": pct]
            if let reset = item["resets_at"] as? String {
                d["resets_at"] = reset
                if let date = ISODate.parse(reset) {
                    d["countdown"] = StoredTime.countdown(date)
                    d["clock"] = StoredTime.clock(date)
                }
            }
            scoped.append(d)
        }
        if !scoped.isEmpty { out["scoped"] = scoped }
        return out.isEmpty ? nil : out
    }

    // MARK: Store protocol

    private func readStore() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: paths.usageFile.path),
              let root = JSONFiles.object(data), (root["schemaVersion"] as? NSNumber)?.intValue == 2 else {
            return ["schemaVersion": 2, "accounts": [String: Any]()]
        }
        return root
    }

    private func writeStore(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONFiles.atomicWrite(try JSONFiles.serialize(root), to: paths.usageFile)
    }

    /// Claims eligible rows under the store lock. Returns slot → claimId.
    private func reserve(_ slots: [Int], roster: Roster) -> [Int: String]? {
        guard let lock = try? FileLock(paths.usageLock) else { return nil }
        defer { lock.release() }
        var root = readStore()
        var accounts = root["accounts"] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        var claims: [Int: String] = [:]
        for n in slots {
            guard let e = roster.entries[n] else { continue }
            var row = accounts[String(n)] as? [String: Any] ?? [:]
            let existing = UsageRow(raw: row)
            if !existing.matches(e) {
                row = ["email": e.email, "organizationUuid": e.organizationUuid]
            } else if !Self.eligible(existing, now: now) {
                continue
            }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            row["lastAttemptAt"] = now
            row["claimId"] = id
            row["claimUntil"] = now + Self.claimLease
            accounts[String(n)] = row
            claims[n] = id
        }
        guard !claims.isEmpty else { return [:] }
        root["accounts"] = accounts
        root["schemaVersion"] = 2
        do { try writeStore(root) } catch { return nil }
        return claims
    }

    /// `_row_eligible` with respect_plans and repair_overslept.
    static func eligible(_ r: UsageRow, now: Double) -> Bool {
        if r.authDeadStrikes >= 1 { return false }
        if let b = UsageParser.number(r.raw["backoffUntil"]), now < b { return false }
        if r.liveClaim(now: now) { return false }
        let stale = r.fetchedAt.map { now - $0 > 180 } ?? true
        let next = r.nextPollAt
        let interval = UsageParser.number(r.raw["pollIntervalS"]) ?? 600
        let due = next.map { now >= $0 } ?? true
        let overslept = next.map { $0 > now + max(interval, 600) * 1.1 + 60 } ?? false
        return stale && (due || overslept)
    }

    private func record(claims: [Int: String], outcomes: [Int: Outcome], roster: Roster, liveSlot: Int?) {
        guard let lock = try? FileLock(paths.usageLock) else { return }
        defer { lock.release() }
        var root = readStore()
        var accounts = root["accounts"] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        let settings = SwapSettings.load(paths)
        for (n, claimId) in claims {
            guard let e = roster.entries[n], var row = accounts[String(n)] as? [String: Any] else { continue }
            let current = UsageRow(raw: row)
            // Fencing: someone else re-claimed or replaced the row meanwhile.
            guard current.matches(e), row["claimId"] as? String == claimId else { continue }
            row["claimId"] = NSNull()
            row["claimUntil"] = 0.0
            guard let outcome = outcomes[n] else { accounts[String(n)] = row; continue }
            row["lastAttemptAt"] = now
            switch outcome {
            case .success(let usage, let planName):
                if let planName {
                    row["plan"] = planName
                    row["planFetchedAt"] = now
                }
                let plan = Self.plan(row: current, newUsage: usage, isActive: n == liveSlot, settings: settings, now: now)
                row["lastGood"] = usage ?? NSNull()
                row["fetchedAt"] = now
                row["nextPollAt"] = plan.next
                row["pollIntervalS"] = plan.interval
                row["consecutiveFailures"] = 0
                row["lastError"] = NSNull()
                row["backoffUntil"] = NSNull()
                row["authDeadStrikes"] = 0
            case .failure(let kind, let retryAfter, let struckFp):
                let failures = current.consecutiveFailures + 1
                row["consecutiveFailures"] = failures
                row["lastError"] = kind
                if kind == "http-429" { row["last429At"] = now }
                row["backoffUntil"] = now + Self.backoff(failures: failures, retryAfter: retryAfter, kind: kind)
                // Only a dead lineage counts as a strike.
                if Self.permanentAuthErrors.contains(kind) {
                    row["authDeadStrikes"] = current.authDeadStrikes + 1
                    row["struckFingerprint"] = struckFp ?? NSNull()
                }
            }
            accounts[String(n)] = row
        }
        root["accounts"] = accounts
        root["schemaVersion"] = 2
        try? writeStore(root)
    }

    /// Retry delay after a failed fetch.
    static func backoff(failures n: Int, retryAfter ra: Double?, kind: String) -> Double {
        let computed = min(30 * pow(2, Double(min(max(0, n - 1), 32))), 600)
        guard let ra else { return computed }
        if ra == 0 { return kind == "http-429" ? min(max(computed, 300), 600) : computed }
        var asked = (ra > 600 && kind == "http-429") ? ra + 900 : ra
        asked = min(asked, kind == "http-429" ? 4500 : 3600)
        return max(asked, computed)
    }

    /// When to poll next after a successful fetch.
    static func plan(row: UsageRow, newUsage: [String: Any]?, isActive: Bool, settings: SwapSettings, now: Double)
        -> (next: Double, interval: Double) {
        let def: Double = isActive ? 180 : 300
        let ceiling: Double = isActive ? 300 : 600
        let base = UsageParser.number(row.raw["pollIntervalS"]) ?? def
        let prevU = UsageParser.usage(row.lastGood, fetchedAt: nil)
        let newU = UsageParser.usage(newUsage, fetchedAt: nil)
        let prev = prevU.flatMap { settings.relevantWindows($0).map(\.pct).max() }
        let new = newU.flatMap { settings.relevantWindows($0).map(\.pct).max() }

        var recent429 = false
        if let last429 = UsageParser.number(row.raw["last429At"]) {
            let backoffUntil = UsageParser.number(row.raw["backoffUntil"]) ?? 0
            let anchor = (row.lastError == "http-429" && backoffUntil > last429) ? backoffUntil : last429
            recent429 = now < anchor + 3600
        }

        var interval: Double
        var moving = false
        if let prev, let new {
            if abs(new - prev) >= 1 { moving = true; interval = max(180, base / 2) }
            else { interval = min(ceiling, max(180, base * 1.5)) }
        } else {
            interval = def
        }
        if isActive, moving, !recent429, let new, new >= settings.threshold - 15 { interval = 60 }
        if recent429 { interval = min(1800, max(interval, max(base * 1.5, 360))) }
        let headroom = 100 - (new ?? 0)
        if new != nil, headroom <= 0 { interval = max(interval, 600) }
        var next = now + interval * (1 + 0.1 * (2 * Double.random(in: 0..<1) - 1))
        if let newU {
            let windows = settings.relevantWindows(newU)
            if new != nil, headroom <= 0 {
                if let r = windows.filter({ $0.pct >= 100 }).compactMap({ $0.resetsAt?.timeIntervalSince1970 }).max(), r > now {
                    next = min(next, r + 60)
                }
            } else if let r = windows.compactMap({ $0.resetsAt?.timeIntervalSince1970 }).filter({ $0 > now }).min() {
                next = min(next, r + 60)
            }
        }
        return (next, interval)
    }
}

/// Countdown / clock strings stored next to each window.
enum StoredTime {
    static func countdown(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func clock(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: date)
    }
}
