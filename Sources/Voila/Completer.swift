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
    /// Combined frequency of every spelling that folds to a key.
    private let frequencyByKey: [String: UInt64]
    /// log10 of the corpus size, to turn frequencies into probabilities.
    private let log10Total: Double

    /// The user's own rules, by folded typed word: "ajurdui" → "aujourd'hui".
    public private(set) var variants: [String: String] = [:]
    /// Folded words of every variant's replacement, which count as known.
    private var variantWords: Set<String> = []

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
        self.frequencyByKey = built.reduce(into: [:]) { $0[$1.key, default: 0] += $1.frequency }
        self.log10Total = log10(Double(max(built.reduce(0) { $0 + $1.frequency }, 1)))
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
    public static func fold(_ word: String) -> String {
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

    // MARK: - User variants

    /// Replaces the user's own rules. Each typed word, matched ignoring case
    /// and accents, is always written as its replacement, ahead of the
    /// dictionary; replacements are never flagged as misspellings. A rule
    /// whose replacement equals the typed word just adds that word.
    public mutating func setVariants(_ rules: [(typed: String, replacement: String)]) {
        variants = [:]
        variantWords = []
        for rule in rules {
            let key = Self.fold(rule.typed.trimmingCharacters(in: .whitespaces))
            let replacement = rule.replacement.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !replacement.isEmpty else { continue }
            variants[key] = replacement
            for word in replacement.split(whereSeparator: { !$0.isLetter && !Self.joiners.contains($0) }) {
                variantWords.insert(Self.fold(String(word)))
            }
        }
    }

    /// The user's replacement for `word`, in the case it was typed.
    private func variant(for word: String) -> String? {
        variants[Self.fold(word)].map { Self.matchCase(of: word, to: $0) }
    }

    // MARK: - Completion

    /// Words starting with `prefix` (accent-insensitively), most frequent
    /// first. Unaccented misspellings the corpus contains are dropped in
    /// favor of their accented form. Results carry the case of the typed
    /// prefix: "Ecol" → "École".
    public func complete(_ prefix: String, limit: Int = 10) -> [Completion] {
        guard limit > 0, !prefix.isEmpty else { return [] }
        let key = Self.fold(prefix)
        // The user's own words come first: they asked for them.
        let own = Set(variants.values).filter { Self.fold($0).hasPrefix(key) }.sorted()
        var matches: [Entry] = []
        for i in lowerBound(of: key)..<entries.count {
            guard entries[i].key.hasPrefix(key) else { break }
            // An entry its own restoration would rewrite is a typo variant.
            guard accentuate(entries[i].word) == entries[i].word else { continue }
            matches.append(entries[i])
        }
        matches.sort { $0.frequency > $1.frequency }
        let ownCompletions = own.map {
            Completion(word: Self.matchCase(of: prefix, to: $0), frequency: 0)
        }
        let dictionary = matches.lazy
            .filter { entry in !own.contains { Self.fold($0) == entry.key } }
            .map { Completion(word: Self.matchCase(of: prefix, to: $0.word), frequency: $0.frequency) }
        return Array((ownCompletions + dictionary).prefix(limit))
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
        if let own = variant(for: word) { return own }
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
        if key.isEmpty || keys.contains(key) || variantWords.contains(key)
            || variants[key] != nil { return true }
        let parts = word.split(whereSeparator: { Self.joiners.contains($0) })
        guard parts.count > 1 else { return false }
        return parts.allSatisfy { $0.count == 1 || keys.contains(Self.fold(String($0))) }
    }

    /// Known words within a few typing mistakes of an unknown `word` (a
    /// missing, extra, wrong or swapped letter each count as one), and the
    /// words it may be several of run together, most likely first:
    /// "ajurdui" → "aujourd'hui", "cestbon" → "c'est bon". A known word
    /// gets suggestions only when it is probably a typo of a far more common
    /// one ("fame" → "femme"). Empty when there is nothing to offer.
    public func suggestions(for word: String, limit: Int = 5) -> [String] {
        guard limit > 0 else { return [] }
        if let own = variant(for: word) { return own == word ? [] : [own] }
        let typedKey = Self.fold(word)
        // The user's own words are never suspect.
        if variantWords.contains(typedKey) { return [] }
        // Each candidate is scored as log10 of its probability: corpus
        // frequency, minus a penalty per edit or per extra word.
        var scored: [Candidate]
        if isKnown(word) {
            scored = commonNeighbours(of: word)
        } else {
            scored = corrections(of: typedKey)
            if let split = segmentation(of: typedKey) {
                scored.append(split)
            }
        }
        scored.sort { $0.score > $1.score }

        var seenKeys: Set<String> = []
        var result: [String] = []
        for candidate in scored {
            // Map corpus typos ("etre") to the spelling they stand for, and
            // offer one spelling per folded key ("écoute", not also "ecoute").
            let suggestion = candidate.isPhrase ? candidate.text : accentuate(candidate.text)
            guard seenKeys.insert(Self.fold(suggestion)).inserted else { continue }
            result.append(Self.matchCase(of: word, to: suggestion))
            if result.count == limit { break }
        }
        return result
    }

    private struct Candidate {
        let score: Double
        let text: String
        let isPhrase: Bool
        var frequency: UInt64 = 0
    }

    /// A known word this rare, typed without accents, is suspect when a
    /// word one mistake away is `dominanceRatio` times more common:
    /// "fame" (241) next to "femme" (233 000).
    private static let suspectBelow: UInt64 = 1000
    private static let dominanceRatio: UInt64 = 200

    /// Far more common words one mistake (or the same sound) away from a
    /// rare known word; empty for words that are common or typed with
    /// accents, which the user evidently meant.
    private func commonNeighbours(of word: String) -> [Candidate] {
        let lowered = word.lowercased(with: Self.locale)
        let key = Self.fold(lowered)
        guard lowered == key, key.count >= 3,
            let frequency = frequencyByKey[key], frequency < Self.suspectBelow else { return [] }
        return corrections(of: key, maxDistance: 1).filter {
            $0.frequency >= frequency * Self.dominanceRatio
        }
    }

    /// Ten times rarer is worth one decade of log probability; one typing
    /// mistake costs two, so closeness dominates and frequency breaks ties.
    private static let editPenalty = 2.0
    /// Splitting into one more word costs this much, so a single word wins
    /// unless the split reads clearly better ("merci" over "mer si").
    private static let splitPenalty = 1.0
    /// Rarer corpus entries are mostly fragments ("aujourd") and noise, not
    /// words to build phrases from.
    private static let minimumPartFrequency: UInt64 = 500

    private func logProbability(_ frequency: UInt64) -> Double {
        log10(Double(max(frequency, 1))) - log10Total
    }

    private func corrections(of typedKey: String, maxDistance limit: Int? = nil) -> [Candidate] {
        let typed = Array(typedKey.unicodeScalars)
        let typedPhonetic = Array(Self.phonetic(typedKey).unicodeScalars)
        let maxDistance = limit ?? Self.allowedMistakes(forLength: typed.count)
        guard maxDistance > 0 else { return [] }

        var result: [Candidate] = []
        for (index, entry) in entries.enumerated() where !entry.word.hasSuffix("'") {
            // Spelled-as-heard mistakes ("bocoup" for "beaucoup") are far
            // apart in letters but close in sound, so the closer wins. Sound
            // keys are coarse, so they get one edit less: gibberish would
            // otherwise sound like something.
            let spelled = Self.editDistance(typed, entryScalars[index], limit: maxDistance)
            let heard = Self.editDistance(
                typedPhonetic, entryPhonetics[index], limit: maxDistance - 1)
            guard let distance = [spelled, heard].compactMap({ $0 }).min() else { continue }
            let score = logProbability(entry.frequency) - Self.editPenalty * Double(distance)
            result.append(Candidate(
                score: score, text: entry.word, isPhrase: false, frequency: entry.frequency))
        }
        return result
    }

    /// Short words allow fewer mistakes: one wrong letter in three makes
    /// almost anything match.
    private static func allowedMistakes(forLength length: Int) -> Int {
        switch length {
        case ..<3: 0
        case 3...4: 1
        case 5...6: 2
        default: 3
        }
    }

    /// The most likely way to read `typedKey` as several known words typed
    /// without spaces: "silvousplait" → "s'il vous plaît". Nil when no split
    /// into two or more frequent words exists.
    private func segmentation(of typedKey: String) -> Candidate? {
        let letters = Array(typedKey)
        guard (4...40).contains(letters.count) else { return nil }
        // best[i]: the best reading of the first i letters.
        var best = [(score: Double, words: [String])?](repeating: nil, count: letters.count + 1)
        best[0] = (0, [])
        for end in 1...letters.count {
            // The whole input as one piece isn't a split.
            for start in max(0, end - 25)..<end where end - start < letters.count {
                guard let before = best[start],
                    let part = phrasePart(String(letters[start..<end])) else { continue }
                let score = before.score + part.score
                    - (before.words.isEmpty ? 0 : Self.splitPenalty)
                if score > best[end]?.score ?? -.infinity {
                    best[end] = (score, before.words + [part.word])
                }
            }
        }
        guard let reading = best[letters.count], reading.words.count > 1 else { return nil }
        return Candidate(
            score: reading.score, text: reading.words.joined(separator: " "), isPhrase: true)
    }

    /// One word of a split, restored ("cest" → "c'est"), with its log
    /// probability; nil for single letters other than "a" and "y", and for
    /// fragments too rare to trust.
    private func phrasePart(_ key: String) -> (word: String, score: Double)? {
        guard key.count > 1 || key == "a" || key == "y" else { return nil }
        let word = accentuate(key)
        // A rebuilt contraction has no frequency of its own: "c'est" is as
        // common as "est".
        let counted = word.split(separator: "'").last.map(String.init) ?? word
        let frequency = max(frequencyByKey[Self.fold(counted)] ?? 0, frequencyByWord[word] ?? 0)
        guard frequency >= Self.minimumPartFrequency else { return nil }
        return (word, logProbability(frequency))
    }

    /// Unknown words in `text` with their suggestions, in text order. Words
    /// with no close match are left out: there is nothing to offer. A word
    /// typed in two pieces ("aujour dhui") is reported once, spanning both
    /// pieces, with the joined word first.
    public func misspellings(in text: String, limit: Int = 5) -> [Misspelling] {
        let words = Self.words(in: text)
        var result: [Misspelling] = []
        var index = 0
        while index < words.count {
            let (range, word) = words[index]
            guard !isKnown(word) else {
                let alternatives = suggestions(for: word, limit: limit)
                if !alternatives.isEmpty {
                    result.append(Misspelling(range: range, word: word, suggestions: alternatives))
                }
                index += 1
                continue
            }
            if index + 1 < words.count, let joined = joinedWord(words[index], words[index + 1], in: text) {
                let span = range.lowerBound..<words[index + 1].range.upperBound
                result.append(Misspelling(
                    range: span, word: String(text[span]),
                    suggestions: joinedFirst(joined, suggestions(for: word, limit: limit), limit)))
                index += 2
                continue
            }
            if index > 0, !result.contains(where: { $0.range.overlaps(words[index - 1].range) }),
                let joined = joinedWord(words[index - 1], words[index], in: text) {
                let span = words[index - 1].range.lowerBound..<range.upperBound
                result.append(Misspelling(
                    range: span, word: String(text[span]),
                    suggestions: joinedFirst(joined, suggestions(for: word, limit: limit), limit)))
                index += 1
                continue
            }
            let suggestions = suggestions(for: word, limit: limit)
            if !suggestions.isEmpty {
                result.append(Misspelling(range: range, word: word, suggestions: suggestions))
            }
            index += 1
        }
        return result
    }

    /// The known word two neighbours make when the space between them is
    /// removed ("aujour" + "dhui" → "aujourd'hui"), in the case of the first.
    private func joinedWord(
        _ first: (range: Range<String.Index>, word: String),
        _ second: (range: Range<String.Index>, word: String),
        in text: String
    ) -> String? {
        guard text[first.range.upperBound..<second.range.lowerBound] == " " else { return nil }
        let key = Self.fold(first.word + second.word)
        guard (frequencyByKey[key] ?? 0) >= Self.minimumPartFrequency else { return nil }
        return accentuate(first.word + second.word)
    }

    private func joinedFirst(_ joined: String, _ others: [String], _ limit: Int) -> [String] {
        Array(([joined] + others.filter { $0 != joined }).prefix(limit))
    }

    /// Runs of letters, joined across ' ’ - when a letter follows.
    private static func words(in text: String) -> [(range: Range<String.Index>, word: String)] {
        var result: [(range: Range<String.Index>, word: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var end = index
            while end < text.endIndex {
                if text[end].isLetter {
                    end = text.index(after: end)
                } else if joiners.contains(text[end]),
                    case let next = text.index(after: end), next < text.endIndex,
                    text[next].isLetter {
                    end = next
                } else {
                    break
                }
            }
            result.append((start..<end, String(text[start..<end])))
            index = end
        }
        return result
    }

    /// A rough French sound key for a folded word: letter groups that sound
    /// alike collapse to one spelling, silent letters drop.
    /// "beaucoup" and "bocoup" both give "bokoup".
    static func phonetic(_ key: String) -> String {
        // Doubled letters first, so "femme" reads like "feme" before "em"
        // is rewritten.
        var text = ""
        for character in key where text.last != character {
            text.append(character)
        }
        // -er and -ez sound like é only at the end ("parler"), not in "ferme".
        if text.hasSuffix("er") || text.hasSuffix("ez") {
            text = String(text.dropLast(2)) + "e"
        }
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
        ("c", "k"), ("ai", "e"), ("ei", "e"),
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
