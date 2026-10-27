import Foundation

/// How a date change applies to a set of items. Dates are absolute: PhotoKit cannot change an item's time
/// zone, and pickers show them on this Mac's clock.
enum DateChange: Hashable {
    /// The earliest item gets this date, the others keep their spacing
    case move(to: Date)
    /// Every item gets this date
    case set(to: Date)
    case shift(by: TimeInterval)
    /// Read from the file name with strptime-style codes (%Y %m %d %H %M %S), anywhere in the name
    case fromFilename(pattern: String)

    func newDate(for item: Item, earliest: Date) -> Date? {
        switch self {
        case .move(let target): item.date.addingTimeInterval(target.timeIntervalSince(earliest))
        case .set(let target): target
        case .shift(let interval): item.date.addingTimeInterval(interval)
        case .fromFilename(let pattern): FilenameDate.parse(item.filename, pattern: pattern)
        }
    }
}

enum FilenameDate {
    private static let codes: [Character: (pattern: String, component: Calendar.Component)] = [
        "Y": (#"(\d{4})"#, .year), "m": (#"(\d{2})"#, .month), "d": (#"(\d{2})"#, .day),
        "H": (#"(\d{2})"#, .hour), "M": (#"(\d{2})"#, .minute), "S": (#"(\d{2})"#, .second),
    ]

    /// "IMG_20240714_183000.jpg" with "%Y%m%d_%H%M%S" gives 14 July 2024 18:30:00 on this Mac's clock.
    static func parse(_ name: String, pattern: String) -> Date? {
        var expression = ""
        var components: [Calendar.Component] = []
        var characters = pattern.makeIterator()
        while let character = characters.next() {
            if character == "%", let code = characters.next() {
                if let known = codes[code] {
                    expression += known.pattern
                    components.append(known.component)
                } else {
                    expression += NSRegularExpression.escapedPattern(for: "%\(code)")
                }
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard !components.isEmpty, let regex = try? NSRegularExpression(pattern: expression),
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
        else { return nil }
        var parts = DateComponents(hour: 0, minute: 0, second: 0)
        for (index, component) in components.enumerated() {
            guard let range = Range(match.range(at: index + 1), in: name), let value = Int(name[range]) else {
                return nil
            }
            parts.setValue(value, for: component)
        }
        return Calendar.current.date(from: parts)
    }
}
