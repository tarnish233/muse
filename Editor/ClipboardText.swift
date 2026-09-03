import Foundation
import MuseKit

/// Pure clipboard range and plain-text conversion helpers used by EditorTextView.
enum ClipboardText {
    private struct Replacement {
        let range: NSRange
        let text: String
    }

    static func effectiveCopyRange(
        in source: NSString,
        selection: NSRange,
        copiesWholeLineWhenEmpty: Bool
    ) -> NSRange? {
        guard selection.location >= 0,
              selection.location <= source.length,
              selection.length >= 0,
              selection.upperBound <= source.length
        else { return nil }
        guard selection.length == 0, copiesWholeLineWhenEmpty else { return selection }
        guard source.length > 0 else { return nil }
        return source.lineRange(for: selection)
    }

    static func renderedPlainText(from source: String, range: NSRange) -> String {
        let nsSource = source as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.upperBound <= nsSource.length
        else { return "" }

        let package = RenderEngine().prepare(source)
        let replacements = package.tokens.flatMap { token -> [Replacement] in
            func replacement(_ byteRange: Range<Int>?, with text: String = "") -> Replacement? {
                guard let byteRange else { return nil }
                return Replacement(range: package.index.nsRange(byteRange), text: text)
            }

            switch token.kind {
            case .heading, .blockquote, .rule:
                return [replacement(token.markerRange)].compactMap { $0 }
            case .unorderedListItem:
                return [replacement(token.markerRange, with: "• ")].compactMap { $0 }
            case let .orderedListItem(_, number):
                return [replacement(token.markerRange, with: "\(number). ")].compactMap { $0 }
            case let .taskListItem(_, checked):
                return [replacement(token.markerRange, with: checked ? "☑ " : "☐ ")].compactMap { $0 }
            case .codeFence, .strong, .emphasis, .inlineCode, .inlineMath, .blockMath,
                 .strikethrough, .link, .image:
                return [
                    replacement(token.markerRange),
                    replacement(token.closingMarkerRange),
                ].compactMap { $0 }
            case .table:
                // A Markdown table has no lossless plain-text equivalent. Keep its source
                // structure instead of concatenating cells after removing delimiters.
                return []
            }
        }

        return applying(replacements, to: source, range: range)
    }

    /// Preserve Markdown block structure while removing inline syntax that is
    /// redundant in that block's default presentation. For now, headings are
    /// already bold, so only complete strong delimiters contained by a heading
    /// are removed. Ordinary strong text remains semantically untouched.
    static func normalizedMarkdown(from source: String, range: NSRange) -> String {
        let nsSource = source as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.upperBound <= nsSource.length
        else { return "" }

        let package = RenderEngine().prepare(source)
        let headingContents = package.tokens.compactMap { token -> Range<Int>? in
            guard case .heading = token.kind else { return nil }
            return token.contentRange
        }
        let replacements = package.tokens.flatMap { token -> [Replacement] in
            guard case .strong = token.kind,
                  let closing = token.closingMarkerRange,
                  let content = token.contentRange,
                  headingContents.contains(where: {
                      $0.lowerBound <= token.markerRange.lowerBound
                          && content.upperBound <= $0.upperBound
                          && closing.upperBound <= $0.upperBound
                  })
            else { return [] }
            let openingNS = package.index.nsRange(token.markerRange)
            let closingNS = package.index.nsRange(closing)
            guard NSIntersectionRange(openingNS, range) == openingNS,
                  NSIntersectionRange(closingNS, range) == closingNS
            else { return [] }
            return [
                Replacement(range: openingNS, text: ""),
                Replacement(range: closingNS, text: ""),
            ]
        }
        return applying(replacements, to: source, range: range)
    }

    private static func applying(
        _ replacements: [Replacement],
        to source: String,
        range: NSRange
    ) -> String {
        let nsSource = source as NSString
        let result = NSMutableString(string: nsSource.substring(with: range))
        let localized = replacements.compactMap { replacement -> Replacement? in
            let overlap = NSIntersectionRange(replacement.range, range)
            guard overlap.length > 0 else { return nil }
            let coversWholeMarker = NSEqualRanges(overlap, replacement.range)
            return Replacement(
                range: NSRange(location: overlap.location - range.location, length: overlap.length),
                text: coversWholeMarker ? replacement.text : ""
            )
        }
        .sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location > $1.range.location
            }
            return $0.range.length > $1.range.length
        }

        var appliedOriginalRanges: [NSRange] = []
        for replacement in localized {
            guard !appliedOriginalRanges.contains(where: {
                NSIntersectionRange($0, replacement.range).length > 0
            }) else { continue }
            result.replaceCharacters(in: replacement.range, with: replacement.text)
            appliedOriginalRanges.append(replacement.range)
        }
        return result as String
    }
}
