import SwiftUI

@main
struct PickupBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("PickupBar").padding()
        } label: {
            Image(systemName: "envelope")
        }
        .menuBarExtraStyle(.window)
    }
}
