import AppIntents
import SwiftUI
import WidgetKit

/// One shortcut, the whole widget its play button, in the small family
/// and, on the lock screen, as a circle of the style glyph. Which one is
/// the widget's own setting (`SelectMixIntent`); unset it is the first
/// card on the Music screen, Shuffle Favorites on a fresh install.
struct ShortcutWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetFeed.Kind.shortcut, intent: SelectMixIntent.self, provider: ShortcutProvider()) { entry in
            ShortcutView(entry: entry)
        }
        .configurationDisplayName("Shortcut")
        .description("Plays one of the shortcuts on the Music screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct ShortcutEntry: TimelineEntry {
    let date: Date
    /// Nil when the shortcut the widget was set up on has been removed.
    let card: WidgetFeed.Card?
    /// True for the gallery and a widget with no feed yet, where the
    /// placeholder stands in.
    let sample: Bool
}

struct ShortcutProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShortcutEntry {
        ShortcutEntry(date: .now, card: .placeholder, sample: true)
    }

    func snapshot(for configuration: SelectMixIntent, in context: Context) async -> ShortcutEntry {
        entry(for: configuration)
    }

    /// One entry that never expires: the app reloads the timelines when
    /// the cards change, so the refresh budget goes unspent.
    func timeline(for configuration: SelectMixIntent, in context: Context) async -> Timeline<ShortcutEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectMixIntent) -> ShortcutEntry {
        guard let feed = WidgetFeed.read(), !feed.cards.isEmpty else {
            return ShortcutEntry(date: .now, card: .placeholder, sample: true)
        }
        guard let chosen = configuration.mix else {
            return ShortcutEntry(date: .now, card: feed.cards[0], sample: false)
        }
        return ShortcutEntry(date: .now, card: feed.cards.first { $0.id == chosen.id }, sample: false)
    }
}

struct ShortcutView: View {
    let entry: ShortcutEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let card = entry.card {
            switch family {
            case .accessoryCircular:
                Button(intent: PlayMixIntent(mix: MixEntity(card))) {
                    Image(systemName: card.symbol)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetAccentable()
            default:
                Button(intent: PlayMixIntent(mix: MixEntity(card))) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            CardArt(card: card, size: 56)
                            Spacer()
                            Image(systemName: card.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(card.accentColor)
                        }
                        Spacer(minLength: 8)
                        Text(card.title)
                            .font(.headline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if let subtitle = card.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .containerBackground(for: .widget) { WidgetGround(tint: card.tint) }
                .redacted(reason: entry.sample ? .placeholder : [])
            }
        } else {
            ContentUnavailableView("Shortcut removed", systemImage: "bookmark.slash")
                .foregroundStyle(Color.ink)
                .containerBackground(for: .widget) { WidgetGround(tint: nil) }
        }
    }
}
