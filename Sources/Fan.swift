import Foundation
import AppKit

// Fan control: Auto vs one shared fixed RPM. Writes on Apple Silicon need root.
// Helper path adapted from MacsFan (MIT).

struct FanInfo: Identifiable, Equatable {
    let id: Int
    var actualRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var isManual: Bool
}

enum FanMode: String {
    case auto
    case fixed
    case curve
}

struct FanCurvePoint: Identifiable, Codable, Equatable {
    var id: UUID
    var celsius: Double
    var rpm: Double

    init(id: UUID = UUID(), celsius: Double, rpm: Double) {
        self.id = id
        self.celsius = celsius
        self.rpm = rpm
    }
}

enum FanCurve {
    /// Fine-grained in 50–70°: that's the common operating band, so steps are small
    /// (300–500 RPM). Above 70° bigger jumps are fine — that's emergency territory.
    static let defaults: [FanCurvePoint] = [
        FanCurvePoint(celsius: 50, rpm: 1700),
        FanCurvePoint(celsius: 55, rpm: 2000),
        FanCurvePoint(celsius: 60, rpm: 2400),
        FanCurvePoint(celsius: 65, rpm: 2900),
        FanCurvePoint(celsius: 70, rpm: 3500),
        FanCurvePoint(celsius: 85, rpm: 5200),
    ]

    /// Defaults before the finer 50–70° curve. A stored curve matching this is
    /// treated as never customized and migrated to `defaults`.
    static let legacyDefaults: [FanCurvePoint] = [
        FanCurvePoint(celsius: 55, rpm: 2000),
        FanCurvePoint(celsius: 70, rpm: 3500),
        FanCurvePoint(celsius: 85, rpm: 5200),
    ]

    /// Step-down hysteresis in °C. After entering a level at threshold T, the fan
    /// only drops back once temp falls below T - hysteresis. Without this, temp
    /// hovering around a threshold makes the speed flip between two levels on
    /// every 2s sample.
    static let dropHysteresis: Double = 2.5

    /// Step-up sustain window in seconds. To step up to a level the temp must
    /// stay continuously at/above that level's threshold for this long. Kills the
    /// "58↔61° flip-flop": a momentary blip no longer yanks the fans up, so a
    /// high-speed level can't turn on and off every few samples.
    static let ascendSustain: TimeInterval = 60

    /// Thresholds at/above this value ignore `ascendSustain` and step up
    /// instantly — emergency territory, waiting there is never right.
    static let ascendBypassCelsius: Double = 70

    static func sortedPoints(_ points: [FanCurvePoint]) -> [FanCurvePoint] {
        points.sorted { $0.celsius < $1.celsius }
    }

    /// Highest matching threshold index; -1 means below all points (floor).
    static func level(for temp: Double, sorted: [FanCurvePoint]) -> Int {
        var level = -1
        for (index, point) in sorted.enumerated() where temp >= point.celsius {
            level = index
        }
        return level
    }

    /// Hysteresis-aware level: down from `currentLevel` waits until temp is
    /// `hysteresis` below that level's entry threshold. Stale levels (curve
    /// shrank after an edit) bypass the hold. Stepping up is NOT handled here —
    /// see `ascentTick`, which gates ascents behind a sustain window.
    static func stableLevel(
        for temp: Double,
        sorted: [FanCurvePoint],
        currentLevel: Int,
        hysteresis: Double
    ) -> Int {
        let raw = level(for: temp, sorted: sorted)
        guard raw < currentLevel, currentLevel >= 0, currentLevel < sorted.count else { return raw }
        return temp >= sorted[currentLevel].celsius - hysteresis ? currentLevel : raw
    }

