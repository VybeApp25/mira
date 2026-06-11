import SwiftUI
import AppKit

private let detailBg    = Color(red: 0.08, green: 0.08, blue: 0.10)
private let detailSurf  = Color(red: 0.12, green: 0.12, blue: 0.14)
private let detailAccent = DS.Colors.accent
private let detailGreen  = Color(red: 0.20, green: 0.84, blue: 0.29)
private let detailAmber  = Color(red: 1.0,  green: 0.78, blue: 0.20)
private let detailRed    = Color(red: 1.0,  green: 0.35, blue: 0.35)

struct OutputDetailView: View {
    let entryId: UUID
    @ObservedObject var store: OutputStore
    @Environment(\.dismiss) private var dismiss

    @AccessibilityFocusState private var titleFocused: Bool
    @State private var editingName = false
    @State private var nameText = ""
    @State private var promptExpanded = false
    @State private var isExporting = false
    @State private var editRequest = ""
    @State private var restoredVersionLabel: String? = nil
    @State private var showPublishPicker = false
    @State private var urlCopied = false

    private var apiKey: String {
        let user = UserDefaults.standard.string(forKey: "mira_api_key") ?? ""
        return user.isEmpty ? AppSecrets.anthropicAPIKey : user
    }

    @State private var healthReanalyzed = false

    private var entry: OutputEntry? { store.entries.first { $0.id == entryId } }

    var body: some View {
        ZStack {
            detailBg.ignoresSafeArea()
            if let entry {
                VStack(spacing: 0) {
                    headerBar(entry)
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            previewSection(entry)
                            if let url = entry.publishedUrl { liveSiteCard(url: url, entry: entry) }
                            nameSection(entry)
                            divider
                            metadataSection(entry)
                            divider
                            healthSection(entry)
                            divider
                            createdBySection(entry)
                            promptSection(entry)
                            divider
                            actionsSection(entry)
                            divider
                            publishSection(entry)
                            divider
                            editingSection(entry)
                            divider
                            historySection(entry)
                        }
                    }
                }
            } else {
                Text("Output not found")
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                titleFocused = true
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
    }

    // MARK: - Header

