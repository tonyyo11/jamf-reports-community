import Foundation

/// A date Jamf Pro keeps for a Mac that `thresholds.stale_basis` can count.
enum StaleBasis: String, CaseIterable, Sendable {
    /// Last Check-in: the Jamf binary checking in (`general.lastCheckIn`).
    case checkIn = "check_in"
    /// Last Inventory Update: the Jamf binary submitting inventory (`general.reportDate`).
    case inventory
    /// Last Contact (Jamf Pro 11.30): any contact, including MDM and declarative device
    /// management (`general.lastContact`).
    case contact

    static let `default`: [StaleBasis] = [.checkIn]

    /// The word as config.yaml spells it, read ignoring case; `-` and spaces read as `_`.
    static func parse(_ word: String) -> StaleBasis? {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return StaleBasis(rawValue: key)
    }

    /// The date's name on screens and in reports.
    var label: String {
        switch self {
        case .checkIn: "Last check-in"
        case .inventory: "Last inventory update"
        case .contact: "Last contact"
        }
    }

    /// What the date measures, after "since" or "no".
    fileprivate var noun: String {
        switch self {
        case .checkIn: "check-in"
        case .inventory: "inventory update"
        case .contact: "contact"
        }
    }

    /// The verb phrase for a Mac that is current on this date.
    fileprivate var currentPhrase: String {
        switch self {
        case .checkIn: "checked in"
        case .inventory: "inventoried"
        case .contact: "in contact"
        }
    }
}

/// How old the oldest counted date of a Mac is.
enum StaleAge: Comparable, Sendable, Hashable {
    case days(Int)
    /// A date the source carries for every Mac and this one lacks: it never checked in or
    /// never inventoried, so it is older than any number of days.
    case never

    static func < (lhs: StaleAge, rhs: StaleAge) -> Bool {
        switch (lhs, rhs) {
        case let (.days(a), .days(b)): a < b
        case (.days, .never): true
        case (.never, _): false
        }
    }

    /// The day count; nil for `never`.
    var days: Int? {
        if case .days(let count) = self { return count }
        return nil
    }
}

/// What a source knows about the dates of one Mac. A date the source does not carry is nil.
struct StaleInputs: Sendable, Equatable {
    /// The source's own count of days since the check-in, when it gives one
    /// (`days_since_contact`). It wins over `checkIn`, so a snapshot's count stays the count.
    var checkInDays: Int?
    var checkIn: Date?
    var inventory: Date?
    var contact: Date?
    /// True when the source records a check-in and an inventory date for every Mac it lists
    /// (the `computers` snapshot, a CSV with those columns): a Mac without one never had it,
    /// which counts as older than any number of days. A source that does not carry the date
    /// leaves it out of the rule instead.
    var carriesDates = false
    /// The source's own stale flag (jamf-cli's `stale`), used only when no counted date is known.
    var flag = false
}

/// `thresholds.stale_device_days` and `thresholds.stale_basis`: the one definition of a stale
/// Mac, used by the daily summary, the Overview, Devices, Offline Outreach, the workbook, the
/// CSV sheets, the HTML report and the score's `checked_in` factor.
///
/// A Mac's stale age is the largest age, in whole days, among the listed dates it has; it is
/// stale when that age is more than `days`, so a Mac at exactly `days` is not. A Mac with none
/// of the listed dates falls back to its source's own flag.
struct StaleRule: Sendable, Equatable {
    var days: Int
    /// In `StaleBasis.allCases` order, never empty, each date once.
    private(set) var basis: [StaleBasis]

    init(days: Int, basis: [StaleBasis] = StaleBasis.default) {
        self.days = days
        let kept = StaleBasis.allCases.filter(basis.contains)
        self.basis = kept.isEmpty ? StaleBasis.default : kept
    }

    var usesDefaultBasis: Bool { basis == StaleBasis.default }

    /// True when a count needs dates the device-compliance rows do not carry.
    var needsComputers: Bool { basis.contains(.inventory) || basis.contains(.contact) }

    func with(days: Int) -> StaleRule { StaleRule(days: days, basis: basis) }

    // MARK: - The rule

    /// Whole days from `date` to `now`, rounded down, so the count matches jamf-cli's
    /// `days_since_contact`. Negative for a date in the future.
    static func wholeDays(from date: Date, to now: Date) -> Int {
        Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
    }

    /// The oldest listed date's age; nil when the source knows none of them.
    func age(of inputs: StaleInputs, now: Date = Date()) -> StaleAge? {
        var ages: [StaleAge] = []
        for date in basis {
            switch date {
            case .checkIn:
                if let days = inputs.checkInDays {
                    ages.append(.days(days))
                } else if let checkIn = inputs.checkIn {
                    ages.append(.days(Self.wholeDays(from: checkIn, to: now)))
                } else if inputs.carriesDates {
                    ages.append(.never)
                }
            case .inventory:
                if let inventory = inputs.inventory {
                    ages.append(.days(Self.wholeDays(from: inventory, to: now)))
                } else if inputs.carriesDates {
                    ages.append(.never)
                }
            case .contact:
                // A Mac without a Last Contact has had none since Jamf Pro began recording it
                // (or runs a Jamf Pro before 11.30): unknown, not old.
                if let contact = inputs.contact {
                    ages.append(.days(Self.wholeDays(from: contact, to: now)))
                }
            }
        }
        return ages.max()
    }

    func isStale(_ inputs: StaleInputs, now: Date = Date()) -> Bool {
        guard let age = age(of: inputs, now: now) else { return inputs.flag }
        return age > .days(days)
    }

    // MARK: - Words

    /// The counted dates after "since": "check-in", "check-in or inventory update",
    /// "check-in, inventory update or contact".
    var basisPhrase: String {
        let nouns = basis.map(\.noun)
        guard nouns.count > 1 else { return nouns.joined() }
        return nouns.dropLast().joined(separator: ", ") + " or " + (nouns.last ?? "")
    }

    /// `basisPhrase` as a table heading: "Check-in", "Check-in or Inventory Update".
    var basisHeading: String {
        basisPhrase.split(separator: " ").map { word in
            word == "or" ? "or" : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// The score factor's name: "Checked in within 30 days", "Checked in and inventoried
    /// within 30 days". `shortUnit` writes "30d" for a tile's sub-line.
    func checkedInLabel(shortUnit: Bool = false) -> String {
        let phrases = basis.map(\.currentPhrase)
        let joined = phrases.count > 1
            ? phrases.dropLast().joined(separator: ", ") + " and " + (phrases.last ?? "")
            : phrases.joined()
        return joined.prefix(1).uppercased() + joined.dropFirst()
            + " within \(days)" + (shortUnit ? "d" : " days")
    }
}
