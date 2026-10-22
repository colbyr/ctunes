import SwiftUI

/// The spinner a page shows while its first read is still out, with a
/// word once the server has been slow to answer it, so a page opened on
/// a weak link says why it waits rather than spinning in silence. The
/// library decides "slow": a miss a screen is waiting on, past a few
/// seconds.
struct LoadingPlaceholder: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            if model.slowConnection {
                Text("Slow connection")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
