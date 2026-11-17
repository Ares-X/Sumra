#if os(macOS)
import SwiftUI

struct ReaderDiagnosticsSettings: View {
    @ObservedObject private var diagnostics = ReaderWindowDiagnostics.shared

    var body: some View {
        Form {
            Section(L("Window Diagnostics")) {
                ReaderDiagnosticsToggle()
                Text(L("Off by default. When enabled, recording stays on after restarting Vira Reader."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(diagnostics.reportSummary)
                    .textSelection(.enabled)
                ReaderDiagnosticsActions(showToggle: false)
                if let error = diagnostics.lastError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section(L("Privacy and Retention")) {
                Text(L("Records only Vira Reader window, tab and full-screen events. Does not record file names, paths, document contents or keystrokes. Nothing is uploaded automatically."))
                Text(L("Each recording is kept separately until you delete it from the diagnostics folder. Export a ZIP archive to attach to a GitHub issue."))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { diagnostics.refresh() }
    }
}

struct ReaderDiagnosticsActions: View {
    var showToggle: Bool
    @ObservedObject private var diagnostics = ReaderWindowDiagnostics.shared

    init(showToggle: Bool = true) { self.showToggle = showToggle }

    var body: some View {
        if showToggle { ReaderDiagnosticsToggle() }
        Button(L("Mark Current Window State")) { diagnostics.markProblem() }
            .disabled(!diagnostics.enabled)
        Button(L("Export Window Diagnostics…")) { diagnostics.exportReport() }
            .disabled(diagnostics.isExporting)
        Button(L("Show Diagnostics Folder")) { diagnostics.showFolder() }
        if showToggle, let error = diagnostics.lastError {
            Text(error)
        }
    }
}

private struct ReaderDiagnosticsToggle: View {
    @ObservedObject private var diagnostics = ReaderWindowDiagnostics.shared

    var body: some View {
        Toggle(L("Record Window Diagnostics"), isOn: Binding(
            get: { diagnostics.enabled }, set: { diagnostics.setEnabled($0) }))
    }
}
#endif
