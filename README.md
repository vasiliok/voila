# AutoFrench

Swift library + CLI that fixes French special characters as you type and
completes words. Type plain ASCII, get proper French:

- **Accent restoration** — `ca va etre genial` → `ça va être génial`,
  `coeur` → `cœur`, `francais` → `français`. Handles à â æ ç é è ê ë î ï ô œ
  ù û ü ÿ and their uppercase forms (case is preserved: `Ecole` → `École`).
  Straight double quotes become guillemets with non-breaking spaces:
  `"bonjour"` → `« bonjour »`.
- **Accent-insensitive completion** — `ecol` suggests `école` first, ranked by
  corpus frequency.

Words already spelled correctly are never rewritten, and unknown words pass
through unchanged.

## Build & test

```sh
swift build
swift test
```

## Usage

```sh
swift run autofrench restore "ca va etre genial"
# → ça va être génial

swift run autofrench complete ecol -n 5
# → école, écoles, écolo, ...

swift run autofrench      # interactive: restores each line as you enter it
```

As a library:

```swift
import AutoFrench

let completer = try Completer.french()
completer.accentuate("francais")        // "français"
completer.restore("ca va etre genial")  // "ça va être génial"
completer.complete("ecol", limit: 5)    // [Completion(word: "école", ...), ...]
```

## Dictionary

Bundles the 50k-word French frequency list from
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
(derived from OpenSubtitles, CC-BY-SA 4.0).
