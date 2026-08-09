import Foundation

enum TitleTagMode: String, CaseIterable, Identifiable, Sendable {
    case firstSegment
    case everyWord

    var id: String { rawValue }
    var label: String {
        switch self {
        case .firstSegment: "First title segment"
        case .everyWord: "Every title word"
        }
    }
}

struct TagGenerationOptions: Sendable {
    var separators = ",|;/"
    var splitOnWhitespace = false
    var generateFromTitle = false
    var titleMode: TitleTagMode = .firstSegment
    var titleSeparators = "-–—_:|/,"
    var keepExistingTags = true
}

enum TagUtilities {
    private static let dateFormats = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "dd-MM-yyyy", "dd/MM/yyyy", "dd.MM.yyyy", "MM-dd-yyyy", "MM/dd/yyyy", "MM.dd.yyyy", "yyyyMMdd"]

    static func dateValue(for tag: String) -> Date? {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value), formatter.string(from: date) == value {
                return date
            }
        }
        return nil
    }

    static func dateTags(from tags: [String]) -> [String: Date] {
        tags.reduce(into: [:]) { result, tag in
            if let date = dateValue(for: tag) {
                result[tag] = date
            }
        }
    }

    static func splitTags(_ value: String, separators: String = ",|;/", splitOnWhitespace: Bool = false) -> [String] {
        unique(value.split { character in
            separators.contains(character) || (splitOnWhitespace && character.isWhitespace)
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    static func tags(title: String, existing: [String], rawTags: String, options: TagGenerationOptions) -> [String] {
        var result = options.keepExistingTags ? existing : []
        result.append(contentsOf: splitTags(rawTags, separators: options.separators, splitOnWhitespace: options.splitOnWhitespace))

        guard options.generateFromTitle else { return unique(result) }
        switch options.titleMode {
        case .firstSegment:
            let segment = title.split { options.titleSeparators.contains($0) }.first.map(String.init) ?? title
            result.append(contentsOf: splitTags(segment, separators: options.separators, splitOnWhitespace: options.splitOnWhitespace))
        case .everyWord:
            result.append(contentsOf: splitTags(title, separators: options.titleSeparators, splitOnWhitespace: true))
        }
        return unique(result)
    }

    static func applyingMergedTags(_ tags: [String], rules: [MergedTagRule]) -> [String] {
        var result = unique(tags)
        let normalized = Set(result.map { $0.lowercased() })
        for rule in rules {
            let sources = rule.sourceTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            let merged = rule.mergedTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sources.count >= 2, !merged.isEmpty, sources.allSatisfy(normalized.contains) else { continue }
            result = unique(result + [merged])
        }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty else { return false }
            return seen.insert(value.lowercased()).inserted
        }
    }
}
