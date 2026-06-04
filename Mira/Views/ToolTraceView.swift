import SwiftUI

struct ToolTraceView: View {
    @ObservedObject private var store = ToolTraceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: UUID? = nil

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))

                if store.traces.isEmpty {
                    emptyState
                } else {
                    traceList
                }
            }
        }
        .frame(width: 420, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tool Activity")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("\(store.traces.count) of 50 calls this session")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            if !store.traces.isEmpty {
                Button("Clear") { store.clear() }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
            }
            Button("Done") { dismiss() }
                .foregroundColor(accent)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.badge.clock")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.12))
            Text("No tool calls yet")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.25))
            Text("Start a voice session and ask Mira to do something.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.18))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Trace list

    private var traceList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(store.traces) { trace in
                    TraceRow(trace: trace, isExpanded: expandedID == trace.id) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedID = expandedID == trace.id ? nil : trace.id
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Row

private struct TraceRow: View {
    let trace: ToolTrace
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed summary
            Button(action: onTap) {
                HStack(spacing: 8) {
                    signalDot
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(trace.toolName)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.90))
                            Text("·")
                                .foregroundColor(.white.opacity(0.25))
                            Text(trace.summary)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.60))
                                .lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text(trace.timestamp.formatted(.dateTime.hour().minute().second()))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.25))
                            Text("\(trace.durationMs)ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var signalDot: some View {
        let color: Color
        switch trace.signal {
        case .correct:    color = Color(red: 0.20, green: 0.84, blue: 0.29)
        case .ambiguous:  color = Color(red: 1.0,  green: 0.75, blue: 0.20)
        case .suspicious: color = Color(red: 1.0,  green: 0.30, blue: 0.30)
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Color.white.opacity(0.06))

            // Args
            detailSection("Args") {
                argRows
            }

            // Result
            detailSection("Result") {
                Text(trace.result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Signal annotation for suspicious memory calls
            if trace.signal != .correct && trace.toolName == "remember" {
                HStack(spacing: 5) {
                    Image(systemName: trace.signal == .suspicious ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(trace.signal == .suspicious
                            ? Color(red: 1.0, green: 0.30, blue: 0.30)
                            : Color(red: 1.0, green: 0.75, blue: 0.20))
                    Text(trace.signal == .suspicious
                         ? "Value looks like content — consider tightening the system prompt."
                         : "Value is longer than expected for a preference — verify intent.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var argRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(trace.args.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 6) {
                    Text(key)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.40))
                        .frame(width: 70, alignment: .trailing)
                    Text("\(value)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.25))
                .tracking(0.8)
            content()
        }
    }
}
