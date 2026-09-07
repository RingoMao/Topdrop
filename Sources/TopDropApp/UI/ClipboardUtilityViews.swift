import AppKit
import SwiftUI
import TopDropCore

struct ClipboardHeaderUtilities: View {
    @ObservedObject var monitor: ClipboardMonitor
    let togglePause: () -> Void
    let pickScreenColor: () -> Void
    let openHandoffSettings: () -> Void
    let announce: (String) -> Void

    @State private var watchPopoverIsPresented = false
    @State private var confirmationIsVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Button(action: pickScreenColor) {
                Image(systemName: "eyedropper")
                    .font(.callout.weight(.semibold))
                    .frame(width: 31, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ClipboardHeaderButtonStyle())
            .help("Pick screen color and copy Hex")
            .accessibilityLabel("Pick Screen Color")
            .accessibilityHint("Hides TopDrop, samples a screen color, and copies its Hex value")

            Button {
                Task { try? await monitor.cleanFormatting() }
            } label: {
                Text("Aa")
                    .font(.callout.weight(.semibold))
                    .frame(width: 31, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ClipboardHeaderButtonStyle())
            .help(
                "Clean Formatting (Control-Option-Command-V): replace text formatting with plain UTF-8 without pasting"
            )
            .accessibilityLabel("Clean Clipboard Formatting")
            .accessibilityHint("Replaces textual clipboard representations with plain text and does not paste")

            watchControl

            Button(action: togglePause) {
                Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 31, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ClipboardHeaderButtonStyle())
            .help(monitor.isPaused ? "Resume Clipboard History" : "Pause Clipboard History")
            .accessibilityLabel(monitor.isPaused ? "Resume Clipboard History" : "Pause Clipboard History")
        }
        .fixedSize()
        .overlay(alignment: .topTrailing) {
            if confirmationIsVisible {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Clipboard change reached this Mac", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                    Text("Source cannot be identified by macOS.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(width: 235, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.28), lineWidth: 1)
                }
                .offset(y: 34)
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(20)
            }
        }
        .onChange(of: monitor.snapshot.arrivalWatch) { _, newState in
            guard case .received = newState else { return }
            let message = "Clipboard change reached this Mac. Its source cannot be identified by macOS."
            announce(message)
            confirmationIsVisible = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                if reduceMotion {
                    confirmationIsVisible = false
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        confirmationIsVisible = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var watchControl: some View {
        switch monitor.snapshot.arrivalWatch {
        case let .watching(_, deadline):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let state = ClipboardUtilityWatchPolicy.state(
                    arrivalWatch: .watching(startedAt: context.date, deadline: deadline),
                    accessState: monitor.accessState,
                    isPaused: monitor.isPaused,
                    now: context.date
                )
                watchButton(for: state)
            }
        case .idle, .received, .timedOut, .unavailable:
            watchButton(
                for: ClipboardUtilityWatchPolicy.state(
                    arrivalWatch: monitor.snapshot.arrivalWatch,
                    accessState: monitor.accessState,
                    isPaused: monitor.isPaused
                ))
        }
    }

    private func watchButton(for state: ClipboardUtilityWatchState) -> some View {
        Button {
            watchPopoverIsPresented = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: state.systemImageName)
                    .font(.callout.weight(.semibold))
                if case let .watching(seconds) = state {
                    Text("\(seconds)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: 4, y: 3)
                }
            }
            .frame(width: 31, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(ClipboardHeaderButtonStyle())
        .help("Clipboard Arrival Watch")
        .accessibilityLabel("Clipboard Arrival Watch")
        .accessibilityValue(watchAccessibilityValue)
        .popover(isPresented: $watchPopoverIsPresented, arrowEdge: .bottom) {
            ClipboardWatchPopover(
                monitor: monitor,
                togglePause: togglePause,
                openHandoffSettings: openHandoffSettings
            )
        }
    }

    private var watchAccessibilityValue: String {
        switch monitor.snapshot.arrivalWatch {
        case .idle: "Ready"
        case .watching: "Watching for a clipboard change"
        case .received: "Clipboard change received; source unverified"
        case .timedOut: "Timed out"
        case let .unavailable(reason): reason.userMessage
        }
    }
}

struct ClipboardHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.16 : 0.055),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.24), lineWidth: 1)
            }
    }
}

struct ClipboardWatchPopover: View {
    @ObservedObject var monitor: ClipboardMonitor
    let togglePause: () -> Void
    let openHandoffSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if showsHandoffSettings {
                    Button("Handoff Settings", action: openHandoffSettings)
                }
                Spacer()
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    private var title: String {
        switch monitor.snapshot.arrivalWatch {
        case .idle: "Clipboard Watch"
        case .watching: "Watching for an Arrival"
        case .received: "Clipboard Change Received"
        case .timedOut: "No Change Arrived"
        case .unavailable: "Watch Unavailable"
        }
    }

    private var symbol: String {
        switch monitor.snapshot.arrivalWatch {
        case .idle, .watching: "iphone.and.arrow.forward"
        case .received: "checkmark.circle.fill"
        case .timedOut: "exclamationmark.triangle"
        case let .unavailable(reason): reason == .paused ? "pause.fill" : "lock.fill"
        }
    }

    private var detail: String {
        switch monitor.snapshot.arrivalWatch {
        case .idle:
            "Watch for the next clipboard change that reaches this Mac. macOS does not reveal whether it came from Universal Clipboard or a local copy."
        case .watching:
            "Copy on another Apple device now. A local Mac copy can also satisfy this watch because macOS does not expose clipboard provenance."
        case .received:
            "A clipboard change reached this Mac. If you copied it on another device, Universal Clipboard appears to be working; the source is not verifiable."
        case .timedOut:
            "Check that both devices use the same Apple Account, are nearby, and have Wi-Fi, Bluetooth, and Handoff enabled."
        case let .unavailable(reason):
            reason.userMessage
        }
    }

    private var primaryTitle: String {
        switch monitor.snapshot.arrivalWatch {
        case .watching: "Cancel"
        case .unavailable(reason: .paused): "Resume"
        case .unavailable(reason: .accessRequired): "Allow"
        case .idle, .received, .timedOut: "Watch Again"
        }
    }

    private var showsHandoffSettings: Bool {
        if case .timedOut = monitor.snapshot.arrivalWatch { return true }
        return false
    }

    private func primaryAction() {
        switch monitor.snapshot.arrivalWatch {
        case .watching:
            monitor.cancelArrivalWatch()
        case .unavailable(reason: .paused):
            togglePause()
            monitor.beginArrivalWatch()
        case .unavailable(reason: .accessRequired):
            _ = monitor.requestPasteboardAccess()
        case .idle, .received, .timedOut:
            monitor.beginArrivalWatch()
        }
    }
}
