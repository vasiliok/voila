import Foundation

/// A completion candidate: a properly accented French word and its corpus frequency.
public struct Completion: Equatable, Sendable {
    public let word: String
    public let frequency: UInt64

    public init(word: String, frequency: UInt64) {
        self.word = word
        self.frequency = frequency
    }
}

/// Accent-insensitive French completer and accent restorer.
///
/// Lookups are keyed on a folded form of each word (lowercased, diacritics
/// stripped, œ→oe, æ→ae), so typing plain ASCII finds the accented word:
/// "ecole" → "école", "coeur" → "cœur".
public struct Completer: Sendable {

    struct Entry: Sendable {
        let key: String
        let word: String
        let frequency: UInt64
    }

    /// The corpus contains unaccented misspellings ("etre", "francais") as
    /// real entries. A typed word is rewritten only when the accented form is
    /// this many times more frequent, which restores typos while keeping
    /// genuine pairs like a/à and ou/où (whose frequencies are comparable).
    private static let restoreThreshold: UInt64 = 5

    private static let locale = Locale(identifier: "fr_FR")

    /// Entries sorted by folded key, for prefix search.
    private let entries: [Entry]
    /// Most frequent entry per folded key whose word carries accents or
    /// ligatures, for whole-word restoration.
    private let bestAccentedByKey: [String: Entry]
    /// Frequency of every dictionary word as written (lowercase).
    private let frequencyByWord: [String: UInt64]
    /// Every folded key, to tell known words from misspellings.
    private let keys: Set<String>
    /// Each entry's key as scalars, parallel to `entries`, for edit distance.
    private let entryScalars: [[Unicode.Scalar]]
    /// Each entry's phonetic key, parallel to `entries`.
    private let entryPhonetics: [[Unicode.Scalar]]

    public init(words: [(word: String, frequency: UInt64)]) {
        var built: [Entry] = []
        built.reserveCapacity(words.count)
        var bestAccented: [String: Entry] = [:]
        var frequencies: [String: UInt64] = [:]
        frequencies.reserveCapacity(words.count)
        for (word, frequency) in words {
            let entry = Entry(key: Self.fold(word), word: word, frequency: frequency)
            built.append(entry)
            frequencies[word] = max(frequencies[word] ?? 0, frequency)
            // Bare elisions ("qu'", "jusqu'") are never restoration targets:
            // restore() splits "qu'il" at the apostrophe, so "qu" would gain
            // a second one.
            if word != entry.key, !word.hasSuffix("'"),
                frequency > (bestAccented[entry.key]?.frequency ?? 0) {
                bestAccented[entry.key] = entry
            }
        }
        built.sort { $0.key < $1.key }
        self.entries = built
        self.bestAccentedByKey = bestAccented
        self.frequencyByWord = frequencies
        self.keys = Set(built.map(\.key))
        self.entryScalars = built.map { Array($0.key.unicodeScalars) }
        self.entryPhonetics = built.map { Array(Self.phonetic($0.key).unicodeScalars) }
    }

    /// Loads the bundled French frequency dictionary (50k words).
    public static func french() throws -> Completer {
        guard let url = Bundle.module.url(forResource: "fr_50k", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    /// Loads a frequency dictionary with one "word count" pair per line.
    public static func load(from url: URL) throws -> Completer {
        let text = try String(contentsOf: url, encoding: .utf8)
        var words: [(String, UInt64)] = []
        words.reserveCapacity(50_000)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let frequency = UInt64(parts[1]) else { continue }
            words.append((String(parts[0]), frequency))
        }
        return Completer(words: words)
    }

    /// Lowercases and strips everything the folded keys don't carry:
    /// diacritics, the ligatures Unicode folding leaves alone, apostrophes
    /// and hyphens ("aujourdhui" finds "aujourd'hui", "peutetre" "peut-être").
    static func fold(_ word: String) -> String {
        unligature(word.lowercased(with: locale))
            .folding(options: .diacriticInsensitive, locale: locale)
            .filter { !joiners.contains($0) }
    }

    private static let joiners: Set<Character> = ["'", "\u{2019}", "-"]

    /// Only the ligature half of `fold`: cœur → coeur, but où stays où.
    static func unligature(_ word: String) -> String {
        word.replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
    }

    // MARK: - Completion

    /// Words starting with `prefix` (accent-insensitively), most frequent
    /// first. Unaccented misspellings the corpus contains are dropped in
    /// favor of their accented form. Results carry the case of the typed
    /// prefix: "Ecol" → "École".
    public func complete(_ prefix: String, limit: Int = 10) -> [Completion] {
        guard limit > 0, !prefix.isEmpty else { return [] }
        let key = Self.fold(prefix)
        var matches: [Entry] = []
        for i in lowerBound(of: key)..<entries.count {
            guard entries[i].key.hasPrefix(key) else { break }
            // An entry its own restoration would rewrite is a typo variant.
            guard accentuate(entries[i].word) == entries[i].word else { continue }
            matches.append(entries[i])
        }
        matches.sort { $0.frequency > $1.frequency }
        return matches.prefix(limit).map {
            Completion(word: Self.matchCase(of: prefix, to: $0.word), frequency: $0.frequency)
        }
    }

    /// Index of the first entry whose key is >= `key`.
    private func lowerBound(of key: String) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].key < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Accent restoration

