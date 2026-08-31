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

    enum ListIndentDirection {
        case indent
        case outdent
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

    /// Typora/Obsidian-style structural list indentation. The edit changes only
    /// Markdown indentation before list markers; ordinary paragraphs return nil
    /// so the caller can deliberately make Tab/Shift-Tab a no-op there.
    ///
    /// Indent aligns the selected item beneath its nearest preceding sibling at
    /// the same level. Outdent returns it to the nearest preceding ancestor. A
    /// collapsed selection also carries the item's contiguous descendants so a
    /// subtree cannot be torn apart by moving only its root line.
    static func listIndentEdit(
        in source: NSString,
        selection: NSRange,
        direction: ListIndentDirection,
        isListContext: (Int) -> Bool = { _ in true }
    ) -> Edit? {
        guard selection.location >= 0,
              selection.location <= source.length,
              NSMaxRange(selection) <= source.length,
              let selected = selectedListLines(in: source, selection: selection),
              selected.isEmpty == false,
              selected.allSatisfy({ isListContext($0.contextLocation) })
        else { return nil }

        let root = selected[0]
        let delta: Int
        let firstOrderedNumberAtDestination: Int
        switch direction {
        case .indent:
            guard let sibling = previousListLine(
                in: source,
                before: root.bounds.full.location,
                quotePrefix: root.prefix.quotePrefix,
                matchingIndent: root.prefix.indentColumns
            ) else { return nil }
            delta = sibling.prefix.markerWidth
            firstOrderedNumberAtDestination = 1
        case .outdent:
            guard root.prefix.indentColumns > 0 else { return nil }
            let ancestor = previousAncestorLine(
                in: source,
                before: root.bounds.full.location,
                quotePrefix: root.prefix.quotePrefix,
                belowIndent: root.prefix.indentColumns
            )
            delta = root.prefix.indentColumns - (ancestor?.prefix.indentColumns ?? 0)
            firstOrderedNumberAtDestination = ancestor?.prefix.orderedNumber.map { $0 + 1 } ?? 1
        }
        guard delta > 0 else { return nil }

        var lines = selected
        if selection.length == 0,
           let descendants = trailingDescendantLines(
               in: source,
               after: selected[selected.count - 1],
               rootIndent: root.prefix.indentColumns
           )
        {
            guard descendants.allSatisfy({ isListContext($0.contextLocation) }) else { return nil }
            lines.append(contentsOf: descendants)
        }

        var changes = lines.compactMap { line -> TextChange? in
            let current = line.prefix.indentColumns
            let target: Int
            switch direction {
            case .indent: target = current + delta
            case .outdent: target = max(0, current - delta)
            }
            guard target != current else { return nil }
            return TextChange(
                range: NSRange(
                    location: line.bounds.contents.location + line.prefix.indentRange.location,
                    length: line.prefix.indentRange.length
                ),
                replacement: String(repeating: " ", count: target)
            )
        }

        // An ordered sublist which immediately follows paragraph content must
        // begin at 1 under CommonMark. Keeping the old top-level marker (`2.`)
        // makes cmark parse the line as plain paragraph text even though its
        // indentation is otherwise correct. Renumber only the selected sibling
        // roots; descendants keep the numbering of their own nested lists.
        var nextOrderedNumber = firstOrderedNumberAtDestination
        for line in selected where line.prefix.indentColumns == root.prefix.indentColumns {
            guard let numberRange = line.prefix.orderedNumberRange else {
                nextOrderedNumber = 1
                continue
            }
            let replacement = String(nextOrderedNumber)
            let currentLength = numberRange.length
            if source.substring(with: NSRange(
                location: line.bounds.contents.location + numberRange.location,
                length: currentLength
            )) != replacement {
                changes.append(TextChange(
                    range: NSRange(
                        location: line.bounds.contents.location + numberRange.location,
                        length: currentLength
                    ),
                    replacement: replacement
                ))
            }
            nextOrderedNumber += 1
        }
        changes.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length < rhs.range.length
        }
        guard let firstChange = changes.first, let lastChange = changes.last else { return nil }

        let replacementRange = NSRange(
            location: firstChange.range.location,
            length: NSMaxRange(lastChange.range) - firstChange.range.location
        )
        let replacement = NSMutableString(string: source.substring(with: replacementRange))
        for change in changes.reversed() {
            replacement.replaceCharacters(
                in: NSRange(
                    location: change.range.location - replacementRange.location,
                    length: change.range.length
                ),
                with: change.replacement
            )
        }

        let mappedStart = mappedLocation(selection.location, through: changes)
        let mappedEnd = mappedLocation(NSMaxRange(selection), through: changes)
        return Edit(
            range: replacementRange,
            replacement: replacement as String,
            selectionAfter: NSRange(
                location: mappedStart,
                length: max(0, mappedEnd - mappedStart)
            )
        )
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
        let full: NSRange
        let contents: NSRange
    }

    private struct Prefix {
        let contentStart: Int
        let continuation: String
    }

    private struct ListPrefix {
        let contentStart: Int
        let continuation: String
        let quotePrefix: String
        let indentRange: NSRange
        let indentColumns: Int
        let markerWidth: Int
        let markerStart: Int
        let orderedNumber: Int?
        let orderedNumberRange: NSRange?
    }

    private struct ListLine {
        let bounds: LineBounds
        let prefix: ListPrefix

        var contextLocation: Int {
            bounds.contents.location + prefix.markerStart
        }
    }

    private struct TextChange {
        let range: NSRange
        let replacement: String
    }

    private static func lineBounds(in source: NSString, at location: Int) -> LineBounds {
        let full = source.lineRange(for: NSRange(location: location, length: 0))
        var contentsEnd = NSMaxRange(full)
        while contentsEnd > full.location {
            let character = source.character(at: contentsEnd - 1)
            guard character == CharacterCode.lineFeed || character == CharacterCode.carriageReturn else { break }
            contentsEnd -= 1
        }
        return LineBounds(
            full: full,
            contents: NSRange(location: full.location, length: contentsEnd - full.location)
        )
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

    private static func listPrefix(in line: String) -> ListPrefix? {
        let full = NSRange(location: 0, length: (line as NSString).length)
        let quote = quotePrefix(in: line)
        let quoteLength = (quote as NSString).length

        if let match = taskListExpression.firstMatch(in: line, range: full) {
            let indent = substring(line, match.range(at: 1))
            let bullet = substring(line, match.range(at: 2))
            let beforeTask = substring(line, match.range(at: 3))
            let task = substring(line, match.range(at: 4))
            let afterTask = substring(line, match.range(at: 5))
            let markerStart = match.range(at: 2).location
            return ListPrefix(
                contentStart: NSMaxRange(match.range),
                continuation: indent + bullet + beforeTask + task + afterTask,
                quotePrefix: quote,
                indentRange: NSRange(location: quoteLength, length: markerStart - quoteLength),
                indentColumns: indentationColumns(in: line, range: NSRange(
                    location: quoteLength, length: markerStart - quoteLength
                )),
                markerWidth: NSMaxRange(match.range(at: 3)) - markerStart,
                markerStart: markerStart,
                orderedNumber: nil,
                orderedNumberRange: nil
            )
        }

        if let match = orderedListExpression.firstMatch(in: line, range: full) {
            let numberText = substring(line, match.range(at: 2))
            guard let number = Int(numberText), number < Int.max else { return nil }
            let indent = substring(line, match.range(at: 1))
            let delimiter = substring(line, match.range(at: 3))
            let spacing = substring(line, match.range(at: 4))
            let markerStart = match.range(at: 2).location
            return ListPrefix(
                contentStart: NSMaxRange(match.range),
                continuation: indent + numberText + delimiter + spacing,
                quotePrefix: quote,
                indentRange: NSRange(location: quoteLength, length: markerStart - quoteLength),
                indentColumns: indentationColumns(in: line, range: NSRange(
                    location: quoteLength, length: markerStart - quoteLength
                )),
                markerWidth: NSMaxRange(match.range(at: 4)) - markerStart,
                markerStart: markerStart,
                orderedNumber: number,
                orderedNumberRange: match.range(at: 2)
            )
        }

        if let match = unorderedListExpression.firstMatch(in: line, range: full) {
            let markerStart = match.range(at: 2).location
            return ListPrefix(
                contentStart: NSMaxRange(match.range),
                continuation: substring(line, match.range),
                quotePrefix: quote,
                indentRange: NSRange(location: quoteLength, length: markerStart - quoteLength),
                indentColumns: indentationColumns(in: line, range: NSRange(
                    location: quoteLength, length: markerStart - quoteLength
                )),
                markerWidth: NSMaxRange(match.range(at: 3)) - markerStart,
                markerStart: markerStart,
                orderedNumber: nil,
                orderedNumberRange: nil
            )
        }

        return nil
    }

    private static func selectedListLines(in source: NSString, selection: NSRange) -> [ListLine]? {
        guard source.length > 0 else { return nil }
        let start = min(selection.location, source.length)
        let endLocation: Int
        if selection.length == 0 {
            endLocation = start
        } else {
            endLocation = max(start, min(source.length, NSMaxRange(selection)) - 1)
        }

        let first = lineBounds(in: source, at: start)
        let last = lineBounds(in: source, at: endLocation)
        var cursor = first.full.location
        let end = NSMaxRange(last.full)
        var lines: [ListLine] = []
        repeat {
            let bounds = lineBounds(in: source, at: cursor)
            let line = source.substring(with: bounds.contents)
            guard let prefix = listPrefix(in: line) else { return nil }
            lines.append(ListLine(bounds: bounds, prefix: prefix))
            let next = NSMaxRange(bounds.full)
            guard next > cursor else { break }
            cursor = next
        } while cursor < end
        return lines
    }

    private static func previousListLine(
        in source: NSString,
        before location: Int,
        quotePrefix: String,
        matchingIndent indent: Int
    ) -> ListLine? {
        var cursor = location
        while cursor > 0 {
            let bounds = lineBounds(in: source, at: cursor - 1)
            let line = source.substring(with: bounds.contents)
            guard line.trimmingCharacters(in: structuralWhitespace).isEmpty == false,
                  let prefix = listPrefix(in: line),
                  prefix.quotePrefix == quotePrefix
            else { return nil }
            if prefix.indentColumns == indent {
                return ListLine(bounds: bounds, prefix: prefix)
            }
            if prefix.indentColumns < indent { return nil }
            cursor = bounds.full.location
        }
        return nil
    }

    private static func previousAncestorLine(
        in source: NSString,
        before location: Int,
        quotePrefix: String,
        belowIndent indent: Int
    ) -> ListLine? {
        var cursor = location
        while cursor > 0 {
            let bounds = lineBounds(in: source, at: cursor - 1)
            let line = source.substring(with: bounds.contents)
            guard line.trimmingCharacters(in: structuralWhitespace).isEmpty == false,
                  let prefix = listPrefix(in: line),
                  prefix.quotePrefix == quotePrefix
            else { return nil }
            if prefix.indentColumns < indent {
                return ListLine(bounds: bounds, prefix: prefix)
            }
            cursor = bounds.full.location
        }
        return nil
    }

    private static func trailingDescendantLines(
        in source: NSString,
        after line: ListLine,
        rootIndent: Int
    ) -> [ListLine]? {
        var cursor = NSMaxRange(line.bounds.full)
        var descendants: [ListLine] = []
        while cursor < source.length {
            let bounds = lineBounds(in: source, at: cursor)
            let text = source.substring(with: bounds.contents)
            guard text.trimmingCharacters(in: structuralWhitespace).isEmpty == false,
                  let prefix = listPrefix(in: text),
                  prefix.quotePrefix == line.prefix.quotePrefix,
                  prefix.indentColumns > rootIndent
            else { break }
            descendants.append(ListLine(bounds: bounds, prefix: prefix))
            let next = NSMaxRange(bounds.full)
            guard next > cursor else { break }
            cursor = next
        }
        return descendants.isEmpty ? nil : descendants
    }

    private static func indentationColumns(in line: String, range: NSRange) -> Int {
        let indentation = (line as NSString).substring(with: range)
        var columns = 0
        for character in indentation.utf16 {
            if character == CharacterCode.tab {
                columns += 4 - columns % 4
            } else {
                columns += 1
            }
        }
        return columns
    }

    private static func mappedLocation(_ location: Int, through changes: [TextChange]) -> Int {
        var delta = 0
        for change in changes {
            let start = change.range.location
            let end = NSMaxRange(change.range)
            let replacementLength = (change.replacement as NSString).length
            if location < start { break }
            if location <= end {
                if change.range.length == 0 {
                    return start + delta + replacementLength
                }
                return start + delta + min(replacementLength, max(0, location - start))
            }
            delta += replacementLength - change.range.length
        }
        return location + delta
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
