import SpriteKit
import SwiftUI

struct ContentView: View {
    @State private var scene = ClassroomGameScene()

    var body: some View {
        SpriteView(scene: scene, options: [.ignoresSiblingOrder])
            .background(Color(red: 0.06, green: 0.08, blue: 0.09))
            .persistentSystemOverlays(.hidden)
    }
}
