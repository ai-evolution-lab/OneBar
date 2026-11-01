import Foundation
import AppKit

// Fan control: Auto, one shared fixed RPM, or a temperature curve. Writes on Apple
// Silicon need root and go through the resident helper (FanHelper.swift). SMC reads
// stay off the main thread on `FanSensor`'s serial queue.

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

/// Stored format is unchanged from the step-curve days ({id, celsius, rpm}); only
/// the meaning moved from "at/above T use R" to "R at T, interpolate between".
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

    static func sortedPoints(_ points: [FanCurvePoint]) -> [FanCurvePoint] {
        points.sorted { $0.celsius < $1.celsius }
    }

    /// Linear between neighbouring points; flat at the first point's RPM below it and
    /// at the last point's RPM above it. nil only for an empty curve.
    static func interpolatedRPM(for temp: Double, sorted: [FanCurvePoint]) -> Double? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if temp <= first.celsius { return first.rpm }
        if temp >= last.celsius { return last.rpm }
        for (lo, hi) in zip(sorted, sorted.dropFirst()) where temp <= hi.celsius {
            let span = hi.celsius - lo.celsius
            guard span > 0.01 else { return hi.rpm }
            return lo.rpm + (hi.rpm - lo.rpm) * (temp - lo.celsius) / span
        }
        return last.rpm
    }

    static func decodeStored(_ data: Data) -> [FanCurvePoint]? {
        guard let points = try? JSONDecoder().decode([FanCurvePoint].self, from: data),
              !points.isEmpty else { return nil }
        // A stored curve identical to the pre-50–70° defaults was never customized;
        // move it to the finer defaults instead of pinning the old coarse one.
        if points.count == legacyDefaults.count,
           zip(points, legacyDefaults).allSatisfy({
               abs($0.celsius - $1.celsius) < 0.5 && abs($0.rpm - $1.rpm) < 1
           }) {
            return defaults
        }
        return points
    }
}

/// Spike filter + asymmetric EMA for one temperature source.
///
/// Measured on this M1 Pro (max of all Tp/Te keys, 1 s sampling): idle stdev 2.2°,
/// 2 s range 7.5°, single-sample jumps up to 12° that revert next sample; GPU (Tg)
/// is calmer (stdev 0.7°). Median-of-3 removes one-sample spikes outright; the EMA
/// then follows rises with τ=4 s (a real 61→84° load step crosses 75° in ~12 s)
/// and falls with τ=20 s, so a brief dip doesn't spin the fans down only to spin
/// them up again. Simulated at the app's 2 s cadence this cut idle range from 7.5°
/// to 2.3° (stdev 2.1° → 0.66°).
struct TempSmoother {
    static let tauUp: TimeInterval = 4
    static let tauDown: TimeInterval = 20
    /// A gap this long (sleep, module off) makes the old state meaningless.
    static let resetGap: TimeInterval = 30

    private var window: [Double] = []
    private(set) var value: Double?
    private var last: Date?

    @discardableResult
    mutating func update(_ raw: Double?, at now: Date) -> Double? {
        guard let raw else { return value }
        if let last, now.timeIntervalSince(last) > Self.resetGap { reset() }
        let dt = last.map { min(max(now.timeIntervalSince($0), 0), 10) } ?? 0
        last = now
        window.append(raw)
        if window.count > 3 { window.removeFirst() }
        let filtered = window.sorted()[(window.count - 1) / 2]
        guard let previous = value else {
            value = filtered
            return value
        }
        let tau = filtered > previous ? Self.tauUp : Self.tauDown
        value = previous + (1 - exp(-dt / tau)) * (filtered - previous)
        return value
    }

    mutating func reset() {
        window.removeAll()
        value = nil
        last = nil
    }
}

/// Curve-mode state machine: smoothed temp → interpolated target → rate-limited
/// command, plus hand-back to the system below the curve and an emergency bypass on
/// the real (unsmoothed) temperature. Pure value type so selftest can drive it.
struct CurveEngine {
    enum Phase: Equatable {
        /// Fresh (mode entered, wake, module re-enabled): decide on the next step.
        case starting
        case controlling
        case released
    }

