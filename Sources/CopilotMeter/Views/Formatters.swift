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

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
