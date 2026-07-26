//
//  GitalApp.swift
//  Gital
//

import SwiftUI

@main
struct GitalApp: App {
    @State private var appModel = AppModel()

    init() {
        // The app writes to pipes of spawned processes (git, gh, codex) that
        // can die mid-write; without this, an EPIPE becomes a fatal SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

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
        @Bindable var appModel = appModel

        Group {
            if let viewModel = appModel.repoViewModel {
                ContentView(model: viewModel)
                    .id(viewModel.repository.root)
            } else {
                WelcomeView()
            }
        }
        // Lives at the root so "Open Another Repository…" failures surface
        // with a repo open too, not only on the welcome screen.
        .alert("Could Not Open Repository", isPresented: Binding(
            get: { appModel.openError != nil },
            set: { if !$0 { appModel.openError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.openError ?? "")
        }
    }
}
