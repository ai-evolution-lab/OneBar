import Foundation
import AppKit

// Root-side fan writes. The app talks to one resident `sudo -n OneBar helper serve`
// over stdin/stdout; one-shot `sudo -n OneBar helper all <rpm|auto>` remains the
// fallback (and the authorization probe). Helper path adapted from MacsFan (MIT).

/// The only commands the root helper accepts. Parsing is strict on purpose: the
/// helper runs as root, so anything not byte-for-byte `all auto` / `all <digits>`
/// is rejected.
enum HelperCommand: Equatable {
    case fixed(Int)
    case auto

    static let rpmRange = 0...20000

    var line: String {
        switch self {
        case .fixed(let rpm): return "all \(rpm)"
        case .auto: return "all auto"
        }
    }

    static func fixed(rpm: Double) -> HelperCommand {
        .fixed(Int(min(max(rpm.rounded(), Double(rpmRange.lowerBound)), Double(rpmRange.upperBound))))
    }

    static func parse(_ line: String) -> HelperCommand? {
        let bytes = Array(line.utf8)
        guard bytes.count <= 16 else { return nil }
        let parts = bytes.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard parts.count == 2, Array(parts[0]) == Array("all".utf8) else { return nil }
        let arg = Array(parts[1])
        if arg == Array("auto".utf8) { return .auto }
        guard (1...5).contains(arg.count),
              arg.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = Int(String(decoding: arg, as: UTF8.self)),
              rpmRange.contains(value) else { return nil }
        return .fixed(value)
    }
}

/// What the helper does with a parsed command; swapped for a dry-run fake in tests.
protocol FanWriting: AnyObject {
    /// nil on success, otherwise a one-line error.
    func setAll(rpm: Double) -> String?
    func releaseAll() -> String?
}

final class DryRunFanWriter: FanWriting {
    private(set) var calls: [String] = []
    private let echo: Bool

    init(echo: Bool) { self.echo = echo }

    func setAll(rpm: Double) -> String? {
        record("set all \(Int(rpm))")
        return nil
    }

    func releaseAll() -> String? {
        record("release all")
        return nil
    }

    private func record(_ call: String) {
        calls.append(call)
        if echo { fputs("dry-run: \(call)\n", stderr) }
    }
}

final class SMCFanWriter: FanWriting {
    private let smc: SMC
    let count: Int

    private init(smc: SMC, count: Int) {
        self.smc = smc
        self.count = count
    }

    static func open() -> (writer: SMCFanWriter?, error: String) {
        let smc = SMC()
        guard smc.open() else { return (nil, "cannot open AppleSMC") }
        let count = Int(smc.readDouble("FNum") ?? 0)
        guard count > 0 else { return (nil, "SMC reports no fans") }
        return (SMCFanWriter(smc: smc, count: count), "")
    }

