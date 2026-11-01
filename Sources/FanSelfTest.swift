import Foundation

// `OneBar selftest`: curve math, control state machine, helper protocol. No SMC writes.

extension FanCurve {
    static func runSelfTest() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if !ok {
                failures += 1
                fputs("fan selftest failed: \(what())\n", stderr)
            }
        }

        // User's curve.
        let user = sortedPoints([
            FanCurvePoint(celsius: 60, rpm: 4800),
            FanCurvePoint(celsius: 50, rpm: 3000),
            FanCurvePoint(celsius: 65, rpm: 6000),
            FanCurvePoint(celsius: 55, rpm: 4200),
        ])

        // Interpolation.
        let interp: [(Double, Double)] = [
            (40, 3000), (50, 3000), (52.5, 3600), (55, 4200), (57.5, 4500), (62.5, 5400), (65, 6000), (90, 6000),
        ]
        for (temp, expected) in interp {
            let got = interpolatedRPM(for: temp, sorted: user) ?? -1
            check(abs(got - expected) < 0.01, "interp \(temp) -> \(got) expected \(expected)")
        }
        check(interpolatedRPM(for: 60, sorted: []) == nil, "interp empty")
        let dup = sortedPoints([FanCurvePoint(celsius: 60, rpm: 2000), FanCurvePoint(celsius: 60, rpm: 3000)])
        check(interpolatedRPM(for: 60, sorted: dup) != nil, "interp duplicate temps")

        // Migration: old stored JSON still loads; untouched legacy defaults move to the new defaults.
        let stored = #"[{"id":"7D8E1C2A-0000-4000-8000-000000000001","celsius":50,"rpm":3000},{"id":"7D8E1C2A-0000-4000-8000-000000000002","celsius":55,"rpm":4200}]"#
        let decoded = decodeStored(Data(stored.utf8))
        check(decoded?.count == 2 && decoded?.first?.rpm == 3000, "stored curve decode")
        let legacy = try! JSONEncoder().encode(legacyDefaults)
        check(decodeStored(legacy) == defaults, "legacy defaults migrate")
        check(decodeStored(Data("[]".utf8)) == nil, "empty stored curve")

        // Smoother: a lone spike barely moves it, a real step gets through.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var smoother = TempSmoother()
        for i in 0..<10 { smoother.update(60, at: t0 + Double(i) * 2) }
        smoother.update(78, at: t0 + 20)            // one-sample spike
        check(abs((smoother.value ?? 0) - 60) < 0.01, "spike leaked: \(smoother.value ?? 0)")
        smoother.update(60, at: t0 + 22)
        check(abs((smoother.value ?? 0) - 60) < 0.01, "spike after-effect: \(smoother.value ?? 0)")
        for i in 0..<6 { smoother.update(80, at: t0 + 24 + Double(i) * 2) }
        check((smoother.value ?? 0) > 75, "step not followed within 12s: \(smoother.value ?? 0)")
        smoother.update(60, at: t0 + 36)
        smoother.update(60, at: t0 + 38)
        check((smoother.value ?? 0) > 75, "fall followed too fast: \(smoother.value ?? 0)")
        smoother.update(60, at: t0 + 200)           // long gap resets state
        check(smoother.value == 60, "gap reset: \(smoother.value ?? 0)")

        // Engine helpers.
        let minRPM = 1200.0, maxRPM = 6241.0
        func step(_ e: inout CurveEngine, _ smoothed: Double, raw: Double? = nil, at t: Double, current: Double? = nil) -> CurveEngine.Action {
            e.step(smoothed: smoothed, raw: raw ?? smoothed, now: t0 + t, sorted: user,
                   minRPM: minRPM, maxRPM: maxRPM, currentRPM: current)
        }

        // Emergency bypass on real temp: 45° → 90° must hit max within two samples,
        // even though smoothing lags and the curve tops out at 65°.
        var e = CurveEngine()
        _ = step(&e, 52, at: 0, current: 3000)
        _ = step(&e, 52, raw: 91, at: 2)
        check(!e.emergency, "single 91° sample tripped emergency")
        let hot = step(&e, 56, raw: 92, at: 4)
        check(e.emergency && hot == .write(maxRPM), "emergency not immediate: \(hot)")
        _ = step(&e, 80, raw: 84, at: 6)
        check(e.emergency, "emergency released before hold")
        _ = step(&e, 80, raw: 84, at: 16)
        check(!e.emergency, "emergency not released after cooling")

        // Single raw spike from idle doesn't trip it either.
        e = CurveEngine()
        _ = step(&e, 55, at: 0, current: 4200)
        _ = step(&e, 55, raw: 95, at: 2)
        _ = step(&e, 55, raw: 56, at: 4)
        check(!e.emergency && (e.target ?? 0) < 4300, "spike moved target: \(e.target ?? 0)")

        // Ramp: up ≤ +600 per 2 s, down ≤ −200 per 2 s; sub-100 changes aren't written.
        e = CurveEngine()
        var a = step(&e, 50, at: 0, current: 3000)
        check(a == .write(3000), "first write \(a)")
        a = step(&e, 65, at: 2)
        check(a == .write(3600), "ramp up step 1: \(a)")
        a = step(&e, 65, at: 4)
        check(a == .write(4200), "ramp up step 2: \(a)")
        for i in 3...6 { _ = step(&e, 65, at: Double(i) * 2) }
        check(e.commanded == 6000, "ramp up reach target: \(e.commanded ?? 0)")
        a = step(&e, 55, at: 14)
        check(a == .write(5800), "ramp down step: \(a)")
        e = CurveEngine()
        _ = step(&e, 55, at: 0, current: 4200)
        a = step(&e, 55.1, at: 2)
        check(a == .none, "deadband write: \(a)")

        // Drop hysteresis on the curve input: a 1.5° dip doesn't lower the target.
        e = CurveEngine()
        _ = step(&e, 60, at: 0, current: 4800)
        _ = step(&e, 58.5, at: 2)
        check(e.target == 4800, "small dip lowered target: \(e.target ?? 0)")
        _ = step(&e, 57, at: 4)
        check((e.target ?? 0) < 4800, "real drop ignored: \(e.target ?? 0)")

        // Hand-back below the curve: < lowest − 3° releases (after dwell), stays released
        // until ≥ lowest and dwell, no flapping in between.
        e = CurveEngine()
        a = step(&e, 45, at: 0)
        check(a == .release && e.phase == .released, "start below curve should release: \(a)")
        a = step(&e, 48, at: 2)
        check(a == .none, "released repeats auto: \(a)")
        a = step(&e, 51, at: 10)
        check(e.phase == .released && a == .none, "re-took control before dwell")
        a = step(&e, 51, at: 31)
        if case .write = a {} else { check(false, "no take-over after dwell: \(a)") }
        check(e.phase == .controlling, "phase after take-over")
        a = step(&e, 46.5, at: 40)
        check(e.phase == .controlling, "released before dwell")
        a = step(&e, 48, at: 62)
        check(e.phase == .controlling, "released inside margin (48 ≥ 47)")
        a = step(&e, 46.5, at: 64)
        check(a == .release && e.phase == .released, "release below margin: \(a)")
        a = step(&e, 49.5, at: 100)
        check(e.phase == .released, "re-took control below lowest point")
        _ = step(&e, 47, raw: 92, at: 102)
        a = step(&e, 47, raw: 93, at: 104)
        check(e.phase == .controlling && a == .write(maxRPM), "emergency must override released: \(a)")
        e = CurveEngine()
        _ = step(&e, 45, at: 0)
        e.releaseFailed()
        a = step(&e, 45, at: 2)
        check(a == .release, "failed release not retried: \(a)")

        // Helper protocol.
        let parseCases: [(String, HelperCommand?)] = [
            ("all auto", .auto), ("all 3000", .fixed(3000)), ("all 0", .fixed(0)), ("all 20000", .fixed(20000)),
            ("all 20001", nil), ("all -1", nil), ("all 3000.5", nil), ("all", nil), ("all  3000", nil),
            (" all 3000", nil), ("all 3000 ", nil), ("ALL auto", nil), ("0 3000", nil), ("all 0x10", nil),
            ("all 99999999999999999999", nil), ("all auto;rm", nil), ("all +300", nil), ("", nil),
            ("all ３０００", nil), ("all 3000\u{0}", nil),
        ]
        for (line, expected) in parseCases {
            check(HelperCommand.parse(line) == expected, "parse \(line.debugDescription)")
        }
        check(HelperCommand.fixed(rpm: 3456.6) == .fixed(3457) && HelperCommand.fixed(rpm: 1e9) == .fixed(20000), "fixed(rpm:) clamp")

        let fake = DryRunFanWriter(echo: false)
        var input = ["all 3000", "bogus", "all auto", "all 25000"][...]
        var replies: [String] = []
        let status = HelperCLI.serve(
            readLine: { input.popFirst() },
            reply: { replies.append($0) },
            writer: fake
        )
        check(status == 0, "serve status \(status)")
        check(replies == ["ready", "ok", "err bad command", "ok", "err bad command"], "serve replies \(replies)")
        check(fake.calls == ["set all 3000", "release all", "release all"], "serve calls \(fake.calls)")

        // End-to-end over real pipes: our own binary in dry-run, no sudo involved.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let (session, failure) = HelperSession.launch(exe, ["helper", "serve", "--dry-run"], readyTimeout: 5)
        if let session {
            check(session.send(.fixed(3200), timeout: 5) == .ok, "session fixed")
            check(session.send(.auto, timeout: 5) == .ok, "session auto")
            check(session.shutdown(timeout: 5), "session EOF exit")
            usleep(100_000)
            let log = session.stderrText
            check(log.contains("set all 3200") && log.components(separatedBy: "release all").count == 3, "session log: \(log)")
            check(session.send(.auto, timeout: 1) == .dead, "send after exit should be dead")
        } else {
            check(false, "session launch: \(failure)")
        }

        if failures == 0 { print("fan selftest ok") }
        return failures == 0 ? 0 : 1
    }
}
