// ProjectsTabView.swift
// Phase 3 + 4 — Project workspace with live agent timeline.
//
// List:   name, status badge, segmented ████░░░ bar, time.
// Detail: big % header, segmented bar, chronological timeline of completions
//         + checkpoints. When an agent is running on this project the timeline
//         switches to a live timestamped activity stream.

import SwiftUI

// MARK: - Timeline event types

private enum TimelineEventKind {
    case created
    case criterionCompleted(CompletionCriterion)
    case checkpoint(ProjectCheckpoint)
    case currentTask(CompletionCriterion)
    case pending(CompletionCriterion)
}

private struct TimelineEvent: Identifiable {
    let id   = UUID()
    let date: Date
    let kind: TimelineEventKind
}

// MARK: - Live pulse dot

private struct LivePulseDot: View {
    @State private var pulsing = false
    private let accent = DS.Colors.accent
    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Projects tab (list ↔ detail)

struct ProjectsTabView: View {
    @ObservedObject private var engine: ProjectEngine = ProjectEngine.shared
    @ObservedObject var animController: AnimationController   // observed so list re-renders on hudMode change
    var onResume: (String) -> Void = { _ in }

    @State private var selectedProject: MiraProject? = nil
    @State private var showNewForm = false
    @State private var newGoal     = ""

    private let accent = DS.Colors.accent

    var body: some View {
        ZStack {
            if let project = selectedProject {
                ProjectDetailView(
                    project:        project,
                    engine:         engine,
                    animController: animController,
                    onResume:       onResume,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedProject = nil }
                    }
                )
                .transition(.opacity)
            } else {
                projectListView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedProject == nil)
    }

    // MARK: - List