    func setAll(rpm: Double) -> String? {
        let errors = (0..<count).compactMap { setFan($0, rpm: rpm) }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    func releaseAll() -> String? {
        let errors = (0..<count).compactMap { releaseFan($0) }
        clearTestMode()
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    func clearTestMode() {
        if smc.keyInfo("Ftst") != nil {
            _ = smc.writeDouble("Ftst", value: 0)
        }
    }

    func setFan(_ i: Int, rpm: Double) -> String? {
        let minRPM = smc.readDouble("F\(i)Mn") ?? 0
        let maxRPM = smc.readDouble("F\(i)Mx") ?? rpm
        let clamped = min(max(rpm, minRPM), maxRPM)
        if modeKey(i) != nil, !setManual(i) {
            return "manual mode rejected for fan \(i)"
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
        return accepted ? nil : "SMC rejected write to \(key)"
    }

    func releaseFan(_ i: Int) -> String? {
        releaseToAuto(i) ? nil : "failed to release fan \(i) to auto"
    }

    private func modeKey(_ i: Int) -> String? {
        ["F\(i)Md", "F\(i)md"].first { smc.keyInfo($0) != nil }
    }

    /// Manual is mode 1. Auto is 0; Apple Silicon thermalmonitord uses 3 (system). Both 0 and 3 mean "not ours".
    private func isHeldManual(_ i: Int) -> Bool {
        guard let mk = modeKey(i) else { return false }
        return smc.readUInt8(mk) == 1
    }

    private func setManual(_ i: Int) -> Bool {
        guard let mk = modeKey(i) else { return true }
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

    private func releaseToAuto(_ i: Int) -> Bool {
        if var flags = smc.readUInt8("FS! ") {
            flags &= ~(1 << i)
            _ = smc.writeData("FS! ", bytes: [flags, 0])
        }
        guard let mk = modeKey(i) else { return true }
        if !isHeldManual(i) { return true }
        _ = smc.writeDouble(mk, value: 0)
        if !isHeldManual(i) { return true }
        if smc.keyInfo("Ftst") != nil {
            _ = smc.writeDouble("Ftst", value: 0)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = smc.writeDouble(mk, value: 0)
            if !isHeldManual(i) { return true }
            usleep(100_000)
        }
        return !isHeldManual(i)
    }
}

enum HelperCLI {
    static func run(_ argv: [String]) -> Int32 {
        // OneBar helper serve [--dry-run]
        // OneBar helper all <rpm|auto>
        // OneBar helper <index> <rpm|auto>
        if argv.count >= 3, argv[1] == "helper", argv[2] == "serve" {
            let dryRun = argv.count == 4 && argv[3] == "--dry-run"
            guard argv.count == 3 || dryRun else {
                fputs("Usage: OneBar helper serve [--dry-run]\n", stderr)
                return 1
            }
            return serveStdio(dryRun: dryRun)
        }
        guard argv.count >= 4, argv[1] == "helper" else {
            fputs("Usage: OneBar helper <fan_index|all> <rpm|auto>\n", stderr)
            return 1
        }
        let (opened, openError) = SMCFanWriter.open()
        guard let writer = opened else {
            fputs("OneBar: \(openError)\n", stderr)
            return 1
        }
        let target = argv[2]
        let indices: [Int]
        if target == "all" {
            indices = Array(0..<writer.count)
        } else if let idx = Int(target), (0...9).contains(idx) {
            indices = [idx]
        } else {
            fputs("OneBar: bad fan index\n", stderr)
            return 1
        }

        if argv[3] == "auto" {
            var ok = true
            for i in indices {
                if let error = writer.releaseFan(i) {
                    fputs("OneBar: \(error)\n", stderr)
                    ok = false
                }
            }
            writer.clearTestMode()
            return ok ? 0 : 1
        }

        guard let rpm = Double(argv[3]), rpm >= 0, rpm <= 20000 else {
            fputs("OneBar: rpm out of range\n", stderr)
            return 1
        }
        var ok = true
        for i in indices {
            if let error = writer.setFan(i, rpm: rpm) {
                fputs("OneBar: \(error)\n", stderr)
                ok = false
            }
        }
        return ok ? 0 : 1
    }

    /// Resident root helper. One command per stdin line, one reply per stdout line
    /// (`ready` once at start, then `ok` / `err <msg>`). stdin EOF means the app quit
    /// or crashed: hand every fan back to the system before exiting, so a dead app
    /// can't leave the fans pinned at a manual speed.
    private static func serveStdio(dryRun: Bool) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let writer: FanWriting
        if dryRun {
            writer = DryRunFanWriter(echo: true)
        } else {
            let (opened, error) = SMCFanWriter.open()
            guard let opened else {
                fputs("OneBar: \(error)\n", stderr)
                return 1
            }
            writer = opened
        }
        let lock = NSLock()
        // SIGTERM/HUP/INT (e.g. sudo relaying a kill) also release before exiting.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                lock.lock()
                _ = writer.releaseAll()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        let status = serve(
            readLine: { Swift.readLine(strippingNewline: true) },
            reply: { line in
                fputs(line + "\n", stdout)
                fflush(stdout)
            },
            writer: writer,
            lock: lock
        )
        sources.forEach { $0.cancel() }
        return status
    }

    /// Protocol loop, separated from stdio so selftest can drive it with a fake writer.
    static func serve(
        readLine: () -> String?,
        reply: (String) -> Void,
        writer: FanWriting,
        lock: NSLock = NSLock()
    ) -> Int32 {
        reply("ready")
        while let line = readLine() {
            guard let command = HelperCommand.parse(line) else {
                reply("err bad command")
                continue
            }
            lock.lock()
            let error: String?
            switch command {
            case .fixed(let rpm): error = writer.setAll(rpm: Double(rpm))
            case .auto: error = writer.releaseAll()
            }
            lock.unlock()
            if let error {
                let flat = error.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                reply("err \(flat.prefix(200))")
            } else {
                reply("ok")
            }
        }
        lock.lock()
        let error = writer.releaseAll()
        lock.unlock()
        if let error { fputs("OneBar: \(error)\n", stderr) }
        // Non-zero tells the app the hand-back failed so it can fall back to a one-shot run.
        return error == nil ? 0 : 1
    }
}

/// App-side handle to one resident helper process.
final class HelperSession {
    enum Reply: Equatable {
        case ok
        case err(String)
        case dead
    }

    let process: Process
    private let inFD: Int32
    private let outFD: Int32
    private let inHandle: FileHandle
    private let outHandle: FileHandle
    private var errHandle: FileHandle?
    private var buffer: [UInt8] = []
    private let stateLock = NSLock()
    private var inputClosed = false
    private var stderrTail = ""

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        inHandle = input
        outHandle = output
        inFD = input.fileDescriptor
        outFD = output.fileDescriptor
        // A dead helper must surface as EPIPE, not a SIGPIPE that kills the app.
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
    }

    var isRunning: Bool { process.isRunning }

    var stderrText: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stderrTail
    }

    /// Launch and wait for the `ready` line. On failure returns the helper's stderr.
    static func launch(_ launchPath: String, _ arguments: [String], readyTimeout: TimeInterval) -> (session: HelperSession?, failure: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        let session = HelperSession(process: task, input: inPipe.fileHandleForWriting, output: outPipe.fileHandleForReading)
        session.errHandle = errPipe.fileHandleForReading
        errPipe.fileHandleForReading.readabilityHandler = { [weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            session?.appendStderr(String(decoding: data, as: UTF8.self))
        }
        do { try task.run() } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (nil, error.localizedDescription)
        }
        guard let line = session.readLine(timeout: readyTimeout), line == "ready" else {
            session.terminate()
            _ = session.waitExit(timeout: 1)
            // stderr arrives through the async handler; give it a moment to land.
            for _ in 0..<15 where session.stderrText.isEmpty { usleep(20_000) }
            let tail = session.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, tail.isEmpty ? "helper did not become ready" : tail)
        }
        return (session, "")
    }

