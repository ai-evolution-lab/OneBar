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
                if !setMode(smc, fanIndex: i, value: 0) { ok = false }
                if var flags = smc.readUInt8("FS! ") {
                    flags &= ~(1 << i)
                    _ = smc.writeData("FS! ", bytes: [flags, 0])
                }
            }
            let allAuto = (0..<count).allSatisfy { i in
                guard let mk = modeKey(smc, fanIndex: i) else { return true }
                return smc.readUInt8(mk) != 1
            }
            if allAuto, smc.keyInfo("Ftst") != nil {
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
            if modeKey(smc, fanIndex: i) != nil, !setMode(smc, fanIndex: i, value: 1) {
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

    private static func setMode(_ smc: SMC, fanIndex: Int, value: UInt8) -> Bool {
        guard let mk = modeKey(smc, fanIndex: fanIndex) else { return false }
        if smc.readUInt8(mk) == value { return true }
        _ = smc.writeDouble(mk, value: Double(value))
        if smc.readUInt8(mk) == value { return true }
        guard smc.keyInfo("Ftst") != nil else { return false }
        _ = smc.writeDouble("Ftst", value: 1)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            _ = smc.writeDouble(mk, value: Double(value))
            if smc.readUInt8(mk) == value { return true }
            usleep(100_000)
        }
        return false
    }
}

@MainActor
final class FanController: ObservableObject {
    @Published var fans: [FanInfo] = []
    @Published var cpuTemp: Double?
    @Published var hottestTemp: Double?
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var needsAdmin = false
    @Published var passwordless = false
    @Published var competitor: String?
    @Published var mode: FanMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "onebar.fan.mode") }
    }
    @Published var fixedRPM: Double {
        didSet { UserDefaults.standard.set(fixedRPM, forKey: "onebar.fan.rpm") }
    }
    @Published var applying = false

    private let smc = SMC()
    private var timer: Timer?
    private var lastReapply = Date.distantPast
    private var cpuKeys: [String] = []
    private var tempKeys: [String] = []

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
        let stored = UserDefaults.standard.string(forKey: "onebar.fan.mode") ?? FanMode.auto.rawValue
        mode = FanMode(rawValue: stored) ?? .auto
        let rpm = UserDefaults.standard.object(forKey: "onebar.fan.rpm") as? Double ?? 5000
        fixedRPM = rpm
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
            }
            if mode == .fixed {
                applyFixed(silent: true)
            }
        } else {
            errorMessage = "找不到 SMC（需要实体 Mac）"
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
        if let firstMax = fans.map(\.maxRPM).max(), fixedRPM > firstMax + 1 {
            // keep user value; clamp happens on write
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
        if mode == .fixed, Date().timeIntervalSince(lastReapply) > 8 {
            let allManual = fans.allSatisfy(\.isManual)
            if !allManual {
                applyFixed(silent: true)
            }
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
        Task.detached { [weak self] in
            let ok = PrivilegedWriter.setAllAuto()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applying = false
                self.passwordless = PrivilegedWriter.hasPasswordlessSudo()
                self.needsAdmin = !ok
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

    func applyFixed(silent: Bool = false) {
        let rpm = min(max(fixedRPM, sliderMin), sliderMax)
        fixedRPM = rpm
        lastReapply = Date()
        if silent {
            Task.detached {
                _ = PrivilegedWriter.setAllFixed(rpm: rpm, promptIfNeeded: false)
            }
            return
        }
        applying = true
        Task.detached { [weak self] in
            let ok = PrivilegedWriter.setAllFixed(rpm: rpm)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applying = false
                self.passwordless = PrivilegedWriter.hasPasswordlessSudo()
                self.needsAdmin = !ok
            }
        }
    }

    nonisolated func restoreAutoOnQuit() {
        PrivilegedWriter.setAllAutoSilently()
    }
}
