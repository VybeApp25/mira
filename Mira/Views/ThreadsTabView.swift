import SwiftUI

// MARK: - ThreadsTabView
// Conversation history from ConversationStore — grouped by day, tap-to-resume.
// Mirrors HeyClicky's NotchThreadsTab.

struct ThreadsTabView: View {
    var onResume: ((String) -> Void)?

    @ObservedObject private var store = ConversationStore.shared

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    private var groupedEntries: [(label: String, entries: [ConversationStore.Entry])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        let groups = Dictionary(grouping: store.entries) { entry in
            if cal.isDateInToday(entry.timestamp)     { return "Today" }
            if cal.isDateInYesterday(entry.timestamp) { return "Yesterday" }
            return fmt.string(from: entry.timestamp)
        }
        let order = ["Today", "Yesterday"]
        let sorted = groups.keys.sorted { a, b in
            let ia = order.firstIndex(of: a)
            let ib = order.firstIndex(of: b)
            if let ia, let ib { return ia < ib }
            if ia != nil { return true }
            if ib != nil { return false }
            // Both are date strings — sort descending
            return a > b
        }
        return sorted.compactMap { key in
            guard let entries = groups[key], !entries.isEmpty else { return nil }
            return (label: key, entries: entries.reversed())
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                threadsList
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.10))
            Text("No conversations yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.28))
            Text("Your history will appear here")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Threads list

    private var threadsList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groupedEntries, id: \.label) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        Text(group.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.28))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.90))
                    }
                }
            }
        }
    }

    // MARK: - Entry row

    private func entryRow(_ entry: ConversationStore.Entry) -> some View {
        let isUser = entry.role == "user"
        return HStack(alignment: .top, spacing: 8) {
            // Role avatar
            ZStack {
                Circle()
                    .fill(isUser ? Color.white.opacity(0.07) : accent.opacity(0.10))
                    .frame(width: 22, height: 22)
                Image(systemName: isUser ? "person.fill" : "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isUser ? .white.opacity(0.40) : accent.opacity(0.65))
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(shortTime(entry.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.20))
            }

            Spacer(minLength: 0)

            // Resume button — only on user messages
            if isUser {
                Button {
                    onResume?(entry.text)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Resume this prompt")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 0.5)
                .padding(.leading, 44)
        }
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: date)
    }
}
