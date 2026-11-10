import SwiftUI

@main
struct RUN30App: App {
    @StateObject private var cloud = CloudStore()
    @StateObject private var gps = GPSTracker()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environmentObject(cloud)
                .environmentObject(gps)
                .tint(Color(red:0.22,green:0.67,blue:0.36))
                .task { await cloud.sync() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await cloud.sync() } }
                }
        }
    }
}