    /// The properly accented spelling of a word typed without accents:
    /// "francais" → "français", "coeur" → "cœur". A genuine unaccented word
    /// is kept ("a" never becomes "à"), and so is any word the restoration
    /// rule can't clearly improve. Unknown words come back unchanged.
    public func accentuate(_ word: String) -> String {
        let lowered = word.lowercased(with: Self.locale)
        // Elision first: the corpus holds typos like "cétait" that would
        // otherwise claim "cetait" before it can become "c'était".
        if let restored = elided(lowered) ?? restoredSpelling(of: lowered) {
            return Self.matchCase(of: word, to: restored)
        }
        return word
    }

    /// The accented dictionary spelling of a lowercase word, or nil when the
    /// word should stay as typed.
    private func restoredSpelling(of lowered: String) -> String? {
        guard let accented = bestAccentedByKey[Self.fold(lowered)],
            accented.word != lowered else {
            return nil
        }
        // A spelling that differs only by œ/æ is never a word of its own
        // (coeur/cœur): always restore, whatever the corpus frequencies say.
        let ligatureOnly = Self.unligature(accented.word) == lowered
        let typedFrequency = frequencyByWord[lowered] ?? 0
        guard ligatureOnly || accented.frequency > typedFrequency * Self.restoreThreshold
        else {
            return nil
        }
        return accented.word
    }

    /// Longest first, so "jusquici" splits as jusqu + ici, not j + usquici.
    private static let elidingPrefixes = [
        "jusqu", "lorsqu", "puisqu", "quoiqu", "qu", "c", "d", "j", "l", "m", "n", "s", "t",
    ]
    private static let elisionStarts: Set<Character> = ["a", "e", "i", "o", "u", "y", "h"]
    /// How much rarer than the word after the apostrophe a typed word must
    /// be to count as a contraction missing its apostrophe. "jaime" is 340×
    /// rarer than "aime"; real words sit well below 200× ("lune" vs "une"
    /// 136×, "quelle" vs "elle" 11×).
    private static let elisionRatio: UInt64 = 200

    /// "cest" → "c'est", "jai" → "j'ai", "cetait" → "c'était". The corpus
    /// splits contractions at the apostrophe, so they have no entries of
    /// their own and are rebuilt from prefix + word.
    private func elided(_ lowered: String) -> String? {
        let key = Self.fold(lowered)
        // A word that is common once accented ("tete" → "tête") is that word,
        // not a contraction ("t'été").
        let typedFrequency = [lowered, restoredSpelling(of: lowered)]
            .compactMap { $0.flatMap { frequencyByWord[$0] } }
            .max() ?? 0
        for prefix in Self.elidingPrefixes where key.hasPrefix(prefix) {
            let rest = String(key.dropFirst(prefix.count))
            guard let first = rest.first, Self.elisionStarts.contains(first) else { continue }
            let restWord = restoredSpelling(of: rest) ?? rest
            guard let restFrequency = frequencyByWord[restWord],
                restFrequency > max(typedFrequency * Self.elisionRatio, 1000) else {
                continue
            }
            return prefix + "'" + restWord
        }
        return nil
    }

