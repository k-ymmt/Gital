import SwiftUI

struct PullRequestDetailView: View {
    @Bindable var model: RepoViewModel
    let detail: PullRequestDetail

    private var isMerging: Bool { model.prs.mergingNumber == detail.number }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusChip

                Text("\(Text(detail.title).fontWeight(.semibold))  \(Text("#\(detail.number)").foregroundStyle(.secondary))")
                    .font(.system(size: 22))
                    .padding(.top, 13)

                mergeSummaryLine
                    .padding(.top, 9)

                metaRow
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                Divider()

                if !detail.labels.isEmpty {
                    labelChips
                        .padding(.top, 16)
                }

                descriptionCard
                    .padding(.top, 16)

                sectionTitle("Reviewers")
                reviewersCard

                // A refresh failure only replaces the list when there is no
                // (possibly stale) cached copy left to show.
                if let error = model.prs.threadsLoadError, model.prs.threads(for: detail.number).isEmpty {
                    sectionTitle("Conversations")
                    InlineErrorText(error, fontSize: 12)
                } else if !model.prs.threads(for: detail.number).isEmpty {
                    sectionTitle("Conversations", count: model.prs.threads(for: detail.number).count)
                    ConversationsCard(model: model, detail: detail)
                }

                // Also shown on closed/merged PRs while drafts remain, so
                // leftover pending comments never become unreachable.
                if detail.state == "OPEN" || !model.prs.pendingComments(for: detail.number).isEmpty {
                    reviewBox
                        .padding(.top, 14)
                }

                sectionTitle("Commits", count: detail.commits.count)
                commitsCard

                mergeBox
                    .padding(.top, 26)
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pieces

    private var statusColor: Color {
        DesignStyle.prStateColor(state: detail.state, isDraft: detail.isDraft)
    }

    private var statusChip: some View {
        Label { Text(detail.statusLabel) } icon: { GitGlyph(kind: .pullRequest, size: 13) }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(statusColor, in: Capsule())
    }

    private var mergeSummaryLine: some View {
        HStack(spacing: 5) {
            Text("\(detail.author) wants to merge \(Text("\(detail.commits.count) commits").foregroundStyle(.primary)) into")
            refChip(detail.base)
            Text("from")
            refChip(detail.head)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private func refChip(_ name: String) -> some View {
        HStack(spacing: 3) {
            refText(name)
            BranchCopyButton(name: name)
        }
    }

    private func refText(_ name: String) -> Text {
        Text(name)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DesignStyle.linkBlue)
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            AvatarView(name: detail.author, size: 26, url: model.avatarURL(login: detail.authorLogin, size: 26))
            Text("\(detail.author) opened \(detail.createdAt)")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(detail.additions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.addition)
            Text("−\(detail.deletions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.deletion)
            Text("\(detail.changedFiles) files")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var labelChips: some View {
        HStack(spacing: 7) {
            ForEach(detail.labels) { label in
                let color = Color(hex: UInt32(label.color, radix: 16) ?? DesignStyle.brandBlueHex)
                TintedChip(text: label.name, color: color, horizontalPadding: 9, verticalPadding: 3)
            }
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AvatarView(name: detail.author, size: 20, url: model.avatarURL(login: detail.authorLogin, size: 20))
                Text("\(detail.author) commented · \(detail.createdAt)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.3))
            Divider()
            if detail.body.isEmpty {
                Text("No description provided.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                MarkdownPreview(markdown: detail.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .cardStyle()
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private var reviewersCard: some View {
        VStack(spacing: 0) {
            if detail.reviewers.isEmpty {
                Text("No reviewers")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(detail.reviewers) { reviewer in
                HStack(spacing: 10) {
                    AvatarView(name: reviewer.name, size: 24, url: model.avatarURL(login: reviewer.login, size: 24))
                    Text(reviewer.name)
                        .font(.system(size: 12.5))
                    Spacer()
                    reviewerState(reviewer.state)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if reviewer.id != detail.reviewers.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private func reviewerState(_ state: String) -> some View {
        let (label, color): (String, Color) = switch state {
        case "APPROVED": ("Approved", DesignStyle.addition)
        case "CHANGES_REQUESTED": ("Changes requested", DesignStyle.deletion)
        case "COMMENTED": ("Commented", .secondary)
        default: ("Pending", DesignStyle.tagAmber)
        }
        return TintedChip(text: label, color: color)
    }

    private var commitsCard: some View {
        VStack(spacing: 0) {
            ForEach(detail.commits) { commit in
                let viewed = model.prs.isCommitViewed(commit.hash, in: detail.number)
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(commit.message)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer()
                        Text(commit.author)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(commit.hash)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(viewed ? 0.4 : 1)
                    ViewedToggle(viewed: viewed, size: 12) {
                        model.prs.toggleCommitViewed(commit.hash, in: detail.number)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.prs.selectItem(.commit(hash: commit.hash), in: detail.number)
                }
                .contextMenu {
                    Button("Copy Commit SHA") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.fullHash, forType: .string)
                    }
                }
                .help("Click to show this commit's diff")
                if commit.id != detail.commits.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    /// Overview entry point into the review flow: shows the pending draft
    /// count and the same "Review changes" form the diff header offers.
    private var reviewBox: some View {
        let count = model.prs.pendingComments(for: detail.number).count
        return HStack(spacing: 11) {
            Image(systemName: "text.bubble")
                .font(.system(size: 17))
                .foregroundStyle(count > 0 ? DesignStyle.tagAmber : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 0 ? "Review in progress" : "Review this pull request")
                    .font(.system(size: 13, weight: .semibold))
                Text(count > 0
                    ? "^[\(count) pending comment](inflect: true) will be submitted with your review."
                    : "Comment on diff lines in Commits or Files Changed to draft review comments.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if let error = model.prs.reviewSubmitError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignStyle.deletion)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            ReviewChangesButton(model: model, number: detail.number)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var canMerge: Bool {
        detail.state == "OPEN" && !detail.isDraft && detail.mergeable == "MERGEABLE"
    }

    private var mergeBox: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 17))
                .foregroundStyle(canMerge ? DesignStyle.addition : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mergeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(mergeNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.prs.merge(detail.number)
            } label: {
                if isMerging {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Merge pull request")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(DesignStyle.addition)
            .disabled(!canMerge || isMerging)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var mergeTitle: String {
        switch detail.state {
        case "MERGED": return "Pull request merged"
        case "CLOSED": return "Pull request closed"
        default:
            if detail.isDraft { return "Draft pull request" }
            return detail.mergeable == "MERGEABLE"
                ? "No conflicts with the base branch"
                : "Merge state: \(detail.mergeable.lowercased())"
        }
    }

    private var mergeNote: String {
        switch detail.state {
        case "MERGED": return "The changes are already part of \(detail.base)."
        case "CLOSED": return "This pull request was closed without merging."
        default:
            if detail.isDraft { return "Mark as ready for review before merging." }
            return "Merging will create a merge commit on \(detail.base)."
        }
    }
}

/// Copies the PR's branch name, flashing a checkmark as feedback.
struct BranchCopyButton: View {
    let name: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? AnyShapeStyle(DesignStyle.addition) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help("Copy branch name")
    }
}
