import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidDisconnect(_ scene: UIScene) {
    PigeonPlatform.shutdownForTermination()
    super.sceneDidDisconnect(scene)
  }
}
