// NotchModuleShellView.swift
// The chrome every notch module is drawn inside. Phase 0 of the MacNotch parity work.
//
// This view owns the header row, the `‹ Back` drill-in chip, the collapse affordance,
// and the pinned dock strip. Modules supply content only. That split is the whole
// point: MacNotch's ~22 panels put their title, controls, and collapse button in
// exactly the same place every time, and that constancy is most of what reads as
// polished. If a module drew its own header, the first inconsistency would show up
// the day someone shipped a panel in a hurry.
//
// Layout, top to bottom:
//
//   ┌──────────────────────────────────────────┐
//   │ ‹ Back   Title  subtitle       ⟳ ⓘ ⚙   │  header (menu-bar height)
//   ├──────────────────────────────────────────┤
//   │                                          │
//   │            module content                │
//   │                                      ⤡  │  collapse, bottom-right
//   └──────────────────────────────────────────┘
//        ● ● ● ● ●                                pinned dock, detached below

import SwiftUI

struct NotchModuleShellView: View {

    @ObservedObject private var registry = NotchModuleRegistry.shared
    @ObservedObject private var accentSvc = AccentColorService.shared

    /// Height of the overlaid header. Modules inset their FOREGROUND content by
    /// this so it clears the title row, while their background (a weather sky, a
    /// media gradient) still runs the full height of the panel. Read it via
    /// `NotchModuleShellView.headerHeight` rather than hardcoding a guess.
    static let headerHeight: CGFloat = 30

    /// Height of the black band the physical notch occludes. Content is seated
    /// below it so the cutout can never cover an interactive control — the same
    /// fix applied to the tab panel on 2026-07-05.
    let notchBandHeight: CGFloat

    /// Invoked when the user hits the collapse affordance.
    var onCollapse: () -> Void = {}

    private var accent: Color { accentSvc.color }

    @ObservedObject private var meetings = MeetingAlertService.shared

    var body: some View {
        Group {
            // A meeting starting pre-empts the module. Drawn INSTEAD of it
            // rather than over it, which is what makes it read as an
            // interruption rather than a banner — and means the module
            // underneath keeps its own state for when the alert is gone.
            if let alert = meetings.alert {
                MeetingAlertView(service: meetings, alert: alert)
                    .transition(.opacity)
            } else if let module = registry.selected {
                // Header OVERLAYS the content rather than sitting in a row above
                // it. A module's backdrop (the weather sky, say) then runs the
                // full height of the panel instead of being boxed below a black
                // header bar — which was what made the first pass read as a card
                // pasted into a slab rather than one object.
                ZStack(alignment: .top) {
                    content(for: module)
                    NotchModuleRail()
                    header(for: module)
                }
                // Horizontal swipe is the PRIMARY navigation between modules —
                // MacNotch's own settings call it "the horizontal swipe carousel"
                // and the pinned dock is only a shortcut into it. Trackpad scroll
                // and drag both work; a drag is what a mouse user reaches for.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            // Ignore mostly-vertical drags so scrolling a module's
                            // own content never flips to the next module.
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            registry.advance(by: value.translation.width < 0 ? 1 : -1)
                        }
                )
                // Bottom corners match the slab's expanded radius so the module
                // ends flush with the panel instead of squaring off inside it.
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: AnimationController.expandedBotR,
                        bottomTrailingRadius: AnimationController.expandedBotR,
                        style: .continuous
                    )
                )
            } else {
                // Registry empty — only reachable before registration during
                // startup. Draw nothing rather than an error state the user
                // would see flash on every launch.
                Color.clear
            }
        }
        .frame(height: registry.currentHeight)
        // Same rule as the panel itself: switching to a module of a different
        // height snaps the frame rather than springing it. Only the content
        // crossfades. See the note on MiraIslandView's frame animation.
        .animation(nil, value: registry.currentHeight)
        .animation(.easeInOut(duration: 0.18), value: registry.selectedID)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for module: AnyNotchModule) -> some View {
        HStack(spacing: 8) {
            if let detail = module.detailTitle {
                backChip(title: detail) { module.popDetail() }
            } else {
                Text(module.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }

            if let sub = module.subtitle {
                if sub.isPill {
                    Text(sub.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Capsule())
                } else {
                    Text(sub.text)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 8)

            ForEach(module.headerAccessories) { accessory in
                accessoryButton(accessory)
            }

            // Widen/narrow the panel. Deliberately LAST — it is the only control
            // here that belongs to the notch rather than to the module, so it
            // stays in the same corner no matter which module is open.
            maximizeButton
        }
        .padding(.horizontal, 14)
        .frame(height: max(notchBandHeight, Self.headerHeight))
        // Scrim so header text stays legible over a bright module backdrop
        // (a sunny sky) without needing an opaque bar.
        .background(
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    /// In-place drill-in affordance. Never opens a window — MacNotch pushes detail
    /// views inside the slab and so do we.
    private func backChip(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(title)")
    }

    @ObservedObject private var layout = NotchLayoutService.shared

    private var maximizeButton: some View {
        Button { layout.toggle() } label: {
            Image(systemName: layout.isMaximized
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.60))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layout.isMaximized ? "Narrow the notch" : "Widen the notch")
        .accessibilityLabel(layout.isMaximized ? "Narrow the notch" : "Widen the notch")
    }

    private func accessoryButton(_ accessory: NotchHeaderAccessory) -> some View {
        Button(action: accessory.action) {
            Image(systemName: accessory.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accessory.isProminent ? accent : .white.opacity(0.60))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(accessory.isProminent
                                  ? accent.opacity(0.16)
                                  : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
        .help(accessory.label)
        .accessibilityLabel(accessory.label)
    }

    // MARK: - Content + collapse

    private func content(for module: AnyNotchModule) -> some View {
        ZStack(alignment: .bottomTrailing) {
            module.makeContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Re-identify on module change so SwiftUI tears down the old
                // module's state instead of trying to diff two unrelated trees.
                .id(module.id)

            collapseButton
                .padding(.trailing, 10)
                .padding(.bottom, 8)
        }
        .onAppear { module.didAppear() }
        .onDisappear { module.didDisappear() }
    }

    /// Always the same glyph in the same corner, on every module.
    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.30)))
        }
        .buttonStyle(.plain)
        .help("Collapse")
        .accessibilityLabel("Collapse the notch")
    }
}

