import SwiftUI
import AppKit

public struct FloatingPillView: View {
    @ObservedObject var appState: AppState = AppState.shared
    @State private var isHovering: Bool = false
    @State private var isShimmering: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if appState.pillOrientation == .vertical {
                verticalPillContent
            } else {
                horizontalPillContent
            }
        }
        .background(pillBackground)
        .help(appState.isRecording ? "Listening: press Escape to cancel" : appState.engineStatus.phase == .ready ? appState.statusMessage : appState.engineStatus.message)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - App Icon Component

    private var appIconView: some View {
        ZStack {
            // App Icon (Contender 1 Studio Mic)
            if let icon = Self.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 19, height: 19)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
            }

            // Pulsing active recording indicator ring around icon
            if appState.isRecording {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .stroke(Color.red, lineWidth: 1.8)
                    .frame(width: 23, height: 23)
                    .scaleEffect(appState.currentAudioLevel > 0.08 ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: appState.currentAudioLevel)
            } else if appState.isProcessing {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.6
                    )
                    .frame(width: 23, height: 23)
                    .rotationEffect(Angle(degrees: isShimmering ? 360 : 0))
                    .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isShimmering)
                    .onAppear { isShimmering = true }
            } else if appState.showSuccess {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                    .offset(x: 8, y: -8)
            }
        }
    }

    // MARK: - Horizontal Pill (Top / Bottom edges)

    private var horizontalPillContent: some View {
        HStack(spacing: 6) {
            // 1. App Icon
            appIconView

            // 2. State content — NO "Hold Fn", NO dots
            if appState.isRecording {
                WaveformView(audioLevel: appState.currentAudioLevel, barCount: 4)
                Text("Listening")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
            } else if appState.isProcessing {
                Text("Transcribing")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            } else if appState.showSuccess {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
                Text("Done")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.green)
            } else if appState.engineStatus.phase == .loading {
                Text("Loading")
                    .font(.system(size: 10.0, weight: .medium, design: .rounded))
                    .foregroundColor(.orange)
            } else if appState.statusMessage != "Ready" {
                Text(appState.statusMessage)
                    .font(.system(size: 10.0, weight: .medium, design: .rounded))
                    .foregroundColor(appState.statusMessage.contains("Error") || appState.statusMessage.contains("failed") ? .orange : .cyan)
                    .lineLimit(1)
                    .frame(maxWidth: 55)
                    .truncationMode(.tail)
            } else if appState.engineStatus.phase != .ready {
                Text(appState.engineStatus.phase == .loading ? "Loading" : "Unavailable")
                    .font(.system(size: 10.0, weight: .medium, design: .rounded))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            } else {
                // Sleek Idle text — NO dots, NO "Hold Fn"
                Text("Press To Write")
                    .font(.system(size: 11.0, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
            }

            // 3. Quick Copy on hover
            if isHovering && !appState.lastTranscribedText.isEmpty && !appState.isRecording && !appState.isProcessing {
                Button {
                    appState.copyLastDictation()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
                .help("Copy last transcription")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }

    // MARK: - Vertical Pill (Left / Right edges — "a pill that's down not sideways")

    private var verticalPillContent: some View {
        VStack(spacing: 3) {
            // App Icon
            appIconView

            // Middle: Vertical Visualizer / Status (only when active)
            if appState.isRecording {
                VStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { i in
                        let multiplier: CGFloat = [0.6, 1.0, 0.7][i]
                        let baseW: CGFloat = 4.0
                        let maxW: CGFloat = 16.0
                        let w = baseW + (CGFloat(appState.currentAudioLevel) * (maxW - baseW) * multiplier)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange, Color.red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(baseW, min(maxW, w)), height: 2.0)
                            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: appState.currentAudioLevel)
                    }
                }
                .frame(height: 10)
            } else if appState.isProcessing {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .rotationEffect(Angle(degrees: isShimmering ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isShimmering)
            } else if appState.showSuccess {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
            } else if appState.engineStatus.phase == .loading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                    .help(appState.engineStatus.message)
                    .accessibilityLabel(Text(appState.engineStatus.message))
            } else if appState.statusMessage != "Ready" || appState.engineStatus.phase != .ready {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .help(appState.statusMessage != "Ready" ? appState.statusMessage : appState.engineStatus.message)
                    .accessibilityLabel(Text(appState.statusMessage != "Ready" ? appState.statusMessage : appState.engineStatus.message))
            } else if isHovering && !appState.lastTranscribedText.isEmpty {
                Button {
                    appState.copyLastDictation()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
                .help("Copy last transcription")
            }
            // In Idle: NOTHING else! ZERO dots! Clean icon only!
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Glass Background

    private var pillBackground: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                )

            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(appState.isRecording ? 0.5 : (isHovering ? 0.3 : 0.15)),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // Decoding the 1024-pixel master costs several milliseconds, and this view's
    // body runs for every audio-level update while recording. Load it once.
    private static let appIcon: NSImage? = loadAppIcon()

    private static func loadAppIcon() -> NSImage? {
        if let masterURL = Bundle.main.url(forResource: "AppIcon_master", withExtension: "png"),
           let img = NSImage(contentsOf: masterURL) {
            return img
        }
        let repoIcon = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/AppIcon_master.png")
        if let img = NSImage(contentsOf: repoIcon) {
            return img
        }
        return NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    }
}
