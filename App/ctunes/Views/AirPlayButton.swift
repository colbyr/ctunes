import AVKit
import SwiftUI

/// The system AirPlay picker: tapping it opens the route sheet, and the
/// glyph takes the accent while audio is going somewhere other than the
/// phone. SwiftUI has no equivalent, so this wraps `AVRoutePickerView`.
/// The picker draws its glyph at one fixed size, a touch under the heart's
/// `.title2`, so it is scaled up inside a container that owns the frame.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> Container { Container() }
    func updateUIView(_ view: Container, context: Context) {}

    final class Container: UIView {
        private let picker = AVRoutePickerView()

        init() {
            super.init(frame: .zero)
            picker.prioritizesVideoDevices = false
            picker.tintColor = .secondaryLabel
            picker.activeTintColor = UIColor(Color.accentText)
            addSubview(picker)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            picker.transform = .identity
            picker.bounds = bounds
            picker.center = CGPoint(x: bounds.midX, y: bounds.midY)
            picker.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        }
    }
}

/// AirPlay as a symbol button, for a vertical toolbar strip, which stacks
/// symbol items but leaves a custom view (the picker itself) in a
/// horizontal bar of its own at the top. AVKit has no call that opens the
/// route sheet, so a picker sits hidden in the screen (`HiddenRoutePicker`,
/// in the content rather than the item, which the strip re-hosts), and
/// the button sends a tap to the picker's own button.
struct AirPlayStripButton: View {
    let picker: RoutePickerHandle
    /// Audio is going somewhere other than the phone: the picker's own
    /// glyph takes the accent then, and so does this one.
    @State private var routedAway = Self.isRoutedAway

    var body: some View {
        Button("AirPlay", systemImage: "airplay.audio") { picker.present() }
            .tint(routedAway ? Color.accentText : nil)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                Task { @MainActor in routedAway = Self.isRoutedAway }
            }
    }

    private static var isRoutedAway: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay || $0.portType == .bluetoothA2DP || $0.portType == .HDMI
        }
    }
}

@MainActor
final class RoutePickerHandle {
    weak var picker: AVRoutePickerView?

    func present() {
        guard let picker, let button = Self.button(in: picker) else { return }
        // The picker is a button underneath; a tap on it opens the sheet.
        button.sendActions(for: .touchUpInside)
    }

    private static func button(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let button = button(in: subview) { return button }
        }
        return nil
    }
}

/// The picker the strip's AirPlay button taps, out of sight.
struct HiddenRoutePicker: UIViewRepresentable {
    let handle: RoutePickerHandle

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        handle.picker = picker
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) { handle.picker = picker }
}

/// AirPlay as a strip item of its own while the window's bars are
/// vertical (an iPhone Duo closed, or open in landscape). Declared first
/// in a page's toolbar it stacks right under back; last, under the rest.
/// The spacer splits it from its neighbour's glass, which works only
/// within one `.toolbar`, so the page puts it in its own rather than in
/// a modifier's. The page hosts the picker (`hostsRoutePicker`).
struct StripAirPlayItem: ToolbarContent {
    let picker: RoutePickerHandle
    let shown: Bool
    /// Before the page's other items, so the spacer comes after it.
    var leading = true

    var body: some ToolbarContent {
        if shown {
            if !leading { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) {
                AirPlayStripButton(picker: picker)
            }
            if leading { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
        }
    }
}

extension View {
    /// The hidden picker a strip's AirPlay item taps, in the content
    /// rather than the item, which the strip re-hosts.
    func hostsRoutePicker(_ picker: RoutePickerHandle, when shown: Bool) -> some View {
        background {
            if shown {
                HiddenRoutePicker(handle: picker)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
        }
    }

    /// AirPlay as a strip item after the page's other items, from a
    /// toolbar of its own: under back on Mix, which has nothing else.
    func stripAirPlay() -> some View { modifier(StripAirPlay()) }
}

private struct StripAirPlay: ViewModifier {
    @Environment(LibraryNavigator.self) private var navigator
    @State private var picker = RoutePickerHandle()

    func body(content: Content) -> some View {
        content
            .hostsRoutePicker(picker, when: navigator.hasVerticalBar)
            .toolbar { StripAirPlayItem(picker: picker, shown: navigator.hasVerticalBar, leading: false) }
    }
}
