import SwiftUI

struct ActivityLogView: View {
    let log: ActivityLog

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity log").font(.headline)
                Spacer()
                Button("Clear", systemImage: "trash") { log.clear() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear the activity log")
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Divider()
            if log.entries.isEmpty {
                EmptyState(title: "No activity yet", systemImage: "waveform.path.ecg",
                           message: "Connections, refreshes, resends and errors show up here.")
            } else {
                ScrollViewReader { proxy in
                    List(log.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            icon(entry.level)
                                .font(.system(size: 13))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(tint(entry.level).opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).font(.callout).textSelection(.enabled)
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .listRowSeparator(.hidden)
                        .id(entry.id)
                    }
                    .onChange(of: log.entries.count) {
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1).ignoresSafeArea()
        }
    }

    @ViewBuilder private func icon(_ level: ActivityEntry.Level) -> some View {
        switch level {
        case .info: Image(systemName: "info").fontWeight(.bold).foregroundStyle(tint(level))
        case .success: Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(tint(level))
        case .error: Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(tint(level))
        }
    }

    private func tint(_ level: ActivityEntry.Level) -> Color {
        switch level {
        case .info: Theme.active
        case .success: Theme.healthy
        case .error: Theme.deadLetter
        }
    }
}