    private func headerBar(_ entry: OutputEntry) -> some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: entry.type.icon).font(.system(size: 9))
                Text(entry.type.rawValue).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.38))

            Spacer()

            Button { store.toggleFavorite(id: entry.id) } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundColor(entry.favorite ? detailAmber : .white.opacity(0.22))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: - Preview

    private func previewSection(_ entry: OutputEntry) -> some View {
        Group {
            if let path = entry.previewImagePath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
            } else {
                ZStack {
                    detailSurf
                    Image(systemName: entry.type.icon)
                        .font(.system(size: 34))
                        .foregroundColor(.white.opacity(0.08))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
            }
        }
    }

    // MARK: - Name

    private func nameSection(_ entry: OutputEntry) -> some View {
        HStack(spacing: 8) {
            if editingName {
                TextField("Name", text: $nameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .onSubmit {
                        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { store.rename(id: entry.id, to: trimmed) }
                        editingName = false
                    }
                Button("Done") { editingName = false }
                    .font(.system(size: 11))
                    .foregroundColor(detailAccent)
                    .buttonStyle(.plain)
            } else {
                Text(entry.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($titleFocused)
                Spacer()
                Button {
                    nameText = entry.name
                    editingName = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.22))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Metadata

    private func metadataSection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Details")
            VStack(spacing: 5) {
                if let genre = entry.metadata["genre"] { metaRow("globe", "Genre", genre.capitalized) }
                if let style = entry.metadata["designStyle"] { metaRow("paintbrush", "Style", style) }
                if let mode = entry.metadata["buildMode"] { metaRow("bolt", "Build Mode", mode) }
                if let lines = entry.metadata["linesOfCode"] { metaRow("doc.text", "Lines of Code", lines) }
                if let refs = entry.metadata["referencesUsed"], refs != "0" { metaRow("photo", "References", refs) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Health Section

    @ViewBuilder
    private func healthSection(_ entry: OutputEntry) -> some View {
        if let report = entry.healthReport {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel("Website Health")
                    Spacer()
                    Button {
                        healthReanalyzed = true
                        AgentJobStore.shared.submitHealthJob(outputEntryId: entryId, apiKey: apiKey)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9))
                            Text("Re-analyze").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(detailAccent.opacity(0.70))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(detailAccent.opacity(0.10))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Overall score
                HStack(alignment: .center, spacing: 10) {
                    Text("\(report.overallScore)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(healthScoreColor(report.overallScore))
                    Text("/100")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.30))
                    Spacer()
                    Text("Analyzed \(relativeHealthDate(report.analyzedAt))")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                // Dimension rows
                VStack(spacing: 5) {
                    healthDimensionRow("chart.bar.fill",  "Traffic",        report.traffic.map { "\($0)" } ?? "--", report.traffic)
                    healthDimensionRow("arrow.up.right",  "Conversions",    report.conversions.map { "\($0)" } ?? "--", report.conversions)
                    healthDimensionRow("iphone",          "Mobile UX",      "\(report.mobileUX)", report.mobileUX)
                    healthDimensionRow("magnifyingglass", "SEO",            "\(report.seo)", report.seo)
                    healthDimensionRow("accessibility",   "Accessibility",  "\(report.accessibility)", report.accessibility)
                }

                if !report.findings.isEmpty {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                    sectionLabel("Findings (\(report.findings.count))")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.findings) { finding in
                            HStack(alignment: .top, spacing: 6) {
                                Text(findingIcon(finding.severity))
                                    .font(.system(size: 11))
                                    .foregroundColor(findingColor(finding.severity))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(finding.category)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(findingColor(finding.severity).opacity(0.75))
                                    Text(finding.message)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.60))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else if entry.type == .website {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Website Health")
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(detailAccent.opacity(0.12)).frame(width: 32, height: 32)
                            Image(systemName: "heart.text.square.fill")
                                .font(.system(size: 14))
                                .foregroundColor(detailAccent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No health report yet")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.80))
                            Text("Analyze SEO, accessibility, and mobile UX")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.38))
                        }
                        Spacer()
                    }
                    Button {
                        AgentJobStore.shared.submitHealthJob(outputEntryId: entryId, apiKey: apiKey)
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "heart.text.square.fill").font(.system(size: 11))
                            Text("Analyze Website").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(detailAccent.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(detailAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func healthDimensionRow(_ icon: String, _ label: String, _ value: String, _ score: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.36))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(score.map { healthScoreColor($0) } ?? .white.opacity(0.28))
        }
    }

    private func healthScoreColor(_ score: Int) -> Color {
        if score >= 80 { return detailGreen }
        if score >= 60 { return detailAmber }
        return detailRed
    }

    private func findingColor(_ severity: HealthFindingSeverity) -> Color {
        switch severity {
        case .critical:   return detailRed
        case .warning:    return detailAmber
        case .suggestion: return detailAccent
        }
    }

    private func findingIcon(_ severity: HealthFindingSeverity) -> String {
        switch severity {
        case .critical:   return "●"
        case .warning:    return "⚠"
        case .suggestion: return "○"
        }
    }

    private func relativeHealthDate(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    private func metaRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.36))
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.68))
        }
    }

    // MARK: - Created By

    private func createdBySection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Provenance")
            VStack(spacing: 5) {
                metaRow("cpu", "Created by", entry.type.agentName)
                metaRow("calendar", "Created", formattedDate(entry.createdAt))
                if let openedAt = entry.lastOpenedAt {
                    metaRow("clock", "Last Opened", formattedDate(openedAt))
                }
                if entry.openCount > 0 {
                    metaRow("eye", "Times Opened", "\(entry.openCount)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Original Prompt

    private func promptSection(_ entry: OutputEntry) -> some View {
        let prompt = entry.metadata["sourcePrompt"] ?? "—"
        let isLong = prompt.count > 110

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Original Prompt")
            VStack(alignment: .leading, spacing: 6) {
                Text(promptExpanded ? prompt : String(prompt.prefix(110)) + (isLong && !promptExpanded ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { promptExpanded.toggle() }
                    } label: {
                        Text(promptExpanded ? "Show less" : "Show more")
                            .font(.system(size: 10))
                            .foregroundColor(detailAccent.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func actionsSection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Actions")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                actionBtn("arrow.up.right.square", "Open") {
                    store.markOpened(id: entry.id)
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.primaryFilePath))
                }
                actionBtn("folder", "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.primaryFilePath)]
                    )
                }
                actionBtn(isExporting ? "hourglass" : "arrow.down.doc",
                          isExporting ? "Exporting…" : "Export ZIP") {
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        let url = await store.exportZIP(id: entry.id)
                        isExporting = false
                        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                actionBtn("doc.on.doc", "Duplicate") {
                    store.duplicate(id: entry.id)
                    dismiss()
                }
                actionBtn("trash", "Delete", color: detailRed) {
                    store.delete(id: entry.id, removeFiles: true)
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func actionBtn(_ icon: String, _ label: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color.opacity(0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editing (conversational thread + input)

    private func editingSection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Edit History")

            // Conversation thread
            if !entry.editHistory.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.editHistory) { msg in
                        editMessageRow(msg, entry: entry)
                    }
                }
                .padding(.bottom, 4)
            }

            // Input
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editRequest)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.05))
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    if editRequest.isEmpty {
                        Text(entry.editHistory.isEmpty
                             ? "Describe what to change… e.g. \"Make the hero darker\""
                             : "What else should I change?")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 5).padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }

                Button {
                    let req = editRequest.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !req.isEmpty else { return }
                    OutputStore.shared.addUserMessage(entryId: entryId, content: req)
                    AgentJobStore.shared.submitEditJob(
                        outputEntryId: entryId,
                        editRequest: req,
                        apiKey: apiKey
                    )
                    editRequest = ""
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 11))
                        Text(entry.editHistory.isEmpty ? "Apply Edit" : "Apply Next Edit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(editRequest.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.22) : .white.opacity(0.90))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(detailAccent.opacity(editRequest.trimmingCharacters(in: .whitespaces).isEmpty ? 0.05 : 0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(editRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func editMessageRow(_ msg: EditMessage, entry: OutputEntry) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 2) {
            HStack {
                if msg.role == .assistant { Spacer() }
                VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 3) {
                    Text(msg.content)
                        .font(.system(size: 11))
                        .foregroundColor(msg.role == .user ? .white.opacity(0.82) : .white.opacity(0.50))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(msg.role == .user ? detailAccent.opacity(0.18) : Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let versionId = msg.linkedVersionId,
                       let version = entry.versions.first(where: { $0.id == versionId }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8))
                                .foregroundColor(detailAccent.opacity(0.60))
                            Text(version.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(detailAccent.opacity(0.75))
                        }
                        .padding(msg.role == .user ? .trailing : .leading, 4)
                    }
                }
                if msg.role == .user { Spacer() }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Live Site Card

    private func liveSiteCard(url: String, entry: OutputEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(detailGreen.opacity(0.15)).frame(width: 28, height: 28)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(detailGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Live")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(detailGreen)
                        if let provider = entry.deploymentProvider {
                            Text("on \(provider)")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    Text(url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                liveSiteBtn("arrow.up.right.square", "Open") {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                liveSiteBtn(urlCopied ? "checkmark" : "doc.on.clipboard", urlCopied ? "Copied" : "Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    withAnimation { urlCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { urlCopied = false }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(detailGreen.opacity(0.06))
        .overlay(Rectangle().fill(detailGreen.opacity(0.15)).frame(height: 0.5), alignment: .bottom)
    }

    private func liveSiteBtn(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(detailGreen.opacity(0.80))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(detailGreen.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Publish Section

    private func publishSection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel(entry.publishedUrl == nil ? "Publish" : "Republish")
                Spacer()
                if entry.publishedUrl != nil {
                    Text("Last: \(entry.deploymentProvider ?? "Unknown")")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.28))
                }
            }

            if entry.type == .website {
                if showPublishPicker {
                    VStack(spacing: 6) {
                        ForEach(PublishingAgent.PublishTarget.allCases) { target in
                            Button {
                                showPublishPicker = false
                                AgentJobStore.shared.submitPublishJob(
                                    outputEntryId: entryId,
                                    target: target,
                                    apiKey: apiKey
                                )
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: target.icon)
                                        .font(.system(size: 11))
                                        .foregroundColor(detailAccent.opacity(0.75))
                                        .frame(width: 16)
                                    Text(target.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(0.80))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.22))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.15)) { showPublishPicker = false }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.28))
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showPublishPicker = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill").font(.system(size: 11))
                            Text(entry.publishedUrl == nil ? "Publish Website" : "Republish Website")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(detailAccent.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(detailAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Publishing is available for Website projects.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.22))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Version History

    private func historySection(_ entry: OutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Version History")
                Spacer()
                if let label = restoredVersionLabel {
                    Text("↩ \(label) saved")
                        .font(.system(size: 9))
                        .foregroundColor(detailGreen.opacity(0.80))
                        .transition(.opacity)
                }
            }
            if entry.versions.isEmpty {
                Text("No versions recorded")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.22))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entry.versions.reversed().enumerated()), id: \.element.id) { idx, version in
                        let originalIndex = entry.versions.count - 1 - idx
                        let isCurrent = idx == 0
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(isCurrent ? detailAccent.opacity(0.18) : Color.white.opacity(0.06))
                                    .frame(width: 22, height: 22)
                                Image(systemName: isCurrent ? "checkmark" : "clock.arrow.circlepath")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(isCurrent ? detailAccent : .white.opacity(0.25))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(version.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(isCurrent ? 0.88 : 0.45))
                                    if isCurrent {
                                        Text("Current")
                                            .font(.system(size: 9))
                                            .foregroundColor(detailAccent.opacity(0.70))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(detailAccent.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                                if let prompt = version.editPrompt {
                                    Text("\"\(prompt.prefix(70))\(prompt.count > 70 ? "…" : "")\"")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.42))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 4) {
                                    Text(formattedDate(version.createdAt))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.28))
                                    if let agent = version.createdByAgent {
                                        Text("·").font(.system(size: 10)).foregroundColor(.white.opacity(0.15))
                                        Text(agent)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.22))
                                    }
                                }
                            }
                            Spacer()
                            if !isCurrent {
                                Button {
                                    let newLabel = "Version \(entry.versions.count + 1)"
                                    if store.restoreVersion(entryId: entry.id, versionIndex: originalIndex) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            restoredVersionLabel = newLabel
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                            withAnimation { restoredVersionLabel = nil }
                                        }
                                    }
                                } label: {
                                    Text("Restore")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(detailAccent.opacity(0.70))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(detailAccent.opacity(0.10))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 7)
                        if idx < entry.versions.count - 1 {
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .padding(.bottom, 20)
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.25))
            .tracking(1)
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
