import Foundation
import XCTest
@testable import Insomnia

final class WakeScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    /// 2026-10-21 is a Wednesday.
    private func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func schedule(days: String = "MTWRFSU", wake: Int = 3 * 60 + 55, end: Int = 9 * 60 + 30) -> WakeSchedule {
        var s = WakeSchedule()
        s.enabled = true
        s.days = days
        s.wakeAt = wake
        s.latestEnd = end
        return s
    }

    // MARK: Schedule

    func testDisabledHasNoWindowOrNextWake() {
        var s = schedule()
        s.enabled = false
        XCTAssertNil(s.window(around: at(21, 4, 0), calendar: calendar))
        XCTAssertNil(s.nextWake(after: at(21, 4, 0), calendar: calendar))
    }

    func testWindowOpensSlightlyBeforeTheWakeAndClosesAtTheLatestEnd() {
        let s = schedule()
        XCTAssertNil(s.window(around: at(21, 3, 50), calendar: calendar))
        XCTAssertEqual(s.window(around: at(21, 3, 54), calendar: calendar)?.wake, at(21, 3, 55))
        XCTAssertEqual(s.window(around: at(21, 9, 29), calendar: calendar)?.latestEnd, at(21, 9, 30))
        XCTAssertNil(s.window(around: at(21, 9, 30), calendar: calendar))
    }

    func testDaysAreRespected() {
        let s = schedule(days: "MTWRF")
        // Saturday 24 October.
        XCTAssertNil(s.window(around: at(24, 5, 0), calendar: calendar))
        XCTAssertNotNil(s.window(around: at(23, 5, 0), calendar: calendar))
        // From Friday after the window, the next wake is Monday.
        XCTAssertEqual(s.nextWake(after: at(23, 10, 0), calendar: calendar), at(26, 3, 55))
    }

    func testThursdayIsR() {
        let s = schedule(days: "R")
        XCTAssertNotNil(s.window(around: at(22, 4, 0), calendar: calendar))
        XCTAssertNil(s.window(around: at(21, 4, 0), calendar: calendar))
    }

    func testLatestEndPastMidnightBelongsToTheWakeDay() {
        let s = schedule(days: "W", wake: 23 * 60, end: 2 * 60)
        let w = s.window(around: at(22, 1, 0), calendar: calendar)
        XCTAssertEqual(w?.wake, at(21, 23, 0))
        XCTAssertEqual(w?.latestEnd, at(22, 2, 0))
        XCTAssertEqual(s.span, 3 * 3600)
    }

    func testProblems() {
        XCTAssertNil(schedule().problem)
        XCTAssertNotNil(schedule(days: "").problem)
        XCTAssertNotNil(schedule(days: "XZ").problem)
        XCTAssertNotNil(schedule(wake: 300, end: 305).problem)
        var s = schedule()
        s.check = DoneCheck(kind: .command, value: "  ")
        XCTAssertNotNil(s.problem)
        s.check = DoneCheck(kind: .file, value: "relative/path")
        XCTAssertNotNil(s.problem)
        s.check = DoneCheck(kind: .file, value: "~/done")
        XCTAssertNil(s.problem)
    }

    func testPmsetForm() {
        let s = schedule(days: "UMMfx", wake: 3 * 60 + 5)
        XCTAssertEqual(s.normalizedDays, "MFU")
        XCTAssertEqual(s.pmsetTime, "03:05:00")
    }

    func testOldConfigWithoutTheKeyDecodesWithTheWakeOff() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"presets": [3600]}"#.utf8))
        XCTAssertFalse(config.wakeSchedule.enabled)
        XCTAssertEqual(config.presets, [3600])
    }

    func testUnreadableScheduleDoesNotCostTheRestOfTheConfig() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"presets": [3600], "wakeSchedule": 7}"#.utf8))
        XCTAssertFalse(config.wakeSchedule.enabled)
        XCTAssertEqual(config.presets, [3600])
    }

    func testScheduleRoundTrips() throws {
        var s = schedule(days: "MW")
        s.check = DoneCheck(kind: .processesGone, value: "codex, python3")
        let back = try JSONDecoder().decode(WakeSchedule.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.check.processNames, ["codex", "python3"])
    }

    // MARK: Run rules

    func testANewWindowBegins() {
        let s = schedule()
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: nil, now: at(21, 3, 55), calendar: calendar), .begin(at(21, 3, 55), until: at(21, 9, 30)))
        // Yesterday's finished run does not stop today's.
        let yesterday = ScheduledRunState(wake: at(20, 3, 55), latestEnd: at(20, 9, 30), owned: true, finished: true)
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: yesterday, now: at(21, 3, 56), calendar: calendar), .begin(at(21, 3, 55), until: at(21, 9, 30)))
    }

    func testChecksAreSpacedAndFinishWaitsForTheGrace() {
        let s = schedule()
        var run = ScheduledRunState(wake: at(21, 3, 55), latestEnd: at(21, 9, 30), owned: true, lastCheck: at(21, 4, 0))
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: run, now: at(21, 4, 1), calendar: calendar), .idle)
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: run, now: at(21, 4, 2), calendar: calendar), .check)
        run.doneSince = at(21, 8, 0)
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: run, now: at(21, 8, 4), calendar: calendar), .check)
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: run, now: at(21, 8, 5), calendar: calendar), .finish)
        run.finished = true
        XCTAssertEqual(ScheduledRunRules.step(schedule: s, state: run, now: at(21, 8, 6), calendar: calendar), .idle)
    }

    func testOutsideTheWindowNothingHappens() {
        XCTAssertEqual(ScheduledRunRules.step(schedule: schedule(), state: nil, now: at(21, 12, 0), calendar: calendar), .idle)
    }

    func testEndingEarlyOnlyForAnOwnedUnextendedSession() {
        let run = ScheduledRunState(wake: at(21, 3, 55), latestEnd: at(21, 9, 30), owned: true)
        XCTAssertTrue(ScheduledRunRules.mayEndEarly(state: run, sessionEndsAt: at(21, 9, 30)))
        XCTAssertFalse(ScheduledRunRules.mayEndEarly(state: run, sessionEndsAt: at(21, 11, 30)), "the user extended it")
        XCTAssertFalse(ScheduledRunRules.mayEndEarly(state: run, sessionEndsAt: nil))
        var notOwned = run
        notOwned.owned = false
        XCTAssertFalse(ScheduledRunRules.mayEndEarly(state: notOwned, sessionEndsAt: at(21, 9, 30)))
    }

    // MARK: Done checks

    func testFileCheckNeedsAChangeAfterTheWake() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("done")
        let check = DoneCheck(kind: .file, value: file.path)
        let now = Date()
        let missing = await DoneChecker.passes(check, since: now.addingTimeInterval(-60), now: now)
        XCTAssertFalse(missing)
        try Data().write(to: file)
        let fresh = await DoneChecker.passes(check, since: now.addingTimeInterval(-60), now: now)
        XCTAssertTrue(fresh)
        let stale = await DoneChecker.passes(check, since: now.addingTimeInterval(3600), now: now)
        XCTAssertFalse(stale)
    }

    func testCommandCheckFollowsTheExitStatus() async {
        let yes = await DoneChecker.passes(DoneCheck(kind: .command, value: "exit 0"), since: Date(), now: Date())
        let no = await DoneChecker.passes(DoneCheck(kind: .command, value: "exit 3"), since: Date(), now: Date())
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
    }

    func testProcessCheckWaitsBeforeTrustingAnEmptyList() async {
        let check = DoneCheck(kind: .processesGone, value: "no-such-process-\(UUID().uuidString.prefix(8))")
        let wake = Date()
        let early = await DoneChecker.passes(check, since: wake, now: wake.addingTimeInterval(60))
        let later = await DoneChecker.passes(check, since: wake, now: wake.addingTimeInterval(DoneCheck.processesSettle))
        XCTAssertFalse(early)
        XCTAssertTrue(later)
    }

    func testNoneNeverPasses() async {
        let passes = await DoneChecker.passes(DoneCheck(), since: Date(), now: Date())
        XCTAssertFalse(passes)
    }

    // MARK: pmset and the helper

    func testRepeatingWakeIsReadFromPmsetSched() {
        let output = """
        Repeating power events:
          wakepoweron at 3:55AM every day
        Scheduled power events:
         [0]  wake at 10/22/2026 00:00:00 by 'com.apple.alarm'
        """
        XCTAssertEqual(PmsetWakeScheduler.repeatingWake(in: output), "wakepoweron at 3:55AM every day")
        XCTAssertNil(PmsetWakeScheduler.repeatingWake(in: "Scheduled power events:\n [0]  wake at 10/22/2026 00:00:00 by 'x'"))
    }

    func testHelperRefusesAnythingButItsTwoForms() throws {
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/insomnia-wake.sh").path
        for args in [[], ["set"], ["set", "MM", "03:55:00"], ["set", "X", "03:55:00"], ["set", "M", "24:00:00"],
                     ["set", "M", "03:55:30"], ["set", "M", "03:55"], ["set", "M;id", "03:55:00"],
                     ["set", "M", "03:55:00", "extra"], ["clear", "now"], ["sleep"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [helper] + args
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 64, "\(args) should be refused")
        }
    }
}
