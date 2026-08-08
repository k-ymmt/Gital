import SwiftUI

/// Xcode-style repository switcher in the center of the window toolbar:
/// the open repository's name and current branch, with a menu of recent
/// repositories to switch to.
struct RepositorySwitcher: View {
    let model: RepoViewModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // The texts sit OUTSIDE the Menu: a Menu label in a toolbar renders
        // icon-only on macOS 27 beta (the Texts silently disappear), so only
        // the chevron is the Menu and the badge/name/branch are plain views.
        HStack(spacing: 8) {
            Text(String(model.repository.name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    LinearGradient(
                        colors: [DesignStyle.linkBlue, DesignStyle.brandBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 5)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.middleEllipsized(model.repository.name, maxLength: 36))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(Self.middleEllipsized(subtitle, maxLength: 44))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button("Open Another Repository…") {
                    appModel.pickRepository()
                }
                ForEach(appModel.recentRepositories, id: \.path) { url in
                    Button {
                        appModel.openRepository(at: url)
                    } label: {
                        Text(url.lastPathComponent)
                        Text(Self.abbreviatedPath(for: url))
                    }
                    // The open repo is always the first recent; reopening it
                    // would tear down and rebuild the whole repo state for
                    // nothing.
                    .disabled(url.standardizedFileURL.path == model.repository.root.standardizedFileURL.path)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch repository")
        }
        // minWidth gives the control an Xcode-like wide footprint even for
        // short names (content stays centered inside). fixedSize is
        // load-bearing: the toolbar compresses a flexible item to its
        // minimum, which collapses the texts to nothing (verified on macOS
        // 27 beta). Under fixedSize the frame resolves to
        // max(minWidth, ideal), and Text truncation can never engage —
        // overlong names are ellipsized in the string itself instead.
        .frame(minWidth: 320)
        .padding(.vertical, 5)
        // Sync spinner at the trailing edge of the switcher capsule
        // (Xcode-style activity placement). An overlay, not an HStack
        // member, so appearing/disappearing never re-lays-out the
        // centered name/branch texts.
        .overlay(alignment: .trailing) {
            if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 10)
            }
        }
        // Own capsule: the item opts out of the toolbar's shared glass
        // background (sharedBackgroundVisibility(.hidden) in ContentView).
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .help(model.repository.displayPath)
    }

    /// Detached HEAD shows where HEAD actually is — a bare "detached HEAD"
    /// gives no way to tell which commit the working copy reflects.
    private var subtitle: String {
        if let branch = model.status.branch { return branch }
        if let oid = model.status.headOID { return "Detached HEAD at \(String(oid.prefix(7)))" }
        return "Detached HEAD"
    }

    /// Menu items ignore Text line-limit/truncation modifiers, so ellipsize the string itself.
    private static func abbreviatedPath(for url: URL, maxLength: Int = 48) -> String {
        middleEllipsized(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), maxLength: maxLength)
    }

    private static func middleEllipsized(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let head = string.prefix((maxLength - 1) / 2)
        let tail = string.suffix(maxLength / 2)
        return "\(head)…\(tail)"
    }
}
