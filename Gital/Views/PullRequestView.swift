import SwiftUI

struct PullRequestView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        if let detail = model.prDetail {
            PullRequestDetailView(model: model, detail: detail)
        } else if model.selectedPRNumber != nil {
            ProgressView("Loading pull request…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(model.prLoadError ?? "Select a pull request")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PullRequestDetailView: View {
    @Bindable var model: RepoViewModel
    let detail: PullRequestDetail

    @State private var isMerging = false

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
        switch detail.state {
        case "MERGED": Color(hex: 0x8957e5)
        case "CLOSED": DesignStyle.deletion
        default: detail.isDraft ? Color.secondary : DesignStyle.addition
        }
    }

    private var statusChip: some View {
        Label(detail.statusLabel, systemImage: "arrow.triangle.pull")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(statusColor, in: Capsule())
    }

    private var mergeSummaryLine: some View {
        Text("\(detail.author) wants to merge \(Text("\(detail.commits.count) commits").foregroundStyle(.primary)) into \(refText(detail.base)) from \(refText(detail.head))")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }

    private func refText(_ name: String) -> Text {
        Text(name)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(hex: 0x6ea8fe))
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            AvatarView(name: detail.author, size: 26)
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
                let color = Color(hex: UInt32(label.color, radix: 16) ?? 0x2f6fed)
                Text(label.name)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
            }
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AvatarView(name: detail.author, size: 20)
                Text("\(detail.author) commented · \(detail.createdAt)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.3))
            Divider()
            Text(detail.body.isEmpty ? "No description provided." : detail.body)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
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
                    AvatarView(name: reviewer.name, size: 24)
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
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
    }

    private func reviewerState(_ state: String) -> some View {
        let (label, color): (String, Color) = switch state {
        case "APPROVED": ("Approved", DesignStyle.addition)
        case "CHANGES_REQUESTED": ("Changes requested", DesignStyle.deletion)
        case "COMMENTED": ("Commented", .secondary)
        default: ("Pending", DesignStyle.tagAmber)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var commitsCard: some View {
        VStack(spacing: 0) {
            ForEach(detail.commits) { commit in
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if commit.id != detail.commits.last?.id {
                    Divider()
                }
            }
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
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
                merge()
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

    private func merge() {
        isMerging = true
        Task {
            defer { isMerging = false }
            do {
                try await model.github.merge(number: detail.number)
                // Reload the detail directly — flipping selectedPRNumber
                // nil→back spawned two loads that both hit gh.
                model.prDetailsCache[detail.number] = nil
                await model.loadPRDetail()
                await model.refreshPullRequests()
            } catch {
                model.prLoadError = error.localizedDescription
            }
        }
    }
}
