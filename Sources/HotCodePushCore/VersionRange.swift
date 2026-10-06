import Foundation

/// The range subset the three evaluators share, over dotted numeric versions: comparators `>=`, `>`, `<=`, `<`, `=`,
/// a bare version as equality, `x` or `*` wildcards and partial versions as intervals, alternatives joined by `||`.
/// Anything else does not parse, and a condition that does not parse is not satisfied.
public enum VersionRange {
    private struct Comparator {
        let op: String
        let version: [Int]
    }

    /// A version's numeric components; `nil` when the string is not a dotted number.
    public static func parseVersion(_ value: String) -> [Int]? {
        let components = value.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(component) else { return nil }
            parsed.append(number)
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// Whether the version satisfies the range: `nil` when the range does not parse.
    /// A comparator compares only as many components as it names, so `2.4.1` matches `2.4.1.57`.
    public static func isVersionInRange(_ version: [Int], _ range: String) -> Bool? {
        var alternatives: [[Comparator]] = []
        for alternative in range.components(separatedBy: "||") {
            guard let comparators = parseAlternative(alternative) else { return nil }
            alternatives.append(comparators)
        }
        return alternatives.contains { $0.allSatisfy { isSatisfied(version, $0) } }
    }

    private static func compare(_ left: [Int], _ right: [Int], length: Int) -> Int {
        for index in 0..<length {
            let difference = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
            if difference != 0 { return difference }
        }
        return 0
    }

    private static func isSatisfied(_ version: [Int], _ comparator: Comparator) -> Bool {
        let order = compare(version, comparator.version, length: comparator.version.count)
        switch comparator.op {
        case "<": return order < 0
        case "<=": return order <= 0
        case "=": return order == 0
        case ">": return order > 0
        default: return order >= 0
        }
    }

    /// One comparator: an optional operator, optional whitespace, a version that may end in wildcards or be
    /// wildcards alone, then whitespace or the end; an alternative parses only when comparators cover it entirely.
    private static let comparatorPattern = try! NSRegularExpression(pattern: #"(>=|<=|>|<|=)?\s*(\d+(?:\.\d+)*(?:\.[xX*])*|[xX*](?:\.[xX*])*)(?:\s+|$)"#)

    private static func parseAlternative(_ alternative: String) -> [Comparator]? {
        let trimmed = alternative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed as NSString
        var comparators: [Comparator] = []
        var position = 0
        while position < text.length {
            guard let match = comparatorPattern.firstMatch(in: trimmed, options: [.anchored], range: NSRange(location: position, length: text.length - position)), match.range.location == position, match.range.length > 0 else {
                return nil
            }
            let op = match.range(at: 1).location == NSNotFound ? nil : text.substring(with: match.range(at: 1))
            guard let parsed = parseComparator(op: op, version: text.substring(with: match.range(at: 2))) else { return nil }
            comparators.append(contentsOf: parsed)
            position = match.range.location + match.range.length
        }
        return comparators
    }

    private static func parseComparator(op: String?, version: String) -> [Comparator]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let wildcardIndex = components.firstIndex { $0 == "x" || $0 == "X" || $0 == "*" }
        if wildcardIndex != nil && op != nil { return nil }
        if wildcardIndex == nil && (op != nil || components.count >= 3) {
            return [Comparator(op: op ?? "=", version: components.compactMap(Int.init))]
        }
        return intervalComparators(components.prefix(wildcardIndex ?? components.count).compactMap(Int.init))
    }

    /// A partial or wildcard version as the interval it names: `1.2` and `1.2.x` are `>=1.2 <1.3`, `x` is everything.
    private static func intervalComparators(_ fixed: [Int]) -> [Comparator] {
        guard !fixed.isEmpty else { return [] }
        var upper = fixed
        upper[upper.count - 1] += 1
        return [Comparator(op: ">=", version: fixed), Comparator(op: "<", version: upper)]
    }
}
