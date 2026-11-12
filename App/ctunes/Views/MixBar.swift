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
    /// The pinned mix opened from its card, whose picks Update replaces.
    var editing: SavedMix.ID?
    /// The picks sheet is up.
    var reviewing = false
    /// A play from the bar or a Recent card on its way: the style, or
    /// the card's key.
    private(set) var loadingStyle: PlayStyle?
    private(set) var loadingKey: String?
    /// The mix started from here and the queue entry it started on, so
    /// its card reads Playing for as long as that queue lasts.
    private var started: (key: String, entry: PlayQueue<PlexTrack>.Entry.ID)?

    var isBarShown: Bool { building && !picks.isEmpty }

    func contains(_ id: String) -> Bool { picks.contains { $0.id == id } }

    func toggle(_ pick: MixPick) {
        withAnimation(.snappy) {
            if let index = picks.firstIndex(of: pick) {
                picks.remove(at: index)
            } else {
                picks.append(pick)
            }
        }
        if picks.isEmpty { reviewing = false }
    }

    func clear() {
        withAnimation(.snappy) { picks = [] }
        editing = nil
        reviewing = false
    }

    func isPlaying(_ key: String, player: AudioPlayer) -> Bool {
        guard let started, started.key == key, !player.hasEnded else { return false }
        return player.queue.index(of: started.entry) != nil
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
        guard await actions.play(mix, presenting: false) else { return false }
        if let entry = actions.player.queue.entries.first?.id {
            started = (RecentMix.key(for: picks), entry)
        }
        return true
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
        guard let key = model.storageKey("mixPicks"),
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

    var body: some View {
        let picks = draft.picks
        VStack(spacing: 10) {
            Button { draft.reviewing = true } label: {
                HStack(spacing: 12) {
                    PickStack(model: model, picks: picks, size: 36)
                    if !compact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(MixDraft.count(picks)).font(.footnote.weight(.semibold))
                            Text(picks.map(\.title).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review \(MixDraft.count(picks))")
            if !compact {
                MixPlayButtons(styles: PlayStyle.cases(for: picks), loading: draft.loadingStyle, height: 44) { style in
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
                .disabled(loading != nil)
            }
        }
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
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.parchmentTop, lineWidth: 1.5))
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MixDraft.count(picks)).font(.title2.bold())
                    Text(summary.map { "\(PlexPlaylist.trackCount($0.count)) · \(PlexPlaylist.length(milliseconds: $0.milliseconds))" } ?? " ")
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
            VStack(spacing: 10) {
                if let editing = draft.editing.flatMap({ model.shortcut($0) }), editing.pickKey != key {
                    Button {
                        let styles = PlayStyle.cases(for: picks)
                        model.updateShortcut(editing.id) {
                            $0.picks = picks
                            if !styles.contains($0.style) { $0.style = styles[0] }
                        }
                    } label: {
                        Label("Update \(editing.name)", systemImage: "pin")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentText)
                }
                MixPlayButtons(styles: PlayStyle.cases(for: picks), loading: draft.loadingStyle, height: 52) { style in
                    draft.play(style, actions: actions)
                }
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
        let plays = model.recentMix(for: picks)?.playCount ?? 0
        let times = "\(plays) time\(plays == 1 ? "" : "s")"
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

// MARK: - Recent

/// One card in Quick Mix's Recent row: a mix played on this device, or
/// one pinned to the Music screen, which carries its name and a pin.
struct RecentMixItem: Identifiable {
    let picks: [MixPick]
    let style: PlayStyle
    let pinned: SavedMix?
    let recent: RecentMix?

    var id: String { RecentMix.key(for: picks) }
    var name: String { pinned?.name ?? SavedMix.suggestedName(for: picks) }

    /// The recents in their order, each pinned one under its pin, then the
    /// pinned mixes this device hasn't played.
    @MainActor static func all(_ model: AppModel) -> [RecentMixItem] {
        let recents = RecentMixes.ranked(model.recentMixes, at: .now).map { recent in
            let pinned = model.pinnedMix(for: recent.picks)
            return RecentMixItem(picks: recent.picks, style: pinned?.style ?? recent.style, pinned: pinned, recent: recent)
        }
        let played = Set(recents.map(\.id))
        let unplayed = model.shortcuts.filter { !played.contains($0.pickKey) }.map {
            RecentMixItem(picks: $0.picks, style: $0.style, pinned: $0, recent: nil)
        }
        return recents + unplayed
    }
}

struct RecentMixCard: View {
    let model: AppModel
    let item: RecentMixItem
    let playing: Bool
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(item.picks.prefix(3), id: \.id) { pick in
                    PickArt(model: model, pick: pick, size: 44)
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
                    Text(playing ? "Playing · \(item.style.verb)" : item.style.verb)
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
