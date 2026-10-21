import Foundation

/// A daily wake for scheduled jobs. macOS wakes the Mac at `wakeAt` on
/// `days` (a `pmset repeat wakeorpoweron` event, set through the
/// `insomnia-wake` helper), Insomnia starts a session that runs until
/// `latestEnd`, and ends it early once `check` reports the jobs done and
/// `grace` has passed. Everything else a session does (lid actions, battery
/// and heat rules, the recovery agent) applies unchanged.
///
/// Times are minutes after local midnight. A `latestEnd` at or before
/// `wakeAt` falls on the next day.
struct WakeSchedule: Codable, Equatable, Sendable {
    var enabled = false
    var wakeAt = 3 * 60 + 55
    var latestEnd = 9 * 60 + 30
    /// pmset weekday letters: M T W R F S U (R is Thursday, U is Sunday).
    var days = "MTWRFSU"
    var check = DoneCheck()
    /// How often the done check runs while a scheduled session is active.
    var checkEvery: TimeInterval = 120
    /// How long the check must have passed before the session ends.
    var grace: TimeInterval = 300

    /// Calendar weekday (1 = Sunday … 7 = Saturday) to pmset's letter.
    static let letters: [Character] = ["U", "M", "T", "W", "R", "F", "S"]
    /// pmset's order, Monday first, for display and normalising.
    static let pmsetOrder: [Character] = ["M", "T", "W", "R", "F", "S", "U"]
    /// A wake that arrives a little early still opens the window.
    static let lead: TimeInterval = 120

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WakeSchedule()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        wakeAt = try c.decodeIfPresent(Int.self, forKey: .wakeAt) ?? d.wakeAt
        latestEnd = try c.decodeIfPresent(Int.self, forKey: .latestEnd) ?? d.latestEnd
        days = try c.decodeIfPresent(String.self, forKey: .days) ?? d.days
        check = try c.decodeIfPresent(DoneCheck.self, forKey: .check) ?? d.check
        checkEvery = try c.decodeIfPresent(TimeInterval.self, forKey: .checkEvery) ?? d.checkEvery
        grace = try c.decodeIfPresent(TimeInterval.self, forKey: .grace) ?? d.grace
    }

    /// The days in pmset order with duplicates and unknown letters dropped.
    var normalizedDays: String {
        let set = Set(days.uppercased())
        return String(Self.pmsetOrder.filter { set.contains($0) })
    }

    /// Why this schedule cannot be applied, or nil when it can.
    var problem: String? {
        if normalizedDays.isEmpty { return "Pick at least one day." }
        if !(0..<1440).contains(wakeAt) || !(0..<1440).contains(latestEnd) { return "Times must be within the day." }
        if span < 10 * 60 { return "The latest end must be at least 10 minutes after the wake." }
        if checkEvery < 30 { return "Check at most every 30 seconds." }
        if case .some(let p) = check.problem { return p }
        return nil
    }

    /// Seconds from the wake to the latest end.
    var span: TimeInterval {
        let minutes = latestEnd > wakeAt ? latestEnd - wakeAt : latestEnd + 1440 - wakeAt
        return TimeInterval(minutes * 60)
    }

    /// The `HH:MM:SS` pmset wants.
    var pmsetTime: String { Self.clock(wakeAt) + ":00" }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    func runs(on day: Date, calendar: Calendar) -> Bool {
        let letter = Self.letters[calendar.component(.weekday, from: day) - 1]
        return normalizedDays.contains(letter)
    }

    /// One morning's run: from the wake to the latest end.
    struct Window: Equatable, Sendable {
        var wake: Date
        var latestEnd: Date
    }

    /// The window `now` falls in (from `lead` before the wake up to the
    /// latest end), for a run that started today or, past midnight,
    /// yesterday. Nil when disabled or outside every window.
    func window(around now: Date, calendar: Calendar = .current) -> Window? {
        guard enabled, problem == nil else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  runs(on: day, calendar: calendar),
                  let w = window(on: day, calendar: calendar) else { continue }
            if now >= w.wake.addingTimeInterval(-Self.lead), now < w.latestEnd { return w }
        }
        return nil
    }

    /// The window of the run that wakes on `day`.
    func window(on day: Date, calendar: Calendar = .current) -> Window? {
        guard let wake = calendar.date(bySettingHour: wakeAt / 60, minute: wakeAt % 60, second: 0, of: day),
              var end = calendar.date(bySettingHour: latestEnd / 60, minute: latestEnd % 60, second: 0, of: day) else { return nil }
        if latestEnd <= wakeAt, let next = calendar.date(byAdding: .day, value: 1, to: end) { end = next }
        return Window(wake: wake, latestEnd: end)
    }

    /// The next wake after `now`, within a week; nil when disabled.
    func nextWake(after now: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, problem == nil else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  runs(on: day, calendar: calendar),
                  let w = window(on: day, calendar: calendar), w.wake > now else { continue }
            return w.wake
        }
        return nil
    }
}

/// What tells Insomnia the scheduled jobs are finished.
struct DoneCheck: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Nothing: hold until the latest end.
        case none
        /// A shell command (zsh -c) that exits 0 once the jobs are done.
        case command
        /// A file modified after the wake.
        case file
        /// None of these processes (comma-separated names, `pgrep -x`) running.
        case processesGone
    }

    var kind: Kind = .none
    var value = ""

    /// A process check passes only after this long, so jobs that have not
    /// started yet are not taken for finished ones.
    static let processesSettle: TimeInterval = 10 * 60
    static let commandTimeout: TimeInterval = 60

    init(kind: Kind = .none, value: String = "") {
        self.kind = kind
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A kind this build does not know holds until the latest end.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .none
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var processNames: [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var problem: String? {
        switch kind {
        case .none: nil
        case .command: trimmed.isEmpty ? "Enter the command that tells when the jobs are done." : nil
        case .file: trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") ? nil : "Enter the full path of the file."
        case .processesGone: processNames.isEmpty ? "Enter at least one process name." : nil
        }
    }

    /// `~/` expanded, for the file check.
    var expandedPath: String { NSString(string: trimmed).expandingTildeInPath }
}
