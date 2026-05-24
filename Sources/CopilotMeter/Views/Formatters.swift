import Foundation

enum Formatters {
    static func compactInt(_ n: Int) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...:
            return String(format: "%.1fB", d / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
        case 1_000_000...:
            return String(format: "%.1fM", d / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 10_000...:
            return String(format: "%.0fK", d / 1_000)
        case 1_000...:
            return String(format: "%.1fK", d / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default:
            return "\(n)"
        }
    }

    static func compactDouble(_ d: Double, fraction: Int = 1) -> String {
        if d == d.rounded() && abs(d) < 1_000 {
            return "\(Int(d))"
        }
        return compactInt(Int(d.rounded()))
    }

    /// Compact AI Credits number for tight chrome (menu bar / chips). Returns
    /// values like "12", "423", "1.2K", "12K", "1.5M".
    static func compactCredits(_ c: Double) -> String {
        if c < 1 && c > 0 {
            return String(format: "%.2f", c)
        }
        return compactDouble(c)
    }

    /// Short USD formatting suited to chrome:
    ///   - $1234   for >= 1000
    ///   - $12.34  for >= 10
    ///   - $1.234  for >= 0.01
    ///   - $0.00   otherwise
    static func compactUSD(_ v: Double) -> String {
        if v >= 1_000 { return String(format: "$%.0f", v) }
        if v >= 10    { return String(format: "$%.2f", v) }
        if v > 0      { return String(format: "$%.3f", v) }
        return "$0.00"
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