    /// One tick of the step-up sustain state machine. When raw level wants to go
    /// higher than `currentLevel`, hold the current level until temp has been
    /// continuously at/above the target threshold for `sustain` seconds; entry
    /// thresholds at/above `bypassCelsius` skip straight up. Returns the level to
    /// use plus the pending wait, if any, to carry into the next tick.
    static func ascentTick(
        rawLevel: Int,
        currentLevel: Int,
        sorted: [FanCurvePoint],
        entry: Double?,
        since: Date?,
        now: Date,
        sustain: TimeInterval,
        bypassCelsius: Double
    ) -> (level: Int, entry: Double?, since: Date?) {
        guard rawLevel > currentLevel else { return (currentLevel, nil, nil) }
        let targetEntry = sorted[rawLevel].celsius
        if targetEntry >= bypassCelsius { return (rawLevel, nil, nil) }
        if entry == targetEntry, let since {
            if now.timeIntervalSince(since) >= sustain {
                return (rawLevel, nil, nil)
            }
            return (currentLevel, targetEntry, since)
        }
        return (currentLevel, targetEntry, now)
    }

    static func rpm(level: Int, sorted: [FanCurvePoint], floor: Double) -> Double {
        level < 0 ? floor : sorted[level].rpm
    }

    /// Highest matching threshold; below all points uses `floor`.
    static func rpm(for temp: Double, points: [FanCurvePoint], floor: Double) -> Double {
        let sorted = sortedPoints(points)
        return rpm(level: level(for: temp, sorted: sorted), sorted: sorted, floor: floor)
    }

    static func runSelfTest() -> Int32 {
        let points = [
            FanCurvePoint(celsius: 50, rpm: 2000),
            FanCurvePoint(celsius: 70, rpm: 4000),
            FanCurvePoint(celsius: 85, rpm: 5700),
        ]
        let cases: [(Double, Double)] = [
            (40, 1200), (50, 2000), (73, 4000), (85, 5700), (90, 5700),
        ]
        for (temp, expected) in cases {
            let got = rpm(for: temp, points: points, floor: 1200)
            if got != expected {
                fputs("curve selftest failed: \(temp) -> \(got) expected \(expected)\n", stderr)
                return 1
            }
        }
        if rpm(for: 60, points: [], floor: 1200) != 1200 {
            fputs("curve selftest failed: empty points\n", stderr)
            return 1
        }

        // Hysteresis: step up instantly, hold on the way down until temp clears
        // the entry threshold minus hysteresis.
        let sorted = sortedPoints([
            FanCurvePoint(celsius: 50, rpm: 2000),
            FanCurvePoint(celsius: 55, rpm: 2400),
            FanCurvePoint(celsius: 60, rpm: 2900),
            FanCurvePoint(celsius: 65, rpm: 3500),
            FanCurvePoint(celsius: 70, rpm: 4200),
        ])
        let hysteresisCases: [(Double, Int, Int)] = [
            (49.9, -1, -1), // below all: floor, nothing to hold
            (61.0, 1, 2),   // crossed 60: up immediately
            (58.5, 2, 2),   // 58.5 >= 60 - 2.5: hold level 2
            (57.4, 2, 1),   // 57.4 < 57.5: released to raw level
            (66.0, 2, 3),   // up across 65
            (45.0, 9, -1),  // stale level past the last point: raw
        ]
        for (temp, current, expected) in hysteresisCases {
            let got = stableLevel(for: temp, sorted: sorted, currentLevel: current, hysteresis: 2.5)
            if got != expected {
                fputs("curve selftest failed: hysteresis \(temp)@L\(current) -> L\(got) expected L\(expected)\n", stderr)
                return 1
            }
        }

        // Ascend sustain: temp must hold over the target threshold before the
        // fan steps up; a stray 61° blip among 58–59° must not trigger it.
        let t0 = Date()
        let tick = { (raw: Int, cur: Int, entry: Double?, since: Date?, now: Date) -> (Int, Double?, Date?) in
            let s = ascentTick(
                rawLevel: raw, currentLevel: cur, sorted: sorted,
                entry: entry, since: since, now: now,
                sustain: 60, bypassCelsius: 70
            )
            return (s.level, s.entry, s.since)
        }
        var s = tick(2, -1, nil, nil, t0) // 61° start: target 60°, begin wait
        if s.0 != -1 || s.1 != 60 || s.2 != t0 {
            fputs("curve selftest failed: sustain start L\(s.0) \(String(describing: s.1))\n", stderr)
            return 1
        }
        s = tick(2, -1, s.1, s.2, t0 + 10) // 10s in: still holding
        if s.0 != -1 || s.1 != 60 || s.2 != t0 {
            fputs("curve selftest failed: sustain hold L\(s.0)\n", stderr)
            return 1
        }
        s = tick(2, -1, s.1, s.2, t0 + 60) // 60s in: release to 60° level
        if s.0 != 2 || s.1 != nil || s.2 != nil {
            fputs("curve selftest failed: sustain release L\(s.0)\n", stderr)
            return 1
        }
        s = tick(4, 0, nil, nil, t0) // 70° (bypass) target: immediate
        if s.0 != 4 || s.1 != nil {
            fputs("curve selftest failed: bypass L\(s.0)\n", stderr)
            return 1
        }
        s = tick(2, -1, 65, t0, t0 + 5) // target drifted 65→60 mid-hold: restart
        if s.0 != -1 || s.1 != 60 || s.2 != t0 + 5 {
            fputs("curve selftest failed: sustain restart L\(s.0)\n", stderr)
            return 1
        }
        s = tick(1, 2, 60, t0, t0) // descending: gate idle
        if s.0 != 2 || s.1 != nil {
            fputs("curve selftest failed: sustain idle L\(s.0)\n", stderr)
            return 1
        }
        return 0
    }
}

