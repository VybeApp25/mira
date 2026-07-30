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

    /// Height of the black band the physical notch occludes. Content is seated
    /// below it so the cutout can never cover an interactive control — the same
    /// fix applied to the tab panel on 2026-07-05.
    let notchBandHeight: CGFloat

    /// Invoked when the user hits the collapse affordance.
    var onCollapse: () -> Void = {}

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(spacing: 0) {
            if let module = registry.selected {
                header(for: module)
                Divider().overlay(Color.white.opacity(0.06))
                content(for: module)
            } else {
                // Registry empty — only reachable before registration during
                // startup. Draw nothing rather than an error state the user
                // would see flash on every launch.
                Color.clear
            }
        }
        .frame(height: registry.currentHeight)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: registry.currentHeight)
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
        }
        .padding(.horizontal, 14)
        .frame(height: max(notchBandHeight, 30))
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
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.07)))
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
        if !pinned.isEmpty {
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
                            .background(
                                Circle().fill(isCurrent
                                              ? accent.opacity(0.18)
                                              : Color.black.opacity(0.55))
                            )
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.18), value: registry.selectedID)
        }
    }
}
