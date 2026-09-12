import SwiftUI
import AppKit

private struct IPAGroup: Identifiable {
    let id: String // normalized bundle identifier
    let variants: [IPAEntry]
}

struct IPAStoreView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [IPAEntry] = []
    @State private var failures: [String] = []
    @State private var selectedID: String?
    @State private var search = ""
    @State private var section = "All"
    @State private var source = "All sources"
    @State private var genre = "All categories"
    @State private var loading = false
    @State private var downloading = false
    @State private var message: String?
    @State private var selectedVariantID: String?
    @State private var selectedVersionID: String?

    private let accent = Color(red: 0.72, green: 0.48, blue: 1.0)
    private let columns = [GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 16)]
    private let sections = ["All", "Games", "Apps", "Mods", "Unsorted"]

    private var groups: [IPAGroup] {
        Dictionary(grouping: entries, by: { $0.bundleID.lowercased() })
            .map { key, variants in
                IPAGroup(id: key, variants: variants.sorted {
                    let left = rank($0.category), right = rank($1.category)
                    return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
                })
            }
            .sorted { $0.variants[0].name.localizedStandardCompare($1.variants[0].name) == .orderedAscending }
    }

    private func rank(_ category: String) -> Int {
        switch category {
        case "Games": return 0
        case "Apps": return 1
        case "Unsorted": return 2
        default: return 3
        }
    }

    private func matchingVariants(in group: IPAGroup) -> [IPAEntry] {
        group.variants.filter { item in
            (section == "All" || item.category == section) &&
            (source == "All sources" || item.source == source) &&
            (genre == "All categories" || categories(for: item).contains(genre)) &&
            (search.isEmpty || ([item.name, item.bundleID, item.developer, item.genre] + item.gameGenres)
                .contains { $0.localizedStandardContains(search) })
        }
    }

    private func categories(for item: IPAEntry) -> [String] {
        item.category == "Games" ? (item.gameGenres.isEmpty ? ["Uncategorized"] : item.gameGenres) : [item.genre]
    }

    private var visible: [IPAGroup] { groups.filter { !matchingVariants(in: $0).isEmpty } }

    private func count(in option: String) -> Int {
        groups.filter { group in
            group.variants.contains { item in
                (option == "All" || item.category == option) &&
                (source == "All sources" || item.source == source)
            }
        }.count
    }

    private var genres: [String] {
        let options = entries.filter { item in
            (section == "All" || item.category == section) &&
            (source == "All sources" || item.source == source)
        }.flatMap { categories(for: $0) }
        return Array(Set(options)).sorted()
    }

    private var selectedGroup: IPAGroup? { groups.first { $0.id == selectedID } }
    private var selected: IPAEntry? {
        guard let group = selectedGroup else { return nil }
        return group.variants.first { $0.id == selectedVariantID } ?? matchingVariants(in: group).first ?? group.variants.first
    }
    private var selectedVersion: IPAVersion? {
        selected?.versions.first { $0.id == selectedVersionID } ?? selected?.latest
    }
    private var savedFile: URL? {
        guard let selected, let selectedVersion else { return nil }
        return IPADownload.savedURL(selected, version: selectedVersion,
                                    allowLegacy: selectedGroup?.variants.count == 1)
    }
    private var installedInPlayCover: Bool {
        guard let selected else { return false }
        return appState.games.contains { game in
            if case .playCover(let bundleID, _) = game.source {
                return bundleID.localizedCaseInsensitiveCompare(selected.bundleID) == .orderedSame
            }
            return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(.white.opacity(0.1))
                if loading && entries.isEmpty {
                    ProgressView("Loading IPA libraries…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    ContentUnavailableView("No IPAs found", systemImage: "magnifyingglass",
                                           description: Text(entries.isEmpty ? "The libraries could not be loaded." : "Try another search or filter."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(visible) { group in
                                card(group)
                            }
                        }
                        .padding(24)
                    }
                }
                if let failure = failures.first {
                    Text("Some sources failed: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            details
                .frame(width: 345)
        }
        .background(Color(red: 0.075, green: 0.065, blue: 0.12))
        .preferredColorScheme(.dark)
        .task { if entries.isEmpty { await refresh() } }
        .onChange(of: selectedVariantID) { _, _ in
            selectedVersionID = selected?.latest?.id
            message = nil
        }
        .onChange(of: source) { _, _ in
            genre = "All categories"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("IPA Store", systemImage: "square.grid.2x2.fill")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.bottom, 18)
            Text("BROWSE")
                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.45))
            ForEach(sections, id: \.self) { option in
                Button {
                    section = option
                    genre = "All categories"
                } label: {
                    HStack {
                        Image(systemName: icon(for: option)).frame(width: 20)
                        Text(option == "Unsorted" ? "CyPwn unsorted" : option)
                        Spacer()
                        if !entries.isEmpty {
                            Text("\(count(in: option))")
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(section == option ? accent.opacity(0.22) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 8)
            Text("SOURCE")
                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.45))
            Picker("Source", selection: $source) {
                Text("All sources").tag("All sources")
                Text("iPASTORE").tag("iPASTORE")
                Text("CyPwn").tag("CyPwn")
            }
            .labelsHidden()
            Spacer()
            Text("Third-party IPAs may be modified or incompatible with PlayCover.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 205)
        .background(Color(red: 0.095, green: 0.075, blue: 0.15))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Search titles, developers, or IDs", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Picker("Category", selection: $genre) {
                Text("All categories").tag("All categories")
                ForEach(genres, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 190)
            Spacer()
            Text("\(visible.count) titles")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh IPA catalogs")
            .disabled(loading)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func card(_ group: IPAGroup) -> some View {
        let item = matchingVariants(in: group).first ?? group.variants[0]
        return Button {
            selectedID = group.id
            selectedVariantID = item.id
            selectedVersionID = item.latest?.id
            message = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                iconImage(item.iconURL, size: 148)
                    .frame(maxWidth: .infinity)
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)
                Text(group.variants.count > 1 ? "\(group.variants.count) variants" : item.source + " · " + item.category)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == group.id ? accent.opacity(0.2) : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selectedID == group.id ? accent.opacity(0.75) : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var details: some View {
        if let item = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        iconImage(item.iconURL, size: 88)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).font(.title3.bold())
                            Text(item.developer).font(.caption).foregroundStyle(.white.opacity(0.6))
                            Text(item.source + " · " + (item.category == "Games" ? categories(for: item).joined(separator: ", ") : item.genre))
                                .font(.caption2).foregroundStyle(accent)
                        }
                    }
                    if !item.screenshots.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(item.screenshots.prefix(6), id: \.self) { url in
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: { Color.white.opacity(0.06) }
                                    .frame(height: 145)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    if !item.summary.isEmpty {
                        Text(cleanDescription(item.summary))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    if let group = selectedGroup, group.variants.count > 1 {
                        Text("Source / variant").font(.caption.bold())
                        Picker("Source / variant", selection: $selectedVariantID) {
                            ForEach(group.variants) { variant in
                                Text("\(variant.name) · \(variant.source) · \(variant.category)")
                                    .tag(Optional(variant.id))
                            }
                        }
                        .labelsHidden()
                    }
                    Text("Version").font(.caption.bold())
                    Picker("Version", selection: $selectedVersionID) {
                        ForEach(item.versions) { version in
                            Text(version.version + (version.date.isEmpty ? "" : " · " + String(version.date.prefix(10))))
                                .tag(Optional(version.id))
                        }
                    }
                    .labelsHidden()
                    if let version = selectedVersion {
                        if let size = version.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        if installedInPlayCover {
                            Label("Installed in PlayCover", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Open PlayCover to uninstall") { openPlayCover() }
                                .frame(maxWidth: .infinity)
                        } else if let savedFile {
                            Button {
                                Task { await installSaved(savedFile) }
                            } label: {
                                Label("Install saved IPA", systemImage: "arrow.down.app.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .disabled(downloading)
                        } else {
                            Button {
                                Task { await download(item, version: version, install: true) }
                            } label: {
                                Label(downloading ? "Downloading…" : "Download & Install", systemImage: "arrow.down.app.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .disabled(downloading)
                        }
                        if savedFile == nil {
                            Button("Download IPA only") {
                                Task { await download(item, version: version, install: false) }
                            }
                            .disabled(downloading)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if downloading { ProgressView().frame(maxWidth: .infinity) }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let savedFile {
                        Button("Show IPA in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) }
                            .font(.caption)
                        Button("Move downloaded IPA to Trash") {
                            do {
                                try IPADownload.moveToTrash(savedFile)
                                message = "Downloaded IPA moved to Trash. This does not uninstall the game."
                            } catch { message = error.localizedDescription }
                        }
                        .font(.caption)
                        .disabled(downloading)
                    }
                    Text(item.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.35))
                        .textSelection(.enabled)
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 35)).foregroundStyle(accent.opacity(0.6))
                Text("Select an app or game").foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func iconImage(_ url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "app.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }

    private func icon(for option: String) -> String {
        switch option {
        case "Games": return "gamecontroller.fill"
        case "Apps": return "app.fill"
        case "Mods": return "wand.and.stars"
        case "Unsorted": return "tray.full.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    private func cleanDescription(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func refresh() async {
        loading = true
        let result = await IPACatalog.load()
        let cached = IPAAppleGenres.cached()
        entries = IPAAppleGenres.apply(cached, to: result.entries)
        failures = result.failures
        loading = false
        await appState.loadAllGames()
        let resolved = await IPAAppleGenres.resolve(for: result.entries, startingWith: cached)
        entries = IPAAppleGenres.apply(resolved, to: result.entries)
    }

    @MainActor
    private func download(_ item: IPAEntry, version: IPAVersion, install: Bool) async {
        guard !downloading else { return }
        downloading = true
        message = nil
        defer { downloading = false }
        do {
            let url = try await IPADownload.save(item, version: version)
            if install {
                await sendToPlayCover(url)
            } else {
                message = "IPA saved."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func installSaved(_ url: URL) async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        await sendToPlayCover(url)
    }

    @MainActor
    private func sendToPlayCover(_ url: URL) async {
        do {
            try await IPADownload.installInPlayCover(url)
            message = "IPA sent to PlayCover. Finish the import there."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await appState.loadAllGames()
        } catch { message = error.localizedDescription }
    }

    private func openPlayCover() {
        do { try IPADownload.openPlayCover() }
        catch { message = error.localizedDescription }
    }
}