enum PrivilegedWriter {
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Serialize every sudo helper run: two concurrent root SMC writers make writes fail intermittently.
    private static let queue = DispatchQueue(label: "onebar.fan.helper")
    private static let logURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/OneBar-fan.log")

    struct Outcome {
        var ok: Bool
        var detail: String
    }

    static func hasPasswordlessSudo() -> Bool {
        let result = runProcess("/usr/bin/sudo", ["-n", executablePath, "helper"])
        let err = result.stderr.lowercased()
        if (err.contains("password") && !err.contains("usage")) || err.contains("a terminal is required") {
            return false
        }
        return err.contains("usage") || result.status == 0 || result.status == 1
    }

    static func ensureAuthorized() -> Bool {
        if hasPasswordlessSudo() { return true }
        guard installSudoers() else { return false }
        return hasPasswordlessSudo()
    }

    static func setAllFixed(rpm: Double, promptIfNeeded: Bool = true) -> Outcome {
        runHelper(["all", String(format: "%.0f", rpm)], promptIfNeeded: promptIfNeeded)
    }

    static func setAllAuto(promptIfNeeded: Bool = true) -> Outcome {
        runHelper(["all", "auto"], promptIfNeeded: promptIfNeeded)
    }

    static func setAllAutoSilently() {
        _ = runProcess("/usr/bin/sudo", ["-n", executablePath, "helper", "all", "auto"])
    }

    private static func appendLog(_ line: String) {
        guard let logURL else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(stamp)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: logURL, options: .atomic)
        }
    }

    private static func runHelper(_ helperArgs: [String], promptIfNeeded: Bool) -> Outcome {
        if promptIfNeeded {
            guard ensureAuthorized() else { return Outcome(ok: false, detail: "未授权") }
        } else if !hasPasswordlessSudo() {
            return Outcome(ok: false, detail: "未授权")
        }
        let result = queue.sync {
            runProcess("/usr/bin/sudo", ["-n", executablePath, "helper"] + helperArgs)
        }
        if result.status == 0 { return Outcome(ok: true, detail: "") }
        appendLog("helper \(helperArgs.joined(separator: " ")) -> status \(result.status.map(String.init) ?? "nil"): \(result.stderr)")
        let detail = result.stderr
            .split(separator: "\n")
            .filter { !$0.localizedCaseInsensitiveContains("usage") }
            .joined(separator: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: false, detail: String(detail.prefix(100)))
    }

    /// One-time: write /etc/sudoers.d/onebar so later fan switches use `sudo -n`.
    private static func installSudoers() -> Bool {
        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.sync {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let user = NSUserName()
        let path = executablePath
        let line = "\(user) ALL=(root) NOPASSWD: \(path)"
        let shell = "printf '%s\\n' '\(line)' > /etc/sudoers.d/onebar && chmod 440 /etc/sudoers.d/onebar && visudo -cf /etc/sudoers.d/onebar"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return runProcess("/usr/bin/osascript", ["-e", script]).status == 0
    }

    private struct ProcResult {
        var status: Int32?
        var stderr: String
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> ProcResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let err = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = err
        do { try task.run() } catch { return ProcResult(status: nil, stderr: error.localizedDescription) }
        task.waitUntilExit()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        return ProcResult(status: task.terminationStatus, stderr: String(data: data, encoding: .utf8) ?? "")
    }
}