// MARK: - Pinned dock strip

/// The detached row of circular buttons below the slab. These are the user's
/// PINNED modules, not every module — which is why the count varies between
/// installs. Primary navigation is the carousel; this is a shortcut.
struct NotchModuleDockStrip: View {

    @ObservedObject private var registry = NotchModuleRegistry.shared
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        let pinned = registry.pinnedModules
        // A single circle floating alone in black reads as a rendering artifact,
        // not as a switcher. The strip only earns its space once there's
        // somewhere to switch TO.
        if pinned.count > 1 || registry.visibleModules.count > pinned.count {
            HStack(spacing: 6) {
                ForEach(pinned) { module in
                    let isCurrent = module.id == registry.selectedID
                    Button {
                        registry.select(module.id)
                    } label: {
                        Image(systemName: module.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isCurrent ? accent : .white.opacity(0.55))
                            .frame(width: 28, height: 28)
                            // OPAQUE. At 0.55 the desktop and any window behind
                            // showed straight through the circles, which read as
                            // a rendering fault rather than as floating controls.
                            // MacNotch's dock buttons are solid black.
                            .background(
                                ZStack {
                                    Circle().fill(Color.black)
                                    if isCurrent { Circle().fill(accent.opacity(0.22)) }
                                }
                            )
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                            .overlay(
                                Circle().strokeBorder(
                                    isCurrent ? accent.opacity(0.45) : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(module.title)
                    .accessibilityLabel(module.title)
                    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
                }

                // Permanent trailing button into the browser. Not a pinned
                // module — with the dock capped at 12 and more than that
                // registered, this is the only guaranteed route to the rest.
                let browsing = registry.selectedID == ModuleBrowserModule.moduleID
                Button {
                    registry.select(ModuleBrowserModule.moduleID)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(browsing ? accent : .white.opacity(0.55))
                        .frame(width: 28, height: 28)
                        .background(
                            ZStack {
                                Circle().fill(Color.black)
                                if browsing { Circle().fill(accent.opacity(0.22)) }
                            }
                        )
                        .overlay(
                            Circle().strokeBorder(
                                browsing ? accent.opacity(0.45) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                        )
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .help("All modules")
                .accessibilityLabel("All modules")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.18), value: registry.selectedID)
        }
    }
}

// MARK: - Right-edge rail

/// A vertical column of small module icons clipped against the slab's right
/// edge — MacNotch's secondary switcher, and the last shell element from the
/// parity audit.
///
/// It shows a WINDOW of the carousel centred on the current module rather than
/// every module. With 26 registered, drawing them all would either shrink the
/// icons to noise or overflow the panel; showing the neighbours communicates the
/// thing the rail is actually for — that there is more either side of you, and
/// roughly where you are in the order.
///
/// Deliberately peripheral: half-opacity, small, and partially clipped at the
/// edge exactly as MacNotch's is. It is orientation, not a primary control —
/// the carousel and the dock are the ways you actually move.
struct NotchModuleRail: View {

    @ObservedObject private var registry = NotchModuleRegistry.shared
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    /// Modules either side of the current one, wrapping.
    private var window: [(module: AnyNotchModule, isCurrent: Bool)] {
        let list = registry.visibleModules
        guard list.count > 1,
              let idx = list.firstIndex(where: { $0.id == registry.selectedID })
        else { return [] }

        let span = 2   // two above, two below
        return (-span...span).map { offset in
            let i = ((idx + offset) % list.count + list.count) % list.count
            return (list[i], offset == 0)
        }
    }

    var body: some View {
        if !window.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 7) {
                    ForEach(window, id: \.module.id) { entry in
                        Image(systemName: entry.module.icon)
                            .font(.system(size: entry.isCurrent ? 10 : 9,
                                          weight: entry.isCurrent ? .semibold : .regular))
                            .foregroundColor(entry.isCurrent ? accent : .white.opacity(0.28))
                            .frame(width: 14, height: 14)
                    }
                }
                // Clipped against the edge: the icons run off the slab rather
                // than sitting in a tidy inset column.
                .padding(.trailing, 3)
            }
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.20), value: registry.selectedID)
            .accessibilityHidden(true)   // orientation only; the dock is the control
        }
    }
}
