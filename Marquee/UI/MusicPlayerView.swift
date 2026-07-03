import SwiftUI

// Shared geometry for the bottom-left music widget. Scrollable views (grid/wall/list) pad
// their content by this much so the last items clear the minimized widget — the cutoff line
// sits ~10px above the collapsed widget's top edge.
enum MusicWidget {
    static let collapsedClearance: CGFloat = 64
}

// MARK: - Music Player (bottom-left, frameless "widget" overlay)
//
// Minimalist white-on-theme layout — no card, no background, no border. Sits over whatever
// theme background the user has chosen, like a Rainmeter widget. Subtle drop shadows keep
// the white legible on light themes.
//
// focusedControlIdx map (expanded):
//   0=prev  1=play/pause  2=next  3=volume  4=repeat(sticky)  5=settings  6=minimize
// collapsed pill:  0=play  1=expand
struct MusicPlayerView: View {
    @Environment(MusicPlayerController.self) private var player

    var zoneFocused: Bool = false
    var focusedControlIdx: Int = 1
    var onSettingsOpen: () -> Void = {}

    // White-tone palette
    private let ink   = Color.white.opacity(0.95)
    private let ink2  = Color.white.opacity(0.55)
    private let ink3  = Color.white.opacity(0.30)
    private let faint = Color.white.opacity(0.16)

    private let widgetWidth: CGFloat = 360

    var body: some View {
        @Bindable var player = player
        Group {
            if player.isExpanded {
                expanded(player: player)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            } else {
                collapsed(player: player)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        // Soft shadow on the whole widget so the thin white strokes stay readable on any theme.
        .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 1)
        // Hovering the widget keeps it from auto-collapsing; leaving restarts the countdown.
        .onHover { inside in
            if inside { player.cancelAutoMinimize() } else { player.scheduleAutoMinimize() }
        }
    }

    // MARK: Expanded

    @ViewBuilder
    private func expanded(player: MusicPlayerController) -> some View {
        @Bindable var player = player
        VStack(alignment: .leading, spacing: 0) {

            // Header: NOW PLAYING + title  |  circle action buttons
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NOW PLAYING")
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(3)
                        .foregroundStyle(ink2)
                    Text(player.currentTrackName)
                        .font(.system(size: 27, weight: .thin))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    circleButton(system: "repeat", size: 24, iconSize: 10,
                                 active: player.isStickyEnabled, focused: idx(4)) {
                        withAnimation(.spring(response: 0.20, dampingFraction: 0.75)) { player.toggleSticky() }
                    }
                    circleButton(system: "gearshape", size: 24, iconSize: 10,
                                 focused: idx(5), action: onSettingsOpen)
                    circleButton(system: "minus", size: 24, iconSize: 10, focused: idx(6)) {
                        player.cancelAutoMinimize()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { player.isExpanded = false }
                    }
                }
                .padding(.top, 2)
            }

            // Waveform
            MinimalWaveform(magnitudes: player.barMagnitudes, isPlaying: player.isPlaying, color: ink)
                .frame(height: 38)
                .padding(.top, 10)

            // Baseline under the waveform
            Rectangle().fill(ink3).frame(height: 1).padding(.top, 2)

            // Time labels + scrubber (driven by a light timer so elapsed updates while playing).
            // Ticking at 3600s instead of 0.2s while the window isn't visible is a cheap way to
            // stop the updates without restructuring this into a conditional mount — nobody can
            // see a frozen scrubber they also can't see the window of.
            TimelineView(.periodic(from: .now, by: player.isWindowVisible ? 0.2 : 3600)) { _ in
                let dur = max(player.duration, 0.001)
                let frac = dragFraction ?? min(max(player.currentTime / dur, 0), 1)

                VStack(spacing: 6) {
                    HStack {
                        Text(Self.timeString(frac * player.duration))
                        Spacer()
                        Text(Self.timeString(player.duration))
                    }
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ink2)

                    Scrubber(fraction: frac, trackColor: faint, fillColor: ink, knobColor: ink) { f, committed in
                        if committed {
                            dragFraction = nil
                            player.seek(to: f * player.duration)
                        } else {
                            dragFraction = f
                        }
                    }
                    .frame(height: 12)
                }
                .padding(.top, 8)
            }

            // Transport + volume
            HStack(spacing: 0) {
                // Volume (idx 3)
                HStack(spacing: 7) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(ink2)
                    Scrubber(fraction: Double(player.volume), trackColor: faint, fillColor: ink2, knobColor: ink) { f, _ in
                        player.setVolume(Float(f))
                    }
                    .frame(width: 86, height: 12)
                }
                .padding(4)
                .overlay(focusRing(cornerRadius: 7, on: idx(3)))

                Spacer()

