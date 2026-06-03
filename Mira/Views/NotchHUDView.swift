import SwiftUI

private let hudBG    = Color(red: 0.06, green: 0.06, blue: 0.07)
private let surface  = Color(red: 0.11, green: 0.11, blue: 0.13)
private let accent   = Color(red: 0.29, green: 0.62, blue: 1.0)

struct NotchHUDView: View {
    @ObservedObject var hudState: NotchHUDState
    @ObservedObject var miraState: MiraState
    @ObservedObject var taskStore: AgentTaskStore
    @ObservedObject var overlay: OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice: VoiceService

    var body: some View {
        VStack(spacing: 0) {
            pill
            if hudState.isExpanded {
                dashboard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(hudBG)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 20,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hudState.isExpanded)
    }

    // MARK: - Pill (always visible)

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)

            Text("Mira")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            // Live listening dot
            if voice.isListening {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("Listening")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            // Agent task badge
            if !taskStore.tasks.isEmpty {
                Text("\(taskStore.tasks.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 36)
    }

    // MARK: - Dashboard (expanded)

    private var dashboard: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.07))
            tabBar
            Divider().background(Color.white.opacity(0.07))
            tabContent
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Home", icon: "house.fill", tab: .home)
            tabButton("Agents", icon: "cpu", tab: .agents)
            Spacer()
            settingsButton
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func tabButton(_ label: String, icon: String, tab: MiraTab) -> some View {
        Button(action: { hudState.selectedTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(hudState.selectedTab == tab ? accent : .white.opacity(0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                hudState.selectedTab == tab
                    ? accent.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button(action: { NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil) }) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.35))
                .padding(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch hudState.selectedTab {
        case .home:
            HomeTabView(miraState: miraState)
        case .agents:
            AgentsTabView(taskStore: taskStore, miraState: miraState, overlay: overlay, capture: capture, voice: voice)
        }
    }
}
