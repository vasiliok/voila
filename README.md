# AutoFrench

Swift library + CLI that fixes French special characters as you type and
completes words. Type plain ASCII, get proper French:

- **Accent restoration** — `ca va etre genial` → `ça va être génial`,
  `coeur` → `cœur`, `francais` → `français`. Handles à â æ ç é è ê ë î ï ô œ
  ù û ü ÿ and their uppercase forms (case is preserved: `Ecole` → `École`).
  Straight double quotes become guillemets with non-breaking spaces:
  `"bonjour"` → `« bonjour »`.
- **Apostrophes and hyphens** — `aujourdhui` → `aujourd'hui`, `peutetre` →
  `peut-être`, and contractions typed without the apostrophe: `cest` →
  `c'est`, `jai` → `j'ai`, `cetait` → `c'était`. Real words that look like
  contractions (`lune`, `quelle`, `son`) are left alone.
- **Typo suggestions** — for words the dictionary doesn't know, the closest
  known words by spelling or by sound: `ajurdui` → `aujourd'hui`,
  `bonjur` → `bonjour`, `bocoup` → `beaucoup`.
- **Accent-insensitive completion** — `ecol` suggests `école` first, ranked by
  corpus frequency.

Words already spelled correctly are never rewritten, and unknown words are
only changed when you pick a suggestion.

## Build & test

```sh
swift build
swift test   # library: restoration, elision, suggestions; app: shortcuts
```

## Usage

```sh
swift run autofrench restore "ca va etre genial"
# → ça va être génial

swift run autofrench complete ecol -n 5
# → école, écoles, écolo, ...

swift run autofrench suggest ajurdui
# → aujourd'hui, aurai, autrui, ...

swift run autofrench      # interactive: restores each line, suggests for typos
```

## Menu bar app

`AutoFrench.app` sits in the menu bar (an "é" icon) and adds
**Restore French Accents** to the right-click **Services** menu of every app:
select text, right-click, pick it, and the selection is replaced in place.

```sh
scripts/build-app.sh            # → build/AutoFrench.app
scripts/build-app.sh --install  # also copy to ~/Applications and launch
```

**Hotkey:** select text anywhere and press **⌃⌥F** to fix it in place. When
the selection has a word the dictionary doesn't know, a menu pops up at the
selection with suggestions: pick one, or Esc / *Keep* to leave the word. Change
the shortcut in the menu's *Settings…* (click the shortcut, press new keys).
The hotkey copies and pastes for you, so macOS asks once for Accessibility
permission (System Settings → Privacy & Security → Accessibility). The build
script signs with your Apple Development certificate when you have one, which
keeps that permission across rebuilds.

The menu also has *Restore Accents in Clipboard*, *Launch at Login* and help.
If the Services item doesn't show up, enable it (and optionally give it a
shortcut) in System Settings → Keyboard → Keyboard Shortcuts → Services → Text.

As a library:

```swift
import AutoFrench

let completer = try Completer.french()
completer.accentuate("francais")        // "français"
completer.restore("ca va etre genial")  // "ça va être génial"
completer.complete("ecol", limit: 5)    // [Completion(word: "école", ...), ...]
completer.suggestions(for: "ajurdui")   // ["aujourd'hui", "aurai", ...]
completer.misspellings(in: "mersi bocoup")  // unknown words, ranges, suggestions
```

## Dictionary

Bundles the 50k-word French frequency list from
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
(derived from OpenSubtitles, CC-BY-SA 4.0).
