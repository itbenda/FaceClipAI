import SwiftUI

@main
struct FaceClipApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Quét", systemImage: "viewfinder") }
            PeopleView()
                .tabItem { Label("Người", systemImage: "person.2.fill") }
            UnknownView()
                .tabItem { Label("Chưa biết", systemImage: "questionmark.circle") }
                .badge(store.clusters.count)
        }
    }
}
