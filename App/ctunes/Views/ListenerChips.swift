import PlexKit
import SwiftUI

/// Who's in the car. Every listener toggles. With one listener or none a
/// plus chip opens the Listeners sheet, so the row never reads as just one
/// chip. A screen that filters to downloads leads the row with that
/// toggle, a chip like the listeners' since it narrows the page the same
/// way. An optional accessory sits pinned at the trailing edge, outside
/// the scroll.
struct ListenerChips<Trailing: View>: View {
    let model: AppModel
    /// Every artist in the library, for the Listeners sheet's veto lists.
    let artists: [AlbumGroup]
    /// The Downloaded filter, on the screens that have one.
    var downloadedOnly: Binding<Bool>? = nil
    @ViewBuilder let trailing: Trailing
    @State private var sheet: ListenersSheetTarget?

    private var pinned: Bool { Trailing.self != EmptyView.self }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let downloadedOnly {
                        Button {
                            withAnimation(.snappy) { downloadedOnly.wrappedValue.toggle() }
                        } label: {
                            IconChip(active: downloadedOnly.wrappedValue, systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Downloaded only")
                        .accessibilityAddTraits(downloadedOnly.wrappedValue ? .isSelected : [])
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
                        .contextMenu { ListenerChipMenu(model: model, listener: listener) { sheet = $0 } }
                    }
                    if model.roster.listeners.count <= 1 {
                        Button {
                            sheet = .list
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
        .sheet(item: $sheet) { target in
            ListenersSheet(model: model, artists: artists, opening: target.listener)
        }
    }
}

/// The listener chips on their own, for the Music screen's top bar: they
/// decide the mixes row as well as the grid, so they sit over both.
struct ListenerBarChips: View {
    let model: AppModel
    let artists: [AlbumGroup]
    /// The Downloaded filter, at the head as in the inline row.
    var downloadedOnly: Binding<Bool>? = nil
    @State private var sheet: ListenersSheetTarget?

    var body: some View {
        HStack(spacing: 6) {
            if let downloadedOnly {
                Button {
                    withAnimation(.snappy) { downloadedOnly.wrappedValue.toggle() }
                } label: {
                    IconChip(active: downloadedOnly.wrappedValue, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Downloaded only")
                .accessibilityAddTraits(downloadedOnly.wrappedValue ? .isSelected : [])
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
                .contextMenu { ListenerChipMenu(model: model, listener: listener) { sheet = $0 } }
            }
            if model.roster.listeners.count <= 1 {
                Button { sheet = .list } label: {
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
        // The bar would squeeze the names out of the chips.
        .fixedSize()
        .sheet(item: $sheet) { target in
            ListenersSheet(model: model, artists: artists, opening: target.listener)
        }
    }
}

/// Which page of the Listeners sheet a chip opens.
enum ListenersSheetTarget: Identifiable {
    case list
    case listener(Listener.ID)

    var id: String {
        switch self {
        case .list: "list"
        case .listener(let id): id.uuidString
        }
    }

    var listener: Listener.ID? {
        if case .listener(let id) = self { return id }
        return nil
    }
}

/// A listener chip's long press: just them, everyone, their page, or the
/// whole list (where one is added).
struct ListenerChipMenu: View {
    let model: AppModel
    let listener: Listener
    let open: (ListenersSheetTarget) -> Void

    var body: some View {
        let roster = model.roster
        Section {
            if roster.listeners.count > 1, roster.activeIDs != [listener.id] {
                Button("Only \(listener.name)", systemImage: "person") {
                    withAnimation(.snappy) { model.listenAlone(listener.id) }
                }
            }
            if roster.listeners.count > 1, roster.active.count < roster.listeners.count {
                Button("Everyone", systemImage: "person.3") {
                    withAnimation(.snappy) { model.listenAll() }
                }
            }
        }
        Section {
            Button("Edit \(listener.name)…", systemImage: "pencil") { open(.listener(listener.id)) }
            Button("Manage Listeners…", systemImage: "person.2") { open(.list) }
        }
    }
}

extension ListenerChips where Trailing == EmptyView {
    init(model: AppModel, artists: [AlbumGroup], downloadedOnly: Binding<Bool>? = nil) {
        self.init(model: model, artists: artists, downloadedOnly: downloadedOnly) { EmptyView() }
    }
}

/// A round chip holding one glyph: the listener pill's colors while
/// active, the quiet fill of the plus and arrange chips otherwise.
struct IconChip: View {
    let active: Bool
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(active ? AnyShapeStyle(Color.pillInk) : AnyShapeStyle(.secondary))
            .frame(width: 34, height: 34)
            .background(active ? AnyShapeStyle(Color.pill) : AnyShapeStyle(.fill.tertiary), in: .circle)
            .contentShape(.circle)
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
