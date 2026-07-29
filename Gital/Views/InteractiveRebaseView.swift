import SwiftUI

/// The interactive-rebase planning sheet: the prepared span of commits
/// (newest at the top, matching the history list), one action per row,
/// drag-to-reorder, and inline message editing for reword/squash. The plan
/// is local `@State` — dismissing the sheet discards it wholesale.
struct InteractiveRebaseSheet: View {
    let prep: GitRepository.InteractiveRebasePrep
    let onStart: (_ stepsNewestFirst: [RebaseStep]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [RebaseStep]

    init(prep: GitRepository.InteractiveRebasePrep, onStart: @escaping (_ stepsNewestFirst: [RebaseStep]) -> Void) {
        self.prep = prep
        self.onStart = onStart
        _steps = State(initialValue: prep.commits.map {
            RebaseStep(commit: $0, message: $0.message)
        })
    }

    /// The plan is validated by generating the actual todo script — the
    /// sheet can never green-light a plan the git layer would reject.
    private var validationError: String? {
        do {
            _ = try GitRepository.rebaseTodoScript(
                stepsOldestFirst: steps.reversed(),
                requireSurvivor: prep.baseHash == nil
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var resultingCommitCount: Int {
        steps.filter { $0.action == .pick || $0.action == .reword }.count
    }

    private var baseLabel: String {
        prep.baseHash.map { String($0.prefix(7)) } ?? "the root"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Interactive Rebase")
                    .font(.headline)
                Text("Rewrites \(steps.count) commits onto \(baseLabel). Newest is at the top; drag to reorder. Squash and Fixup fold a commit into the older one below it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            List {
                ForEach($steps) { $step in
                    RebaseStepRow(step: $step)
                }
                .onMove { indices, offset in
                    steps.move(fromOffsets: indices, toOffset: offset)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 12) {
                if let error = validationError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignStyle.deletion)
                        .lineLimit(2)
                } else {
                    Text("\(steps.count) commits → \(resultingCommitCount) commits")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    onStart(steps)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 380, idealHeight: 480)
    }
}

private struct RebaseStepRow: View {
    @Binding var step: RebaseStep

    private var isFollower: Bool {
        step.action == .squash || step.action == .fixup
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Picker("Action", selection: $step.action) {
                ForEach(RebaseAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 90)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(step.commit.shortHash)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(step.commit.subject)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(step.action == .drop)
                        .foregroundStyle(step.action == .drop ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(step.commit.author)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Reword rewrites this commit's message; squash appends this
                // draft to the commit it folds into.
                if step.action == .reword || step.action == .squash {
                    TextField("Commit message", text: $step.message, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .lineLimit(1...4)
                }
            }
            .padding(.leading, isFollower ? 18 : 0)
        }
        .padding(.vertical, 3)
    }
}
