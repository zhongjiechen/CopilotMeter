import Foundation

/// Utilities for scrubbing personally-identifying details out of strings that
/// might be surfaced to the UI (error banners, tooltips) or copied into a bug
/// report. We strip the user's home directory and known sensitive prefixes so
/// users can share screenshots without leaking their macOS username.
enum PathScrubber {
    private static let homeDir: String = NSHomeDirectory()

    /// Returns the input with any occurrence of the user's home directory
    /// replaced with `~`. Also strips the SwiftPM "Prepare failed" SQL dump
    /// suffix because it can include long file paths.
    static func scrub(_ s: String) -> String {
        var out = s.replacingOccurrences(of: homeDir, with: "~")
        if let range = out.range(of: "\nSQL: ") {
            out.removeSubrange(range.lowerBound..<out.endIndex)
            out += "\nSQL: <redacted>"
        }
        return out
    }
}
