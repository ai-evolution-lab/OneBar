import Foundation

extension MenuBarSelection {
    static func runSelfTest() -> Int32 {
        let suite = "OneBar.MenuBarSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            if !value { failures += 1; fputs("menu bar selftest failed: \(message)\n", stderr) }
        }
        let apps = (0..<10).map { "test.app.\($0)" }
        var preferences = MenuBarSelection(defaults: defaults)
        check(preferences.hidden.isEmpty, "first launch should show all apps")
        for app in apps.dropFirst(3) { preferences.setVisible(false, bundle: app, defaults: defaults) }
        let chosen = Set(preferences.allowedBundles(running: Set(apps))).intersection(apps)
        check(chosen == Set(apps.prefix(3)), "10 apps, exactly the selected 3 stay visible")
        let restored = MenuBarSelection(defaults: defaults)
        check(restored.hidden == preferences.hidden, "selection survives app restart")
        let fresh = "test.newApp"
        check(restored.allowedBundles(running: Set(apps + [fresh])).contains(fresh), "new apps are visible")
        check(!restored.allowedBundles(running: Set(apps)).contains(apps[8]), "hidden app stays hidden after PID/relaunch changes")
        preferences.setVisible(true, bundle: apps[8], defaults: defaults)
        check(preferences.allowedBundles(running: Set(apps)).contains(apps[8]), "a hidden app can be shown independently")
        for id in [ownBundle, "com.apple.MenuBarAgent", "com.apple.controlcenter", ""] {
            preferences.setVisible(false, bundle: id, defaults: defaults)
            check(!preferences.hidden.contains(id), "protected app cannot be hidden: \(id)")
        }
        defaults.set([ownBundle, "com.apple.clock", apps[7]], forKey: key)
        let sanitized = MenuBarSelection(defaults: defaults)
        check(sanitized.hidden == [apps[7]], "stored preferences cannot hide own/system controls")
        let allow = sanitized.allowedBundles(running: [])
        check(allow.contains(ownBundle) && allow.contains("com.apple.MenuBarAgent"), "control remains reachable without inventory")
        for id in preferences.hidden { preferences.setVisible(true, bundle: id, defaults: defaults) }
        check(MenuBarSelection(defaults: defaults).hidden.isEmpty, "show all clears persisted hiding")
        print("Menu bar selection selftest: \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
        return failures == 0 ? 0 : 1
    }
}
