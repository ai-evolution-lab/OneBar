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
    static let defaults: [FanCurvePoint] = [
        FanCurvePoint(celsius: 55, rpm: 2000),
        FanCurvePoint(celsius: 70, rpm: 3500),
        FanCurvePoint(celsius: 85, rpm: 5200),
    ]

    /// Highest matching threshold; below all points uses `floor`.
    static func rpm(for temp: Double, points: [FanCurvePoint], floor: Double) -> Double {
        let sorted = points.sorted { $0.celsius < $1.celsius }
        var result = floor
        for point in sorted where temp >= point.celsius {
            result = point.rpm
        }
        return result
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
        return 0
    }
}

enum PrivilegedWriter {
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
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

    static func setAllFixed(rpm: Double, promptIfNeeded: Bool = true) -> Bool {
        runHelper(["all", String(format: "%.0f", rpm)], promptIfNeeded: promptIfNeeded)
    }

    static func setAllAuto(promptIfNeeded: Bool = true) -> Bool {
        runHelper(["all", "auto"], promptIfNeeded: promptIfNeeded)
    }

    static func setAllAutoSilently() {
        _ = runProcess("/usr/bin/sudo", ["-n", executablePath, "helper", "all", "auto"])
    }

    private static func runHelper(_ helperArgs: [String], promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            guard ensureAuthorized() else { return false }
        } else if !hasPasswordlessSudo() {
            return false
        }
        return runProcess("/usr/bin/sudo", ["-n", executablePath, "helper"] + helperArgs).status == 0
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
                if !releaseToAuto(smc, fanIndex: i) { ok = false }
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
            if !accepted { ok = false }
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
        _ = smc.writeDouble(mk, value: 1)
        if smc.readUInt8(mk) == 1 { return true }
        guard smc.keyInfo("Ftst") != nil else { return false }
        _ = smc.writeDouble("Ftst", value: 1)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            _ = smc.writeDouble(mk, value: 1)
            if smc.readUInt8(mk) == 1 { return true }
            usleep(100_000)
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
    private var applyGeneration = 0
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

    private func loadFans() {
        guard let count = smc.readDouble("FNum"), count > 0 else {
            errorMessage = "没有风扇（无风扇机型）"
            return
        }
        fans = (0..<Int(count)).compactMap { index in
            guard let actual = smc.readDouble("F\(index)Ac"),
                  let minRPM = smc.readDouble("F\(index)Mn"),
                  let maxRPM = smc.readDouble("F\(index)Mx") else { return nil }
            return FanInfo(
                id: index,
                actualRPM: actual,
                minRPM: minRPM,
                maxRPM: maxRPM,
                targetRPM: smc.readDouble("F\(index)Tg") ?? actual,
                isManual: isManual(index: index)
            )
        }
    }

    private func isManual(index: Int) -> Bool {
        if let flags = smc.readUInt8("FS! ") {
            return (flags & (1 << index)) != 0
        }
        if let mode = smc.readUInt8("F\(index)Md") ?? smc.readUInt8("F\(index)md") {
            return mode == 1
        }
        return false
    }

    private func tick() {
        for i in fans.indices {
            let idx = fans[i].id
            if let actual = smc.readDouble("F\(idx)Ac") { fans[i].actualRPM = actual }
            if let target = smc.readDouble("F\(idx)Tg") { fans[i].targetRPM = target }
            fans[i].isManual = isManual(index: idx)
        }
        refreshTemps()
        competitor = Self.detectCompetitor()
        refreshCurveTarget()
        if isEditingSpeed, Date().timeIntervalSince(speedEditBegan) < 30 { return }
        isEditingSpeed = false
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
        var target = FanCurve.rpm(for: temp, points: curvePoints, floor: floor)
        if temp >= 100 { target = sliderMax }
        curveTargetRPM = min(max(target, sliderMin), sliderMax)
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

    func selectAuto() {
        mode = .auto
        applying = true
        writeError = nil
        applyGeneration += 1
        let generation = applyGeneration
        Task.detached { [weak self] in
            let ok = PrivilegedWriter.setAllAuto()
            let passwordless = ok || PrivilegedWriter.hasPasswordlessSudo()
            await MainActor.run { [weak self] in
                guard let self, self.applyGeneration == generation else { return }
                self.applying = false
                self.recordResult(ok: ok, passwordless: passwordless, failText: "交还系统控制失败，请再试一次。")
                if ok {
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
        let last = curvePoints.max(by: { $0.celsius < $1.celsius })
        let nextTemp = min(99, (last?.celsius ?? 50) + 10)
        let nextRPM = min(sliderMax, (last?.rpm ?? sliderMin) + 500)
        curvePoints.append(FanCurvePoint(celsius: nextTemp, rpm: nextRPM))
        persistCurve()
        scheduleCurveApply()
    }

    func removeCurvePoint(_ id: UUID) {
        guard curvePoints.count > 1 else { return }
        curvePoints.removeAll { $0.id == id }
        persistCurve()
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
        writeRPM(target, silent: silent)
    }

    private func writeRPM(_ rpm: Double, silent: Bool) {
        lastAppliedRPM = rpm
        lastReapply = Date()
        applyGeneration += 1
        let generation = applyGeneration
        if silent {
            Task.detached {
                _ = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: false)
            }
            return
        }
        applying = true
        writeError = nil
        Task.detached { [weak self] in
            let ok = PrivilegedWriter.setAllFixed(rpm: rpm)
            let passwordless = ok || PrivilegedWriter.hasPasswordlessSudo()
            await MainActor.run { [weak self] in
                guard let self, self.applyGeneration == generation else { return }
                self.applying = false
                self.recordResult(ok: ok, passwordless: passwordless, failText: "写入转速失败，请再试一次。")
            }
        }
    }

    private func recordResult(ok: Bool, passwordless: Bool, failText: String) {
        self.passwordless = passwordless
        if ok {
            needsAdmin = false
            writeError = nil
            return
        }
        if passwordless {
            needsAdmin = false
            writeError = failText
        } else {
            needsAdmin = true
            writeError = nil
        }
    }

    nonisolated func restoreAutoOnQuit() {
        PrivilegedWriter.setAllAutoSilently()
    }
}
