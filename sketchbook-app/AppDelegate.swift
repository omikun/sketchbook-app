
import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
}

// UIKit creates the window and root controller from the scene's Main storyboard.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
