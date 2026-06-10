import SwiftUI

struct SkillsTabView: View {
    @ObservedObject private var store = SkillStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(MiraSkill.Category.allCases, id: \.self) { category in
                        let skills = MiraSkillCatalog.all.filter { $0.category == category }
                        if !skills.isEmpty {
                            Section {
                                ForEach(skills) { skill in
                                    SkillCard(skill: skill, isActive: store.isActive(skill.id)) {
                                        store.toggle(skill.id)
                                    }
                                }
                            } header: {
                                HStack(spacing: 4) {
                                    Image(systemName: category.icon)
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(category.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundColor(.secondary.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.top, 10)
                                .gridCellColumns(2)
                            }
                        }
                    }
                }
                .padding(10)
            }
            if !store.activeIDs.isEmpty {
                activeBar
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Skills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text("\(store.activeIDs.count) active")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Active bar

    private var activeBar: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(activeLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
    }

    private var activeLabel: String {
        let names = MiraSkillCatalog.all.filter { store.isActive($0.id) }.map(\.name)
        if names.count <= 2 { return names.joined(separator: " · ") + " enabled" }
        return "\(names.prefix(2).joined(separator: " · ")) +\(names.count - 2) more"
    }
}

// MARK: - Skill card

private struct SkillCard: View {
    let skill:    MiraSkill
    let isActive: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: skill.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isActive ? miraTeale : .secondary)
                        .frame(width: 20)
                    Spacer()
                    // Toggle indicator
                    Circle()
                        .fill(isActive ? miraTeale : Color.white.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
                Text(skill.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                Text(skill.tagline)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                        ? miraTeale.opacity(0.12)
                        : Color.white.opacity(isHovered ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isActive ? miraTeale.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { isHovered = h } }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
    }
}

// MARK: - Sidecar banner (shown inside the island, above nav)

struct SidecarSuggestionBanner: View {
    @ObservedObject private var sidecar = SidecarSuggestionService.shared

    var body: some View {
        if let s = sidecar.active {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text(s.headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Button("Enable") {
                    withAnimation(.easeOut(duration: 0.18)) { sidecar.accept() }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(miraTeale)
                .buttonStyle(.plain)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { sidecar.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.yellow.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