    private var projectListView: some View {
        VStack(spacing: 0) {
            listHeader
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            let visible = engine.projects.filter { $0.status != .archived }
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { project in
                            ProjectRowView(project: project)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        selectedProject = project
                                    }
                                }
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        }
                    }
                }
            }
            if showNewForm {
                newProjectForm.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showNewForm)
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Text("Projects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.50))
            let active = engine.activeProjects.count
            if active > 0 {
                Text("\(active) active")
                    .font(.system(size: 10))
                    .foregroundColor(accent.opacity(0.80))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showNewForm.toggle()
                    if !showNewForm { newGoal = "" }
                }
            } label: {
                Image(systemName: showNewForm ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var newProjectForm: some View {
        HStack(spacing: 8) {
            TextField("Project goal…", text: $newGoal)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .tint(accent)
                .onSubmit { createProject() }
            Button(action: createProject) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(newGoal.isEmpty ? .white.opacity(0.15) : accent)
            }
            .buttonStyle(.plain)
            .disabled(newGoal.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.08)), alignment: .top)
    }

    private func createProject() {
        let goal = newGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        engine.createProject(name: String(goal.prefix(40)), goal: goal)
        newGoal = ""
        withAnimation(.easeInOut(duration: 0.18)) { showNewForm = false }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 26)).foregroundColor(.white.opacity(0.10))
            Text("No projects yet").font(.system(size: 12)).foregroundColor(.white.opacity(0.28))
            Text("Tap + to start one").font(.system(size: 11)).foregroundColor(.white.opacity(0.18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Project row

private struct ProjectRowView: View {
    let project: MiraProject
    private let accent   = DS.Colors.accent
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let amber    = Color(red: 1.0,  green: 0.75, blue: 0.20)
    private var depBlocked: Bool { ProjectEngine.shared.isBlockedByDependency(project.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // Status badge circle
                ZStack {
                    Circle().fill(statusColor.opacity(0.16)).frame(width: 24, height: 24)
                    Image(systemName: project.status.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(statusColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(project.status == .completed ? .white.opacity(0.38) : .white.opacity(0.90))
                            .lineLimit(1)
                        if depBlocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(amber.opacity(0.75))
                        }
                    }
                    Text(rowSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(project.status == .blocked ? amber.opacity(0.85) : statusColor.opacity(0.70))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if project.status == .completed {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundColor(successG)
                    } else if !project.criteria.isEmpty {
                        Text("\(project.progressPercent)%")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.88))
                    }
                    Text(project.relativeTime).font(.system(size: 10)).foregroundColor(.white.opacity(0.25))
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.16))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            // Segmented ████░░░ bar
            if !project.criteria.isEmpty && project.status != .completed {
                GeometryReader { geo in
                    let n = max(project.criteria.count, 1)
                    let done = project.completedCriteriaCount
                    let gap: CGFloat = 2
                    let segW = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    HStack(spacing: gap) {
                        ForEach(0..<n, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i < done ? statusColor.opacity(0.75) : Color.white.opacity(0.08))
                                .frame(width: max(segW, 2), height: 4)
                        }
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    private var statusColor: Color {
        switch project.status {
        case .inProgress: return accent
        case .paused:     return Color(red: 0.62, green: 0.62, blue: 0.68)
        case .blocked:    return amber
        case .completed:  return successG
        case .planning:   return .white.opacity(0.45)
        case .archived:   return .white.opacity(0.20)
        }
    }

    private var rowSubtitle: String {
        switch project.status {
        case .inProgress: return project.isStalled ? "Stalled · \(project.relativeTime)" : "In Progress · \(project.relativeTime)"
        case .paused:     return "Paused · \(project.relativeTime)"
        case .blocked:    return "Blocked · needs input"
        case .completed:  return "Completed"
        case .planning:   return "Planning · \(project.relativeTime)"
        case .archived:   return "Archived"
        }
    }
}

// MARK: - Project detail

private struct ProjectDetailView: View {
    let project:  MiraProject
    let engine:   ProjectEngine
    @ObservedObject var animController: AnimationController
    @ObservedObject private var hud: HUDService
    var onResume: (String) -> Void
    let onBack:   () -> Void

    @ObservedObject private var proposalStore = ProposalStore.shared
    @State private var localProject: MiraProject
    @State private var selectedSession: ProjectSession? = nil
    @State private var selectedProposal: ProposalMetadata? = nil
    @State private var showCompletionSummary = false
    // Phase 16 — dependency management
    @State private var showAddDep = false
    @State private var depTargetId: UUID? = nil
    @State private var depKind: DependencyKind = .blocks
    @State private var depNote = ""

    private let accent   = DS.Colors.accent
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let amber    = Color(red: 1.0,  green: 0.75, blue: 0.20)

    init(project: MiraProject, engine: ProjectEngine, animController: AnimationController,
         onResume: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.project         = project
        self.engine          = engine
        self._animController = ObservedObject(wrappedValue: animController)
        self._hud            = ObservedObject(wrappedValue: HUDService.shared)
        self.onResume        = onResume
        self.onBack          = onBack
        self._localProject   = State(initialValue: project)
    }

    // Is the agent actively working on THIS project right now?
    private var isLive: Bool {
        animController.hudMode == .running &&
        (hud.activeProjectName == nil || hud.activeProjectName == localProject.name)
    }

    // Is a different project running?
    private var otherIsLive: Bool {
        animController.hudMode == .running &&
        hud.activeProjectName != nil &&
        hud.activeProjectName != localProject.name
    }

    var body: some View {
        ZStack {
            if showCompletionSummary {
                CompletionSummaryView(
                    project: localProject,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { showCompletionSummary = false }
                    }
                )
                .transition(.opacity)
            } else if let proposal = selectedProposal {
                ProposalDetailView(
                    proposal: proposal,
                    project: localProject,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedProposal = nil }
                    }
                )
                .transition(.opacity)
            } else if let session = selectedSession {
                SessionDetailView(
                    session: session,
                    project: localProject,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedSession = nil }
                    }
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    detailHeader
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                    if !localProject.criteria.isEmpty {
                        progressHeader
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                if isLive {
                                    liveSection
                                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                                } else if otherIsLive {
                                    otherProjectBanner
                                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                                }

                                ForEach(buildTimeline()) { event in
                                    timelineRow(event)
                                        .opacity(isLive ? 0.40 : 1.0)
                                        .animation(.easeInOut(duration: 0.25), value: isLive)
                                }

                                let pendingProposals = proposalStore.pending(for: localProject.id)
                                if !pendingProposals.isEmpty {
                                    proposalSectionHeader(count: pendingProposals.count)
                                    ForEach(pendingProposals) { proposal in
                                        ProposalRowView(proposal: proposal)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    selectedProposal = proposal
                                                }
                                            }
                                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                                    }
                                }

                                let approvedProposals = proposalStore.load(for: localProject.id)
                                    .filter { $0.status == .approved }
                                    .sorted { ($0.reviewedAt ?? $0.createdAt) > ($1.reviewedAt ?? $1.createdAt) }
                                if !approvedProposals.isEmpty {
                                    let unassessed = approvedProposals.filter { $0.outcomes.isEmpty }.count
                                    approvedProposalSectionHeader(total: approvedProposals.count,
                                                                  unassessed: unassessed)
                                    ForEach(approvedProposals) { proposal in
                                        ApprovedProposalRowView(proposal: proposal)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    selectedProposal = proposal
                                                }
                                            }
                                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                                    }
                                }

                                dependencySection

                                let completedSessions = localProject.sessions
                                    .filter { !$0.isActive }
                                    .sorted { $0.startedAt > $1.startedAt }
                                if !completedSessions.isEmpty {
                                    sessionHistoryHeader
                                    ForEach(completedSessions) { s in
                                        SessionRowView(session: s)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    selectedSession = s
                                                }
                                            }
                                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: hud.updates.count) {
                            if isLive, let last = hud.updates.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("live-\(last.id)", anchor: .bottom)
                                }
                            }
                        }
                    }

                    actionBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedSession == nil)
        .onReceive(engine.$projects) { updated in
            if let fresh = updated.first(where: { $0.id == project.id }) {
                localProject = fresh
            } else {
                onBack()
            }
        }
    }

    // MARK: - Header

    private var detailHeader: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Projects").font(.system(size: 11))
                }
                .foregroundColor(accent.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(localProject.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: isLive ? "bolt.fill" : localProject.status.icon)
                    .font(.system(size: 8, weight: .bold))
                Text(isLive ? "Running" : localProject.status.label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(isLive ? accent : statusColor)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((isLive ? accent : statusColor).opacity(0.15))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        HStack(spacing: 14) {
            Text("\(localProject.progressPercent)%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    let n = max(localProject.criteria.count, 1)
                    let done = localProject.completedCriteriaCount
                    let gap: CGFloat = 2
                    let segW = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    HStack(spacing: gap) {
                        ForEach(0..<n, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(i < done ? statusColor.opacity(0.82) : Color.white.opacity(0.08))
                                .frame(width: max(segW, 2), height: 6)
                        }
                    }
                }
                .frame(height: 6)
                Text("\(localProject.completedCriteriaCount) of \(localProject.criteria.count) criteria")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.32))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Phase 6: active agent card + live stream

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            agentCard
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
            ForEach(hud.updates.suffix(8)) { update in
                liveUpdateRow(update, isCurrent: update.id == hud.updates.last?.id)
                    .id("live-\(update.id)")
            }
            if hud.updates.isEmpty {
                Text("Starting…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.30))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .padding(.bottom, 4)
    }

    private var agentCard: some View {
        HStack(spacing: 10) {
            if let session = localProject.activeSession {
                PersonaBadge(persona: session.persona, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.persona.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                    Text("Session #\(session.number) · \(activeDuration(session.startedAt))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
            } else {
                LivePulseDot()
                Text("Working on \(localProject.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(accent.opacity(0.65))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    // MARK: - Proposal section

    private func proposalSectionHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("Proposals")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.5)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundColor(amber.opacity(0.80))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(amber.opacity(0.14))
                .clipShape(Capsule())
            Text("pending review")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.20))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }

    private func approvedProposalSectionHeader(total: Int, unassessed: Int) -> some View {
        HStack(spacing: 6) {
            Text("Approved")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.5)
            Text("\(total)")
                .font(.system(size: 9))
                .foregroundColor(successG.opacity(0.80))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(successG.opacity(0.14))
                .clipShape(Capsule())
            if unassessed > 0 {
                Text("·")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.15))
                Text("\(unassessed) need outcomes")
                    .font(.system(size: 9))
                    .foregroundColor(amber.opacity(0.65))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }

    // MARK: - Dependencies (Phase 16)

    private var dependencySection: some View {
        let upstream   = engine.upstreamProjects(for: localProject.id)
        let downstream = engine.downstreamProjects(for: localProject.id)
        let candidates = engine.projects.filter { $0.id != localProject.id && $0.status != .archived }
        return VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Text("Dependencies")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.28))
                    .tracking(0.5)
                let total = upstream.count + downstream.count
                if total > 0 {
                    Text("\(total)")
                        .font(.system(size: 9))
                        .foregroundColor(accent.opacity(0.65))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(accent.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAddDep.toggle() }
                    if !showAddDep { depNote = ""; depTargetId = nil; depKind = .blocks }
                } label: {
                    Image(systemName: showAddDep ? "xmark" : "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.28))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)

            // Upstream: this depends on
            if !upstream.isEmpty {
                Text("Depends on")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.22))
                    .padding(.horizontal, 12).padding(.bottom, 3)
                ForEach(upstream, id: \.dep.id) { pair in
                    depRow(name: pair.project.name, kind: pair.dep.kind,
                           status: pair.project.status, note: pair.dep.note,
                           depId: pair.dep.id, isUpstream: true)
                    Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                }
            }

            // Downstream: depends on this
            if !downstream.isEmpty {
                Text("Used by")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.22))
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 3)
                ForEach(downstream, id: \.dep.id) { pair in
                    depRow(name: pair.project.name, kind: pair.dep.kind,
                           status: pair.project.status, note: pair.dep.note,
                           depId: pair.dep.id, isUpstream: false)
                    Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                }
            }

            // Add form
            if showAddDep {
                VStack(alignment: .leading, spacing: 6) {
                    if candidates.isEmpty {
                        Text("No other projects to link")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.30))
                    } else {
                        Picker("Project", selection: $depTargetId) {
                            Text("Select project…").tag(Optional<UUID>.none)
                            ForEach(candidates) { p in
                                Text(p.name).tag(Optional(p.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                        .tint(.white.opacity(0.65))

                        Picker("Kind", selection: $depKind) {
                            ForEach(DependencyKind.allCases, id: \.self) { k in
                                Label(k.label, systemImage: k.icon).tag(k)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                        .tint(.white.opacity(0.65))

                        TextField("Note (optional)", text: $depNote)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .tint(accent)

                        HStack {
                            Spacer()
                            Button("Add") {
                                guard let targetId = depTargetId else { return }
                                engine.addDependency(from: localProject.id, to: targetId,
                                                     kind: depKind, note: depNote.isEmpty ? nil : depNote)
                                withAnimation { showAddDep = false }
                                depNote = ""; depTargetId = nil; depKind = .blocks
                            }
                            .disabled(depTargetId == nil)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(depTargetId == nil ? .white.opacity(0.20) : accent)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.08)), alignment: .top)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showAddDep)
    }

    private func depRow(name: String, kind: DependencyKind, status: ProjectStatus,
                        note: String?, depId: UUID, isUpstream: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 9))
                .foregroundColor(depKindColor(kind))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
                    .lineLimit(1)
                if let n = note {
                    Text(n)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.30))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(kind.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(depKindColor(kind))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(depKindColor(kind).opacity(0.14))
                .clipShape(Capsule())
            if isUpstream {
                Button {
                    engine.removeDependency(id: depId, from: localProject.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.22))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func depKindColor(_ kind: DependencyKind) -> Color {
        switch kind {
        case .blocks:   return amber
        case .requires: return Color(red: 1.0, green: 0.50, blue: 0.20)
        case .informs:  return accent
        case .succeeds: return Color(red: 0.20, green: 0.84, blue: 0.60)
        }
    }

    // MARK: - Session history

    private var sessionHistoryHeader: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
                .tracking(0.5)
            let count = localProject.sessions.filter { !$0.isActive }.count
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundColor(accent.opacity(0.65))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func activeDuration(_ startedAt: Date) -> String {
        let diff = Date().timeIntervalSince(startedAt)
        if diff < 60    { return "< 1 min" }
        if diff < 3_600 { return "\(Int(diff / 60))m" }
        let h = Int(diff / 3_600)
        let m = Int(diff.truncatingRemainder(dividingBy: 3_600) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func liveUpdateRow(_ update: HUDUpdate, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(liveTime(update.timestamp))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(isCurrent ? .white.opacity(0.40) : .white.opacity(0.18))
                .frame(width: 36, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: update.category.icon)
                    .font(.system(size: 9))
                    .foregroundColor(isCurrent ? accent : .white.opacity(0.18))
                    .frame(width: 12)
                Text(update.message)
                    .font(.system(size: 12))
                    .foregroundColor(isCurrent ? .white.opacity(0.92) : .white.opacity(0.26))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(isCurrent ? accent.opacity(0.07) : .clear)
    }

    private func liveTime(_ date: Date) -> String {
        let c = Calendar.current
        let h = c.component(.hour, from: date)
        let m = c.component(.minute, from: date)
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d", h12, m)
    }

    // MARK: - Other project running banner

    private var otherProjectBanner: some View {
        HStack(spacing: 8) {
            LivePulseDot()
            Text("Working on \(hud.activeProjectName ?? "another project")")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Historical timeline

    private func buildTimeline() -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        events.append(TimelineEvent(date: localProject.createdAt, kind: .created))
        for c in localProject.criteria.filter(\.isComplete) {
            events.append(TimelineEvent(date: c.verifiedAt ?? localProject.createdAt, kind: .criterionCompleted(c)))
        }
        for cp in localProject.checkpoints {
            events.append(TimelineEvent(date: cp.createdAt, kind: .checkpoint(cp)))
        }
        events.sort { $0.date < $1.date }
        if localProject.status != .completed {
            let incomplete = localProject.criteria.filter { !$0.isComplete }.sorted { $0.sortOrder < $1.sortOrder }
            if let current = incomplete.first {
                events.append(TimelineEvent(date: Date(), kind: .currentTask(current)))
                for c in incomplete.dropFirst() {
                    events.append(TimelineEvent(date: .distantFuture, kind: .pending(c)))
                }
            }
        }
        return events
    }

    @ViewBuilder
    private func timelineRow(_ event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(iconBg(event)).frame(width: 18, height: 18)
                    Image(systemName: iconName(event))
                        .font(.system(size: iconPt(event), weight: .bold))
                        .foregroundColor(iconFg(event))
                }
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1, height: 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(rowLabel(event))
                    .font(.system(size: 12, weight: rowWeight(event)))
                    .foregroundColor(rowFg(event))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = rowSub(event) {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(rowSubFg(event))
                }
            }
            .padding(.top, 1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(rowBg(event))
    }

    // MARK: - Timeline icon helpers

    private func iconName(_ e: TimelineEvent) -> String {
        switch e.kind {
        case .created:            return "plus"
        case .criterionCompleted: return "checkmark"
        case .checkpoint:         return "pin.fill"
        case .currentTask:        return "arrow.right"
        case .pending:            return "circle"
        }
    }
    private func iconPt(_ e: TimelineEvent) -> CGFloat {
        switch e.kind { case .checkpoint: return 7; case .pending: return 9; default: return 8 }
    }
    private func iconBg(_ e: TimelineEvent) -> Color {
        switch e.kind {
        case .created:            return accent.opacity(0.20)
        case .criterionCompleted: return successG.opacity(0.20)
        case .checkpoint:         return accent.opacity(0.15)
        case .currentTask:        return statusColor.opacity(0.25)
        case .pending:            return Color.white.opacity(0.05)
        }
    }
    private func iconFg(_ e: TimelineEvent) -> Color {
        switch e.kind {
        case .created:            return accent
        case .criterionCompleted: return successG
        case .checkpoint:         return accent.opacity(0.75)
        case .currentTask:        return statusColor
        case .pending:            return .white.opacity(0.20)
        }
    }

    // MARK: - Timeline text helpers

    private func rowLabel(_ e: TimelineEvent) -> String {
        switch e.kind {
        case .created:                   return "Project created"
        case .criterionCompleted(let c): return c.description
        case .checkpoint(let cp):        return "Checkpoint #\(cp.number): \(cp.title)"
        case .currentTask(let c):        return c.description
        case .pending(let c):            return c.description
        }
    }
    private func rowWeight(_ e: TimelineEvent) -> Font.Weight {
        switch e.kind { case .currentTask: return .medium; case .checkpoint: return .semibold; default: return .regular }
    }
    private func rowFg(_ e: TimelineEvent) -> Color {
        switch e.kind {
        case .created:            return .white.opacity(0.38)
        case .criterionCompleted: return .white.opacity(0.36)
        case .checkpoint:         return .white.opacity(0.65)
        case .currentTask:        return .white.opacity(0.92)
        case .pending:            return .white.opacity(0.26)
        }
    }
    private func rowSub(_ e: TimelineEvent) -> String? {
        switch e.kind {
        case .created:                   return relativeTime(e.date)
        case .criterionCompleted:        return relativeTime(e.date)
        case .checkpoint(let cp):        return cp.relativeTime + (cp.blockedReason.map { " · ⚠ \($0)" } ?? "")
        case .currentTask:               return localProject.status == .blocked ? "⚠ Blocked" : "→ Active"
        case .pending:                   return nil
        }
    }
    private func rowSubFg(_ e: TimelineEvent) -> Color {
        switch e.kind {
        case .currentTask where localProject.status == .blocked: return amber.opacity(0.85)
        case .currentTask:                                        return statusColor.opacity(0.70)
        default:                                                  return .white.opacity(0.22)
        }
    }
    private func rowBg(_ e: TimelineEvent) -> Color {
        if case .currentTask = e.kind { return statusColor.opacity(0.07) }
        return .clear
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Spacer()
            switch localProject.status {
            case .planning:
                primaryBtn(label: "Start",   icon: "bolt.fill", color: accent) { resume() }
            case .inProgress:
                primaryBtn(label: "Resume",  icon: "bolt.fill", color: accent) { resume() }
            case .paused:
                primaryBtn(label: "Resume",  icon: "bolt.fill", color: accent) { resume() }
                secondaryBtn(label: "Archive", icon: "archivebox") { engine.archive(id: localProject.id); onBack() }
            case .blocked:
                primaryBtn(label: "Mark Unblocked", icon: "checkmark", color: amber) {
                    engine.markPaused(id: localProject.id)
                    animController.clearHUD()
                }
            case .completed:
                primaryBtn(label: "Summary", icon: "list.bullet.rectangle.fill", color: successG) {
                    withAnimation(.easeInOut(duration: 0.18)) { showCompletionSummary = true }
                }
                secondaryBtn(label: "Archive", icon: "archivebox") { engine.archive(id: localProject.id); onBack() }
            case .archived:
                EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.07)), alignment: .top)
    }

    private func primaryBtn(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func secondaryBtn(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.28))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Resume

    private func resume() {
        let prompt = engine.buildResumePrompt(for: localProject)
        engine.markInProgress(id: localProject.id)
        onResume(prompt)
        onBack()
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch localProject.status {
        case .inProgress: return accent
        case .paused:     return Color(red: 0.62, green: 0.62, blue: 0.68)
        case .blocked:    return amber
        case .completed:  return successG
        case .planning:   return .white.opacity(0.45)
        case .archived:   return .white.opacity(0.20)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let d = Date().timeIntervalSince(date)
        if d < 60     { return "just now" }
        if d < 3_600  { return "\(Int(d / 60))m ago" }
        if d < 86_400 { return "\(Int(d / 3_600))h ago" }
        return "\(Int(d / 86_400))d ago"
    }
}

// MARK: - PersonaBadge

private struct PersonaBadge: View {
    let persona: AgentPersona
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(personaColor.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: persona.icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(personaColor)
        }
    }

    private var personaColor: Color {
        switch persona {
        case .developer:  return DS.Colors.accent
        case .tester:     return Color(red: 0.20, green: 0.84, blue: 0.60)
        case .researcher: return Color(red: 0.76, green: 0.60, blue: 1.0)
        case .writer:     return Color(red: 1.0,  green: 0.75, blue: 0.20)
        }
    }
}

// MARK: - SessionRowView

private struct SessionRowView: View {
    let session: ProjectSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PersonaBadge(persona: session.persona, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Session #\(session.number)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.18))
                    Text(session.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                }
                if let summary = session.summary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.50))
                        .lineLimit(1)
                } else {
                    Text(session.persona.displayName + " · " + session.duration)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.16))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - SessionDetailView

