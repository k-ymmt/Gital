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
    // Raw hex values, shared between the SwiftUI colors and the CSS mirror
    // below so the WKWebView diff pages can never drift from the palette.
    static let additionHex: UInt32 = 0x3fb950
    static let deletionHex: UInt32 = 0xf85149
    static let additionBackgroundHex: UInt32 = 0x2ea043
    static let hunkHex: UInt32 = 0x388bfd
    static let hunkTextHex: UInt32 = 0x6ea8fe
    static let brandBlueHex: UInt32 = 0x2f6fed
    static let mergedPurpleHex: UInt32 = 0x8957e5

    static let addition = Color(hex: additionHex)
    static let deletion = Color(hex: deletionHex)
    static let additionBackground = Color(hex: additionBackgroundHex, opacity: 0.15)
    static let deletionBackground = Color(hex: deletionHex, opacity: 0.12)
    static let hunkBackground = Color(hex: hunkHex, opacity: 0.10)
    static let hunkText = Color(hex: hunkTextHex)
    static let tagAmber = Color(hex: 0xe0b25a)
    /// GitHub's merged-purple; also the agent accent.
    static let mergedPurple = Color(hex: mergedPurpleHex)
    static let linkBlue = Color(hex: hunkTextHex)
    static let brandBlue = Color(hex: brandBlueHex)

    /// CSS spellings of the palette for `DiffHTMLBuilder`'s pages — the
    /// "no raw hex values in views" rule extends to the generated CSS.
    enum CSS {
        static let addition = hex(additionHex)
        static let deletion = hex(deletionHex)
        static let additionBackground = rgba(additionBackgroundHex, 0.15)
        static let deletionBackground = rgba(deletionHex, 0.12)
        static let hunkBackground = rgba(hunkHex, 0.10)
        static let hunkText = hex(hunkTextHex)
        static let brandBlue = rgb(brandBlueHex)
        static let mergedPurple = rgb(mergedPurpleHex)

        static func hex(_ value: UInt32) -> String {
            String(format: "#%06x", value)
        }

        static func rgb(_ value: UInt32) -> String {
            "rgb(\((value >> 16) & 0xff), \((value >> 8) & 0xff), \(value & 0xff))"
        }

        static func rgba(_ value: UInt32, _ alpha: Double) -> String {
            "rgba(\((value >> 16) & 0xff), \((value >> 8) & 0xff), \(value & 0xff), \(alpha))"
        }
    }

    /// State color of a pull request (list icon, detail status chip).
    static func prStateColor(state: String, isDraft: Bool) -> Color {
        switch state {
        case "MERGED": mergedPurple
        case "CLOSED": deletion
        default: isDraft ? Color.secondary : addition
        }
    }

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

/// "+N" badge shown when a commit row has more refs than it displays.
struct RefOverflowBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 30
    /// Real avatar image (github.com); nil falls back to colored initials.
    var url: URL? = nil

    var body: some View {
        Group {
            if let url {
                // Initials show only while loading and on failure — never
                // underneath the image, where a transparent-background avatar
                // (common for org logos) would let them bleed through.
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(DesignStyle.initials(for: name))
            .font(.system(size: size * 0.37, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(DesignStyle.avatarColor(for: name), in: Circle())
    }
}
