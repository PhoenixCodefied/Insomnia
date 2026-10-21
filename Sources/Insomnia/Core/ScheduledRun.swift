import Foundation

/// One morning's scheduled run, kept on disk so a relaunch mid-run carries on
/// instead of starting the run again.
struct ScheduledRunState: Codable, Equatable, Sendable {
    var wake: Date
    var latestEnd: Date
    /// True when this run started the session; a session the user had
    /// already started is only extended, never ended early by the check.
    var owned: Bool
    var lastCheck: Date?
    /// When the done check first passed.
    var doneSince: Date?
    var finished = false
}

/// What a scheduled run should do at `now`. Pure, so the rules are tested
/// without timers, pmset or a session.
enum ScheduledRunStep: Equatable, Sendable {
    case idle
    /// A window opened that has not run yet: start a session, or extend the
    /// user's one, to `until`.
    case begin(ScheduleWindowID, until: Date)
    case check
    /// The check has held for the grace period: end the session if this run
    /// owns it and nobody moved its end.
    case finish
}

/// A window is identified by its wake time.
typealias ScheduleWindowID = Date

enum ScheduledRunRules {
    static func step(schedule: WakeSchedule, state: ScheduledRunState?, now: Date, calendar: Calendar = .current) -> ScheduledRunStep {
        guard let w = schedule.window(around: now, calendar: calendar) else { return .idle }
        guard let state, state.wake == w.wake else { return .begin(w.wake, until: w.latestEnd) }
        if state.finished { return .idle }
        if let since = state.doneSince, now.timeIntervalSince(since) >= schedule.grace { return .finish }
        if let last = state.lastCheck, now.timeIntervalSince(last) < schedule.checkEvery { return .idle }
        return .check
    }

    /// Whether ending early is this run's call: it started the session and
    /// the session still ends when the run set it to (within a minute), so
    /// the user has not extended it.
    static func mayEndEarly(state: ScheduledRunState, sessionEndsAt: Date?) -> Bool {
        guard state.owned, let ends = sessionEndsAt else { return false }
        return abs(ends.timeIntervalSince(state.latestEnd)) < 60
    }
}

/// Runs the daily wake: keeps macOS's repeating wake in step with the
/// settings, starts a session when a window opens (on the scheduled wake, or
/// on the minute tick when the Mac was already awake), runs the done check
/// and ends the session once the jobs are finished.
@MainActor
@Observable
final class ScheduledRunner {
    private let manager: SessionManager
    private let scheduler: any WakeScheduling
    private let clock: @Sendable () -> Date
    private let stateFile: URL
    @ObservationIgnored private var power: SystemPowerObserver?
    @ObservationIgnored private let hold = WakeHold()
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var busy = false

    private(set) var state: ScheduledRunState?
    /// The repeating wake macOS has on file, for Settings.
    private(set) var systemWake: String?
    private(set) var lastError: String?

    init(manager: SessionManager, scheduler: any WakeScheduling = PmsetWakeScheduler(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.manager = manager
        self.scheduler = scheduler
        self.clock = clock
        stateFile = manager.paths.appSupport.appendingPathComponent("scheduled-run.json")
        state = try? JSONDecoder.insomnia.decode(ScheduledRunState.self, from: Data(contentsOf: stateFile))
    }

    var schedule: WakeSchedule { manager.config.wakeSchedule }

    var nextWake: Date? { schedule.nextWake(after: clock()) }

    func start() {
        let observer = SystemPowerObserver { [weak self] in self?.poweredOn() }
        observer.start()
        power = observer
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateSoon() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
        Task {
            await applySchedule()
            await evaluate()
        }
    }

    /// Settings changed: hand macOS the new wake and look again.
    func scheduleChanged() {
        Task {
            await applySchedule()
            await evaluate()
        }
    }

    func applySchedule() async {
        let s = schedule
        if !s.enabled, !PmsetWakeScheduler.helperInstalled {
            systemWake = await scheduler.current()
            return
        }
        do {
            try await scheduler.apply(s)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.error("scheduled wake: \(error.localizedDescription)")
        }
        systemWake = await scheduler.current()
    }

    private func poweredOn() {
        // Inside a window, hold sleep off at once: the session start below
        // takes a few seconds and a lid-closed wake may not wait for it.
        if schedule.window(around: clock()) != nil, state?.finished != true {
            hold.take()
            Log.info("scheduled wake: woke inside the window; holding sleep while the session starts")
        }
        evaluateSoon()
    }

    private func evaluateSoon() {
        Task { await evaluate() }
    }

    func evaluate() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            if manager.session != nil || state?.finished != false { hold.release() }
        }
        let now = clock()
        switch ScheduledRunRules.step(schedule: schedule, state: state, now: now) {
        case .idle:
            return
        case let .begin(wake, until):
            await begin(wake: wake, until: until, now: now)
        case .check:
            await check(now: now)
        case .finish:
            await finish()
        }
    }

    private func begin(wake: Date, until: Date, now: Date) async {
        var run = ScheduledRunState(wake: wake, latestEnd: until, owned: false)
        if let session = manager.session {
            if session.endsAt < until {
                await manager.extend(by: until.timeIntervalSince(session.endsAt))
                Log.info("scheduled wake: extended the running session to the latest end")
            } else {
                Log.info("scheduled wake: a session already runs past the latest end; leaving it")
            }
        } else {
            await manager.start(duration: until.timeIntervalSince(now))
            run.owned = manager.session != nil
            Log.info(run.owned ? "scheduled wake: session started until the latest end" : "scheduled wake: the session did not start")
        }
        hold.release()
        if manager.session == nil {
            // Nothing to hold awake; try again on the next tick.
            lastError = manager.lastError ?? "The scheduled session did not start."
            return
        }
        save(run)
        await check(now: clock())
    }

    private func check(now: Date) async {
        guard var run = state else { return }
        guard manager.session != nil else {
            Log.info("scheduled wake: the session ended before the jobs were done (timer, user or a rule)")
            run.finished = true
            save(run)
            return
        }
        run.lastCheck = now
        let done = await DoneChecker.passes(schedule.check, since: run.wake, now: now)
        if done {
            if run.doneSince == nil {
                run.doneSince = now
                Log.info("scheduled wake: done check passed; ending after \(Int(schedule.grace)) s grace")
            }
        } else if run.doneSince != nil {
            Log.info("scheduled wake: done check no longer passes; waiting again")
            run.doneSince = nil
        }
        save(run)
    }

    private func finish() async {
        guard var run = state else { return }
        run.finished = true
        save(run)
        if ScheduledRunRules.mayEndEarly(state: run, sessionEndsAt: manager.session?.endsAt) {
            Log.info("scheduled wake: jobs done; ending the session")
            await manager.end(reason: .jobsDone)
        } else {
            Log.info("scheduled wake: jobs done; the session is not this run's to end, leaving it")
        }
    }

    private func save(_ run: ScheduledRunState) {
        state = run
        do {
            let data = try JSONEncoder.insomnia.encode(run)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            Log.error("scheduled wake: could not save the run state: \(error.localizedDescription)")
        }
    }
}

extension JSONEncoder {
    static var insomnia: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var insomnia: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
