import AppKit

@main
struct MacMetricsApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private var preferences: AppPreferences?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let preferences = AppPreferences()
        self.preferences = preferences
        statusController = StatusBarController(preferences: preferences)
    }
}
