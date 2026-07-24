import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 92, height: 92)
                    .glassEffect(in: .circle)
                Text("Gital")
                    .font(.system(size: 30, weight: .bold))
                Text("A native Git client for macOS")
                    .foregroundStyle(.secondary)
            }

            Button {
                appModel.pickRepository()
            } label: {
                Label("Open Repository…", systemImage: "folder")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if !appModel.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)

                    ForEach(appModel.recentRepositories, id: \.path) { url in
                        Button {
                            appModel.openRepository(at: url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .fontWeight(.medium)
                                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 380)
                .padding(.vertical, 10)
                .glassEffect(in: .rect(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
