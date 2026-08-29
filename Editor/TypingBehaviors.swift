import Foundation
import MuseKit

/// M4 block-editing decisions.
///
/// AppKit remains responsible for applying edits, selection, IME, and undo.
/// This type only recognizes the small amount of Markdown source context that
/// native `NSTextView` does not provide: list prefixes, ATX heading prefixes,
/// and the symmetric markers Muse auto-pairs.
enum TypingBehaviors {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selectionAfter: NSRange
    }

    enum BlockContext: Equatable {
        case list(depth: Int)
        case heading
        case other
    }

    /// Returns a single replacement for Enter, or `nil` to let NSTextView use
    /// its normal newline behavior.
    static func newlineEdit(
        in source: NSString,
        selection: NSRange,
        blockContext: BlockContext
    ) -> Edit? {
        guard selection.length == 0,
              selection.location >= 0,
              selection.location <= source.length
        else { return nil }

        let bounds = lineBounds(in: source, at: selection.location)
        let line = source.substring(with: bounds.contents)
        let relativeCaret = selection.location - bounds.contents.location

        if case .list = blockContext,
           let list = listPrefix(in: line),
           relativeCaret >= list.contentStart
        {
            let content = (line as NSString).substring(from: list.contentStart)
            if content.trimmingCharacters(in: structuralWhitespace).isEmpty {
                return Edit(
                    range: bounds.contents,
                    replacement: "",
                    selectionAfter: NSRange(location: bounds.contents.location, length: 0)
                )
            }

            let insertionStart: Int
            if relativeCaret == (line as NSString).length {
                let whitespaceStart = trailingWhitespaceStart(
                    in: line as NSString,
                    before: relativeCaret,
                    lowerBound: list.contentStart
                )
                insertionStart = relativeCaret - whitespaceStart >= 2
                    ? relativeCaret
                    : whitespaceStart
            } else {
                insertionStart = relativeCaret
            }
            let replacement = "\n" + list.continuation
            return Edit(
                range: NSRange(
                    location: bounds.contents.location + insertionStart,
                    length: relativeCaret - insertionStart
                ),
                replacement: replacement,
                selectionAfter: NSRange(
                    location: bounds.contents.location + insertionStart + (replacement as NSString).length,
                    length: 0
                )
            )
        }

        // At the content start of an ATX heading, Enter creates a plain blank
        // paragraph before it while retaining the heading and its source mark.
        // An empty heading exits the heading instead of leaving an empty mark.
        if blockContext == .heading,
           let heading = headingPrefix(in: line),
           relativeCaret == heading.contentStart
        {
            let nsLine = line as NSString
            let content = nsLine.substring(from: heading.contentStart)
            if content.trimmingCharacters(in: structuralWhitespace).isEmpty {
                return Edit(
                    range: bounds.contents,
                    replacement: "",
                    selectionAfter: NSRange(location: bounds.contents.location, length: 0)
                )
            }

            // The blank line has to carry the enclosing blockquote's marker, or
            // `> # Heading` would be split into two separate quotes by a bare
            // empty line. The list branch gets this for free from
            // `list.continuation`; the heading branch re-derives its prefix, so
            // it has to add the quote back explicitly.
            let quote = quotePrefix(in: line)
            let prefix = nsLine.substring(to: heading.contentStart)
            return Edit(
                range: NSRange(location: bounds.contents.location, length: heading.contentStart),
                replacement: quote + "\n" + prefix,
                selectionAfter: NSRange(
                    location: bounds.contents.location + (quote as NSString).length,
                    length: 0
                )
            )
        }

        return nil
    }

    /// Returns a conservative auto-pair edit for `*`, `**`, and backticks.
    /// `nil` means the input must be inserted literally by NSTextView.
    static func pairEdit(
        in source: NSString,
        input: String,
        selection: NSRange,
        allowMarkerUpgrade: Bool = false,
        allowCloserSkip: Bool = false
    ) -> Edit? {
        guard selection.location >= 0,
              selection.location + selection.length <= source.length,
              input == "*" || input == "**" || input == "`"
        else { return nil }

        if selection.length > 0 {
            let selected = source.substring(with: selection)
            let marker = input == "`"
                ? String(repeating: "`", count: longestBacktickRun(in: selected) + 1)
                : input
            let replacement = marker + selected + marker
            return Edit(
                range: selection,
                replacement: replacement,
                selectionAfter: NSRange(
                    location: selection.location + (marker as NSString).length,
                    length: selection.length
                )
            )
        }

        guard isEscaped(in: source, at: selection.location) == false else { return nil }

        let marker = input
        let markerLength = (marker as NSString).length
        let suffixRange = NSRange(location: selection.location, length: min(markerLength, source.length - selection.location))
        if suffixRange.length == markerLength, source.substring(with: suffixRange) == marker {
            // Consecutive input may grow only the empty pair the editor owns:
            // `*|*` → `**|**`, or a backtick delimiter by one on each side.
            // Once content exists, the same input consumes the owned closer.
            if allowMarkerUpgrade,
               selection.location > 0,
               source.character(at: selection.location - 1) == (marker as NSString).character(at: 0)
            {
                return Edit(
                    range: selection,
                    replacement: marker + marker,
                    selectionAfter: NSRange(location: selection.location + 1, length: 0)
                )
            }
            guard allowCloserSkip else { return nil }
            return Edit(
                range: selection,
                replacement: "",
                selectionAfter: NSRange(location: selection.location + markerLength, length: 0)
            )
        }

        // Only open at a conservative left-flanking boundary: the following
        // character must exist and be non-whitespace, and the preceding
        // character must not be alphanumeric.
        guard let following = source.characterAfter(selection.location),
              isWhitespace(following) == false,
              isWordCharacterEnding(at: selection.location, in: source) == false
        else { return nil }

        let replacement = marker + marker
        return Edit(
            range: selection,
            replacement: replacement,
            selectionAfter: NSRange(location: selection.location + markerLength, length: 0)
        )
    }


    /// A CommonMark code span delimiter must be longer than every backtick run
    /// inside its contents. Selection wrapping therefore chooses the shortest
    /// safe run instead of blindly adding one backtick on each side.
    private static func longestBacktickRun(in string: String) -> Int {
        var longest = 0
        var current = 0
        for character in string {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    // MARK: - Line recognition

    private struct LineBounds {
        let contents: NSRange
    }

    private struct Prefix {
        let contentStart: Int
        let continuation: String
    }

    private static func lineBounds(in source: NSString, at location: Int) -> LineBounds {
        let full = source.lineRange(for: NSRange(location: location, length: 0))
        var contentsEnd = NSMaxRange(full)
        while contentsEnd > full.location {
            let character = source.character(at: contentsEnd - 1)
            guard character == CharacterCode.lineFeed || character == CharacterCode.carriageReturn else { break }
            contentsEnd -= 1
        }
        return LineBounds(contents: NSRange(location: full.location, length: contentsEnd - full.location))
    }

    private static let taskListExpression = try! NSRegularExpression(
        pattern: #"^((?:[ \t]{0,3}>[ \t]?)*[ \t]*)([-+*])([ \t]+)(\[[ xX]\])([ \t]+)"#
    )
    private static let orderedListExpression = try! NSRegularExpression(
        pattern: #"^((?:[ \t]{0,3}>[ \t]?)*[ \t]*)([0-9]+)([.)])([ \t]+)"#
    )
    private static let unorderedListExpression = try! NSRegularExpression(
        pattern: #"^((?:[ \t]{0,3}>[ \t]?)*[ \t]*)([-+*])([ \t]+)"#
    )
    private static let headingExpression = try! NSRegularExpression(
        pattern: #"^((?:[ \t]{0,3}>[ \t]?)*[ \t]{0,3})(#{1,6})([ \t]+)"#
    )
    /// Block context inferred from the line alone.
    ///
    /// Used only while the rendered attributes have not caught up with the
    /// keystroke — measured 37.9ms at 20KB, 343ms at 200KB and 1.83s at 1MB
    /// between the last keystroke and `.museBlock` landing, which is far longer
    /// than the pause before a user presses Enter.
    ///
    /// Classification is delegated to swift-markdown (`MarkdownSemantics
    /// .lineBlockKind`), not hand-written rules: a hand-rolled version of this
    /// mistook `- - -` for a bullet and 4-space indented code for a list. The
    /// caller stays responsible for the code-fence veto, which is the one thing
    /// a line cannot answer about itself.
    ///
    /// `depth` is informational — `newlineEdit` gates on the case only.
    static func lineShapeContext(in source: NSString, at location: Int) -> BlockContext {
        guard location >= 0, location <= source.length else { return .other }
        let bounds = lineBounds(in: source, at: location)
        switch MarkdownSemantics.lineBlockKind(of: source.substring(with: bounds.contents)) {
        case .list: return .list(depth: 0)
        case .heading: return .heading
        case .other: return .other
        }
    }

    private static func listPrefix(in line: String) -> Prefix? {
        let full = NSRange(location: 0, length: (line as NSString).length)

        if let match = taskListExpression.firstMatch(in: line, range: full) {
            let indent = substring(line, match.range(at: 1))
            let bullet = substring(line, match.range(at: 2))
            let beforeTask = substring(line, match.range(at: 3))
            let task = substring(line, match.range(at: 4))
            let afterTask = substring(line, match.range(at: 5))
            return Prefix(
                contentStart: NSMaxRange(match.range),
                continuation: indent + bullet + beforeTask + task + afterTask
            )
        }

        if let match = orderedListExpression.firstMatch(in: line, range: full) {
            let numberText = substring(line, match.range(at: 2))
            guard let number = Int(numberText), number < Int.max else { return nil }
            let indent = substring(line, match.range(at: 1))
            let delimiter = substring(line, match.range(at: 3))
            let spacing = substring(line, match.range(at: 4))
            return Prefix(
                contentStart: NSMaxRange(match.range),
                continuation: indent + numberText + delimiter + spacing
            )
        }

        if let match = unorderedListExpression.firstMatch(in: line, range: full) {
            return Prefix(
                contentStart: NSMaxRange(match.range),
                continuation: substring(line, match.range)
            )
        }

        return nil
    }

    private static let quotePrefixExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]{0,3}>[ \t]?)*"#
    )

    /// The run of blockquote markers opening the line, or `""`.
    private static func quotePrefix(in line: String) -> String {
        let full = NSRange(location: 0, length: (line as NSString).length)
        guard let match = quotePrefixExpression.firstMatch(in: line, range: full) else { return "" }
        return substring(line, match.range)
    }

    private static func headingPrefix(in line: String) -> Prefix? {
        let full = NSRange(location: 0, length: (line as NSString).length)
        guard let match = headingExpression.firstMatch(in: line, range: full) else {
            return nil
        }
        return Prefix(contentStart: NSMaxRange(match.range), continuation: "")
    }

    private static func substring(_ string: String, _ range: NSRange) -> String {
        (string as NSString).substring(with: range)
    }

    private static func trailingWhitespaceStart(in line: NSString, before caret: Int, lowerBound: Int) -> Int {
        var start = caret
        while start > lowerBound {
            let character = line.character(at: start - 1)
            guard character == CharacterCode.space || character == CharacterCode.tab else { break }
            start -= 1
        }
        return start
    }

    // MARK: - Pair context

    private enum CharacterCode {
        static let tab: unichar = 0x09
        static let lineFeed: unichar = 0x0A
        static let carriageReturn: unichar = 0x0D
        static let space: unichar = 0x20
        static let asterisk: unichar = 0x2A
        static let backslash: unichar = 0x5C
    }

    private static func isEscaped(in source: NSString, at location: Int) -> Bool {
        var index = location
        var count = 0
        while index > 0, source.character(at: index - 1) == CharacterCode.backslash {
            count += 1
            index -= 1
        }
        return count.isMultiple(of: 2) == false
    }

    /// Whether the character cluster ending at `location` is a word character.
    ///
    /// Takes the whole composed character sequence rather than one UTF-16 code
    /// unit: `UnicodeScalar(unichar)` returns nil for a surrogate, so a raw
    /// code-unit test answers "not a word character" for every astral-plane
    /// letter and digit — CJK Extension B, Deseret, mathematical alphanumerics —
    /// and would open a pair mid-word there while correctly refusing after a BMP
    /// letter. Using the cluster also fixes combining marks: for `e` + U+0301 the
    /// cluster's first scalar is `e`, where the bare mark U+0301 is `Mn` and
    /// tested as a non-word character.
    private static func isWordCharacterEnding(at location: Int, in source: NSString) -> Bool {
        guard location > 0, location <= source.length else { return false }
        let cluster = source.rangeOfComposedCharacterSequence(at: location - 1)
        guard let scalar = source.substring(with: cluster).unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static let structuralWhitespace = CharacterSet(charactersIn: " \t")
}

private extension NSString {
    func characterBefore(_ location: Int) -> unichar? {
        location > 0 ? character(at: location - 1) : nil
    }

    func characterAfter(_ location: Int) -> unichar? {
        location < length ? character(at: location) : nil
    }
}

