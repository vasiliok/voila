import Voila
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage: voila complete <prefix> [-n N]   ranked completions for a prefix
       voila restore <text...>          restore accents in text
       voila suggest <word>             close matches for a misspelled word
       voila                            interactive mode
"""

let completer: Completer
do {
    completer = try Completer.french()
} catch {
    fail("voila: cannot load dictionary: \(error.localizedDescription)")
}

var args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "complete":
    args.removeFirst()
    var limit = 10
    if let i = args.firstIndex(of: "-n") {
        guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
            fail("voila: -n expects a positive number\n\(usage)")
        }
        limit = n
        args.removeSubrange(i...(i + 1))
    }
    guard args.count == 1 else { fail(usage) }
    for completion in completer.complete(args[0], limit: limit) {
        print("\(completion.word)\t\(completion.frequency)")
    }

case "restore":
    args.removeFirst()
    guard !args.isEmpty else { fail(usage) }
    print(completer.restore(args.joined(separator: " ")))

case "suggest":
    args.removeFirst()
    guard args.count == 1 else { fail(usage) }
    let suggestions = completer.suggestions(for: args[0])
    if !suggestions.isEmpty {
        print(suggestions.joined(separator: "\n"))
    } else if completer.isKnown(args[0]) {
        print("\(completer.accentuate(args[0])) (known word)")
    } else {
        print("no suggestions")
    }

case "-h", "--help":
    print(usage)

case .some:
    fail(usage)

case nil:
    print("Voilà — tapez du texte sans accents, entrée pour restaurer (exit pour quitter)")
    while true {
        print("fr> ", terminator: "")
        guard let line = readLine(), line != "exit" else { break }
        guard !line.isEmpty else { continue }
        let restored = completer.restore(line)
        print("→ \(restored)")
        for misspelling in completer.misspellings(in: restored) {
            print("  ? \(misspelling.word) → " + misspelling.suggestions.joined(separator: ", "))
        }
        if let lastWord = line.split(whereSeparator: { !$0.isLetter }).last {
            let completions = completer.complete(String(lastWord), limit: 5)
            if completions.count > 1 {
                print("  … " + completions.map(\.word).joined(separator: "  "))
            }
        }
    }
}
