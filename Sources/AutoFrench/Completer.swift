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
            if word != entry.key,
                frequency > (bestAccented[entry.key]?.frequency ?? 0) {
                bestAccented[entry.key] = entry
            }
        }
        built.sort { $0.key < $1.key }
        self.entries = built
        self.bestAccentedByKey = bestAccented
        self.frequencyByWord = frequencies
    }

    /// Loads the bundled French frequency dictionary (50k words).
    public static func french() throws -> Completer {
        guard let url = Bundle.module.url(forResource: "fr_50k", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
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
    /// diacritics and the ligatures Unicode folding leaves alone.
    static func fold(_ word: String) -> String {
        unligature(word.lowercased(with: locale))
            .folding(options: .diacriticInsensitive, locale: locale)
    }

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
        guard let accented = bestAccentedByKey[Self.fold(word)],
            accented.word != lowered else {
            return word
        }
        // A spelling that differs only by œ/æ is never a word of its own
        // (coeur/cœur): always restore, whatever the corpus frequencies say.
        let ligatureOnly = Self.unligature(accented.word) == lowered
        let typedFrequency = frequencyByWord[lowered] ?? 0
        guard ligatureOnly || accented.frequency > typedFrequency * Self.restoreThreshold
        else {
            return word
        }
        return Self.matchCase(of: word, to: accented.word)
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
