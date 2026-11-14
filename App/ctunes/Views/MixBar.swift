import PlexKit
import SwiftUI

/// What Quick Mix has picked, shared by the builder and the bottom bar,
/// where the picks show as the mix bar in the mini player's place. Lives
/// with the stack rather than the page, so the picks wait across visits.
@MainActor @Observable
final class MixDraft {
    /// Quick Mix is on screen.
    var building = false
    /// In the order they were tapped.
    var picks: [MixPick] = []
    /// The pinned mix whose picks are being edited: the builder is in its
    /// edit mode, and the picks made before it wait in `stashed`.
    private(set) var editing: SavedMix.ID?
    private var stashed: [MixPick] = []
    /// The pin's name and style as edited, saved with its picks.
    var editName = ""
    var editStyle: PlayStyle = .shuffle
    /// The picks sheet is up.
    var reviewing = false
    /// A mix the bar just started: the stack goes home and the Music
    /// screen brings its card into view, then clears this.
    var landed: String?
    /// The slots of the Music screen's row of mixes in the order they
    /// were first shown, kept until the next launch: see `MixesRow`.
    var rowOrder: [String] = []
    /// Each card's slot by its id. A card that changes id (a recent
    /// pinned, a pin removed) keeps its slot, and the slot is its
    /// identity on screen, so it is redrawn rather than replaced.
    var rowSlots: [String: String] = [:]
    /// What each slot plays, to match a card that changed id to it.
    var rowKeys: [String: String] = [:]
    /// A play from the bar or a Recent card on its way: the style, or
    /// the card's key.
    private(set) var loadingStyle: PlayStyle?
    private(set) var loadingKey: String?

    /// The bar stands in for the mini player for as long as the builder is
    /// up, empty or not.
    var isBarShown: Bool { building }

    func contains(_ id: String) -> Bool { picks.contains { $0.id == id } }

    func toggle(_ pick: MixPick) {
        withAnimation(.snappy) {
            if let index = picks.firstIndex(of: pick) {
                picks.remove(at: index)
            } else {
                picks.append(pick)
            }
        }
        // The editor's sheet stays: it holds the name and style too.
        if picks.isEmpty, editing == nil { reviewing = false }
    }

    func clear() {
        withAnimation(.snappy) { picks = [] }
        reviewing = false
    }

    /// Puts a pinned mix's picks in the bar, setting aside what was there,
    /// and opens the sheet that edits its name, style and picks together.
    func beginEditing(_ mix: SavedMix) {
        if editing == nil { stashed = picks }
        picks = mix.picks
        editName = mix.name
        editStyle = mix.style
        editing = mix.id
        reviewing = true
    }

    /// The edit differs from the pin and has something to play.
    func canSave(_ model: AppModel) -> Bool {
        guard let mix = editing.flatMap({ model.shortcut($0) }), !picks.isEmpty else { return false }
        return mix.pickKey != RecentMix.key(for: picks) || mix.style != editStyle
            || mix.name != editName.trimmingCharacters(in: .whitespaces)
    }

    /// The pin takes the edit (a style the picks still offer, a name or
    /// the suggested one), and the bar its picks from before.
    func saveEdit(_ model: AppModel) {
        guard let id = editing, let mix = model.shortcut(id), !picks.isEmpty else { return }
        let picks = picks
        model.moveRecentMix(mix.pickKey, to: picks)
        let styles = PlayStyle.cases(for: picks)
        let style = styles.contains(editStyle) ? editStyle : styles[0]
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? SavedMix.suggestedName(for: picks) : trimmed
        model.updateShortcut(id) {
            $0.picks = picks
            $0.style = style
            $0.name = name
        }
        endEditing()
    }

    /// Back to the picks from before, saved or not.
    func endEditing() {
        guard editing != nil else { return }
        picks = stashed
        stashed = []
        editing = nil
        reviewing = false
    }

    /// The picks in the bar: played without opening Now Playing, after
    /// which the bar gives way to the mini player and the picks clear.
    func play(_ style: PlayStyle, actions: LibraryActions) {
        guard loadingStyle == nil, loadingKey == nil else { return }
        let picks = picks
        loadingStyle = style
        Task {
            defer { loadingStyle = nil }
            guard await start(picks, style: style, actions: actions) else { return }
            clear()
            landed = RecentMix.key(for: picks)
        }
    }