    enum Action: Equatable {
        case none
        case write(Double)
        case release
    }

    /// Hand the fans back to the system once smoothed temp is this far below the lowest point.
    static let handoverMargin: Double = 3
    /// Minimum time in a phase before switching controlling ↔ released (unless emergency).
    static let handoverDwell: TimeInterval = 30
    /// Temp used for the curve follows rises at once but only follows a fall after it
    /// exceeds this, so ±1–2° wobble of the smoothed value doesn't move the target.
    static let dropHysteresis: Double = 2
    /// Real temp at/above this on `emergencySamples` consecutive samples → max RPM,
    /// skipping smoothing and ramp. Two samples (≈2 s apart) so one 12° spike can't trip it.
    static let emergencyCelsius: Double = 90
    static let emergencySamples = 2
    /// Leave emergency once both real and smoothed temp are below this and it held ≥ `emergencyHold`.
    static let emergencyExitCelsius: Double = 85
    static let emergencyHold: TimeInterval = 10
    /// RPM per second. At the 2 s cadence: +600 / −200 per tick. Rising fast matters for
    /// heat; falling slowly is what makes the change inaudible.
    static let rampUpPerSecond: Double = 300
    static let rampDownPerSecond: Double = 100
    /// Commands closer than this to the last written value aren't sent.
    static let writeDeadband: Double = 100

    private(set) var phase: Phase = .starting
    private(set) var phaseSince = Date.distantPast
    private(set) var heldTemp: Double?
    /// Interpolated (pre-ramp) target; nil while released.
    private(set) var target: Double?
    /// Ramp output — what we want the fans at right now.
    private(set) var commanded: Double?
    private(set) var lastWritten: Double?
    private(set) var emergency = false
    private var emergencySince = Date.distantPast
    private var hotStreak = 0
    private var lastStep: Date?
    private var releasePending = false

    mutating func step(
        smoothed: Double?,
        raw: Double?,
        now: Date,
        sorted: [FanCurvePoint],
        minRPM: Double,
        maxRPM: Double,
        currentRPM: Double?
    ) -> Action {
        let dt = lastStep.map { min(max(now.timeIntervalSince($0), 0), 4) } ?? 2
        lastStep = now
        guard let smoothed, let lowest = sorted.first?.celsius else { return .none }

        if let raw, raw >= Self.emergencyCelsius { hotStreak += 1 } else { hotStreak = 0 }
        if hotStreak >= Self.emergencySamples {
            if !emergency { emergencySince = now }
            emergency = true
        } else if emergency,
                  smoothed < Self.emergencyExitCelsius,
                  (raw ?? 0) < Self.emergencyExitCelsius,
                  now.timeIntervalSince(emergencySince) >= Self.emergencyHold {
            emergency = false
        }

        let dwellDone = now.timeIntervalSince(phaseSince) >= Self.handoverDwell
        switch phase {
        case .starting:
            if !emergency, smoothed < lowest - Self.handoverMargin {
                return enterReleased(now)
            }
            enterControlling(now, smoothed: smoothed)
        case .released:
            if emergency || (smoothed >= lowest && dwellDone) {
                enterControlling(now, smoothed: smoothed)
            } else {
                if releasePending {
                    releasePending = false
                    return .release
                }
                return .none
            }
        case .controlling:
            if !emergency, smoothed < lowest - Self.handoverMargin, dwellDone {
                return enterReleased(now)
            }
        }

        if let held = heldTemp, smoothed < held {
            if smoothed < held - Self.dropHysteresis { heldTemp = smoothed + Self.dropHysteresis }
        } else {
            heldTemp = smoothed
        }
        let curveRPM = FanCurve.interpolatedRPM(for: heldTemp ?? smoothed, sorted: sorted) ?? minRPM
        let goal = emergency ? maxRPM : min(max(curveRPM, minRPM), maxRPM)
        target = goal

        let start = min(max(commanded ?? currentRPM ?? minRPM, minRPM), maxRPM)
        let next: Double
        if emergency {
            next = goal
        } else if goal > start {
            next = min(goal, start + Self.rampUpPerSecond * dt)
        } else {
            next = max(goal, start - Self.rampDownPerSecond * dt)
        }
        commanded = next
        if let lastWritten, abs(next - lastWritten) < Self.writeDeadband { return .none }
        lastWritten = next
        return .write(next)
    }