private struct SessionDetailView: View {
    let session: ProjectSession
    let project: MiraProject
    let onBack:  () -> Void

    private let accent = DS.Colors.accent

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Project").font(.system(size: 11))
                    }
                    .foregroundColor(accent.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Session #\(session.number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                // Visual balance for centered title
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Project").font(.system(size: 11))
                }
                .opacity(0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    personaRow
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)

                    if let summary = session.summary {
                        metaSection("Summary") {
                            Text(summary)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.68))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }

                    if !session.artifactPaths.isEmpty {
                        metaSection("Artifacts") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(session.artifactPaths, id: \.self) { path in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.25))
                                        Text((path as NSString).lastPathComponent)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.65))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }

                    if !sessionCheckpoints.isEmpty {
                        metaSection("Checkpoints") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(sessionCheckpoints) { cp in
                                    HStack(spacing: 6) {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(accent.opacity(0.55))
                                        Text("#\(cp.number): \(cp.title)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.65))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var personaRow: some View {
        HStack(spacing: 12) {
            PersonaBadge(persona: session.persona, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.persona.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                HStack(spacing: 6) {
                    Text(session.duration)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.38))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.20))
                    Text(session.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.38))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder
    private func metaSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .tracking(1)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var sessionCheckpoints: [ProjectCheckpoint] {
        let ids = Set(session.checkpointIds)
        return project.checkpoints
            .filter { ids.contains($0.id) }
            .sorted { $0.number < $1.number }
    }
}

// MARK: - ProposalRowView

private struct ProposalRowView: View {
    let proposal: ProposalMetadata
    private let accent = DS.Colors.accent
    private let amber  = Color(red: 1.0,  green: 0.75, blue: 0.20)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(amber.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: typeIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(amber.opacity(0.80))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(proposal.type.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.18))
                    Text(String(format: "%.0f%% confidence", proposal.confidence * 100))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.18))
                    Text(relativeTime(proposal.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.28))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.16))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var typeIcon: String {
        switch proposal.type {
        case .investigation: return "magnifyingglass"
        case .refactor:      return "arrow.triangle.2.circlepath"
        case .test:          return "checkmark.shield"
        case .migration:     return "arrow.right.circle"
        case .patch:         return "doc.badge.plus"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let d = Date().timeIntervalSince(date)
        if d < 60     { return "just now" }
        if d < 3_600  { return "\(Int(d / 60))m ago" }
        if d < 86_400 { return "\(Int(d / 3_600))h ago" }
        return "\(Int(d / 86_400))d ago"
    }
}

