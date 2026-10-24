import SwiftUI

struct ResetCreditsPresentation {
    let count: Int?
    let compactText: String
    let detailText: String

    init(credits: ResetCredits?, now: Date = Date()) {
        guard let credits else {
            count = nil
            compactText = "↻—"
            detailText = "Extra resets unavailable"
            return
        }
        let remaining = credits.remainingCount(at: now)
        count = remaining
        let grants = credits.activeGrants(at: now)
        let next = grants.compactMap(\.expiresAt).min()
        compactText = "↻\(remaining)" + (next.map {
            " · " + $0.formatted(.dateTime.month(.abbreviated).day())
        } ?? "")
        let expirations = grants.map {
            "\($0.count) reset(s): \(Self.expiration($0.expiresAt))"
        }
        let missing = remaining > grants.reduce(0) { $0 + $1.count }
        detailText = "\(remaining) extra resets available" +
            (expirations.isEmpty ? "" : ", " + expirations.joined(separator: "; ")) +
            (missing ? "; some expiration details unavailable" : "")
    }

    static func expiration(_ date: Date?) -> String {
        guard let date else { return "No expiration" }
        return "Expires " + date.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute().timeZone()
        )
    }
}

struct ResetCreditsView: View {
    let credits: ResetCredits?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = ResetCreditsPresentation(credits: credits, now: context.date)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Extra resets", systemImage: "arrow.counterclockwise")
                    Spacer()
                    Text(presentation.count.map { "\($0) available" } ?? "Unavailable")
                        .monospacedDigit()
                }
                if let credits {
                    let grants = credits.activeGrants(at: context.date)
                    ForEach(grants) { grant in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(grant.count) \(grant.count == 1 ? "reset" : "resets") · \(ResetCreditsPresentation.expiration(grant.expiresAt))")
                            if grant.isUsableNow == false {
                                Text("Not redeemable right now")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    if credits.remainingCount(at: context.date) > grants.reduce(0, { $0 + $1.count }) {
                        Text("Some expiration details unavailable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }
}