enum HelperCLI {
    static func run(_ argv: [String]) -> Int32 {
        // OneBar helper all <rpm|auto>
        // OneBar helper <index> <rpm|auto>
        guard argv.count >= 4, argv[1] == "helper" else {
            fputs("Usage: OneBar helper <fan_index|all> <rpm|auto>\n", stderr)
            return 1
        }
        let smc = SMC()
        guard smc.open() else {
            fputs("OneBar: cannot open AppleSMC\n", stderr)
            return 1
        }
        defer { smc.close() }

        let count = Int(smc.readDouble("FNum") ?? 0)
        guard count > 0 else {
            fputs("OneBar: SMC reports no fans\n", stderr)
            return 1
        }
        let target = argv[2]
        let indices: [Int]
        if target == "all" {
            indices = Array(0..<count)
        } else if let idx = Int(target), (0...9).contains(idx) {
            indices = [idx]
        } else {
            fputs("OneBar: bad fan index\n", stderr)
            return 1
        }

        if argv[3] == "auto" {
            var ok = true
            for i in indices {
                if !releaseToAuto(smc, fanIndex: i) {
                    fputs("OneBar: failed to release fan \(i) to auto\n", stderr)
                    ok = false
                }
            }
            if smc.keyInfo("Ftst") != nil {
                _ = smc.writeDouble("Ftst", value: 0)
            }
            return ok ? 0 : 1
        }

        guard let rpm = Double(argv[3]), rpm >= 0, rpm <= 20000 else {
            fputs("OneBar: rpm out of range\n", stderr)
            return 1
        }

        var ok = true
        for i in indices {
            let minRPM = smc.readDouble("F\(i)Mn") ?? 0
            let maxRPM = smc.readDouble("F\(i)Mx") ?? rpm
            let clamped = min(max(rpm, minRPM), maxRPM)
            if modeKey(smc, fanIndex: i) != nil, !setManual(smc, fanIndex: i) {
                fputs("OneBar: manual mode rejected for fan \(i)\n", stderr)
                ok = false
                continue
            }
            if var flags = smc.readUInt8("FS! ") {
                flags |= (1 << i)
                _ = smc.writeData("FS! ", bytes: [flags, 0])
            }
            let key = "F\(i)Tg"
            var accepted = false
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                accepted = smc.writeDouble(key, value: clamped)
                if let after = smc.readDouble(key), abs(after - clamped) < 2 { break }
                usleep(150_000)
            }
            if !accepted {
                fputs("OneBar: SMC rejected write to \(key)\n", stderr)
                ok = false
            }
        }
        return ok ? 0 : 1
    }

    private static func modeKey(_ smc: SMC, fanIndex: Int) -> String? {
        ["F\(fanIndex)Md", "F\(fanIndex)md"].first { smc.keyInfo($0) != nil }
    }

    /// Manual is mode 1. Auto is 0; Apple Silicon thermalmonitord uses 3 (system). Both 0 and 3 mean "not ours".
    private static func isHeldManual(_ smc: SMC, fanIndex: Int) -> Bool {
        guard let mk = modeKey(smc, fanIndex: fanIndex) else { return false }
        return smc.readUInt8(mk) == 1
    }

    private static func setManual(_ smc: SMC, fanIndex: Int) -> Bool {
        guard let mk = modeKey(smc, fanIndex: fanIndex) else { return true }
        if smc.readUInt8(mk) == 1 { return true }
        let hasTst = smc.keyInfo("Ftst") != nil
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = smc.writeDouble(mk, value: 1)
            if hasTst { _ = smc.writeDouble("Ftst", value: 1) }
            if smc.readUInt8(mk) == 1 { return true }
            usleep(120_000)
        }
        return smc.readUInt8(mk) == 1
    }

    private static func releaseToAuto(_ smc: SMC, fanIndex: Int) -> Bool {
        if var flags = smc.readUInt8("FS! ") {
            flags &= ~(1 << fanIndex)
            _ = smc.writeData("FS! ", bytes: [flags, 0])
        }
        guard let mk = modeKey(smc, fanIndex: fanIndex) else { return true }
        if !isHeldManual(smc, fanIndex: fanIndex) { return true }
        _ = smc.writeDouble(mk, value: 0)
        if !isHeldManual(smc, fanIndex: fanIndex) { return true }
        if smc.keyInfo("Ftst") != nil {
            _ = smc.writeDouble("Ftst", value: 0)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = smc.writeDouble(mk, value: 0)
            if !isHeldManual(smc, fanIndex: fanIndex) { return true }
            usleep(100_000)
        }
        return !isHeldManual(smc, fanIndex: fanIndex)
    }
}

