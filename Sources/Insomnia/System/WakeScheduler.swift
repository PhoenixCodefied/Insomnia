import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sets and clears the daily wake. pmset needs root, so the call goes
/// through `insomnia-wake`, a root-owned helper install.sh puts in
/// /usr/local/libexec with its own sudoers rule. The helper accepts only
/// `set <days> <HH:MM:00>` and `clear`.
protocol WakeScheduling: Sendable {
    func apply(_ schedule: WakeSchedule) async throws
    /// The repeating wake macOS has on file, as `pmset -g sched` words it,
    /// or nil when there is none.
    func current() async -> String?
}

struct WakeHelperError: Error, LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

struct PmsetWakeScheduler: WakeScheduling {
    static let helper = "/usr/local/libexec/insomnia-wake"
    static let sudo = "/usr/bin/sudo"
    static let timeout: TimeInterval = 20

    static var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helper) }

    func apply(_ schedule: WakeSchedule) async throws {
        guard Self.helperInstalled else {
            throw WakeHelperError(detail: "The scheduled-wake helper is not installed. Run scripts/install-wake-helper.sh from a checkout of this fork.")
        }
        let args: [String]
        if schedule.enabled, schedule.problem == nil {
            args = ["-n", Self.helper, "set", schedule.normalizedDays, schedule.pmsetTime]
        } else {
            args = ["-n", Self.helper, "clear"]
        }
        let r = try await Shell.run(Self.sudo, args, timeout: Self.timeout)
        guard r.succeeded else {
            let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WakeHelperError(detail: "insomnia-wake \(args[2]) failed (exit \(r.status))\(why.isEmpty ? "" : ": \(why)")")
        }
        Log.info("scheduled wake \(args[2] == "set" ? "set: \(schedule.normalizedDays) \(schedule.pmsetTime)" : "cleared")")
    }

    func current() async -> String? {
        guard let r = try? await Shell.run("/usr/bin/pmset", ["-g", "sched"], timeout: Self.timeout), r.succeeded else { return nil }
        return Self.repeatingWake(in: r.stdout)
    }

    /// The wake line under "Repeating power events:" in `pmset -g sched`.
    static func repeatingWake(in output: String) -> String? {
        var inRepeating = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { inRepeating = true; continue }
            if line.hasSuffix(":"), !line.hasPrefix("wake") { inRepeating = false; continue }
            if inRepeating, line.lowercased().contains("wake") { return line }
        }
        return nil
    }
}

/// Calls `onPoweredOn` each time the system finishes powering on. Background
/// maintenance wakes do not send this; a scheduled (RTC) wake does, lid
/// closed or open. Sleep is always allowed: this only listens.
@MainActor
final class SystemPowerObserver {
    // IOKit message ids; the iokit_common_msg macros are not imported into Swift.
    nonisolated static let canSystemSleep: UInt32 = 0xE000_0270
    nonisolated static let systemWillSleep: UInt32 = 0xE000_0280
    nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private final class Box: @unchecked Sendable {
        var rootPort: io_connect_t = 0
        let onPoweredOn: @MainActor () -> Void
        init(_ f: @escaping @MainActor () -> Void) { onPoweredOn = f }
    }

    private let box: Box
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onPoweredOn: @escaping @MainActor () -> Void) {
        box = Box(onPoweredOn)
    }

    func start() {
        guard box.rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let port = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, arg in
            guard let refcon else { return }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            switch messageType {
            case SystemPowerObserver.canSystemSleep, SystemPowerObserver.systemWillSleep:
                IOAllowPowerChange(box.rootPort, Int(bitPattern: arg))
            case SystemPowerObserver.systemHasPoweredOn:
                DispatchQueue.main.async { MainActor.assumeIsolated { box.onPoweredOn() } }
            default:
                break
            }
        }, &notifier)
        guard port != 0, let np = notifyPort else {
            Log.error("scheduled wake: could not register for system power notifications")
            return
        }
        box.rootPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(np).takeUnretainedValue(), .defaultMode)
    }
}

/// A PreventSystemSleep assertion held from a scheduled wake until the
/// session has disabled sleep, so the Mac cannot drop back to sleep in
/// between. Released as soon as the session is up (or the attempt failed).
@MainActor
final class WakeHold {
    private var id: IOPMAssertionID = 0

    func take() {
        guard id == 0 else { return }
        let r = IOPMAssertionCreateWithName("PreventSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Insomnia scheduled wake" as CFString, &id)
        if r != kIOReturnSuccess {
            id = 0
            Log.error("scheduled wake: could not take a sleep assertion (\(r))")
        }
    }

    func release() {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}

/// Runs a `DoneCheck`.
enum DoneChecker {
    static func passes(_ check: DoneCheck, since wake: Date, now: Date) async -> Bool {
        switch check.kind {
        case .none:
            return false
        case .command:
            do {
                let r = try await Shell.run("/bin/zsh", ["-c", check.trimmed], timeout: DoneCheck.commandTimeout)
                return r.succeeded
            } catch {
                Log.info("scheduled wake: done check did not run: \(error.localizedDescription)")
                return false
            }
        case .file:
            let attrs = try? FileManager.default.attributesOfItem(atPath: check.expandedPath)
            guard let modified = attrs?[.modificationDate] as? Date else { return false }
            return modified >= wake
        case .processesGone:
            guard now.timeIntervalSince(wake) >= DoneCheck.processesSettle else { return false }
            for name in check.processNames {
                guard let r = try? await Shell.run("/usr/bin/pgrep", ["-x", name], timeout: 10) else { return false }
                if r.status == 0 { return false }      // running
                if r.status != 1 { return false }      // pgrep failed: not proof of done
            }
            return true
        }
    }
}
