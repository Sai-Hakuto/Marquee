import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Panel Manager
// Opens Fix Cover as a floating NSPanel (its own key window) so AppKit's
// first-responder chain is completely separate from the SceneKit view.
// No hacks needed — TextField in a key window just works.

@MainActor
final class FixCoverPanel {
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    func open(game: Game, appState: AppState, mode: FixCoverContent.FixMode = .cover) {
        close()

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 596),
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

        let rootView = FixCoverContent(game: game, mode: mode)
            .environment(appState)
            .preferredColorScheme(.dark)
        p.contentView = NSHostingView(rootView: rootView)

        // Center over the main window. Filtering on level == .normal (not just "not an
        // NSPanel") matters: AppKit's own transient windows for tooltips/menus (seen in the
        // wild as a private "SPRoundedWindow" class) are regular NSWindow subclasses, not
        // NSPanel, but sit at an elevated window level — without this filter one of those,
        // if still around from a hover a moment earlier, can outrank the real main window in
        // NSApp.windows and get centered/reclaimed against instead (see FixCoverPanel.close()).
        let windows = NSApp.windows.filter { $0 !== p && $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
        if let mainWin = windows.first {
            let mf = mainWin.frame
            let pf = p.frame
            p.setFrameOrigin(NSPoint(x: mf.midX - pf.width / 2, y: mf.midY - pf.height / 2))
        } else {
            p.center()
        }

        // willCloseNotification handles the close button AND programmatic close
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                switch mode {
                case .cover:  appState.fixCoverTarget = nil
                case .banner: appState.fixBannerTarget = nil
                }
                self?.panel = nil
                self?.closeObserver = nil
            }
        }

        // Bring the app forward AND make the panel key, or the floating panel can open behind
        // the main window / not take focus until manually clicked.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        panel?.close()
        panel = nil
        // Closing the panel doesn't reliably hand real key-window/first-responder status
        // back to the main window — AppKit can leave the main window "key" but with no
        // well-defined first responder, which silently breaks the search field's SwiftUI
        // @FocusState from ever reacquiring real focus on a later click (the click sets
        // the Bool, but nothing actually calls makeFirstResponder on the field's editor).
        // Explicitly reclaiming key status + resetting first responder to the window
        // itself gives SwiftUI's focus system a clean slate to claim from next time.
        // Deferred a tick: reclaiming key status in the SAME callout as panel.close() (itself
        // still inside the click that dismissed the panel) races the window server's own
        // teardown of the closing panel's key status — the reclaim can silently lose. Letting
        // the current run loop turn over first means the panel is fully gone before we ask.
        DispatchQueue.main.async {
            // level == .normal excludes transient AppKit windows (tooltips, menus — see the
            // matching comment in open() above) that can otherwise outrank the real main
            // window in NSApp.windows and silently steal this reclaim.
            if let mainWin = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }) {
                // makeKeyAndOrderFront alone is not enough here: closing the panel can leave
                // NSApp itself (not just the window) without a clear "active app" claim, and a
                // background app's window can never truly become key no matter how many times
                // its own makeKeyAndOrderFront is called. Mirrors the activate() call open()
                // already does before making the panel itself key.
                NSApp.activate(ignoringOtherApps: true)
                mainWin.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Content View

struct FixCoverContent: View {
    @Environment(AppState.self) private var appState
    let game: Game

    // Cover = portrait poster (library_600x900). Banner = landscape header (header.jpg),
    // used by the List view. Both share this panel; the mode steers the title, the art
    // shape searched/previewed, the web query, and which refetch path submit uses.
    enum FixMode {
        case cover, banner
        var isBanner: Bool { self == .banner }
        var heading: String { self == .cover ? "FIX COVER ART" : "FIX BANNER ART" }
        var doneText: String { self == .cover ? "Cover art updated." : "Banner art updated." }
        var webSuffix: String { self == .cover ? "game cover art" : "game banner hero art" }
    }
    var mode: FixMode = .cover

    @State private var searchTerm   = ""
    @State private var steamAppId   = ""
    @State private var status: Status = .idle
    @State private var liveResults: [SearchResult] = []
    @State private var selectedResult: SearchResult? = nil
    @State private var isLiveSearching = false
    @State private var liveSearchTask: Task<Void, Never>? = nil
    @State private var searchSource: SearchSource = .steam
    @State private var uploadedFileURL: URL? = nil

    // Mouse-wheel scrolling through the results row (v0.20.2) — a plain mouse only ever sends
    // vertical (dy) deltas, and `ScrollView(.horizontal)` never reacts to those on its own
    // (only two-finger trackpad swipe / shift+wheel naturally pan it), so mouse users had no way
    // to browse past the first handful of cards. Mirrors DetailView's media-rail scroll monitor:
    // step one card per wheel notch, scroll it into view via ScrollViewReader.
    @State private var resultsScrollProxy: ScrollViewProxy?
    @State private var resultsScrollMonitor: Any?
    @State private var resultsScrollIndex = 0

    @FocusState private var searchFocused: Bool
    @FocusState private var steamIdFocused: Bool

    enum Status { case idle, fetching, done, failed }
    enum SearchSource: CaseIterable {
        case steam, web, upload
        var label: String {
            switch self {
            case .steam:  "Steam"
            case .web:    "Web"
            case .upload: "My File"
            }
        }
    }

    struct SearchResult: Identifiable, Equatable {
        let id: UUID
        let name: String
        let artURL: URL?
        let steamAppId: Int?

        static func steam(appId: Int, name: String, landscape: Bool = false) -> SearchResult {
            // Banner mode previews/uses the horizontal header.jpg; cover mode the 600×900 poster.
            let file = landscape ? "header.jpg" : "library_600x900.jpg"
            return SearchResult(id: UUID(), name: name,
                artURL: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/\(file)"),
                steamAppId: appId)
        }
        static func web(name: String, imageURL: URL) -> SearchResult {
            SearchResult(id: UUID(), name: name, artURL: imageURL, steamAppId: nil)
        }
        static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
    }

    private var resolvedSteamId: Int? {
        let t = steamAppId.trimmingCharacters(in: .whitespaces)
        if let id = Int(t) { return id }
        let withScheme = t.hasPrefix("http") ? t : "https://\(t)"
        if let url = URL(string: withScheme) {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0] == "app", let id = Int(parts[1]) { return id }
        }
        return nil
    }

    private var canSubmit: Bool {
        if searchSource == .upload { return uploadedFileURL != nil }
        return selectedResult != nil
            || !searchTerm.trimmingCharacters(in: .whitespaces).isEmpty
            || resolvedSteamId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Game identity ────────────────────────────────────────────
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.heading)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                        .tracking(2.5)
                    Text(game.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(game.sourceBadgeTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(
                        red: game.sourceBadgeColor.r,
                        green: game.sourceBadgeColor.g,
                        blue: game.sourceBadgeColor.b
                    ).opacity(0.85)))
                    .padding(.top, 4)
            }

            Divider().overlay(Color.white.opacity(0.12))

            // ── Search source picker ─────────────────────────────────────
            HStack {
                Picker("", selection: $searchSource) {
                    ForEach(SearchSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: searchSource) { _, _ in
                    selectedResult = nil
                    liveResults = []
                    triggerLiveSearch(for: searchTerm)
                }
                Spacer()
                if searchSource == .web {
                    Text("DuckDuckGo image search")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }

            if searchSource == .upload {
                uploadPicker
            } else {

            // ── Search field ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.40))
                        .font(.system(size: 13))
                    TextField("Search…", text: $searchTerm)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .onSubmit { submit() }
                        .onChange(of: searchTerm) { _, new in triggerLiveSearch(for: new) }
                    if isLiveSearching {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else if !searchTerm.isEmpty {
                        Button {
                            searchTerm = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.30))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            searchFocused ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                )

                if !liveResults.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(liveResults) { result in
                                    SearchResultCard(result: result, landscape: mode.isBanner,
                                                     isSelected: selectedResult?.id == result.id) {
                                        selectedResult = result
                                        if let appId = result.steamAppId { steamAppId = String(appId) }
                                    }
                                    .id(result.id)
                                }
                            }
                            .padding(.vertical, 3).padding(.horizontal, 2)
                        }
                        .onAppear {
                            resultsScrollProxy = proxy
                            resultsScrollIndex = 0
                        }
                    }
                    .frame(height: 120)
                    .onChange(of: liveResults) { _, _ in resultsScrollIndex = 0 }
                } else if !isLiveSearching && searchTerm.count >= 2 {
                    Text(searchSource == .steam ? "No Steam results — try Web search." : "No results found.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 2)
                }
            }

            }

            // ── Steam App ID field ───────────────────────────────────────
            if searchSource == .steam {
                HStack {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    Text("or paste Steam ID / URL").font(.system(size: 11)).foregroundStyle(.white.opacity(0.30))
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Steam App ID or store page URL", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))

                    TextField("413150  or  store.steampowered.com/app/413150", text: $steamAppId)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .focused($steamIdFocused)
                        .onSubmit { submit() }
                        .onChange(of: steamAppId) { _, new in
                            if let sel = selectedResult, new != String(sel.steamAppId ?? -1) {
                                selectedResult = nil
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    steamIdFocused ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                                .allowsHitTesting(false)
                        )

                    if let id = resolvedSteamId {
                        Text("App ID \(id) ✓")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.75))
                    }
                }
            }

            // ── Status ────────────────────────────────────────────────────
            if status == .fetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else if status == .done {
                Label(mode.doneText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.5))
            } else if status == .failed {
                Label("No art found — try a different search.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.2))
            }

            // ── Buttons ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(FixCoverButtonStyle(primary: false))
                Button(status == .fetching ? "Fetching…"
                                           : (mode.isBanner ? "Use This Banner" : "Use This Cover")) { submit() }
                    .buttonStyle(FixCoverButtonStyle(primary: true))
                    .disabled(status == .fetching || !canSubmit)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            let key = game.id.uuidString
            let ud = UserDefaults.standard
            let searchKey = mode.isBanner ? "bannerSearch_\(key)"  : "coverSearch_\(key)"
            let idKey     = mode.isBanner ? "bannerSteamId_\(key)" : "coverSteamId_\(key)"
            searchTerm = game.title
            if let saved = ud.string(forKey: searchKey), !saved.isEmpty { searchTerm = saved }
            let existingId = ud.integer(forKey: idKey)
            if existingId > 0 { steamAppId = String(existingId) }
            triggerLiveSearch(for: searchTerm)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            installResultsScrollMonitor()
        }
        .onDisappear {
            if let monitor = resultsScrollMonitor { NSEvent.removeMonitor(monitor) }
            resultsScrollMonitor = nil
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    // Real mouse wheels only ever send vertical (dy) deltas — a plain `ScrollView(.horizontal)`
    // never reacts to those (only two-finger trackpad swipe, which arrives as a precise dx delta
    // and already works natively). Left un-intercepted here, so trackpad users keep the native
    // feel; only non-precise (real mouse wheel) events get redirected into stepping the row.
    @MainActor
    private func installResultsScrollMonitor() {
        guard resultsScrollMonitor == nil else { return }
        resultsScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) >= 1.0,
                  !liveResults.isEmpty else { return event }
            let delta = event.scrollingDeltaY > 0 ? -1 : 1
            Task { @MainActor in self.stepResults(by: delta) }
            return nil
        }
    }

    @MainActor
    private func stepResults(by delta: Int) {
        guard let proxy = resultsScrollProxy, !liveResults.isEmpty else { return }
        resultsScrollIndex = max(0, min(liveResults.count - 1, resultsScrollIndex + delta))
        withAnimation { proxy.scrollTo(liveResults[resultsScrollIndex].id, anchor: .center) }
    }

    // MARK: - Upload your own file

    private var uploadPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let url = uploadedFileURL, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: mode.isBanner ? 118 : 56, height: mode.isBanner ? 55 : 84)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                        )
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button { pickFile() } label: {
                        Label(uploadedFileURL == nil ? "Choose Image…" : "Change Image…",
                              systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(FixCoverButtonStyle(primary: false))
                    if let url = uploadedFileURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    } else {
                        Text("Pick a \(mode.isBanner ? "landscape banner" : "portrait cover") image from your Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                }
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(mode.isBanner ? "Banner" : "Cover") Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            uploadedFileURL = url
        }
    }

    // MARK: - Live Search

    private func triggerLiveSearch(for term: String) {
        liveSearchTask?.cancel()
        guard searchSource != .upload else { liveResults = []; isLiveSearching = false; return }
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { liveResults = []; isLiveSearching = false; return }
        isLiveSearching = true
        let src = searchSource
        liveSearchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let results: [SearchResult] = switch src {
            case .steam:  await searchSteam(for: trimmed)
            case .web:    await searchWeb(for: trimmed)
            case .upload: []
            }
            guard !Task.isCancelled else { return }
            liveResults = results
            isLiveSearching = false
        }
    }

    private func searchSteam(for term: String) async -> [SearchResult] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=english&cc=US"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.prefix(8).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return .steam(appId: id, name: name, landscape: mode.isBanner)
        }
    }

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // DuckDuckGo's vqd token is tied to the EXACT query string, and the i.js
    // image endpoint now 403s without the Sec-Fetch / Accept-Language headers a
    // real browser sends. Both the vqd request and the i.js request must use the
    // identical query, or DDG rejects the token.
    private func searchWeb(for term: String) async -> [SearchResult] {
        let query = "\(term) \(mode.webSuffix)"
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }

        // 1) Fetch the results page to obtain a query-specific vqd token.
        guard let homeURL = URL(string: "https://duckduckgo.com/?q=\(q)&iax=images&ia=images") else { return [] }
        var homeReq = URLRequest(url: homeURL)
        homeReq.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        guard let (html, _) = try? await URLSession.shared.data(for: homeReq),
              let htmlStr = String(data: html, encoding: .utf8),
              let vqd = Self.extractVQD(from: htmlStr) else { return [] }

        // 2) Call i.js with the SAME query + token and the headers DDG requires.
        guard let imgURL = URL(string: "https://duckduckgo.com/i.js?l=us-en&o=json&q=\(q)&vqd=\(vqd)&p=1")
        else { return [] }
        var imgReq = URLRequest(url: imgURL)
        imgReq.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        imgReq.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        imgReq.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        imgReq.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        imgReq.setValue("empty",       forHTTPHeaderField: "Sec-Fetch-Dest")
        imgReq.setValue("cors",        forHTTPHeaderField: "Sec-Fetch-Mode")
        imgReq.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        guard let (imgData, _) = try? await URLSession.shared.data(for: imgReq),
              let json = try? JSONSerialization.jsonObject(with: imgData) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        // Banner mode wants horizontal art — float the widest (landscape) results to the front.
        let ordered = mode.isBanner
            ? results.sorted { Self.aspect($0) > Self.aspect($1) }
            : results
        return ordered.prefix(12).compactMap { r in
            guard let imageStr = r["image"] as? String,
                  let imageURL = URL(string: imageStr),
                  let title    = r["title"] as? String else { return nil }
            return .web(name: title, imageURL: imageURL)
        }
    }

    // width/height ratio from a DDG image result (>1 = landscape). DDG sends these as Ints.
    private static func aspect(_ r: [String: Any]) -> Double {
        let w = (r["width"] as? Double) ?? Double((r["width"] as? Int) ?? 0)
        let h = (r["height"] as? Double) ?? Double((r["height"] as? Int) ?? 0)
        return h > 0 ? w / h : 0
    }

    // Extracts the vqd token from DDG HTML — handles both vqd="…" and vqd='…'.
    static func extractVQD(from html: String) -> String? {
        for delimiter in ["vqd=\"" as String, "vqd='"] {
            guard let r = html.range(of: delimiter) else { continue }
            let closing = delimiter.hasSuffix("\"") ? "\"" : "'"
            let rest = html[r.upperBound...]
            if let e = rest.range(of: closing) {
                let v = String(rest[..<e.lowerBound])
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - Submit

    private func submit() {
        guard status != .fetching else { return }
        status = .fetching
        if searchSource == .upload, let fileURL = uploadedFileURL {
            switch mode {
            case .cover:  appState.applyCustomCover(for: game, fileURL: fileURL, completion: finish)
            case .banner: appState.applyCustomBanner(for: game, fileURL: fileURL, completion: finish)
            }
            return
        }
        // Route to the cover or banner refetch path based on the panel's mode.
        func apply(searchTerm: String? = nil, steamAppId: Int? = nil, directURL: URL? = nil) {
            switch mode {
            case .cover:
                appState.refetchCover(for: game, searchTerm: searchTerm,
                                      steamAppId: steamAppId, directURL: directURL, completion: finish)
            case .banner:
                appState.refetchBanner(for: game, searchTerm: searchTerm,
                                       steamAppId: steamAppId, directURL: directURL, completion: finish)
            }
        }
        if let result = selectedResult {
            if let appId = result.steamAppId {
                apply(steamAppId: appId)
            } else if let artURL = result.artURL {
                apply(directURL: artURL)
            }
        } else if let appId = resolvedSteamId {
            apply(steamAppId: appId)
        } else {
            let term = searchTerm.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { status = .idle; return }
            apply(searchTerm: term)
        }
    }

    private func finish(_ success: Bool) {
        status = success ? .done : .failed
        guard success else { return }
        let gameId = game.id
        // Cover fixes re-center the carousel on the fixed game; banner fixes don't move it.
        if mode == .cover, let idx = appState.filteredGames.firstIndex(where: { $0.id == gameId }) {
            appState.selectedIndex = idx
        }
        // Guard the auto-close: only close if this panel is still the active one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            switch mode {
            case .cover:  if appState.fixCoverTarget?.id  == gameId { appState.fixCoverTarget  = nil }
            case .banner: if appState.fixBannerTarget?.id == gameId { appState.fixBannerTarget = nil }
            }
        }
    }

    // Close the panel by clearing whichever target opened it.
    private func dismiss() {
        switch mode {
        case .cover:  appState.fixCoverTarget = nil
        case .banner: appState.fixBannerTarget = nil
        }
    }
}

// MARK: - Search Result Card

struct SearchResultCard: View {
    let result: FixCoverContent.SearchResult
    var landscape: Bool = false   // banner previews use a wide thumbnail
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var coverImage: NSImage? = nil
    @State private var loading = true

    // Landscape ≈ Steam header 460×215 ratio; portrait = 2:3 cover.
    private var thumbW: CGFloat { landscape ? 118 : 56 }
    private var thumbH: CGFloat { landscape ? 55 : 84 }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                    if let img = coverImage {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else if loading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: thumbW, height: thumbH)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.white.opacity(0.15),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .animation(.spring(duration: 0.15), value: isSelected)

                Text(result.name)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: thumbW + 4)
            }
        }
        .buttonStyle(.plain)
        .task { await loadCover() }
    }

    private func loadCover() async {
        guard let url = result.artURL else { loading = false; return }
        var req = URLRequest(url: url)
        req.setValue(FixCoverContent.browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let img = NSImage(data: data) else { loading = false; return }
        coverImage = img
        loading = false
    }
}

// MARK: - Button Style

struct FixCoverButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? .black : .white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(primary ? Color.white : Color.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