@MainActor
final class FanController: ObservableObject {
    private static let modeKey = "onebar.fan.mode"
    private static let rpmKey = "onebar.fan.rpm"
    private static let curveKey = "onebar.fan.curve"

    @Published var fans: [FanInfo] = []
    @Published var cpuTemp: Double?
    @Published var hottestTemp: Double?
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var needsAdmin = false
    @Published var writeError: String?
    @Published var passwordless = false
    @Published var competitor: String?
    @Published var mode: FanMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var fixedRPM: Double
    @Published var curvePoints: [FanCurvePoint]
    @Published var applying = false
    @Published private(set) var curveTargetRPM: Double = 0

    private let smc = SMC()
    private var timer: Timer?
    private var lastReapply = Date.distantPast
    private var lastAppliedRPM: Double?
    private var curveLevel = -1
    private var ascendEntry: Double?
    private var ascendSince: Date?
    private var applyGeneration = 0
    private var writeInFlightGeneration: Int?
    private var readFailStreak = 0
    private var lastSilentCurveApply = Date.distantPast
    private var cpuKeys: [String] = []
    private var tempKeys: [String] = []
    private var isEditingSpeed = false
    private var speedEditBegan = Date.distantPast
    private var curveDebounce: DispatchWorkItem?

    var sliderMin: Double {
        fans.map(\.minRPM).min() ?? 1200
    }

    var sliderMax: Double {
        fans.map(\.maxRPM).max() ?? 6500
    }