                // Transport
                HStack(spacing: 18) {
                    transportButton(system: "backward.end.fill", iconSize: 13, focused: idx(0)) {
                        player.previousTrack()
                    }
                    circleButton(system: player.isPlaying ? "pause.fill" : "play.fill",
                                 size: 38, iconSize: 14, lineWidth: 1.4, focused: idx(1)) {
                        player.toggle()
                    }
                    transportButton(system: "forward.end.fill", iconSize: 13, focused: idx(2)) {
                        player.nextTrack()
                    }
                }
            }
            .padding(.top, 12)
        }
        .frame(width: widgetWidth, alignment: .leading)
    }

    // MARK: Collapsed

    @ViewBuilder
    private func collapsed(player: MusicPlayerController) -> some View {
        @Bindable var player = player
        HStack(spacing: 10) {
            circleButton(system: player.isPlaying ? "pause.fill" : "play.fill",
                         size: 30, iconSize: 11, lineWidth: 1.3, focused: idx(0)) {
                player.toggle()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("NOW PLAYING")
                    .font(.system(size: 7, weight: .semibold))
                    .kerning(2)
                    .foregroundStyle(ink2)
                Text(player.currentTrackName)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            transportButton(system: "chevron.up", iconSize: 10, focused: idx(1)) {
                player.expand()
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    // MARK: - Components

    @State private var dragFraction: Double?

    private func idx(_ i: Int) -> Bool { zoneFocused && focusedControlIdx == i }

    // Outline circle button (used for the three header actions and the play/pause disc).
    private func circleButton(system: String, size: CGFloat, iconSize: CGFloat,
                              lineWidth: CGFloat = 1, active: Bool = false,
                              focused: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            player.noteInteraction()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(active ? Color(red: 0.78, green: 0.55, blue: 1.0) : ink)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(active ? Color(red: 0.78, green: 0.55, blue: 1.0).opacity(0.9) : ink2,
                                               lineWidth: lineWidth))
                .overlay(Circle().strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2).padding(-3))
                // Full circular hit area — the thin glyph alone was hard to click.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, brighten: 0.12)
    }

    // Bare icon button (no outline) for the skip controls.
    private func transportButton(system: String, iconSize: CGFloat,
                                 focused: Bool, action: @escaping () -> Void) -> some View {
        Button {
            player.noteInteraction()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2).padding(-2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.12, brighten: 0.12)
    }

    private func focusRing(cornerRadius: CGFloat, on focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 2)
            .padding(-2)
            // A stroke overlay sits on top of the volume Scrubber and otherwise swallows the
            // drag gesture — making the volume slider non-interactive with the mouse.
            .allowsHitTesting(false)
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Scrubber (thin draggable track with a knob)

private struct Scrubber: View {
    let fraction: Double
    let trackColor: Color
    let fillColor: Color
    let knobColor: Color
    // onChange(fraction, committed): committed=false during drag, true on release.
    let onChange: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knob: CGFloat = 9
            let usable = max(1, w - knob)
            let x = CGFloat(min(max(fraction, 0), 1)) * usable

            ZStack(alignment: .leading) {
                Capsule().fill(trackColor).frame(height: 2)
                Capsule().fill(fillColor).frame(width: x + knob / 2, height: 2)
                Circle().fill(knobColor)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in onChange(Double(min(max(g.location.x - knob / 2, 0), usable) / usable), false) }
                    .onEnded   { g in onChange(Double(min(max(g.location.x - knob / 2, 0), usable) / usable), true) }
            )
        }
    }
}

// MARK: - Minimal Waveform
//
// Renders many thin vertical bars by interpolating the 16 FFT magnitudes up to a denser bar
// count, for a fuller "spectrum" look. Bars are bottom-aligned and grow upward.
struct MinimalWaveform: View {
    let magnitudes: [Float]
    let isPlaying: Bool
    let color: Color

    private let barCount = 56
    private let barWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height
            HStack(alignment: .bottom, spacing: (geo.size.width - barWidth * CGFloat(barCount)) / CGFloat(barCount - 1)) {
                ForEach(0..<barCount, id: \.self) { i in
                    let mag = interpolated(at: i)
                    let h = max(1.5, CGFloat(mag) * maxH)
                    Capsule()
                        .fill(color.opacity(isPlaying ? 0.85 : 0.18))
                        .frame(width: barWidth, height: h)
                        .animation(.easeOut(duration: 0.08), value: mag)
                }
            }
            .frame(width: geo.size.width, height: maxH, alignment: .bottom)
        }
    }

    // Linearly interpolate the source magnitudes across the denser display bar count.
    private func interpolated(at display: Int) -> Float {
        let n = magnitudes.count
        guard n > 1 else { return magnitudes.first ?? 0 }
        let pos = Double(display) / Double(barCount - 1) * Double(n - 1)
        let lo  = Int(pos.rounded(.down))
        let hi  = min(lo + 1, n - 1)
        let f   = Float(pos - Double(lo))
        return magnitudes[lo] * (1 - f) + magnitudes[hi] * f
    }
}
