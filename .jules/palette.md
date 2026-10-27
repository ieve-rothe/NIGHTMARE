# Palette's UX Journal - Critical Learnings

This journal documents critical, high-impact CLI UX and terminal design discoveries specific to this codebase.

## 2026-10-26 - Damerau-Levenshtein "Did You Mean?" Command and Flag Suggestions
Discovery: When users mistype slash commands (`/clera`, `/thnk`, `/modle`) or CLI flags (`--systm`), traditional CLIs reject them with a generic error and a wall of help text. Adjacent character transposition (Damerau distance) and subsequence prefixes are the most frequent typographical errors in interactive shells.
Action: Integrate `Salamander::Fuzzy.find_closest` in REPL unknown command routing and CLI `OptionParser::InvalidOption` rescue handlers to offer clear `💡 Did you mean '<suggestion>'?` prompts. Maintain a single source of truth for recognized options/commands to keep suggestions up to date automatically.