    /// Force the next step to write even inside the deadband (fans drifted, write failed).
    mutating func invalidate() {
        lastWritten = nil
    }

    mutating func writeFailed() {
        lastWritten = nil
    }

    mutating func releaseFailed() {
        if phase == .released { releasePending = true }
    }

    mutating func reset() {
        self = CurveEngine()
    }

    private mutating func enterReleased(_ now: Date) -> Action {
        phase = .released
        phaseSince = now
        target = nil
        commanded = nil
        lastWritten = nil
        heldTemp = nil
        releasePending = false
        return .release
    }

    private mutating func enterControlling(_ now: Date, smoothed: Double) {
        phase = .controlling
        phaseSince = now
        heldTemp = smoothed
        commanded = nil
        lastWritten = nil
    }
}

/// Which SMC temperature keys feed what. Families with a lowercase second letter are
/// the SoC's on-die sensors; on this M1 Pro they all rose 9–26° under an all-core load.
/// Uppercase families are board/peripheral sensors (TB battery, TA/Ta ambient & airflow,
/// TH SSD, TD/TP/TR/TV/TS/TW power rails, regulators, Wi-Fi…): ±0–2° under the same load
/// or obviously not die temps, so they're kept out of "全机最高". TG* (battery gauge,
/// `ioft`) doesn't even decode. Tz* reads 0.
enum TempKeys {
    enum Kind {
        case cpu
        case gpu
        case chip
    }

    static func kind(of key: String) -> Kind? {
        guard key.utf8.count == 4, key.hasPrefix("T") else { return nil }
        switch key.prefix(2) {
        case "Tp", "Te": return .cpu   // P-core / E-core clusters
        case "Tg": return .gpu
        case "Tm", "Ts", "Th", "Td": return .chip
        default: return nil
        }
    }

    static func plausible(_ value: Double) -> Bool {
        value > 1 && value < 125
    }
}

struct FanSample {
    var connected = false
    /// nil when this read failed; keep showing the previous fans.
    var fans: [FanInfo]?
    var fanError: String?
    var cpu: Double?
    var gpu: Double?
    var hottest: Double?
}

