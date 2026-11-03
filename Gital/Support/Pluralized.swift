import Foundation

/// "1 file" / "3 files": a count followed by its noun, plural taking a plain
/// "s". UI copy is English-only; irregular plurals ("Branches") are spelled
/// out at their call sites.
nonisolated func pluralized(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
