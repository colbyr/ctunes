import AppIntents
import Foundation

/// A shortcut from the Music screen as Siri, the Shortcuts app and a
/// widget's configuration see it. The ids are the saved mixes' own, so a
/// widget set up on "Shuffle Favorites" survives the app being reinstalled
/// and iCloud bringing the list back.
struct MixEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shortcut"
    static let defaultQuery = MixQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    init(_ card: WidgetFeed.Card) {
        self.init(id: card.id, title: card.title)
    }
}

/// The shortcuts, from the feed the app writes for the widgets: the one
/// list both processes can read. In the app the model's own list is
/// asked first, so a mix saved a moment ago resolves before the root has
/// written the feed again.
struct MixQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [MixEntity] {
        let all = await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [MixEntity] {
        await Self.all()
    }

    func defaultResult() async -> MixEntity? {
        await Self.all().first
    }

    static func all() async -> [MixEntity] {
        #if !WIDGET
        let saved = await MainActor.run {
            AppRuntime.shared.model.shortcuts.map { MixEntity(id: $0.id, title: $0.title) }
        }
        if !saved.isEmpty { return saved }
        #endif
        return (WidgetFeed.read()?.cards ?? []).map(MixEntity.init)
    }
}

/// Plays a shortcut the way its card on the Music screen does: fetched
/// fresh, every veto of the people listening applied, ordered by its
/// style. An `AudioPlaybackIntent`, so a widget's button runs it in the
/// app's process in the background and the phone stays where it is.
/// Compiled into the widget extension too, since `Button(intent:)` needs
/// the type there; the body only exists in the app, which is the one
/// process that ever performs it.
struct PlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Shortcut"
    static let description = IntentDescription("Plays one of the shortcuts on the Music screen.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$mix)") }

    @Parameter(title: "Shortcut")
    var mix: MixEntity

    init() {}

    init(mix: MixEntity) {
        self.mix = mix
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET
        // Never reached: the app performs every one. Here so the
        // extension's copy has a body to compile.
        return .result(dialog: "Open Tunes to play.")
        #else
        let playback = try await IntentPlayback.ready()
        let played = try await playback.play(mixID: mix.id)
        return .result(dialog: "\(played.title).")
        #endif
    }
}

/// The small widget's setting: which shortcut it is. None is the first
/// card on the Music screen.
struct SelectMixIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Shortcut"
    static let description = IntentDescription("Which shortcut the widget plays.")

    @Parameter(title: "Shortcut")
    var mix: MixEntity?
}