/// Owns the read-only SMC connection. Every call runs on `queue`, so the SMC instance
/// is never touched from two threads.
final class FanSensor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "onebar.fan.smc", qos: .utility)
    private let smc = SMC()
    private var discovered = false
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var chipKeys: [String] = []
    private var fans: [FanInfo] = []
    private var readFailStreak = 0

    func sample(_ completion: @escaping @Sendable (FanSample) -> Void) {
        queue.async { [self] in completion(read()) }
    }

    private func read() -> FanSample {
        var sample = FanSample()
        guard smc.open() else { return sample }
        sample.connected = true
        if !discovered {
            discovered = true
            discoverTemps()
            sample.fanError = loadFans()
        } else if refreshFans() {
            readFailStreak = 0
        } else {
            readFailStreak += 1
            if readFailStreak >= 3 {
                // Fan values frozen/gone usually means the SMC connection went stale; rebuild it.
                readFailStreak = 0
                smc.close()
                if smc.open() { _ = loadFans() }
            }
        }
        if !fans.isEmpty { sample.fans = fans }
        sample.cpu = maxTemp(cpuKeys)
        sample.gpu = maxTemp(gpuKeys)
        sample.hottest = [sample.cpu, sample.gpu, maxTemp(chipKeys)].compactMap { $0 }.max()
        return sample
    }

    private func maxTemp(_ keys: [String]) -> Double? {
        keys.compactMap { smc.readDouble($0) }.filter(TempKeys.plausible).max()
    }

    private func discoverTemps() {
        let count = min(smc.keyCount(), 4000)
        for i in 0..<count {
            guard let key = smc.key(atIndex: i), let kind = TempKeys.kind(of: key) else { continue }
            guard let value = smc.readDouble(key), TempKeys.plausible(value) else { continue }
            switch kind {
            case .cpu: cpuKeys.append(key)
            case .gpu: gpuKeys.append(key)
            case .chip: chipKeys.append(key)
            }
        }
    }

    /// nil on success, else the message to show.
    private func loadFans() -> String? {
        guard let count = smc.readDouble("FNum"), count > 0 else { return "没有风扇（无风扇机型）" }
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
        guard !fresh.isEmpty else { return "没有风扇（无风扇机型）" }
        fans = fresh
        return nil
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

    private func refreshFans() -> Bool {
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
}

@MainActor
final class FanController: ObservableObject {
    enum CurveState: Equatable {
        case following
        case released
        case emergency
    }

    private static let modeKey = "onebar.fan.mode"
    private static let rpmKey = "onebar.fan.rpm"
    private static let curveKey = "onebar.fan.curve"
    private static let sampleInterval: TimeInterval = 2

    @Published var fans: [FanInfo] = []
    /// Display temps, rounded to whole degrees so a 0.1° wobble doesn't republish the UI.
    @Published private(set) var cpuTemp: Double?
    @Published private(set) var gpuTemp: Double?
    @Published private(set) var hottestTemp: Double?
    /// Smoothed max(CPU, GPU) — what the curve acts on.
    @Published private(set) var controlTemp: Double?
    @Published private(set) var curveTargetRPM: Double = 0
    @Published private(set) var curveState: CurveState = .following
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

    private let sensor = FanSensor()
    private var timer: Timer?
    private var active = true
    private var sleeping = false
    private var sampleInFlight = false
    private var cpuSmoother = TempSmoother()
    private var gpuSmoother = TempSmoother()
    private var hottestSmoother = TempSmoother()
    private var smoothedControl: Double?
    private var rawControl: Double?
    private var engine = CurveEngine()
    /// Apply the current mode once fresh readings arrive (launch, wake, re-enable).
    private var takeoverPending = true
    private var lastReapply = Date.distantPast
    private var lastWriteDone = Date.distantPast
    private var retryAfter = Date.distantPast
    private var applyGeneration = 0
    private var writeInFlightGeneration: Int?
    private var isEditingSpeed = false
    private var speedEditBegan = Date.distantPast
    private var observers: [NSObjectProtocol] = []

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
        Task.detached(priority: .utility) { [weak self] in
            let ok = PrivilegedWriter.hasPasswordlessSudo()
            await MainActor.run { [weak self] in self?.passwordless = ok }
        }
        observePower()
        startTimer()
        requestSample()
    }

    private static func loadCurve() -> [FanCurvePoint] {
        guard let data = UserDefaults.standard.data(forKey: curveKey) else { return FanCurve.defaults }
        return FanCurve.decodeStored(data) ?? FanCurve.defaults
    }

    private func persistRPM() {
        UserDefaults.standard.set(fixedRPM, forKey: Self.rpmKey)
    }

    private func persistCurve() {
        if let data = try? JSONEncoder().encode(curvePoints) {
            UserDefaults.standard.set(data, forKey: Self.curveKey)
        }
    }

    // MARK: Module on/off

    /// false: stop sampling and every write, hand the fans back to the system and stop
    /// the root helper (in the background). true: resume sampling and re-take control
    /// per the current mode.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            PrivilegedWriter.resume()
            engine.reset()
            takeoverPending = true
            retryAfter = .distantPast
            startTimer()
            requestSample()
            return
        }
        timer?.invalidate()
        timer = nil
        applyGeneration += 1
        writeInFlightGeneration = nil
        applying = false
        takeoverPending = false
        engine.reset()
        let release = mode != .auto || fans.contains(where: \.isManual)
        PrivilegedWriter.suspend()
        Task.detached(priority: .utility) {
            PrivilegedWriter.deactivate(release: release)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestSample() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })
    }

    /// Hand back to the system before sleeping; a manual speed held through sleep/wake
    /// is exactly how fans end up stuck. Waits briefly so it lands before the system sleeps.
    private func handleWillSleep() {
        sleeping = true
        applyGeneration += 1
        writeInFlightGeneration = nil
        applying = false
        engine.reset()
        guard active else { return }
        PrivilegedWriter.suspend()
        let release = mode != .auto || fans.contains(where: \.isManual)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            PrivilegedWriter.deactivate(release: release)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private func handleDidWake() {
        sleeping = false
        if active { PrivilegedWriter.resume() }
        cpuSmoother.reset()
        gpuSmoother.reset()
        hottestSmoother.reset()
        engine.reset()
        guard active else { return }
        takeoverPending = true
        // SMC writes right at wake are flaky; let readings settle first.
        retryAfter = Date().addingTimeInterval(3)
        requestSample()
    }

    // MARK: Sampling

    private func requestSample() {
        guard active, !sleeping, !sampleInFlight else { return }
        sampleInFlight = true
        sensor.sample { sample in
            Task { @MainActor [weak self] in self?.apply(sample) }
        }
    }

    private func apply(_ sample: FanSample) {
        sampleInFlight = false
        guard active, !sleeping else { return }
        if isConnected != sample.connected { isConnected = sample.connected }
        if let fresh = sample.fans, fresh != fans { fans = fresh }
        let error: String?
        if !sample.connected {
            error = "找不到 SMC（需要实体 Mac）"
        } else if fans.isEmpty {
            error = sample.fanError ?? errorMessage
        } else {
            error = nil
        }
        if errorMessage != error { errorMessage = error }

        let now = Date()
        let cpu = cpuSmoother.update(sample.cpu, at: now)
        let gpu = gpuSmoother.update(sample.gpu, at: now)
        let hottest = hottestSmoother.update(sample.hottest, at: now)
        // Display smoothed values too: raw CPU max jumps ~7° between 2 s samples,
        // which made the menu bar number flicker without meaning anything.
        setIfChanged(\.cpuTemp, Self.display(cpu ?? hottest))
        setIfChanged(\.gpuTemp, Self.display(gpu))
        setIfChanged(\.hottestTemp, Self.display(hottest))

        smoothedControl = [cpu, gpu].compactMap { $0 }.max() ?? hottest
        rawControl = [sample.cpu, sample.gpu].compactMap { $0 }.max() ?? sample.hottest
        setIfChanged(\.controlTemp, smoothedControl.map { ($0 * 10).rounded() / 10 })

        let other = Self.detectCompetitor()
        if competitor != other { competitor = other }
        drive(userInitiated: false)
    }

    private static func display(_ value: Double?) -> Double? {
        value.map { $0.rounded() }
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<FanController, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Control loop

    private func drive(userInitiated: Bool) {
        let now = Date()
        guard active, !sleeping, isConnected, !fans.isEmpty else {
            refreshCurvePreview()
            return
        }
        if !userInitiated, now < retryAfter {
            refreshCurvePreview()
            return
        }
        if takeoverPending {
            takeoverPending = false
            engine.reset()
            if mode == .fixed {
                applyFixed(silent: true)
                return
            }
        }
        switch mode {
        case .auto:
            refreshCurvePreview()
        case .fixed:
            refreshCurvePreview()
            // Don't fight the slider mid-drag. Curve mode ignores this: its edits only
            // land on commit, and it must keep running for the emergency bypass.
            if isEditingSpeed, now.timeIntervalSince(speedEditBegan) < 30 { return }
            isEditingSpeed = false
            guard writeInFlightGeneration == nil, now.timeIntervalSince(lastReapply) > 8, fixedDrifted() else { return }
            applyFixed(silent: true)
        case .curve:
            stepCurve(userInitiated: userInitiated, now: now)
        }
    }

    /// Fixed mode doesn't rewrite on a timer: only when the fans visibly left our
    /// manual setting (system reset after wake, another tool, SMC hiccup).
    private func fixedDrifted() -> Bool {
        fans.contains { fan in
            let wanted = min(max(fixedRPM, fan.minRPM), fan.maxRPM)
            return !fan.isManual || abs(fan.targetRPM - wanted) > 100
        }
    }

    private func stepCurve(userInitiated: Bool, now: Date) {
        // Background ticks wait for the previous write; a user switch supersedes it
        // (writes are serialized in PrivilegedWriter anyway).
        guard userInitiated || writeInFlightGeneration == nil else { return }
        if engine.phase == .controlling, engine.lastWritten != nil,
           now.timeIntervalSince(lastWriteDone) > 6, !fans.allSatisfy(\.isManual) {
            // Something took the fans back (wake, thermalmonitord, another app): re-assert.
            engine.invalidate()
        }
        let action = engine.step(
            smoothed: smoothedControl,
            raw: rawControl,
            now: now,
            sorted: FanCurve.sortedPoints(curvePoints),
            minRPM: sliderMin,
            maxRPM: sliderMax,
            currentRPM: fans.map(\.actualRPM).max()
        )
        publishCurveState()
        switch action {
        case .none:
            break
        case .write(let rpm):
            writeRPM(rpm, silent: !userInitiated, fromCurve: true)
        case .release:
            releaseForCurve(userInitiated: userInitiated)
        }
    }

    private func publishCurveState() {
        let state: CurveState = engine.emergency ? .emergency : (engine.phase == .released ? .released : .following)
        setIfChanged(\.curveState, state)
        setIfChanged(\.curveTargetRPM, (engine.target ?? 0).rounded())
    }

    /// Outside curve mode (or before the engine has run), show what the curve would do now.
    private func refreshCurvePreview() {
        if mode == .curve, engine.phase != .starting {
            publishCurveState()
            return
        }
        let sorted = FanCurve.sortedPoints(curvePoints)
        guard let temp = smoothedControl, let lowest = sorted.first?.celsius else {
            setIfChanged(\.curveTargetRPM, 0)
            return
        }
        if temp < lowest - CurveEngine.handoverMargin {
            setIfChanged(\.curveState, .released)
            setIfChanged(\.curveTargetRPM, 0)
            return
        }
        setIfChanged(\.curveState, .following)
        let rpm = FanCurve.interpolatedRPM(for: temp, sorted: sorted) ?? sliderMin
        setIfChanged(\.curveTargetRPM, min(max(rpm, sliderMin), sliderMax).rounded())
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

    // MARK: User actions

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
                if ok { self.retryAfter = .distantPast }
            }
        }
    }

    nonisolated private static func setAutoWithRetry() -> PrivilegedWriter.Outcome {
        var outcome = PrivilegedWriter.setAllAuto()
        if !outcome.ok, !outcome.unauthorized {
            Thread.sleep(forTimeInterval: 0.4)
            outcome = PrivilegedWriter.setAllAuto()
        }
        return outcome
    }

    nonisolated private static func setFixedWithRetry(rpm: Double, promptIfNeeded: Bool) -> PrivilegedWriter.Outcome {
        var outcome = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: promptIfNeeded)
        if !outcome.ok, !outcome.unauthorized {
            Thread.sleep(forTimeInterval: 0.4)
            outcome = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: promptIfNeeded)
        }
        return outcome
    }

    func selectAuto() {
        mode = .auto
        engine.reset()
        takeoverPending = false
        guard active else { return }
        applying = true
        writeError = nil
        applyGeneration += 1
        let generation = applyGeneration
        writeInFlightGeneration = generation
        Task.detached { [weak self] in
            let outcome = Self.setAutoWithRetry()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.applyGeneration == generation else { return }
                self.writeInFlightGeneration = nil
                self.applying = false
                self.recordResult(outcome, failText: "交还系统控制失败，请再试一次。")
                if outcome.ok {
                    for i in self.fans.indices { self.fans[i].isManual = false }
                }
            }
        }
    }

    func selectFixed() {
        mode = .fixed
        takeoverPending = false
        applyFixed()
    }

    func selectCurve() {
        mode = .curve
        engine.reset()
        takeoverPending = false
        retryAfter = .distantPast
        drive(userInitiated: true)
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
        writeRPM(clamped, silent: silent, fromCurve: false)
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
        curveEdited()
    }

    func removeCurvePoint(_ id: UUID) {
        guard curvePoints.count > 1 else { return }
        curvePoints.removeAll { $0.id == id }
        curveEdited()
    }

    func updateCurvePoint(id: UUID, celsius: Double? = nil, rpm: Double? = nil) {
        guard let index = curvePoints.firstIndex(where: { $0.id == id }) else { return }
        if let celsius {
            curvePoints[index].celsius = min(max(celsius, 0), 110)
        }
        if let rpm {
            curvePoints[index].rpm = min(max(rpm, sliderMin), sliderMax)
        }
        curveEdited()
    }

    /// The engine picks the new curve up on its next tick and ramps toward it.
    private func curveEdited() {
        persistCurve()
        refreshCurvePreview()
    }

    // MARK: Writes

    private func writeRPM(_ rpm: Double, silent: Bool, fromCurve: Bool) {
        guard active else { return }
        lastReapply = Date()
        applyGeneration += 1
        let generation = applyGeneration
        writeInFlightGeneration = generation
        if !silent {
            applying = true
            writeError = nil
        }
        Task.detached { [weak self] in
            let outcome = Self.setFixedWithRetry(rpm: rpm, promptIfNeeded: !silent)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.writeInFlightGeneration == generation { self.writeInFlightGeneration = nil }
                guard self.applyGeneration == generation else { return }
                if !silent { self.applying = false }
                self.lastWriteDone = Date()
                if !outcome.ok {
                    if fromCurve { self.engine.writeFailed() }
                    self.retryAfter = Date().addingTimeInterval(outcome.unauthorized ? 30 : 6)
                }
                let failText = silent ? "自动调整转速失败，请重新切换一次策略。" : "写入转速失败，请再试一次。"
                self.recordResult(outcome, failText: failText)
            }
        }
    }

    /// Curve fell below its lowest point: give the fans back to the system (may stop them).
    private func releaseForCurve(userInitiated: Bool) {
        guard active else { return }
        applyGeneration += 1
        let generation = applyGeneration
        writeInFlightGeneration = generation
        Task.detached { [weak self] in
            let outcome = PrivilegedWriter.setAllAuto(promptIfNeeded: userInitiated)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.writeInFlightGeneration == generation { self.writeInFlightGeneration = nil }
                guard self.applyGeneration == generation else { return }
                self.lastWriteDone = Date()
                if outcome.ok {
                    for i in self.fans.indices { self.fans[i].isManual = false }
                } else {
                    self.engine.releaseFailed()
                    self.retryAfter = Date().addingTimeInterval(outcome.unauthorized ? 30 : 6)
                }
                self.recordResult(outcome, failText: "交还系统控制失败。")
            }
        }
    }

    private func recordResult(_ outcome: PrivilegedWriter.Outcome, failText: String) {
        passwordless = outcome.ok || !outcome.unauthorized
        if outcome.ok {
            needsAdmin = false
            writeError = nil
            return
        }
        if outcome.unauthorized {
            needsAdmin = true
            writeError = nil
        } else {
            needsAdmin = false
            writeError = outcome.detail.isEmpty ? failText : "\(failText)（\(outcome.detail)）"
        }
    }

    nonisolated func restoreAutoOnQuit() {
        PrivilegedWriter.setAllAutoSilently()
    }
}
