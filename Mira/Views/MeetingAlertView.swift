// MeetingAlertView.swift
// The meeting alert as it takes over the notch.
//
// Rendered INSTEAD of the selected module rather than over it, which is what
// MacNotch does (demo-03) and what makes it read as an interruption rather than
// a banner. The shell still owns the slab, so this draws only the contents.

import SwiftUI

struct MeetingAlertView: View {

    @ObservedObject var service: MeetingAlertService
    let alert: MeetingAlert

    @ObservedObject private var accentSvc = AccentColorService.shared
    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            details
            Spacer(minLength: 0)
            actions
        }
        .padding(.top, NotchModuleShellView.headerHeight + 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(alert.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if !alert.calendarName.isEmpty {
                Text(alert.calendarName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }

            Spacer(minLength: 0)
            counter
        }
    }

    /// Keeps counting after the meeting begins, which is the state you most
    /// need to see — "Started 3 min ago" is the thing that gets you to click.
    private var counter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delta = alert.start.timeIntervalSince(context.date)
            Text(Self.countdown(delta))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(delta <= 0 ? Color(red: 0.98, green: 0.62, blue: 0.35) : accent)
        }
    }

    static func countdown(_ delta: TimeInterval) -> String {
        let seconds = Int(abs(delta).rounded())
        let text: String
        if seconds < 60 {
            text = "\(seconds) sec"
        } else if seconds < 3600 {
            let m = seconds / 60, s = seconds % 60
            text = s == 0 ? "\(m) min" : "\(m) min \(s) sec"
        } else {
            text = "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        return delta > 0 ? "In \(text)" : "Started \(text) ago"
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("\(alert.timeRange) · \(alert.duration)", systemImage: "clock")
            if let location = alert.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
            }
            if let join = alert.join {
                // The destination host is shown, not just "Join". A meeting link
                // arrives inside an invite someone else wrote, and a button that
                // opens it without saying where is a button you press blind.
                Label(join.url.host ?? join.url.absoluteString, systemImage: "link")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.62))
        .labelStyle(.titleAndIcon)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if let join = alert.join {
                Button { service.join() } label: {
                    Text(join.buttonTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .help(join.url.absoluteString)
            }

            SecondaryButton(title: "Snooze \(Int(MeetingAlertService.snoozeDuration / 60))m") {
                service.snooze()
            }
            SecondaryButton(title: "Dismiss") { service.dismiss() }

            Spacer(minLength: 0)

            Button("Dismiss All") { service.dismissAll() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.40))
        }
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