    func send(_ command: HelperCommand, timeout: TimeInterval) -> Reply {
        guard writeLine(command.line) else { return .dead }
        let deadline = Date().addingTimeInterval(timeout)
        // Skip anything that isn't a reply (e.g. a pty echo of our own line if sudo
        // is configured with use_pty).
        while let line = readLine(timeout: deadline.timeIntervalSinceNow) {
            if line == "ok" { return .ok }
            if line.hasPrefix("err ") { return .err(String(line.dropFirst(4))) }
        }
        return .dead
    }

    /// EOF tells the helper to release the fans and exit.
    func closeInput() {
        stateLock.lock()
        let shouldClose = !inputClosed
        inputClosed = true
        stateLock.unlock()
        if shouldClose { try? inHandle.close() }
    }

    func waitExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        return !process.isRunning
    }

    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
    }

    /// Close input, give the helper time to release, then make sure it is gone.
    @discardableResult
    func shutdown(timeout: TimeInterval) -> Bool {
        closeInput()
        let clean = waitExit(timeout: timeout) && process.terminationStatus == 0
        if process.isRunning { process.terminate() }
        return clean
    }

    private func appendStderr(_ text: String) {
        stateLock.lock()
        stderrTail = String((stderrTail + text).suffix(2000))
        stateLock.unlock()
    }

    private func writeLine(_ line: String) -> Bool {
        stateLock.lock()
        let closed = inputClosed
        stateLock.unlock()
        guard !closed else { return false }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(inFD, raw.baseAddress! + offset, raw.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }

    /// nil on timeout or EOF.
    private func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var end = newline
                if end > buffer.startIndex, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, 60_000)))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 256)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(outFD, $0.baseAddress!, 256) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 4096 { return nil }
        }
    }
}

enum PrivilegedWriter {
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Serialize every root write: two concurrent root SMC writers make writes fail intermittently.
    private static let queue = DispatchQueue(label: "onebar.fan.helper")
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var session: HelperSession?
    nonisolated(unsafe) private static var nextLaunch = Date.distantPast
    nonisolated(unsafe) private static var quitting = false
    nonisolated(unsafe) private static var quitReleased = false
    /// Module off / asleep: writes already queued must not relaunch the helper.
    nonisolated(unsafe) private static var suspended = false

    /// One SMC write per fan can take ~3 s of retries; leave room for two fans plus mode switch.
    private static let replyTimeout: TimeInterval = 20

    private static let logURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/OneBar-fan.log")

    struct Outcome {
        var ok: Bool
        var detail: String
        var unauthorized = false
    }

    /// A live session already proves passwordless sudo; otherwise probe with a one-shot run.
    static func hasPasswordlessSudo() -> Bool {
        lock.lock()
        let alive = session?.isRunning == true
        lock.unlock()
        if alive { return true }
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
        allowRelaunch()
        return hasPasswordlessSudo()
    }

    static func setAllFixed(rpm: Double, promptIfNeeded: Bool = true) -> Outcome {
        perform(.fixed(rpm: rpm), promptIfNeeded: promptIfNeeded)
    }

    static func setAllAuto(promptIfNeeded: Bool = true) -> Outcome {
        perform(.auto, promptIfNeeded: promptIfNeeded)
    }

    static func suspend() {
        lock.lock()
        suspended = true
        lock.unlock()
    }

    static func resume() {
        lock.lock()
        suspended = false
        nextLaunch = .distantPast
        lock.unlock()
    }

