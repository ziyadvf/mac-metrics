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
        refreshInterval = max(3, defaults.object(forKey: Keys.refreshInterval) as? Double ?? 3)
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
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 490),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            created.title = "Settings"
            created.isReleasedWhenClosed = false
            created.contentMinSize = NSSize(width: 440, height: 490)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Metrics").font(.system(size: 20, weight: .semibold))
                    Text("A quiet view of your Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            section("General") {
                settingToggle("Open at login", isOn: launchAtLoginBinding)
                if preferences.launchAtLoginStatus == .requiresApproval {
                    Text("Allow Mac Metrics in System Settings → General → Login Items.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = preferences.launchAtLoginError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Menu Bar") {
                settingToggle("CPU", isOn: $preferences.showsCPU)
                Divider()
                settingToggle("GPU", isOn: $preferences.showsGPU)
                Divider()
                settingToggle("RAM", isOn: $preferences.showsRAM)
            }

            VStack(alignment: .leading, spacing: 8) {
                section("Updates") {
                    HStack {
                        Text("Refresh interval")
                        Spacer()
                        Picker("Refresh interval", selection: $preferences.refreshInterval) {
                            Text("3 seconds").tag(3.0)
                            Text("5 seconds").tag(5.0)
                            Text("10 seconds").tag(10.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                Text("When panels are closed, updates run no faster than every 5 seconds. Opening a panel warms all process lists. Frequent use keeps them ready longer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(24)
        .frame(width: 440, height: 490, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
        .frame(minHeight: 20)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 10, content: content)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}
