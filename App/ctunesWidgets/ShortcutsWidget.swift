import AppIntents
import SwiftUI
import WidgetKit

/// The shortcut cards as the Music screen shows them, two in the medium
/// family and up to five in the large, each row's body the play button
/// and its chevron a link that opens the mix in the app.
struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFeed.Kind.shortcuts, provider: ShortcutsProvider()) { entry in
            ShortcutsView(entry: entry)
        }
        .configurationDisplayName("Shortcuts")
        .description("The shortcuts on the Music screen, each a play button.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ShortcutsEntry: TimelineEntry {
    let date: Date
    let cards: [WidgetFeed.Card]
    let sample: Bool
}

struct ShortcutsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutsEntry {
        ShortcutsEntry(date: .now, cards: Self.samples, sample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ShortcutsEntry) -> Void) {
        completion(Self.entry())
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ShortcutsEntry>) -> Void) {
        completion(Timeline(entries: [Self.entry()], policy: .never))
    }

    private static func entry() -> ShortcutsEntry {
        guard let feed = WidgetFeed.read(), !feed.cards.isEmpty else {
            return ShortcutsEntry(date: .now, cards: samples, sample: true)
        }
        return ShortcutsEntry(date: .now, cards: feed.cards, sample: false)
    }

    private static let samples: [WidgetFeed.Card] = [
        .placeholder,
        WidgetFeed.Card(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                        title: "Mix Albums Road Trip", subtitle: "3 artists", art: .mix,
                        thumb: nil, tint: nil, symbol: "square.stack", accent: .mix),
    ]
}

struct ShortcutsView: View {
    let entry: ShortcutsEntry
    @Environment(\.widgetFamily) private var family

    private var shown: [WidgetFeed.Card] {
        Array(entry.cards.prefix(family == .systemLarge ? 5 : 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(shown) { card in
                CardRow(card: card)
                if card.id != shown.last?.id {
                    Rectangle().fill(Color.divider).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color.ink)
        .containerBackground(for: .widget) { WidgetGround(tint: nil) }
        .redacted(reason: entry.sample ? .placeholder : [])
    }
}

/// The card as a row: art, title, the line under it, the style glyph,
/// then the chevron past a hairline, as on the Music screen.
private struct CardRow: View {
    let card: WidgetFeed.Card

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: PlayMixIntent(mix: MixEntity(card))) {
                HStack(spacing: 12) {
                    CardArt(card: card, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.headline).lineLimit(1)
                        if let subtitle = card.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: card.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(card.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Link(destination: card.openURL) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
