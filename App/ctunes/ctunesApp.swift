import SwiftUI

@main
struct CtunesApp: App {
    init() {
        // Navigation titles are UIKit labels, out of reach of foregroundStyle.
        let ink = UIColor(Color.ink)
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: ink]
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: ink]
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