// MARK: - ApprovedProposalRowView

private struct ApprovedProposalRowView: View {
    let proposal: ProposalMetadata
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let amber    = Color(red: 1.0,  green: 0.75, blue: 0.20)

    private var summary: OutcomeSummary? {
        OutcomeSummary.compute(from: proposal.outcomes, reviewedAt: proposal.reviewedAt)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(successG.opacity(0.10))
                    .frame(width: 26, height: 26)
                Image(systemName: typeIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(successG.opacity(0.70))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                if let s = summary {
                    HStack(spacing: 4) {
                        outcomeBadge(s.currentAdoption.label, color: adoptionColor(s.currentAdoption))
                        outcomeBadge(s.currentImpact.label,   color: impactColor(s.currentImpact))
                        if s.currentRegret != .none {
                            outcomeBadge(s.currentRegret.label, color: Color(red: 1.0, green: 0.40, blue: 0.40))
                        }
                    }
                } else {
                    Text("No outcome recorded yet")
                        .font(.system(size: 10))
                        .foregroundColor(amber.opacity(0.55))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.16))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func outcomeBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func adoptionColor(_ s: AdoptionStatus) -> Color {
        switch s {
        case .notReviewed:            return .white.opacity(0.30)
        case .approvedNotImplemented: return amber
        case .implemented:            return successG
        case .abandoned:              return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }

    private func impactColor(_ s: ImpactStatus) -> Color {
        switch s {
        case .unknown:  return .white.opacity(0.30)
        case .improved: return successG
        case .neutral:  return DS.Colors.accent
        case .worsened: return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }

    private var typeIcon: String {
        switch proposal.type {
        case .investigation: return "magnifyingglass"
        case .refactor:      return "arrow.triangle.2.circlepath"
        case .test:          return "checkmark.shield"
        case .migration:     return "arrow.right.circle"
        case .patch:         return "doc.badge.plus"
        }
    }
}

// MARK: - ProposalDetailView

private struct ProposalDetailView: View {
    let proposal: ProposalMetadata
    let project:  MiraProject
    let onBack:   () -> Void

    @ObservedObject private var proposalStore = ProposalStore.shared
    @State private var selectedConfidence:    ReviewConfidence? = nil
    @State private var rejectNote = ""
    @State private var showRejectField = false
    // Phase 15 — outcome form state
    @State private var oAdoption:    AdoptionStatus       = .approvedNotImplemented
    @State private var oImpact:      ImpactStatus         = .unknown
    @State private var oRegret:      RegretStatus         = .none
    @State private var oConfidence:  AssessmentConfidence = .medium
    @State private var oNote:        String               = ""
    @State private var oSubmitted:   Bool                 = false

    private let accent   = DS.Colors.accent
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let amber    = Color(red: 1.0,  green: 0.75, blue: 0.20)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    typeConfidenceRow
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    metaSection("Rationale") {
                        Text(proposal.rationale)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !proposal.affectedFiles.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        metaSection("Files") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(proposal.affectedFiles, id: \.self) { path in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.25))
                                        Text((path as NSString).lastPathComponent)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.65))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    if let content = proposalStore.artifactContent(for: proposal), !content.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        metaSection("Proposal") {
                            Text(content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if showRejectField {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        metaSection("Rejection note (optional)") {
                            TextField("Why are you rejecting this?", text: $rejectNote)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .tint(accent)
                        }
                    }
                    // Phase 15: outcome tracking (approved proposals only)
                    if proposal.status == .approved {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        outcomeSection
                    }
                }
                .padding(.bottom, 8)
            }
            actionBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Project").font(.system(size: 11))
                }
                .foregroundColor(accent.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(proposal.type.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text("Project").font(.system(size: 11))
            }
            .opacity(0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    // MARK: - Type + confidence

    private var typeConfidenceRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(amber.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: typeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(amber.opacity(0.80))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                confidenceBar
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var confidenceBar: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(confidenceColor.opacity(0.70))
                        .frame(width: geo.size.width * proposal.confidence)
                }
            }
            .frame(height: 4)
            Text(String(format: "%.0f%%", proposal.confidence * 100))
                .font(.system(size: 10))
                .foregroundColor(confidenceColor.opacity(0.75))
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var confidenceColor: Color {
        if proposal.confidence >= 0.75 { return successG }
        if proposal.confidence >= 0.50 { return amber }
        return Color(red: 1.0, green: 0.40, blue: 0.40)
    }

    // MARK: - Confidence picker

    private var confidencePicker: some View {
        HStack(spacing: 0) {
            Text("Confidence")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.28))
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(ReviewConfidence.allCases, id: \.self) { level in
                    let selected = selectedConfidence == level
                    Button {
                        selectedConfidence = selected ? nil : level
                    } label: {
                        Text(level.label)
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? confidenceColor(level) : .white.opacity(0.32))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(selected ? confidenceColor(level).opacity(0.15) : Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(selected ? confidenceColor(level).opacity(0.35) : Color.clear, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.05)), alignment: .top)
    }

