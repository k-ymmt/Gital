//
//  GitalApp.swift
//  Gital
//

import SwiftUI

@main
struct GitalApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository…") {
                    appModel.pickRepository()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let viewModel = appModel.repoViewModel {
            ContentView(model: viewModel)
                .id(viewModel.repository.root)
        } else {
            WelcomeView()
        }
    }
}
