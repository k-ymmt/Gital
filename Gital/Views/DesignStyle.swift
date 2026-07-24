import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

/// Palette lifted from the reference design.
enum DesignStyle {
    static let addition = Color(hex: 0x3fb950)
    static let deletion = Color(hex: 0xf85149)
    static let additionBackground = Color(hex: 0x2ea043, opacity: 0.15)
    static let deletionBackground = Color(hex: 0xf85149, opacity: 0.12)
    static let hunkBackground = Color(hex: 0x388bfd, opacity: 0.10)
    static let hunkText = Color(hex: 0x6ea8fe)
    static let tagAmber = Color(hex: 0xe0b25a)

    static let laneColors: [Color] = [
        Color(hex: 0x4d9fff),
        Color(hex: 0xc07ff0),
        Color(hex: 0x5fd18a),
        Color(hex: 0xe0a559),
    ]

    static func laneColor(_ index: Int) -> Color {
        laneColors[index % laneColors.count]
    }

    static func avatarColor(for name: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0xe0823d), Color(hex: 0x2ea043),
            Color(hex: 0x8957e5), Color(hex: 0x2f6fed),
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initials(for name: String) -> String {
        let words = name.split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: - Shared small views

struct StatusBadge: View {
    let status: FileChange.Status

    var body: some View {
        Text(status.badge)
            .font(.system(size: 10.5, weight: .bold))
            .frame(width: 17, height: 17)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        switch status {
        case .added, .untracked: DesignStyle.addition
        case .deleted: DesignStyle.deletion
        case .conflicted: .orange
        default: DesignStyle.tagAmber
        }
    }

    private var background: Color {
        foreground.opacity(0.18)
    }
}

struct RefBadge: View {
    let gitRef: GitRef

    var body: some View {
        Text(gitRef.name)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(foreground)
            .lineLimit(1)
    }

    private var foreground: Color {
        switch gitRef.kind {
        case .head: .white
        case .branch: Color(hex: 0x8fbcff)
        case .remoteBranch: .secondary
        case .tag: DesignStyle.tagAmber
        }
    }

    private var background: Color {
        switch gitRef.kind {
        case .head: Color.accentColor
        case .branch: Color(hex: 0x6ea8fe, opacity: 0.16)
        case .remoteBranch: Color.primary.opacity(0.08)
        case .tag: DesignStyle.tagAmber.opacity(0.16)
        }
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Text(DesignStyle.initials(for: name))
            .font(.system(size: size * 0.37, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(DesignStyle.avatarColor(for: name), in: Circle())
    }
}
