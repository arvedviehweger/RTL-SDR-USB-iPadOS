//
//  RTLSDRHostApp.swift
//  RTL-SDR Host
//

import SwiftUI

@main
struct RTLSDRHostApp: App {

    @State private var model = ReceiverModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings, the driver may have been switched on.
            if phase == .active { model.refreshDevice() }
        }
    }
}

struct RootView: View {

    enum Page: String { case server, diagnostics, about }

    @SceneStorage("page") private var selection = Page.server

    var body: some View {
        TabView(selection: $selection) {
            Tab("Network", systemImage: "network", value: .server) {
                NavigationStack { ServerView() }
            }
            Tab("Diagnostics", systemImage: "stethoscope", value: .diagnostics) {
                NavigationStack { DiagnosticsView() }
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                NavigationStack { AboutView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
