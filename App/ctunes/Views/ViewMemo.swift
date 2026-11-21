import Foundation

/// A view's derived lists, kept from one redraw to the next until what
/// they were made from changes. Held in `@State` and not observable:
/// filling it during a body is a cache write, never a change anything
/// redraws on.
///
/// The key must read every observable input the value is made from.
/// Observation registers only what a body touches, so on a hit, when
/// `make` doesn't run, reading the key is what keeps the view redrawing
/// when any of those inputs changes.
@MainActor
final class ViewMemo {
    private var entries: [String: (key: Any, value: Any)] = [:]

    func callAsFunction<Key: Equatable, Value>(_ slot: String, key: Key, _ make: () -> Value) -> Value {
        if let entry = entries[slot], let old = entry.key as? Key, old == key,
           let value = entry.value as? Value {
            return value
        }
        let value = make()
        entries[slot] = (key, value)
        return value
    }
}