    /// A Recent card: the same, but what is picked stays picked.
    func play(_ picks: [MixPick], style: PlayStyle, actions: LibraryActions) {
        guard loadingStyle == nil, loadingKey == nil else { return }
        let key = RecentMix.key(for: picks)
        loadingKey = key
        Task {
            defer { loadingKey = nil }
            await start(picks, style: style, actions: actions)
        }
    }

    @discardableResult
    private func start(_ picks: [MixPick], style: PlayStyle, actions: LibraryActions) async -> Bool {
        let mix = SavedMix(name: "", picks: picks, style: style)
        return await actions.play(mix, presenting: false)
    }

    /// "3 albums", "1 artist", "Favorites", "4 picks" for a mix of kinds.
    static func count(_ picks: [MixPick]) -> String {
        if picks == [.favorites] { return "Favorites" }
        let kinds = Set(picks.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return "\(picks.count) picks" }
        return "\(picks.count) \(kind.label.lowercased())\(picks.count == 1 ? "" : "s")"
    }

    /// Persisted per account and library as JSON, so the picks wait for
    /// the next launch in the library they were made in.
    static func saved(_ model: AppModel) -> [MixPick] {
        guard let key = model.storageKey("mixPicks"),
              let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MixPick].self, from: data)) ?? []
    }

    func save(_ model: AppModel) {
        guard editing == nil, let key = model.storageKey("mixPicks"),
              let data = try? JSONEncoder().encode(picks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - The bar

/// The picks in the mini player's place while Quick Mix is open: their
/// art and names, a tap away from the sheet that reviews them, over the
/// two ways to play them. While a search is open it shrinks to the art.
struct MixBar: View {
    let model: AppModel
    let compact: Bool
    @Environment(MixDraft.self) private var draft
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    /// What the pool lists, for the empty bar's hint.
    @AppStorage("mixSubject") private var subject: BrowseSubject = .albums

    private var noun: String {
        switch subject {
        case .albums: "albums"
        case .artists: "artists"
        case .playlists: "playlists"
        }
    }

    var body: some View {
        let picks = draft.picks
        let editing = draft.editing.flatMap { model.shortcut($0) }
        VStack(spacing: 10) {
            Button { draft.reviewing = !picks.isEmpty || editing != nil } label: {
                HStack(spacing: 12) {
                    if picks.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.secondary, style: .init(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 36, height: 36)
                            .overlay(Image(systemName: "plus").font(.footnote.weight(.semibold)).foregroundStyle(.secondary))
                    } else {
                        PickStack(model: model, picks: picks, size: 36)
                    }
                    if !compact, editing != nil {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(draft.editName.isEmpty ? SavedMix.suggestedName(for: picks) : draft.editName)
                                .font(.footnote.weight(.semibold))
                            Text(picks.isEmpty ? "Tap \(noun) to add them" : "\(draft.editStyle.verb) · \(MixDraft.count(picks))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if !compact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(picks.isEmpty ? "Nothing selected" : MixDraft.count(picks))
                                .font(.footnote.weight(.semibold))
                            Text(picks.isEmpty ? "Tap \(noun) to start a mix" : picks.map(\.title).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !picks.isEmpty {
                            Image(systemName: "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(picks.isEmpty ? "Nothing selected" : "Review \(MixDraft.count(picks))")
            // Editing a pin, Save is the action; the bar only shows it.
            if !compact, editing == nil {
                MixPlayButtons(styles: PlayStyle.cases(for: picks), loading: draft.loadingStyle, enabled: !picks.isEmpty, height: 44) { style in
                    draft.play(style, actions: LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator))
                }
                .transition(.opacity)
            }
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: compact ? nil : .infinity)
        .contentShape(.rect(cornerRadius: 26))
        // Tinted toward the page: bare glass over a grid of covers left
        // the tinted button and the names hard to read.
        .glassEffect(.regular.tint(Color.parchmentTop.opacity(0.75)).interactive(),
                     in: .rect(cornerRadius: compact ? 26 : 28))
    }
}

/// Play and Shuffle, or Mix Albums and Shuffle: the first a tinted
/// pill, the last, the usual choice, filled.
struct MixPlayButtons: View {
    let styles: [PlayStyle]
    let loading: PlayStyle?
    var enabled = true
    let height: CGFloat
    let action: (PlayStyle) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(styles) { style in
                let primary = style == styles.last
                Button { action(style) } label: {
                    HStack(spacing: 8) {
                        if loading == style {
                            ProgressView().tint(primary ? Color.pillInk : Color.mix)
                        } else {
                            Image(systemName: style.symbol)
                        }
                        Text(style.verb).lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primary ? Color.pillInk : Color.mix)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(primary ? AnyShapeStyle(Color.pill) : AnyShapeStyle(Color.mix.opacity(0.16)), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(loading != nil || !enabled)
            }
        }
        .opacity(enabled ? 1 : 0.5)
        .animation(.snappy, value: styles)
    }
}

/// The picks' art overlapped like a hand of cards, three at most.
struct PickStack: View {
    let model: AppModel
    let picks: [MixPick]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.55) {
            ForEach(Array(picks.suffix(3).enumerated()), id: \.element.id) { index, pick in
                PickArt(model: model, pick: pick, size: size)
                    .overlay(pick.artShape.stroke(Color.parchmentTop, lineWidth: 1.5))
                    .zIndex(Double(index))
            }
        }
    }
}

// MARK: - The sheet

/// The picks to review: how much music they come to, whether they are a
/// mix already pinned or played, each removable, and the two ways to
/// play. Opened on a pinned mix with different picks, it can update it.
struct MixReviewSheet: View {
    let model: AppModel
    @Environment(MixDraft.self) private var draft
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator
    /// What the playable tracks come to, once fetched.
    @State private var summary: (count: Int, milliseconds: Int)?

    private var actions: LibraryActions {
        LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
    }

    var body: some View {
        let picks = draft.picks
        let key = RecentMix.key(for: picks)
        let summaryLine = summary.map { "\(PlexPlaylist.trackCount($0.count)) · \(PlexPlaylist.length(milliseconds: $0.milliseconds))" } ?? " "
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MixDraft.count(picks)).font(.title2.bold())
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { draft.clear() }
                    .foregroundStyle(Color.accentText)
            }
            .padding(.init(top: 28, leading: 20, bottom: 12, trailing: 20))
            if let line = knownLine(picks) {
                line
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.fill.tertiary, in: .capsule)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            List {
                ForEach(picks, id: \.id) { pick in
                    HStack(spacing: 14) {
                        PickArt(model: model, pick: pick, size: 44)
                            .artworkShadow()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.title).lineLimit(1)
                            Text(caption(pick)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { draft.toggle(pick) } label: {
                            Image(systemName: "minus.circle").font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(pick.title)")
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    for pick in offsets.map({ picks[$0] }) { draft.toggle(pick) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            MixPlayButtons(styles: PlayStyle.cases(for: picks), loading: draft.loadingStyle, height: 52) { style in
                draft.play(style, actions: actions)
            }
            .padding(.init(top: 8, leading: 20, bottom: 12, trailing: 20))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Again once a server answers: before then only what is on disk
        // counts, and a saved copy landing can change the lists.
        .task(id: "\(key)|\(model.isConnected)|\(model.libraryRevision)") {
            summary = nil
            let tracks = actions.playable(await model.tracks(of: picks), within: nil)
            guard !Task.isCancelled else { return }
            summary = (tracks.count, tracks.reduce(0) { $0 + Int(($1.durationSeconds ?? 0) * 1000) })
        }
    }

    /// "Pinned as Sunday Laura · played 6 times", or "Played 3 times"
    /// for one only this device remembers.
    private func knownLine(_ picks: [MixPick]) -> Label<Text, Image>? {
        let plays = model.recentMix(for: picks)?.plays.count ?? 0
        // Only the last plays are kept, so the cap reads as "50+".
        let times = plays >= RecentMixes.playLimit ? "\(plays)+ times" : "\(plays) time\(plays == 1 ? "" : "s")"
        if let pinned = model.pinnedMix(for: picks) {
            let played = plays > 0 ? " · played \(times)" : ""
            return Label { Text("Pinned as **\(pinned.name)**\(played)") } icon: { Image(systemName: "pin") }
        }
        guard plays > 0 else { return nil }
        return Label { Text("Played \(times)") } icon: { Image(systemName: "clock.arrow.circlepath") }
    }

    private func caption(_ pick: MixPick) -> String {
        if case .album(_, _, _, let artist?, _) = pick, !artist.isEmpty { return artist }
        return pick.kind.label
    }
}

/// Editing a pin: the Pin Mix sheet's form over the bar's picks, which
/// can be removed here and added behind it.
struct MixEditSheet: View {
    let model: AppModel
    @Environment(MixDraft.self) private var draft

    var body: some View {
        @Bindable var draft = draft
        NavigationStack {
            MixForm(model: model, picks: draft.picks, name: $draft.editName, style: $draft.editStyle) { pick in
                draft.toggle(pick)
            }
            .navigationTitle("Edit Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { draft.endEditing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { draft.saveEdit(model) }
                        .disabled(!draft.canSave(model))
                        .tint(Color.mix)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Recent

/// One card in the Music screen's row of mixes: one pinned there, which
/// carries its name and a pin, or one played on this device.
struct RecentMixItem: Identifiable {
    let picks: [MixPick]
    let style: PlayStyle
    let pinned: SavedMix?
    let recent: RecentMix?

    /// Its place in the row: a pin by the pin, so editing its picks keeps
    /// it where it was; a recent by its picks.
    var id: String { pinned?.id.uuidString ?? key }
    /// What it plays, for whether it is playing.
    var key: String { RecentMix.key(for: picks) }
    var name: String { pinned?.name ?? SavedMix.suggestedName(for: picks) }

    /// The pinned mixes in their order, then the rest of the recents in
    /// theirs: the last played, then by frecency.
    @MainActor static func all(_ model: AppModel, pinned: [SavedMix]) -> [RecentMixItem] {
        let pins = pinned.map {
            RecentMixItem(picks: $0.picks, style: $0.style, pinned: $0, recent: model.recentMix(for: $0.picks))
        }
        let keys = Set(model.shortcuts.map(\.pickKey))
        let recents = RecentMixes.ranked(model.recentMixes, at: .now)
            .filter { !keys.contains($0.id) }
            .map { RecentMixItem(picks: $0.picks, style: $0.style, pinned: nil, recent: $0) }
        return pins + recents
    }
}

/// The row of mix cards on the Music screen. A tap plays the mix in its
/// style without opening Now Playing; a long press plays it another
/// way, opens it, edits a pinned one's picks, pins or unpins it.
struct MixesRow: View {
    let model: AppModel
    let items: [RecentMixItem]
    let margin: CGFloat
    /// Opens a single pick's own page.
    let open: (MixPick) -> Void
    @Environment(MixDraft.self) private var draft
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator
    /// A recent being pinned, or a pinned one being renamed.
    @State private var pinning: PinRequest?
    /// The row never re-sorts while the app runs: a card played would
    /// jump to the front, often out of view, and re-sorting on the way
    /// back to the screen jumped as badly. It keeps the order it was
    /// first shown in (`MixDraft.rowOrder`) until the next launch; a mix
    /// it hasn't shown before leads.
    private var shown: [(slot: String, item: RecentMixItem)] {
        let rank = Dictionary(draft.rowOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .map { (offset: $0.offset, slot: draft.rowSlots[$0.element.id] ?? $0.element.id, item: $0.element) }
            .sorted { (rank[$0.slot] ?? -1, $0.offset) < (rank[$1.slot] ?? -1, $1.offset) }
            .map { ($0.slot, $0.item) }
    }

    private struct PinRequest: Identifiable {
        let picks: [MixPick]
        let style: PlayStyle
        let editing: SavedMix.ID?
        var id: String { RecentMix.key(for: picks) }
    }

    private var actions: LibraryActions {
        LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
    }

    /// The Mixer button's id: the front of the row.
    private static let front = "mixer"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                // The way in to the mixer, now that the screen has no
                // tile for it: always first, there even with no mixes.
                // A plain button, not a card, so it doesn't read as a mix.
                Button { navigator.open(.mix(MixRoute())) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "square.stack")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.mix)
                            .frame(width: 52, height: 52)
                            .background(Color.mix.opacity(0.16), in: .circle)
                        Text("Mixer")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.mix)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the mixer")
                .id(Self.front)
                ForEach(shown, id: \.slot) { slot, item in
                    Button {
                        draft.play(item.picks, style: item.style, actions: actions)
                    } label: {
                        RecentMixCard(model: model, item: item,
                                      playing: model.isPlaying(mix: item.key, player: player),
                                      loading: draft.loadingKey == item.key)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(item) }
                    .id(slot)
                }
            }
            // The button as tall as the cards.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, margin)
            // Room for the cards' shadow; see `cardShadow`.
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, -14)
        .animation(.snappy, value: shown.map(\.slot))
        .onChange(of: items.map(\.id), initial: true) { settle() }
        // A mix played from the bar: once the stack is home, its card.
        .task(id: draft.landed) {
            guard let key = draft.landed else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if let card = shown.first(where: { $0.item.key == key }) {
                withAnimation(.snappy) { proxy.scrollTo(card.slot, anchor: .center) }
            }
            draft.landed = nil
        }
        }
        .sheet(item: $pinning) { request in
            SaveMixSheet(model: model, picks: request.picks, editing: request.editing, style: request.style)
        }
    }

    /// A push from a card's menu waits for the menu to finish closing:
    /// pushed at once, Quick Mix opened and the stack fell straight back
    /// to the Music screen.
    private func afterMenu(_ go: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            go()
        }
    }

    /// Keeps every card in its slot. A card that changed id while playing
    /// the same picks (a recent pinned, a pin removed) takes the slot of
    /// the one it was; only a mix the row has never shown is new, and
    /// leads.
    private func settle() {
        let first = draft.rowOrder.isEmpty && draft.rowSlots.isEmpty
        // The slots some card still holds.
        var held = Set(items.compactMap { draft.rowSlots[$0.id] })
        // New slots take the front, once, in the items' order, and keep
        // their place after that like any other.
        var fresh: [String] = []
        for item in items where draft.rowSlots[item.id] == nil {
            if !first, let slot = draft.rowOrder.first(where: { !held.contains($0) && draft.rowKeys[$0] == item.key }) {
                draft.rowSlots[item.id] = slot
                held.insert(slot)
            } else {
                draft.rowSlots[item.id] = item.id
                fresh.append(item.id)
            }
        }
        for item in items {
            if let slot = draft.rowSlots[item.id] { draft.rowKeys[slot] = item.key }
        }
        if !fresh.isEmpty { draft.rowOrder = fresh + draft.rowOrder }
    }

    @ViewBuilder private func menu(_ item: RecentMixItem) -> some View {
        Section {
            ForEach(PlayStyle.cases(for: item.picks)) { style in
                Button(style.verb, systemImage: style.symbol) {
                    draft.play(item.picks, style: style, actions: actions)
                }
            }
        }
        Section {
            if item.picks.count == 1 {
                Button("Go to \(item.picks[0].kind.label)", systemImage: "arrow.right") {
                    afterMenu { open(item.picks[0]) }
                }
            }
            Button("Open in Mixer", systemImage: "square.stack") {
                navigator.open(.mixer(item.picks))
            }
            if let pinned = item.pinned {
                Button("Edit Pinned Mix", systemImage: "pin") {
                    afterMenu { navigator.open(.mix(MixRoute(mixID: pinned.id))) }
                }
            } else {
                Button("Pin…", systemImage: "pin") {
                    pinning = PinRequest(picks: item.picks, style: item.style, editing: nil)
                }
            }
        }
        if let pinned = item.pinned {
            Button("Remove Pin", systemImage: "pin.slash", role: .destructive) {
                model.removeShortcut(pinned.id)
            }
        } else if let recent = item.recent {
            Button("Remove", systemImage: "xmark", role: .destructive) {
                model.forgetRecentMix(recent.id)
            }
        }
    }
}

struct RecentMixCard: View {
    let model: AppModel
    let item: RecentMixItem
    let playing: Bool
    let loading: Bool

    /// Three of the picks, a different three each launch and the same
    /// three while it runs: ordered by hash, whose seed Swift draws anew
    /// for every process.
    static func shown(_ picks: [MixPick]) -> [MixPick] {
        guard picks.count > 3 else { return picks }
        return Array(picks.sorted { $0.id.hashValue < $1.id.hashValue }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                let shown = Self.shown(item.picks)
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, pick in
                    PickArt(model: model, pick: pick, size: 44)
                        .overlay {
                            // The third stands for the rest too.
                            if index == 2, item.picks.count > 3 {
                                pick.artShape
                                    .fill(.black.opacity(0.45))
                                    .overlay(Text("+\(item.picks.count - 2)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white))
                            }
                        }
                        .artworkShadow()
                }
                if item.picks.isEmpty {
                    MixArt(model: model, picks: [], size: 44)
                }
            }
            .frame(height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.pinned != nil {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                HStack(spacing: 4) {
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: playing ? "waveform" : item.style.symbol)
                    }
                    Text(playing ? "Playing" : item.style.verb)
                }
                .font(.caption.weight(playing ? .semibold : .regular))
                .foregroundStyle(playing ? AnyShapeStyle(Color.mix) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 168, alignment: .leading)
        .glassCard(cornerRadius: 18)
        .overlay {
            if playing {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.mix, lineWidth: 2)
            }
        }
    }
}
