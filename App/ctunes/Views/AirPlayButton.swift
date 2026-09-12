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