    /// Module off / sleep: stop the resident helper (EOF makes it release the fans);
    /// without one, release with a one-shot run when asked. Never prompts.
    static func deactivate(release: Bool) {
        queue.sync {
            lock.lock()
            // Re-enabled before this ran: don't undo the fresh take-over.
            guard suspended || quitting else {
                lock.unlock()
                return
            }
            let current = session
            session = nil
            lock.unlock()
            if let current, current.shutdown(timeout: 4) { return }
            if release { _ = oneShot(.auto) }
        }
    }

    /// Quit path: synchronous, never prompts, never waits on `queue` (which may be
    /// blocked on an auth prompt that needs the main thread).
    static func setAllAutoSilently() {
        lock.lock()
        let already = quitReleased
        quitting = true
        quitReleased = true
        let current = session
        session = nil
        lock.unlock()
        // quit() and applicationWillTerminate both call this; one hand-back is enough.
        guard !already else { return }
        if let current, current.shutdown(timeout: 4) { return }
        _ = runProcess("/usr/bin/sudo", ["-n", executablePath, "helper", "all", "auto"])
    }

    private static func allowRelaunch() {
        lock.lock()
        nextLaunch = .distantPast
        lock.unlock()
    }

    private static func perform(_ command: HelperCommand, promptIfNeeded: Bool) -> Outcome {
        queue.sync {
            lock.lock()
            let paused = suspended || quitting
            lock.unlock()
            if paused { return Outcome(ok: false, detail: "风扇控制已暂停") }
            if let outcome = viaSession(command) { return outcome }
            // Quit/suspend may have landed while we were talking to the helper.
            lock.lock()
            let pausedNow = suspended || quitting
            lock.unlock()
            if pausedNow { return Outcome(ok: false, detail: "风扇控制已暂停") }
            var outcome = oneShot(command)
            if outcome.unauthorized, promptIfNeeded, installSudoers() {
                allowRelaunch()
                if let viaHelper = viaSession(command) { return viaHelper }
                outcome = oneShot(command)
            }
            return outcome
        }
    }

    /// nil when no resident helper is available; caller falls back to one-shot.
    private static func viaSession(_ command: HelperCommand) -> Outcome? {
        for _ in 0..<2 {
            guard let current = liveSession() else { return nil }
            switch current.send(command, timeout: replyTimeout) {
            case .ok:
                return Outcome(ok: true, detail: "")
            case .err(let message):
                appendLog("serve \(command.line) -> err \(message)")
                return Outcome(ok: false, detail: String(message.prefix(100)))
            case .dead:
                appendLog("serve \(command.line) -> helper died: \(current.stderrText)")
                lock.lock()
                if session === current { session = nil }
                lock.unlock()
                current.terminate()
            }
        }
        return nil
    }

    private static func liveSession() -> HelperSession? {
        lock.lock()
        if quitting {
            lock.unlock()
            return nil
        }
        if let current = session, current.isRunning {
            lock.unlock()
            return current
        }
        session = nil
        let mayLaunch = Date() >= nextLaunch
        lock.unlock()
        guard mayLaunch else { return nil }

        let (launched, failure) = HelperSession.launch(
            "/usr/bin/sudo",
            ["-n", executablePath, "helper", "serve"],
            readyTimeout: 5
        )
        lock.lock()
        defer { lock.unlock() }
        guard let launched else {
            // Unauthorized won't fix itself; don't spawn sudo on every tick.
            nextLaunch = Date().addingTimeInterval(isUnauthorized(failure) ? 60 : 10)
            appendLog("serve launch failed: \(failure)")
            return nil
        }
        if quitting {
            launched.terminate()
            return nil
        }
        session = launched
        return launched
    }

    private static func oneShot(_ command: HelperCommand) -> Outcome {
        let args: [String]
        switch command {
        case .fixed(let rpm): args = ["all", String(rpm)]
        case .auto: args = ["all", "auto"]
        }
        let result = runProcess("/usr/bin/sudo", ["-n", executablePath, "helper"] + args)
        if result.status == 0 { return Outcome(ok: true, detail: "") }
        if isUnauthorized(result.stderr) {
            return Outcome(ok: false, detail: "未授权", unauthorized: true)
        }
        appendLog("helper \(args.joined(separator: " ")) -> status \(result.status.map(String.init) ?? "nil"): \(result.stderr)")
        let detail = result.stderr
            .split(separator: "\n")
            .filter { !$0.localizedCaseInsensitiveContains("usage") }
            .joined(separator: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: false, detail: String(detail.prefix(100)))
    }

    static func isUnauthorized(_ stderr: String) -> Bool {
        let err = stderr.lowercased()
        return (err.contains("password") && !err.contains("usage"))
            || err.contains("a terminal is required")
            || err.contains("not in the sudoers")
            || err.contains("not allowed to execute")
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
