import SwiftUI
import AppKit
import GHCore

/// Every `gh` call the app made this session. Built for finding out why a request fails inside the app when the same
/// call works in a terminal: failures show the exact error, and "Copy log" gives text to paste into a bug report.
struct CallLogView: View {
    @Environment(AppModel.self) private var model
    @State private var failuresOnly = false
    @State private var search = ""
    @State private var selection: GhCall.ID?
    @State private var showEnvironment = false

    private var calls: [GhCall] {
        model.callLog.filter { call in
            (!failuresOnly || call.failed)
                && (search.isEmpty || call.text.localizedCaseInsensitiveContains(search)
                    || (call.detail ?? "").localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: GhCall? { model.callLog.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if model.callLog.isEmpty {
                ContentUnavailableView(
                    "No requests yet", systemImage: "terminal",
                    description: Text("Every call GHView makes to the GitHub CLI shows up here."))
            } else if calls.isEmpty {
                ContentUnavailableView(
                    failuresOnly && search.isEmpty ? "Nothing has failed" : "No matching requests",
                    systemImage: failuresOnly && search.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } else {
                VSplitView {
                    table
                    if let call = selected { CallDetail(call: call).frame(minHeight: 110, idealHeight: 170) }
                }
            }
            Divider()
            statusBar
        }
        .searchable(text: $search, prompt: "Filter requests and errors")
        .toolbar {
            ToolbarItemGroup {
                Picker("Show", selection: $failuresOnly) {
                    Text("All").tag(false)
                    Text("Failed").tag(true)
                }
                .pickerStyle(.segmented)
                Button {
                    model.ghCalls.clear(); selection = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log").disabled(model.callLog.isEmpty)
                Button {
                    copy(calls.map(\.text).joined(separator: "\n"))
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                }
                .help("Copy the shown requests as text").disabled(calls.isEmpty)
            }
        }
        .navigationTitle("Request Log")
        .frame(minWidth: 760, minHeight: 380)
    }

    private var table: some View {
        Table(calls, selection: $selection) {
            TableColumn("Time") { call in
                Text(call.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 62, ideal: 70, max: 80)
            TableColumn("Result") { call in ResultBadge(call: call) }
                .width(min: 70, ideal: 80, max: 100)
            TableColumn("Took") { call in
                Text(Self.duration(call.duration)).monospacedDigit()
                    .foregroundStyle(call.duration >= 10 ? Color.orange : Color.secondary)
            }
            .width(min: 44, ideal: 52, max: 64)
            TableColumn("Request") { call in
                Text(call.summary).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(call.failed ? Color.red : Color.primary)
                    .help(call.summary)
            }
        }
    }

    private var statusBar: some View {
        let failed = model.callLog.filter(\.failed).count
        let slowest = model.callLog.map(\.duration).max() ?? 0
        return HStack(spacing: 12) {
            Text("\(model.callLog.count) requests")
            Label("\(failed) failed", systemImage: failed > 0 ? "xmark.octagon.fill" : "checkmark.circle")
                .foregroundStyle(failed > 0 ? Color.red : Color.secondary)
            if slowest > 0 { Text("slowest \(Self.duration(slowest))") }
            if calls.count != model.callLog.count { Text("showing \(calls.count)").foregroundStyle(.tertiary) }
            Spacer()
            Button("Environment") { showEnvironment.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showEnvironment, arrowEdge: .top) {
                    Text(verbatim: GhDiagnostics.summary()).font(.caption.monospaced()).textSelection(.enabled).padding(12)
                }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    static func duration(_ s: TimeInterval) -> String { s < 10 ? String(format: "%.1fs", s) : String(format: "%.0fs", s) }

    private func copy(_ body: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GhDiagnostics.summary() + "\n\n" + body, forType: .string)
    }
}

private struct ResultBadge: View {
    let call: GhCall

    var body: some View {
        switch call.outcome {
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let status, _):
            Label(status == 124 ? "Timeout" : "Exit \(status)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Label("Cancelled", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// The selected request in full: what was asked, what came back, and a button that copies it.
private struct CallDetail: View {
    let call: GhCall

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ResultBadge(call: call).font(.callout.weight(.semibold))
                    Text(call.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    Text("took \(CallLogView.duration(call.duration))").foregroundStyle(.secondary)
                    if call.bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(call.bytes), countStyle: .file)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        copy()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.controlSize(.small)
                }
                .font(.caption)
                if case .failed(_, let stderr) = call.outcome {
                    block("Error", stderr.isEmpty ? "(no message)" : stderr, color: .red)
                }
                block("Request", call.summary)
                if let detail = call.detail { block("Query", detail) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    private func block(_ title: String, _ text: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(verbatim: text).font(.caption.monospaced()).foregroundStyle(color).textSelection(.enabled)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(call.text + (call.failed ? "" : (call.detail.map { "\n    query: \($0)" } ?? "")), forType: .string)
    }
}

struct CallLogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Request Log") { openWindow(id: "log") }.keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
