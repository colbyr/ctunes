import PlexKit
import SwiftUI

/// Who's in the car. The owner is always in; each listener toggles. With
/// nobody else on the roster a plus chip opens the Listeners sheet, so the
/// row never reads as empty. An optional accessory sits pinned at the
/// trailing edge, outside the scroll.
struct ListenerChips<Trailing: View>: View {
    let model: AppModel
    /// Every artist in the library, for the Listeners sheet's veto lists.
    let artists: [AlbumGroup]
    @ViewBuilder let trailing: Trailing
    @State private var showingListeners = false

    private var pinned: Bool { Trailing.self != EmptyView.self }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(active: true) {
                        OwnerAvatar()
                        Text("You")
                    }
                    ForEach(model.roster.listeners) { listener in
                        let active = model.roster.isActive(listener.id)
                        Button {
                            withAnimation(.snappy) { model.toggleListening(listener.id) }
                        } label: {
                            FilterChip(active: active) {
                                ListenerAvatar(listener: listener).opacity(active ? 1 : 0.45)
                                Text(listener.name)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(active ? "\(listener.name) is listening" : "\(listener.name) is not listening")
                    }
                    if model.roster.listeners.isEmpty {
                        Button {
                            showingListeners = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                                .background(.fill.tertiary, in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add listener")
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Chips would otherwise slide under the pinned accessory.
            .scrollClipDisabled(!pinned)
            .contentMargins(.leading, 16, for: .scrollContent)
            .contentMargins(.trailing, pinned ? 0 : 16, for: .scrollContent)
            if pinned {
                trailing.padding(.trailing, 16)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingListeners) {
            ListenersSheet(model: model, artists: artists)
        }
    }
}

extension ListenerChips where Trailing == EmptyView {
    init(model: AppModel, artists: [AlbumGroup]) {
        self.init(model: model, artists: artists) { EmptyView() }
    }
}

/// A capsule pill: filled while active, quiet otherwise.
struct FilterChip<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? AnyShapeStyle(Color.pillInk) : AnyShapeStyle(.secondary))
            .padding(.leading, 5)
            .padding(.trailing, 15)
            .frame(height: 34)
            .background(active ? AnyShapeStyle(Color.pill) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
    }
}
