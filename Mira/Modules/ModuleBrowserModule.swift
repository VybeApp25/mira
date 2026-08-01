// ModuleBrowserModule.swift
// MacNotch's "All Modules" browser — the pane behind its "Search modules..."
// field and its Dock Favorites settings.
//
// This exists because the dock caps at 12 pinned modules and Mira now registers
// more than that. Without a browser, anything past the cap is reachable only by
// swiping the carousel through every other module, which stops being navigation
// and becomes a scavenger hunt. The cap itself is right — past ~12 the circles
// shrink below a comfortable hit target — so the answer is a way to see
// everything and choose what earns a dock slot.
//
// It is itself a NotchModule, so it obeys the same shell contract as everything
// else. But it is NOT pinned: the dock draws a permanent trailing button for it,
// because a browser that consumes one of the twelve slots it exists to manage
// would be self-defeating.

import SwiftUI

@MainActor
final class ModuleBrowserModule: NotchModule, ObservableObject {

    /// Referenced by the dock's trailing button; keep in sync if renamed.
    static let moduleID = "browser"

    let id    = ModuleBrowserModule.moduleID
    let title = "All Modules"
    let icon  = "square.grid.2x2.fill"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    func makeContent() -> AnyView { AnyView(ModuleBrowserView()) }
}

// MARK: - View

private struct ModuleBrowserView: View {

    @ObservedObject private var registry = NotchModuleRegistry.shared
    @ObservedObject private var accentSvc = AccentColorService.shared
    @State private var query = ""

    private var accent: Color { accentSvc.color }

    /// Every registered module except this browser — listing itself would be
    /// noise, and selecting itself from itself is a no-op.
    private var results: [AnyNotchModule] {
        registry.modules.filter { $0.id != ModuleBrowserModule.moduleID }
            .filter { m in
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { return true }
                return m.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            grid
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
            TextField("Search modules…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.92))
            Spacer(minLength: 0)
            Text("\(registry.pinnedIDs.count)/\(NotchModuleRegistry.maxPinned) pinned")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.30))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                spacing: 8
            ) {
                ForEach(results) { module in
                    card(module)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .overlay {
            if results.isEmpty {
                Text("No modules found.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.40))
            }
        }
    }

    private func card(_ module: AnyNotchModule) -> some View {
        let isPinned = registry.isPinned(module.id)
        let isHidden = registry.isHidden(module.id)
        let atCap = registry.pinnedIDs.count >= NotchModuleRegistry.maxPinned

        return HStack(spacing: 9) {
            // Tapping the body switches to the module — the primary action, and
            // the whole reason someone opens this pane.
            Button {
                registry.select(module.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: module.icon)
                        .font(.system(size: 13))
                        .foregroundColor(isHidden ? .white.opacity(0.25) : accent)
                        .frame(width: 20)
                    Text(module.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHidden ? 0.35 : 0.90))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isHidden)

            // Pin toggle. Disabled rather than hidden when at the cap, so it is
            // obvious the control exists and why it won't act.
            Button {
                registry.togglePin(module.id)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundColor(isPinned ? accent : .white.opacity(0.30))
            }
            .buttonStyle(.plain)
            .disabled(!isPinned && atCap)
            .help(isPinned ? "Unpin from dock"
                           : (atCap ? "Dock is full — unpin something first" : "Pin to dock"))

            Button {
                registry.setHidden(!isHidden, for: module.id)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(isHidden ? 0.45 : 0.28))
            }
            .buttonStyle(.plain)
            .help(isHidden ? "Show in carousel" : "Hide from carousel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(module.id == registry.selectedID ? accent.opacity(0.45) : .clear,
                              lineWidth: 1)
        )
    }
}
