import SwiftUI
import AppKit
import Combine

public struct PermissionsView: View {
    @State private var hasMic: Bool = AudioRecorder.shared.hasPermission
    @State private var micDenied: Bool = AudioRecorder.shared.isPermissionDenied
    @State private var hasAccessibility: Bool = HotkeyManager.isAccessibilityGranted()
    @State private var allGrantedNotice: Bool = false
    @State private var statusInfo: String = ""

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions & Setup")
                        .font(.headline)
                    Text("Press To Write requires two macOS permissions to listen and insert text.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if hasMic && hasAccessibility {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Permissions Active!")
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                        Text("Press To Write is fully configured and ready. Hold Fn and speak anytime.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
                .cornerRadius(8)
            }

            Divider()

            // 1. Microphone Permission
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.blue)
                        Text("Microphone Access")
                            .fontWeight(.medium)
                    }
                    Text("Needed to record your voice when holding the hotkey. Audio is processed on this Mac; temporary recordings are deleted after processing or cancellation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if micDenied && !hasMic {
                        Text("Access was declined, so macOS will not ask again. Turn on Press To Write under Privacy & Security → Microphone.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                if hasMic {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if micDenied {
                    // macOS shows its prompt only once; afterward the request does nothing.
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Grant Access") {
                        AudioRecorder.shared.requestPermission { granted in
                            hasMic = granted
                            micDenied = AudioRecorder.shared.isPermissionDenied
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            // 2. Accessibility Permission
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "keyboard.fill")
                            .foregroundColor(.purple)
                        Text("Accessibility Access")
                            .fontWeight(.medium)
                    }
                    Text("Needed to detect the Function (Fn) key globally and simulate Cmd+V to paste into active applications.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if hasAccessibility {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button("Open Settings") {
                        HotkeyManager.requestAccessibilityPermission()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            // 3. Pro-Tip on macOS Fn / Globe Key
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                    Text("Pro-Tip for the Fn / Globe Key")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                Text("In macOS **System Settings → Keyboard**, set **\"Press 🌐 key to:\"** to **\"Do Nothing\"**. This prevents macOS from popping up the emoji window when you hold Fn to speak.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Open Keyboard Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .padding(10)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)

            if !statusInfo.isEmpty {
                Text(statusInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("Auto-Fix / Reset Permissions") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                    task.arguments = ["reset", "Accessibility", "com.presstowrite.mac"]
                    try? task.run()
                    task.waitUntilExit()

                    HotkeyManager.requestAccessibilityPermission()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    statusInfo = "Reset macOS permission cache. Toggle Press To Write in System Settings."
                }
                .buttonStyle(.bordered)
                .help("Clears old build signatures from macOS Privacy cache if System Settings gets stuck")

                Spacer()

                if hasMic && hasAccessibility {
                    Button("Close") {
                        closeWindow()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Restart App") {
                        let appPath = Bundle.main.bundlePath
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-n", appPath]
                        try? task.run()
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        let mic = AudioRecorder.shared.hasPermission
        let ax = HotkeyManager.isAccessibilityGranted()
        if mic != hasMic { hasMic = mic }
        let denied = AudioRecorder.shared.isPermissionDenied
        if denied != micDenied { micDenied = denied }
        if ax != hasAccessibility {
            hasAccessibility = ax
            if ax {
                HotkeyManager.shared.startListening()
            }
        }

        if hasMic && hasAccessibility && !allGrantedNotice {
            allGrantedNotice = true
            // Auto close after 1.5s once both permissions are satisfied
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if hasMic && hasAccessibility {
                    closeWindow()
                }
            }
        }
    }

    private func closeWindow() {
        for window in NSApp.windows {
            if window.title.contains("Permissions") {
                window.close()
            }
        }
    }
}
