import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showsCPU: Bool {
        didSet { UserDefaults.standard.set(showsCPU, forKey: Keys.showsCPU) }
    }
    @Published var showsGPU: Bool {
        didSet { UserDefaults.standard.set(showsGPU, forKey: Keys.showsGPU) }
    }
    @Published var showsRAM: Bool {
        didSet { UserDefaults.standard.set(showsRAM, forKey: Keys.showsRAM) }
    }
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Keys.refreshInterval) }
    }
    @Published private(set) var launchAtLoginStatus: SMAppService.Status
    @Published private(set) var launchAtLoginError: String?

    var launchAtLogin: Bool { launchAtLoginStatus == .enabled }

    init(defaults: UserDefaults = .standard) {
        showsCPU = defaults.object(forKey: Keys.showsCPU) as? Bool ?? true
        showsGPU = defaults.object(forKey: Keys.showsGPU) as? Bool ?? true
        showsRAM = defaults.object(forKey: Keys.showsRAM) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 2
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginStatus = SMAppService.mainApp.status
        } catch {
            launchAtLoginStatus = SMAppService.mainApp.status
            launchAtLoginError = error.localizedDescription
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private enum Keys {
        static let showsCPU = "menu.showCPU"
        static let showsGPU = "menu.showGPU"
        static let showsRAM = "menu.showRAM"
        static let refreshInterval = "sampling.refreshInterval"
    }
}

@MainActor
final class SettingsWindowController {
    private let preferences: AppPreferences
    private var window: NSWindow?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func show() {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            created.title = "Mac Metrics Settings"
            created.isReleasedWhenClosed = false
            created.contentMinSize = NSSize(width: 460, height: 390)
            created.contentViewController = NSHostingController(rootView: SettingsView(preferences: preferences))
            self.window = created
            window = created
        }
        preferences.refreshLaunchAtLoginStatus()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) })
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: launchAtLoginBinding)
                if preferences.launchAtLoginStatus == .requiresApproval {
                    Text("Allow Mac Metrics in System Settings → General → Login Items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = preferences.launchAtLoginError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Menu Bar") {
                Toggle("CPU", isOn: $preferences.showsCPU)
                Toggle("GPU", isOn: $preferences.showsGPU)
                Toggle("RAM", isOn: $preferences.showsRAM)
            }

            Section("Updates") {
                Picker("Refresh interval", selection: $preferences.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 460, height: 390, alignment: .topLeading)
    }
}
