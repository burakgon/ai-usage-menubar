import Foundation

struct ResetGrant: Equatable, Sendable, Identifiable {
    let id: String
    let count: Int
    let expiresAt: Date?
    let isUsableNow: Bool?

    func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

struct ResetCredits: Equatable, Sendable {
    let availableCount: Int
    // nil means the count is known, but expiration details are unavailable.
    let grants: [ResetGrant]?

    func remainingCount(at now: Date) -> Int {
        max(0, availableCount - (grants ?? []).filter { $0.isExpired(at: now) }
            .reduce(0) { $0 + $1.count })
    }

    func activeGrants(at now: Date) -> [ResetGrant] {
        (grants ?? []).filter { !$0.isExpired(at: now) }.sorted {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
    }

    static func claude(_ value: Any?) -> ResetCredits? {
        guard let block = ProviderParsing.object(value) else { return nil }
        if block["ineligible_reason"] as? String == "no_grant" {
            return ResetCredits(availableCount: 0, grants: [])
        }
        guard block["eligible"] as? Bool == true,
              let rows = block["grants"] as? [[String: Any]] else { return nil }
        var grants: [ResetGrant] = []
        var total = 0
        for row in rows {
            guard let count = count(row["resets_left"]),
                  let id = ProviderParsing.string(row["id"]),
                  let expiry = expiry(row, key: "ends_at"),
                  !total.addingReportingOverflow(count).overflow else { return nil }
            total += count
            if count > 0 {
                grants.append(ResetGrant(
                    id: id, count: count, expiresAt: expiry.date,
                    isUsableNow: row["paused"] as? Bool == true
                        ? false : row["usable_now"] as? Bool
                ))
            }
        }
        guard Set(grants.map(\.id)).count == grants.count else { return nil }
        return ResetCredits(availableCount: total, grants: grants)
    }

    static func codex(_ value: Any?) -> ResetCredits? {
        guard let block = ProviderParsing.object(value),
              let total = count(block["available_count"]) else { return nil }
        let summary = ResetCredits(availableCount: total, grants: nil)
        guard let rows = block["credits"] as? [[String: Any]] else { return summary }
        var grants: [ResetGrant] = []
        for row in rows {
            guard let status = row["status"] as? String else { return summary }
            guard status == "available" else { continue }
            guard let id = ProviderParsing.string(row["id"]),
                  let expiry = expiry(row, key: "expires_at") else { return summary }
            grants.append(ResetGrant(id: id, count: 1, expiresAt: expiry.date, isUsableNow: nil))
        }
        guard grants.count <= total, Set(grants.map(\.id)).count == grants.count else {
            return summary
        }
        return ResetCredits(availableCount: total, grants: grants)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = ProviderParsing.double(value), number >= 0,
              number.rounded() == number, number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private struct Expiry { let date: Date? }

    private static func expiry(_ row: [String: Any], key: String) -> Expiry? {
        // Explicit null is no expiration. A missing/malformed field is unknown.
        if row[key] is NSNull { return Expiry(date: nil) }
        guard let date = ProviderParsing.date(row[key]) else { return nil }
        return Expiry(date: date)
    }
}