    var menuTitle: String {
        if let temp = cpuTemp {
            let rpm = fans.map(\.actualRPM).max() ?? 0
            return String(format: "FAN %.0f° %.0f", temp, rpm)
        }
        if let rpm = fans.map(\.actualRPM).max() {
            return String(format: "FAN %.0f", rpm)
        }
        return "FAN"
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.modeKey) ?? FanMode.auto.rawValue
        mode = FanMode(rawValue: stored) ?? .auto
        let rpm = UserDefaults.standard.object(forKey: Self.rpmKey) as? Double ?? 5000
        fixedRPM = rpm
        curvePoints = Self.loadCurve()
        passwordless = PrivilegedWriter.hasPasswordlessSudo()
        if smc.open() {
            isConnected = true
            loadFans()
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            DispatchQueue.main.async { [weak self] in
                self?.discoverTemps()
                self?.refreshTemps()
                self?.refreshCurveTarget()
                if self?.mode == .fixed {
                    self?.applyFixed(silent: true)
                } else if self?.mode == .curve {
                    self?.applyCurveIfNeeded(force: true, silent: true)
                }
            }
        } else {
            errorMessage = "找不到 SMC（需要实体 Mac）"
        }
    }

    private static func loadCurve() -> [FanCurvePoint] {
        guard let data = UserDefaults.standard.data(forKey: curveKey),
              let points = try? JSONDecoder().decode([FanCurvePoint].self, from: data),
              !points.isEmpty else {
            return FanCurve.defaults
        }
        // A stored curve identical to the pre-50–70° defaults was never customized;
        // move it to the finer defaults instead of pinning the old coarse one.
        if points.count == FanCurve.legacyDefaults.count,
           zip(points, FanCurve.legacyDefaults).allSatisfy({
               abs($0.celsius - $1.celsius) < 0.5 && abs($0.rpm - $1.rpm) < 1
           }) {
            return FanCurve.defaults
        }
        return points
    }

    private func persistRPM() {
        UserDefaults.standard.set(fixedRPM, forKey: Self.rpmKey)
    }

    private func persistCurve() {
        if let data = try? JSONEncoder().encode(curvePoints) {
            UserDefaults.standard.set(data, forKey: Self.curveKey)
        }
    }

    private func loadFans(reset: Bool = true) {
        guard let count = smc.readDouble("FNum"), count > 0 else {
            if reset { errorMessage = "没有风扇（无风扇机型）" }
            return
        }
        let fresh = (0..<Int(count)).compactMap { index -> FanInfo? in
            guard let actual = smc.readDouble("F\(index)Ac"),
                  let minRPM = smc.readDouble("F\(index)Mn"),
                  let maxRPM = smc.readDouble("F\(index)Mx") else { return nil }
            return FanInfo(
                id: index,
                actualRPM: actual,
                minRPM: minRPM,
                maxRPM: maxRPM,
                targetRPM: smc.readDouble("F\(index)Tg") ?? actual,
                isManual: readManualFlag(index: index) ?? false
            )
        }
        guard !fresh.isEmpty else {
            if reset { errorMessage = "没有风扇（无风扇机型）" }
            return
        }
        errorMessage = nil
        fans = fresh
    }

    private func readManualFlag(index: Int) -> Bool? {
        if let flags = smc.readUInt8("FS! ") {
            return (flags & (1 << index)) != 0
        }
        if let mode = smc.readUInt8("F\(index)Md") ?? smc.readUInt8("F\(index)md") {
            return mode == 1
        }
        return nil
    }

    @discardableResult
    private func refreshFanReadings() -> Bool {
        var any = false
        for i in fans.indices {
            let idx = fans[i].id
            if let actual = smc.readDouble("F\(idx)Ac"), actual >= 0, actual <= fans[i].maxRPM * 1.5 + 1000 {
                fans[i].actualRPM = actual
                any = true
            }
            if let target = smc.readDouble("F\(idx)Tg") {
                fans[i].targetRPM = target
                any = true
            }
            if let manual = readManualFlag(index: idx) {
                fans[i].isManual = manual
                any = true
            }
        }
        return any
    }

    private func tick() {
        if refreshFanReadings() {
            readFailStreak = 0
        } else {
            readFailStreak += 1
            if readFailStreak >= 3 {
                // Fan values frozen/gone usually means the SMC connection went stale; rebuild it.
                readFailStreak = 0
                smc.close()
                if smc.open() { loadFans(reset: false) }
            }
        }
        refreshTemps()
        competitor = Self.detectCompetitor()
        refreshCurveTarget()
        if isEditingSpeed, Date().timeIntervalSince(speedEditBegan) < 30 { return }
        isEditingSpeed = false
        guard writeInFlightGeneration == nil else { return }
        switch mode {
        case .fixed:
            if Date().timeIntervalSince(lastReapply) > 8, !fans.allSatisfy(\.isManual) {
                applyFixed(silent: true)
            }
        case .curve:
            applyCurveIfNeeded(force: false, silent: true)
        case .auto:
            break
        }
    }

    private func discoverTemps() {
        let count = min(smc.keyCount(), 4000)
        for i in 0..<count {
            guard let key = smc.key(atIndex: i), key.first == "T" else { continue }
            guard let value = smc.readDouble(key), value > 1, value < 125 else { continue }
            tempKeys.append(key)
            if key.hasPrefix("Tp") || key.hasPrefix("Te") {
                cpuKeys.append(key)
            }
        }
    }

    private func refreshTemps() {
        var cpu: Double?
        var hottest: Double?
        for key in cpuKeys {
            if let value = smc.readDouble(key), value > 1, value < 125 {
                cpu = max(cpu ?? value, value)
            }
        }
        for key in tempKeys {
            if let value = smc.readDouble(key), value > 1, value < 125 {
                hottest = max(hottest ?? value, value)
            }
        }
        cpuTemp = cpu ?? hottest
        hottestTemp = hottest
    }

    func refreshCurveTarget() {
        let temp = cpuTemp ?? hottestTemp ?? 0
        let floor = sliderMin
        let sorted = FanCurve.sortedPoints(curvePoints)
        let raw = FanCurve.level(for: temp, sorted: sorted)
        if raw > curveLevel {
            let step = FanCurve.ascentTick(
                rawLevel: raw,
                currentLevel: curveLevel,
                sorted: sorted,
                entry: ascendEntry,
                since: ascendSince,
                now: Date(),
                sustain: FanCurve.ascendSustain,
                bypassCelsius: FanCurve.ascendBypassCelsius
            )
            curveLevel = step.level
            ascendEntry = step.entry
            ascendSince = step.since
        } else {
            ascendEntry = nil
            ascendSince = nil
            curveLevel = FanCurve.stableLevel(
                for: temp,
                sorted: sorted,
                currentLevel: curveLevel,
                hysteresis: FanCurve.dropHysteresis
            )
        }
        var target = FanCurve.rpm(level: curveLevel, sorted: sorted, floor: floor)
        if temp >= 100 { target = sliderMax }
        curveTargetRPM = min(max(target, sliderMin), sliderMax)
    }

    /// Curve edits invalidate the held level and any pending ascend wait;
    /// re-derive from raw temp on the new curve.
    private func resetCurveLevel() {
        let temp = cpuTemp ?? hottestTemp ?? 0
        curveLevel = FanCurve.level(for: temp, sorted: FanCurve.sortedPoints(curvePoints))
        ascendEntry = nil
        ascendSince = nil
    }

    static func detectCompetitor() -> String? {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: {
            ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("macsfan")
                || ($0.localizedName ?? "").localizedCaseInsensitiveContains("Macs Fan Control")
        }) {
            return "Macs Fan Control"
        }
        return nil
    }

    func authorize() {
        applying = true
        writeError = nil
        Task.detached { [weak self] in
            let ok = PrivilegedWriter.ensureAuthorized()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applying = false
                self.passwordless = ok
                self.needsAdmin = !ok
            }
        }
    }

    nonisolated private static func setAutoWithRetry() -> PrivilegedWriter.Outcome {
        var outcome = PrivilegedWriter.setAllAuto()
        if !outcome.ok {
            Thread.sleep(forTimeInterval: 0.4)
            outcome = PrivilegedWriter.setAllAuto()
        }
        return outcome
    }

    nonisolated private static func setFixedWithRetry(rpm: Double, promptIfNeeded: Bool) -> PrivilegedWriter.Outcome {
        var outcome = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: promptIfNeeded)
        if !outcome.ok {
            Thread.sleep(forTimeInterval: 0.4)
            outcome = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: promptIfNeeded)
        }
        return outcome
    }

    func selectAuto() {
        mode = .auto
        applying = true
        writeError = nil
        applyGeneration += 1
        let generation = applyGeneration
        writeInFlightGeneration = generation
        Task.detached { [weak self] in
            let outcome = Self.setAutoWithRetry()
            let passwordless = outcome.ok || PrivilegedWriter.hasPasswordlessSudo()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.applyGeneration == generation else { return }
                self.writeInFlightGeneration = nil
                self.applying = false
                self.recordResult(ok: outcome.ok, passwordless: passwordless, failText: "交还系统控制失败，请再试一次。", detail: outcome.detail)
                if outcome.ok {
                    for i in self.fans.indices { self.fans[i].isManual = false }
                }
            }
        }
    }

    func selectFixed() {
        mode = .fixed
        applyFixed()
    }

    func selectCurve() {
        mode = .curve
        refreshCurveTarget()
        applyCurveIfNeeded(force: true, silent: false)
    }

    func beginSpeedEdit() {
        isEditingSpeed = true
        speedEditBegan = Date()
    }

    func endSpeedEdit() {
        isEditingSpeed = false
    }

    /// Clear one-off failure hints so a stale error doesn't haunt every panel open.
    func clearTransientFeedback() {
        applying = false
        writeError = nil
        needsAdmin = false
    }

    func applyFixed(rpm: Double? = nil, silent: Bool = false) {
        isEditingSpeed = false
        if let rpm {
            fixedRPM = rpm
        }
        let clamped = min(max(fixedRPM, sliderMin), sliderMax)
        fixedRPM = clamped
        persistRPM()
        writeRPM(clamped, silent: silent)
    }

    func addCurvePoint() {
        guard curvePoints.count < 8 else { return }
        let lastCelsius = curvePoints.map(\.celsius).max() ?? 40
        let lastRPM = curvePoints.max(by: { $0.celsius < $1.celsius })?.rpm ?? sliderMin
        let taken = Set(curvePoints.map { Int($0.celsius.rounded()) })
        var nextTemp = min(lastCelsius + 10, 105)
        while taken.contains(Int(nextTemp.rounded())) && nextTemp > 0 {
            nextTemp -= 5
        }
        guard !taken.contains(Int(nextTemp.rounded())) else { return }
        let nextRPM = min(max(lastRPM + 500, sliderMin), sliderMax)
        curvePoints.append(FanCurvePoint(celsius: nextTemp, rpm: nextRPM))
        persistCurve()
        resetCurveLevel()
        scheduleCurveApply()
    }

    func removeCurvePoint(_ id: UUID) {
        guard curvePoints.count > 1 else { return }
        curvePoints.removeAll { $0.id == id }
        persistCurve()
        resetCurveLevel()
        scheduleCurveApply()
    }

    func updateCurvePoint(id: UUID, celsius: Double? = nil, rpm: Double? = nil) {
        guard let index = curvePoints.firstIndex(where: { $0.id == id }) else { return }
        if let celsius {
            curvePoints[index].celsius = min(max(celsius, 0), 110)
        }
        if let rpm {
            curvePoints[index].rpm = min(max(rpm, sliderMin), sliderMax)
        }
        persistCurve()
        resetCurveLevel()
        scheduleCurveApply()
    }

    private func scheduleCurveApply() {
        refreshCurveTarget()
        guard mode == .curve else { return }
        curveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyCurveIfNeeded(force: true, silent: false)
        }
        curveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func applyCurveIfNeeded(force: Bool, silent: Bool) {
        refreshCurveTarget()
        let target = curveTargetRPM
        let stale = Date().timeIntervalSince(lastReapply) > 8 && !fans.allSatisfy(\.isManual)
        let changed = lastAppliedRPM.map { abs($0 - target) >= 80 } ?? true
        guard force || stale || changed else { return }
        if silent, !force, Date().timeIntervalSince(lastSilentCurveApply) < 3 { return }
        if silent { lastSilentCurveApply = Date() }
        writeRPM(target, silent: silent)
    }

    private func writeRPM(_ rpm: Double, silent: Bool) {
        lastAppliedRPM = rpm
        lastReapply = Date()
        applyGeneration += 1
        let generation = applyGeneration
        writeInFlightGeneration = generation
        if silent {
            Task.detached { [weak self] in
                let outcome = Self.setFixedWithRetry(rpm: rpm, promptIfNeeded: false)
                let passwordless = outcome.ok || PrivilegedWriter.hasPasswordlessSudo()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.writeInFlightGeneration == generation { self.writeInFlightGeneration = nil }
                    guard self.applyGeneration == generation else { return }
                    self.recordResult(ok: outcome.ok, passwordless: passwordless, failText: "自动调整转速失败，请重新切换一次策略。", detail: outcome.detail)
                }
            }
            return
        }
        applying = true
        writeError = nil
        Task.detached { [weak self] in
            let outcome = Self.setFixedWithRetry(rpm: rpm, promptIfNeeded: true)
            let passwordless = outcome.ok || PrivilegedWriter.hasPasswordlessSudo()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.applyGeneration == generation else { return }
                self.writeInFlightGeneration = nil
                self.applying = false
                self.recordResult(ok: outcome.ok, passwordless: passwordless, failText: "写入转速失败，请再试一次。", detail: outcome.detail)
            }
        }
    }

    private func recordResult(ok: Bool, passwordless: Bool, failText: String, detail: String = "") {
        self.passwordless = passwordless
        if ok {
            needsAdmin = false
            writeError = nil
            return
        }
        if passwordless {
            needsAdmin = false
            writeError = detail.isEmpty ? failText : "\(failText)（\(detail)）"
        } else {
            needsAdmin = true
            writeError = nil
        }
    }

    nonisolated func restoreAutoOnQuit() {
        PrivilegedWriter.setAllAutoSilently()
    }
}
