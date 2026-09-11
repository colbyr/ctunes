import CarPlay
import UIKit

/// The CarPlay scene. A second window scene beside the phone's, named in
/// `Info.plist` under `CPTemplateApplicationSceneSessionRoleApplication`;
/// the SwiftUI `App` has no slot for that role, so this is UIKit code living
/// next to it. The car can connect before the phone window exists, or
/// launch the app with the phone locked, which is why the model and player
/// come from `AppRuntime` rather than a view.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        controller = CarPlayController(interfaceController: interfaceController, runtime: .shared)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.disconnect()
        controller = nil
    }
}
