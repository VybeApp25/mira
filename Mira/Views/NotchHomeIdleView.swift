import SwiftUI
import EventKit

// MARK: - NotchHomeTabView
//
// The Home tab — BoringNotch-parity idle panel: media player (left, big art +
// blur glow + marquee text + seekable slider + shuffle/prev/play/next/repeat)
// and a scrollable calendar strip (right). This is the notch's default landing
// tab; the conversational UI lives in the separate Chat tab (IslandChatView).

struct NotchHomeTabView: View {
    @ObservedObject private var np  = NowPlayingService.shared
    @ObservedObject private var cal = CalendarTodayService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NotchMediaPanel(np: np)
                .frame(maxWidth: .infinity, alignment: .leading)
            NotchCalendarPanel(cal: cal)
                .frame(width: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .padding(.horizontal, 4)
        .onAppear {
            np.start()
            cal.requestAccess()
        }
    }
}

// MARK: - Marquee text (scrolls long titles that don't fit their frame)

private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let width: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        let overflow = textWidth > width + 1

        Text(text)
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { textWidth = geo.size.width }
                }
            )
            .offset(x: (overflow && animate) ? -(textWidth - width) : 0)
            .animation(
                overflow
                    ? .linear(duration: Double(textWidth) / 24).repeatForever(autoreverses: true).delay(1.2)
                    : .default,
                value: animate
            )
            .frame(width: width, alignment: .leading)
            .clipped()
            .onAppear { animate = overflow }
            .onChange(of: text) { _, _ in
                animate = false
                textWidth = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if textWidth > width { animate = true }
                }
            }
    }
}

// MARK: - Media panel

private struct NotchMediaPanel: View {
    @ObservedObject var np: NowPlayingService
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    private let tickTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            albumArt
            if np.info.hasContent {
                VStack(alignment: .leading, spacing: 4) {
                    songInfo
                    slider
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    Text("Nothing Playing").font(.system(size: 12)).foregroundColor(.white.opacity(0.30))
                    Spacer(minLength: 0)
                }
                .frame(height: 84)
            }
        }
        .onReceive(tickTimer) { _ in
            if !dragging { sliderValue = np.info.currentPosition }
        }
        .onChange(of: np.info.title) { _, _ in
            if !dragging { sliderValue = np.info.currentPosition }
        }
    }

    // MARK: Album art + ambient glow

    private var albumArt: some View {
        ZStack {
            if let art = np.info.artwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .blur(radius: 26)
                    .opacity(np.info.isPlaying ? 0.55 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .allowsHitTesting(false)
            }
            Group {
                if let art = np.info.artwork {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(.white.opacity(0.2)))
                }
            }
            // BoringNotch parity: MusicPlayerImageSizes.size.opened = 90x90, cornerRadiusInset.opened = 13.
            // Trimmed slightly (80 vs 90) to leave room for the slider + control row underneath
            // within Mira's compact Home-tab panel height.
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .scaleEffect(np.info.isPlaying ? 1.0 : 0.88)
            .opacity(np.info.isPlaying ? 1.0 : 0.6)
        }
        .frame(width: 84, height: 84)
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: np.info.isPlaying)
    }

    // MARK: Title / artist

    private var songInfo: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: np.info.title.isEmpty ? " " : np.info.title,
                            font: .system(size: 13, weight: .semibold), color: .white, width: geo.size.width)
                MarqueeText(text: np.info.artist, font: .system(size: 11), color: .white.opacity(0.5), width: geo.size.width)
            }
        }
        .frame(height: 32)
    }

    // MARK: Seekable slider

    private var slider: some View {
        VStack(spacing: 1) {
            GeometryReader { geo in
                let w = geo.size.width
                let duration = max(np.info.duration, 1)
                let progress = min(max(sliderValue / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: dragging ? 5 : 3)
                    Capsule().fill(Color.white.opacity(0.75)).frame(width: w * progress, height: dragging ? 5 : 3)
                }
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let ratio = min(max(g.location.x / w, 0), 1)
                            sliderValue = ratio * duration
                        }
                        .onEnded { _ in
                            np.seek(to: sliderValue)
                            dragging = false
                        }
                )
            }
            .frame(height: 10)

            HStack {
                Text(timeString(sliderValue)).font(.system(size: 8)).foregroundColor(.white.opacity(0.35))
                Spacer()
                Text(timeString(np.info.duration)).font(.system(size: 8)).foregroundColor(.white.opacity(0.35))
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Controls (shuffle · prev · play/pause · next · repeat)

    private var controls: some View {
        HStack(spacing: 8) {
            ctrlBtn("shuffle", size: 10, tint: np.info.isShuffled ? .accentColor : .white.opacity(0.65)) {
                np.toggleShuffle()
            }
            ctrlBtn("backward.fill", size: 11) { np.previousTrack() }
            ctrlBtn(np.info.isPlaying ? "pause.fill" : "play.fill", size: 13, prominent: true) { np.togglePlayPause() }
            ctrlBtn("forward.fill", size: 11) { np.nextTrack() }
            ctrlBtn("repeat", size: 10, tint: np.info.isRepeating ? .accentColor : .white.opacity(0.65)) {
                np.toggleRepeat()
            }
        }
    }

    private func ctrlBtn(_ icon: String, size: CGFloat, tint: Color = .white.opacity(0.75),
                          prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: prominent ? 24 : 20, height: 20)
                .background(prominent ? Color.white.opacity(0.10) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar panel

private struct NotchCalendarPanel: View {
    @ObservedObject var cal: CalendarTodayService
    @State private var scrollPos: Date?
    private let accent = DS.Colors.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            dateStrip
            Divider().background(Color.white.opacity(0.08))
            eventsSection
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(cal.selectedDate.formatted(.dateTime.month(.abbreviated)))
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            Text(cal.selectedDate.formatted(.dateTime.year()))
                .font(.system(size: 11, weight: .regular)).foregroundColor(.white.opacity(0.4))
        }
    }

    private var dateStrip: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 2) {
                        ForEach(cal.scrollDates, id: \.self) { day in
                            dayCell(day).id(day)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollPos, anchor: .center)
                .frame(height: 40)
                .mask(
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                )
            }
            .onAppear { scrollPos = Calendar.current.startOfDay(for: Date()) }
            .onChange(of: scrollPos) { _, new in
                guard let new, !Calendar.current.isDate(new, inSameDayAs: cal.selectedDate) else { return }
                cal.selectedDate = new
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: cal.selectedDate)
        let isToday    = calendar.isDateInToday(day)
        return Button {
            withAnimation { cal.selectedDate = day }
        } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(isToday ? 0.85 : 0.55))
                    .frame(width: 20, height: 20)
                    .background(isSelected ? accent : Color.clear)
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .frame(width: 24)
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !cal.permitted && cal.checked {
            Text("Enable calendar in System Settings")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        } else if cal.eventsForSelectedDate.isEmpty && cal.checked {
            VStack(spacing: 3) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.25))
                Text(Calendar.current.isDateInToday(cal.selectedDate) ? "No events today" : "No events")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                Text("Enjoy your free time!")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cal.eventsForSelectedDate.prefix(4), id: \.eventIdentifier) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.calendar.cgColor.map { Color($0) } ?? accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(event.isAllDay ? "All day" : event.startDate.formatted(.dateTime.hour().minute()))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
        }
    }
}