    /// Restores a whole line of text: every word goes through `accentuate`,
    /// and straight double quotes become guillemets with non-breaking spaces
    /// («\u{00A0}ainsi\u{00A0}»).
    public func restore(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var word = ""
        var insideQuote = false
        func flushWord() {
            if !word.isEmpty {
                result += accentuate(word)
                word = ""
            }
        }
        for character in text {
            if character.isLetter {
                word.append(character)
            } else if character == "\"" {
                flushWord()
                result += insideQuote ? "\u{00A0}»" : "«\u{00A0}"
                insideQuote.toggle()
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()
        return result
    }

    // MARK: - Suggestions

    /// A word the dictionary doesn't know, where it is in the text, and the
    /// closest known words to offer instead.
    public struct Misspelling: Equatable, Sendable {
        public let range: Range<String.Index>
        public let word: String
        public let suggestions: [String]
    }

    /// Whether the dictionary knows `word`. Contractions and compounds
    /// ("qu'il", "peut-être") are known when each part is.
    public func isKnown(_ word: String) -> Bool {
        let key = Self.fold(word)
        if key.isEmpty || keys.contains(key) { return true }
        let parts = word.split(whereSeparator: { Self.joiners.contains($0) })
        guard parts.count > 1 else { return false }
        return parts.allSatisfy { $0.count == 1 || keys.contains(Self.fold(String($0))) }
    }

    /// Known words within a few typing mistakes of an unknown `word` (a
    /// missing, extra, wrong or swapped letter each count as one), closest
    /// and most frequent first: "ajurdui" → "aujourd'hui". Empty when the
    /// word is known or too short to guess from.
    public func suggestions(for word: String, limit: Int = 5) -> [String] {
        guard limit > 0, !isKnown(word) else { return [] }
        let typedKey = Self.fold(word)
        let typed = Array(typedKey.unicodeScalars)
        let typedPhonetic = Array(Self.phonetic(typedKey).unicodeScalars)
        let maxDistance = switch typed.count {
        case ..<3: 0
        case 3...4: 1
        case 5...6: 2
        default: 3
        }
        guard maxDistance > 0 else { return [] }

        var scored: [(score: Double, word: String)] = []
        for (index, entry) in entries.enumerated() where !entry.word.hasSuffix("'") {
            // Spelled-as-heard mistakes ("bocoup" for "beaucoup") are far
            // apart in letters but close in sound, so the closer wins. Sound
            // keys are coarse, so they get one edit less: gibberish would
            // otherwise sound like something.
            let spelled = Self.editDistance(typed, entryScalars[index], limit: maxDistance)
            let heard = Self.editDistance(
                typedPhonetic, entryPhonetics[index], limit: maxDistance - 1)
            guard let distance = [spelled, heard].compactMap({ $0 }).min() else { continue }
            // Each edit costs more than a 10× frequency difference is worth
            // (log10 * 0.5), so closeness dominates and frequency breaks ties.
            let score = Double(distance) - 0.5 * log10(Double(max(entry.frequency, 1)))
            scored.append((score, entry.word))
        }
        scored.sort { $0.score < $1.score }

        var seenKeys: Set<String> = []
        var result: [String] = []
        for candidate in scored {
            // Map corpus typos ("etre") to the spelling they stand for, and
            // offer one spelling per folded key ("écoute", not also "ecoute").
            let suggestion = accentuate(candidate.word)
            guard seenKeys.insert(Self.fold(suggestion)).inserted else { continue }
            result.append(Self.matchCase(of: word, to: suggestion))
            if result.count == limit { break }
        }
        return result
    }

    /// Unknown words in `text` with their suggestions, in text order. Words
    /// with no close match are left out: there is nothing to offer.
    public func misspellings(in text: String, limit: Int = 5) -> [Misspelling] {
        var result: [Misspelling] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }
            // A word is a run of letters, joined across ' ’ - when a letter follows.
            let start = index
            var end = index
            while end < text.endIndex {
                if text[end].isLetter {
                    end = text.index(after: end)
                } else if Self.joiners.contains(text[end]),
                    case let next = text.index(after: end), next < text.endIndex,
                    text[next].isLetter {
                    end = next
                } else {
                    break
                }
            }
            let word = String(text[start..<end])
            let suggestions = suggestions(for: word, limit: limit)
            if !suggestions.isEmpty {
                result.append(Misspelling(range: start..<end, word: word, suggestions: suggestions))
            }
            index = end
        }
        return result
    }

    /// A rough French sound key for a folded word: letter groups that sound
    /// alike collapse to one spelling, silent letters drop.
    /// "beaucoup" and "bocoup" both give "bokoup".
    static func phonetic(_ key: String) -> String {
        var text = key
        for (group, sound) in phoneticGroups {
            text = text.replacingOccurrences(of: group, with: sound)
        }
        var result = ""
        for character in text where character != "h" {
            if result.last != character { result.append(character) }
        }
        while result.count > 2, let last = result.last, "stdxpe".contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Ordered: longer groups must rewrite before their parts ("eau" before "au").
    private static let phoneticGroups: [(String, String)] = [
        ("eau", "o"), ("au", "o"), ("ph", "f"), ("qu", "k"), ("ck", "k"),
        ("c", "k"), ("ai", "e"), ("ei", "e"), ("ez", "e"), ("er", "e"),
        ("em", "an"), ("en", "an"), ("am", "an"), ("y", "i"), ("w", "v"),
    ]

    /// `text` with each misspelling's range replaced by the chosen word.
    /// The misspellings must come from `misspellings(in: text)`.
    public static func applying(
        _ corrections: [(misspelling: Misspelling, replacement: String)], to text: String
    ) -> String {
        var result = text
        // Back to front, so earlier ranges stay valid.
        for correction in corrections.sorted(by: {
            $0.misspelling.range.lowerBound > $1.misspelling.range.lowerBound
        }) {
            result.replaceSubrange(correction.misspelling.range, with: correction.replacement)
        }
        return result
    }

    /// Optimal string alignment distance (Levenshtein plus adjacent swaps),
    /// or nil as soon as it must exceed `limit`.
    static func editDistance(
        _ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int
    ) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    /// Transfers the case pattern of what the user typed onto the dictionary
    /// word: all-caps stays all-caps, a capitalized first letter stays
    /// capitalized ("Ecole" → "École"), anything else comes back lowercase.
    static func matchCase(of source: String, to target: String) -> String {
        if source.count > 1, source == source.uppercased(with: locale) {
            return target.uppercased(with: locale)
        }
        if let first = source.first, first.isUppercase {
            return target.prefix(1).uppercased(with: locale) + target.dropFirst()
        }
        return target
    }
}
