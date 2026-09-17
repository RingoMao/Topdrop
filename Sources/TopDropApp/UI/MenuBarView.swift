@preconcurrency import AppKit
import SwiftUI
import TopDropCore

struct MenuBarView: View {
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let toggleTray: () -> Void
    let cleanClipboard: () -> Void
    let toggleClipboardPause: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TopDrop").font(.headline)
                    Text("Ready at the top edge").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button("Open TopDrop", action: toggleTray)
                .buttonStyle(MonochromeProminentButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Clean Clipboard Formatting", action: cleanClipboard)
            Button(
                clipboard.isPaused ? "Resume Clipboard History" : "Pause Clipboard History",
                action: toggleClipboardPause
            )
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )

            Divider()
            HStack {
                Button("Settings…", action: showSettings)
                Spacer()
                Button("Quit", action: quit)
            }
        }
        .padding(14)
        .frame(width: 300)
        .tint(.primary)
    }
}
