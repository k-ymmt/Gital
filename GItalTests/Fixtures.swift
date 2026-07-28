// Diff fixtures shared between the DiffParser and PatchBuilder suites.
// The literals close at column 0 so the diffs' significant leading
// whitespace survives verbatim.

enum Fixtures {
    static let sampleDiff = """
diff --git a/Sources/Login/LoginViewModel.swift b/Sources/Login/LoginViewModel.swift
index 1111111..2222222 100644
--- a/Sources/Login/LoginViewModel.swift
+++ b/Sources/Login/LoginViewModel.swift
@@ -42,5 +42,6 @@ final class LoginViewModel {
     func validate(token: String) -> Bool {
-        return !token.isEmpty
+        guard !token.isEmpty else { return false }
+        return token.count >= minTokenLength
    \u{20}}
\u{20}}
diff --git a/Resources/logo.png b/Resources/logo.png
index 3333333..4444444 100644
Binary files a/Resources/logo.png and b/Resources/logo.png differ
"""

    // A file without a trailing newline keeps the "\ No newline" marker.
    static let noNewlineDiff = """
diff --git a/end.txt b/end.txt
index 1111111..2222222 100644
--- a/end.txt
+++ b/end.txt
@@ -1,2 +1,2 @@
 first
-old last
\\ No newline at end of file
+new last
\\ No newline at end of file
"""

    // New file via diff --no-index (untracked preview).
    static let untrackedDiff = """
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..ebb3a2b
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+CLAUDE.md
+line2
"""

    // Combined diff for a conflicted path ("git diff" during a merge).
    static let combinedDiff = """
diff --cc file.txt
index 1e427e4,c08134a..0000000
--- a/file.txt
+++ b/file.txt
@@@ -1,3 -1,4 +1,8 @@@
  line1
++<<<<<<< HEAD
 +main change
++=======
+ feature change
++>>>>>>> feature
  line3
+ feature tail
"""
}
