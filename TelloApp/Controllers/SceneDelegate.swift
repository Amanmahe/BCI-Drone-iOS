// SceneDelegate.swift

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = UIWindow(windowScene: windowScene)
        // Match the HomeViewController gradient start colour so safe-area
        // margins on iPhone 16 Pro (Dynamic Island, rounded corners) blend in
        // instead of showing as black bars.
        window.backgroundColor = UIColor(red:0.04, green:0.04, blue:0.14, alpha:1)
        window.rootViewController = HomeViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
