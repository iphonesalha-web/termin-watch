import SwiftUI

@main
struct TerminPiApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("الحالة", systemImage: "checkmark.seal") }
            LogView()
                .tabItem { Label("السجل", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
    }
}