    private func confidenceColor(_ level: ReviewConfidence) -> Color {
        switch level {
        case .low:    return Color(red: 1.0, green: 0.75, blue: 0.20)   // amber
        case .medium: return DS.Colors.accent   // accent blue
        case .high:   return Color(red: 0.20, green: 0.84, blue: 0.60)  // successG
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            if proposal.status == .pending { confidencePicker }
            HStack(spacing: 8) {
                Spacer()
                // Non-pending proposals: show status pill only — outcome tracking is in the scroll body above
                if proposal.status != .pending {
                    HStack(spacing: 5) {
                        Image(systemName: proposal.status == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(proposal.status == .approved ? successG : Color(red: 1.0, green: 0.40, blue: 0.40))
                        Text(proposal.status == .approved ? "Approved" : proposal.status.rawValue.capitalized)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if showRejectField {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showRejectField = false; rejectNote = "" }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.28))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Button {
                        proposalStore.update(proposalId: proposal.id, projectId: project.id,
                                             status: .rejected, confidence: selectedConfidence,
                                             note: rejectNote.isEmpty ? nil : rejectNote)
                        onBack()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            Text("Reject").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.40, blue: 0.40))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(red: 1.0, green: 0.40, blue: 0.40).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showRejectField = true }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            Text("Reject").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.28))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Button {
                        proposalStore.update(proposalId: proposal.id, projectId: project.id,
                                             status: .approved, confidence: selectedConfidence)
                        onBack()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            Text("Approve").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(successG)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(successG.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.03))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.07)), alignment: .top)
    }

    // MARK: - Phase 15 outcome section

    @ViewBuilder
    private var outcomeSection: some View {
        // Load the freshest copy so form reflects any just-saved assessment
        let live = proposalStore.load(for: project.id).first(where: { $0.id == proposal.id }) ?? proposal
        let summary = OutcomeSummary.compute(from: live.outcomes, reviewedAt: live.reviewedAt)

        metaSection("Outcome Tracking") {
            VStack(alignment: .leading, spacing: 10) {
                // Summary badge row if assessments exist
                if let s = summary {
                    HStack(spacing: 8) {
                        outcomeBadge(s.currentAdoption.label, color: adoptionColor(s.currentAdoption))
                        outcomeBadge(s.currentImpact.label,   color: impactColor(s.currentImpact))
                        outcomeBadge(s.currentRegret.label,   color: regretColor(s.currentRegret))
                        Spacer()
                        Text("\(s.assessmentCount) assessment\(s.assessmentCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }

                // Assessment form
                VStack(alignment: .leading, spacing: 8) {
                    outcomePickerRow("Adoption", cases: AdoptionStatus.allCases,
                                     label: \.label, selection: $oAdoption)
                    outcomePickerRow("Impact",   cases: ImpactStatus.allCases,
                                     label: \.label, selection: $oImpact)
                    outcomePickerRow("Regret",   cases: RegretStatus.allCases,
                                     label: \.label, selection: $oRegret)
                    outcomePickerRow("Confidence", cases: AssessmentConfidence.allCases,
                                     label: \.label, selection: $oConfidence)

                    TextField("Note (optional)", text: $oNote)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.70))
                        .tint(accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        let assessment = OutcomeAssessment(
                            id:                   UUID(),
                            assessedAt:           Date(),
                            assessedBy:           "user",
                            adoptionStatus:       oAdoption,
                            impactStatus:         oImpact,
                            regretStatus:         oRegret,
                            assessmentConfidence: oConfidence,
                            note:                 oNote.isEmpty ? nil : oNote
                        )
                        proposalStore.appendOutcome(assessment, to: proposal.id, projectId: project.id)
                        oNote      = ""
                        oSubmitted = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { oSubmitted = false }
                    } label: {
                        Text(oSubmitted ? "Recorded ✓" : "Record Outcome")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundColor(.white)
                            .background(oSubmitted ? successG : accent)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // History list (most recent first)
                if !live.outcomes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HISTORY")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.20))
                            .tracking(1)
                        ForEach(live.outcomes.sorted { $0.assessedAt > $1.assessedAt }) { a in
                            HStack(spacing: 6) {
                                Text(a.assessedAt, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.30))
                                    .frame(width: 70, alignment: .leading)
                                outcomeBadge(a.adoptionStatus.label, color: adoptionColor(a.adoptionStatus))
                                outcomeBadge(a.impactStatus.label,   color: impactColor(a.impactStatus))
                                outcomeBadge(a.regretStatus.label,   color: regretColor(a.regretStatus))
                            }
                        }
                    }
                }
            }
        }
    }

    private func outcomeBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func outcomePickerRow<T: Hashable>(_ title: String, cases: [T],
                                               label: KeyPath<T, String>,
                                               selection: Binding<T>) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.30))
                .frame(width: 68, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(cases, id: \.self) { c in
                    let sel = selection.wrappedValue == c
                    Button { selection.wrappedValue = c } label: {
                        Text(c[keyPath: label])
                            .font(.system(size: 9, weight: sel ? .semibold : .regular))
                            .foregroundColor(sel ? .white : .white.opacity(0.35))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(sel ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func adoptionColor(_ s: AdoptionStatus) -> Color {
        switch s {
        case .notReviewed:            return .white.opacity(0.30)
        case .approvedNotImplemented: return amber
        case .implemented:            return successG
        case .abandoned:              return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }

    private func impactColor(_ s: ImpactStatus) -> Color {
        switch s {
        case .unknown:  return .white.opacity(0.30)
        case .improved: return successG
        case .neutral:  return accent
        case .worsened: return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }

    private func regretColor(_ s: RegretStatus) -> Color {
        switch s {
        case .none:                          return successG
        case .reverted:                      return Color(red: 1.0, green: 0.40, blue: 0.40)
        case .supersededAfterImplementation: return amber
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func metaSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .tracking(1)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var typeIcon: String {
        switch proposal.type {
        case .investigation: return "magnifyingglass"
        case .refactor:      return "arrow.triangle.2.circlepath"
        case .test:          return "checkmark.shield"
        case .migration:     return "arrow.right.circle"
        case .patch:         return "doc.badge.plus"
        }
    }
}

// MARK: - CompletionSummaryView

private struct CompletionSummaryView: View {
    let project: MiraProject
    let onBack:  () -> Void

    private let accent   = DS.Colors.accent
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let columns  = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let s = project.completionSummary {
                        statsGrid(s)
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }
                    if !project.criteria.isEmpty {
                        accomplishmentsSection
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }
                    if let s = project.completionSummary, !s.personaBreakdown.isEmpty {
                        contributorsSection(s)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Project").font(.system(size: 11))
                }
                .foregroundColor(accent.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(successG)
                Text("Complete")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text("Project").font(.system(size: 11))
            }
            .opacity(0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    // MARK: - Stats grid

    private func statsGrid(_ s: CompletionSummary) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            statCell(value: "\(s.sessionCount)",    label: "Sessions")
            statCell(value: "\(s.checkpointCount)", label: "Checkpoints")
            statCell(value: "\(s.artifactCount)",   label: "Artifacts")
            statCell(value: s.formattedTimeInvested, label: "Invested")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.30))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(2)
    }

    // MARK: - Accomplishments

    private var accomplishmentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Accomplishments")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(project.criteria) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(successG.opacity(0.80))
                        Text(c.description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    // MARK: - Contributors

    private func contributorsSection(_ s: CompletionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Contributors")
            VStack(spacing: 8) {
                ForEach(s.personaBreakdown, id: \.persona) { item in
                    HStack(spacing: 10) {
                        PersonaBadge(persona: item.persona, size: 22)
                        Text(item.persona.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.70))
                        Spacer()
                        Text("\(item.sessions) session\(item.sessions == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.30))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.25))
            .tracking(1)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }
}
