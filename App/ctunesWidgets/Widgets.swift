import SwiftUI
import WidgetKit

/// The home screen widgets: one shortcut as a button, and the row of
/// them. Everything drawn comes from the feed the app writes into the App
/// Group (`WidgetFeed`); a tap on a card is `PlayMixIntent`, performed in
/// the app's process without opening it. The plan is `notes/widgets.md`.
@main
struct CtunesWidgets: WidgetBundle {
    var body: some Widget {
        ShortcutWidget()
        ShortcutsWidget()
    }
}
