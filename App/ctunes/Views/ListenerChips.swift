import PlexKit
import SwiftUI

/// Who's in the car. The owner is always in; each listener toggles. An
/// optional accessory sits pinned at the trailing edge, outside the scroll.
struct ListenerChips<Trailing: View>: View {
    let model: AppModel
    @ViewBuilder let trailing: Trailing

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
    }
}

extension ListenerChips where Trailing == EmptyView {
    init(model: AppModel) {
        self.init(model: model) { EmptyView() }
    }
}

/// A capsule pill: filled while active, quiet otherwise.
struct FilterChip<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.secondary))
            .padding(.leading, 5)
            .padding(.trailing, 15)
            .frame(height: 34)
            .background(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
    }
}
