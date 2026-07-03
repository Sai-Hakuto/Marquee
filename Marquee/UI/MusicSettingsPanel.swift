import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Panel Manager

@MainActor
final class MusicSettingsPanel {
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    func open(player: MusicPlayerController) {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = ""
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.backgroundColor = NSColor(red: 0.07, green: 0.04, blue: 0.14, alpha: 1.0)
        p.isOpaque = true
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.transient, .ignoresCycle]

        let rootView = MusicSettingsContent(player: player)
            .preferredColorScheme(.dark)
        p.contentView = NSHostingView(rootView: rootView)

        let mainWindows = NSApp.windows.filter { $0 !== p && $0.isVisible && !($0 is NSPanel) }
        if let mainWin = mainWindows.first {
            let mf = mainWin.frame
            let pf = p.frame
            p.setFrameOrigin(NSPoint(x: mf.midX - pf.width / 2, y: mf.midY - pf.height / 2))
        } else {
            p.center()
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel = nil
                self?.closeObserver = nil
            }
        }

        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        panel?.close()
        panel = nil
    }
}

// MARK: - Content View

struct MusicSettingsContent: View {
    let player: MusicPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.76, green: 0.46, blue: 1.0))
                Text("Music Settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)

            Text("Set each track's chance of playing in shuffle. \"Off\" tracks never auto-advance to.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(player.trackNames.indices, id: \.self) { i in
                        TrackWeightRow(index: i, player: player)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 24)

            // Footer
            HStack {
                Button { importTracks() } label: {
                    Label("Import Song…", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Shuffle picks by weight when a track ends")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .foregroundStyle(.white)
        .frame(width: 500)
    }

    private func importTracks() {
        let op = NSOpenPanel()
        op.allowsMultipleSelection = true
        op.canChooseFiles = true
        op.canChooseDirectories = false
        op.allowedContentTypes = [.audio]
        op.title = "Import Song Files"
        op.prompt = "Import"
        op.begin { [player] response in
            guard response == .OK else { return }
            for url in op.urls {
                player.importTrack(url: url)
            }
        }
    }
}

// MARK: - Per-Track Shuffle Weight Row (slider, 0–100%)

struct TrackWeightRow: View {
    let index: Int
    let player: MusicPlayerController

    @State private var sliderValue: Double

    init(index: Int, player: MusicPlayerController) {
        self.index  = index
        self.player = player
        _sliderValue = State(initialValue: Double(player.trackWeights[safe: index] ?? 50))
    }

    var body: some View {
        let name    = player.trackNames[safe: index] ?? "Song \(index + 1)"
        let playing = player.currentTrackIndex == index && player.isPlaying
        let pct     = Int(sliderValue)

        HStack(spacing: 8) {
            Group {
                if playing {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.76, green: 0.46, blue: 1.0))
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
            .frame(width: 18, alignment: .center)

            Button { player.playTrack(at: index) } label: {
                Text(name)
                    .font(.system(size: 13, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? .white : .white.opacity(0.72))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 60, maxWidth: 160, alignment: .leading)

            Slider(value: $sliderValue, in: 0...100, step: 1)
                .onChange(of: sliderValue) { _, v in
                    player.setWeight(Int(v), for: index)
                }

            Text(pct == 0 ? "Off" : "\(pct)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(pct == 0
                    ? Color(red: 0.75, green: 0.30, blue: 0.30)
                    : .white.opacity(0.55))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(playing ? Color.white.opacity(0.06) : Color.clear)
        )
        .onChange(of: player.trackWeights[safe: index] ?? 50) { _, w in
            if Int(sliderValue) != w { sliderValue = Double(w) }
        }
    }
}
