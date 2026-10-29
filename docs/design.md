# corvus-regex-ecma262-pas: design

An outline of the library as it is: what it offers, how the engine is built and why, and how it is tested and
measured. The [getting-started page](getting-started.md) shows how to use it.

## 1. What it is

An Object Pascal regular expression engine with ECMA-262's grammar and answers (ECMAScript 2025), over UTF-8
(`UTF8String`, `TUtf8Text`) and UTF-16 (`UnicodeString`). It is a port of the corvus-regex-ecma262 Rust crate, built
and tested with Free Pascal 3.2.2, written to compile with Delphi too, and with no dependencies beyond the compiler's
RTL.

**Why ECMA-262.** JSON Schema, OpenAPI and many wire formats specify their patterns as ECMAScript regular
expressions. Delphi's `TRegEx` (PCRE) and TRegExpr have their own grammars and their own meaning for `\d`, `\w`, `\s`,
`.` and case folding, so a translation to them can never be exact. An engine that reads ECMA-262 directly, held to
V8's answers over a large data set (section 6), needs no translation.

## 2. Public surface

**Names.** A program names one unit, `Corvus.Ecma262.RegularExpressions`. `CompileEcmaRegex` returns an `IEcmaRegex`,
a reference-counted interface, with `IsMatch`, `Match`, `Matches` (a `for ... in` loop), `Count`, `Replace`,
`ReplaceAll`, `Split` and `Exec`, each taking the position as `StartIndex` where JavaScript keeps `lastIndex`.
Positions are 1-based, as Pascal indexes a string. A match is a `TEcmaMatch` (`TEcmaMatchW` over UTF-16) with its
groups.

**Flags.** ECMA-262's, as a string or a `TEcmaRegexFlags` set, and nothing else.

**Edition and Unicode version.** By default a pattern is read with today's grammar (`ereCurrent`) and V8's version of
Unicode (`eruDefault`, 17 today). A `TEcmaRegexOptions` overrides either, independently, beside the match timeout:
`ereEs2020` is the grammar JSON Schema 2020-12 names, and the versions are `eru13`, `eru17`, `eru18` and `eruLatest`.
Both are resolved when the pattern is compiled.

**Errors.** A pattern that does not compile raises `EEcmaRegexSyntax` (with `Reason` and `Offset`), `EEcmaRegexFlags`
or `EEcmaRegexTooLarge`; `TryCompileEcmaRegex` gives a `TEcmaRegexError` in place of raising. A match that reaches its
limit raises `EEcmaRegexTimeout` or `EEcmaRegexMemory`; text that is not UTF-8 raises `EEcmaRegexEncoding`.

**ECMA-262 algorithms.** `Replace` substitutes as `GetSubstitution` does, replacing every match only with `g`;
`ReplaceAll` always does. `Split` follows `RegExp.prototype[Symbol.split]`.

**Input.** A `UTF8String` (or a `RawByteString`) is UTF-8, checked before it is read and refused when it is not, never
read as U+FFFD; `TUtf8Text.Create` checks a text once. A `UnicodeString` is UTF-16, lone surrogates and all. `Exec`
also takes a pointer and a length in either encoding. Nothing is transcoded.

**Allocation.** A warm `IsMatch`, `Count` and `Exec`, which writes a match's groups into a `TEcmaCaptures`, ask for no
memory: the working memory is a thread variable, grown to what a match needs and kept up to a cap, with no pool and no
lock (`ReleaseEcmaRegexThreadState` frees a thread's).

**Limits.** No pattern and no text can hang a program or overflow the stack.

- A match timeout per pattern, or a process-wide default (`SetDefaultEcmaRegexMatchTimeout`), bounds every match and
  caps its backtracking memory.
- Size limits on the pattern are deterministic.
- The matcher keeps its choices on a stack of its own, and the parser's and compiler's recursion, bounded by
  `MaxNesting`, fits a thread's stack of 1 MB, Windows' default.

## 3. Engine

**One matcher, two encodings.** The matcher is one include file (`Matcher.inc`), included by the `Utf8` and `Utf16`
units, so the compiler builds a copy for each encoding with no indirect call in the loop. Matching by UTF-16 code unit
over UTF-8 places the position between the halves of a four-byte character at its third byte.

**The matcher.** A backtracking matcher over a flat program, with V8's quick check of the next character at each
choice. A memo of the places that failed, taken into use once a match has made sixty-four steps a position, makes a
pattern without backreferences linear in the text. The clock is read every 4,096 steps.

**Where a match can start.** The search layer is the Rust crate's. Free Pascal has no vector intrinsics, so the `Swar`
unit writes the kernels as inline assembler for x86-64: SSE2 for one to four bytes, ranges of bytes, a pair of
positions and a UTF-16 unit; SSSE3 for Teddy; and AVX2, found when the program starts, for one byte, a literal's two
rarest bytes and the skip window. Every kernel has a SWAR fallback (eight bytes of a `UInt64` at a time) or a unit at a
time, which any other processor takes, and the tests pass with each fallback forced. A literal at a fixed or bounded
distance opens windows of starts.

**The automata.** For a pattern that needs no backtracking: an automaton over ASCII for a test from the start, an
anchored leftmost-first automaton for where a match from a start ends, a reverse automaton for the terms before a
window's anchors, and a forward automaton for a pattern with no literal. Each is built on first use, with its states
bounded.

## 4. Generated tables

The Unicode tables of each version (the units `Ucd<major>`, with `Strings<major>.inc`) and the property names of
ECMAScript 2020 (`Es2020`) are written from the Rust crate's by `tools/unicode`, and CI checks them against the crate,
so the engines carry the same tables. The API reference (`docs/api.md`) is generated from the unit's interface by
`tools/docs/gen-api.ps1`, which CI checks is current.

## 5. Targets and layout

Free Pascal 3.2.2 on Linux (x64 and arm64), macOS and Windows; the assembler kernels are x86-64's, with their fallbacks
elsewhere. A release is a source archive.

- `src/`: the units and include files; `tests/`: the tests.
- `tools/build.ps1`: the build; `tools/dataset`: the test-data runner; `tools/unicode`: the tables' writers;
  `tools/docs`: the getting-started runner and the API reference's generator; `tools/benchmarks`: the harness.

## 6. Testing

**The ECMA-262 test data.** [`ecma262-regex-test-data`](https://github.com/corvus-dotnet/ecma262-regex-test-data)
holds V8's answers: validity under each grammar, `test` answers, the positions of `exec`, the global search, `y`,
`replace` and `split`, and every `exec` call of test262. `bin/run` runs all of it over UTF-8 and UTF-16, with none
wrong, refused or at a limit: on every change, again with the memo from the first step, and on Linux as the data's own
scripts write it for Unicode 13 and 18 and for ECMAScript 2020.

**Other tests.** Tests over the API and over the searches at every position, each kernel and its fallback; a test that a
warm match asks for no memory, counted by a memory manager of its own; the getting-started page's programs; and the
stack probe, which asks 964 deep, wide and long patterns through every call, each on a thread with a stack of 4 MB and
of 2 MB, none overflowing.

## 7. Benchmarks

The harness image, `ghcr.io/corvus-dotnet/corvus-regex-ecma262-pas`, runs the Industry workloads of
`dotnet/performance` over this library (UTF-8 and UTF-16), TRegExpr (over UTF-8 and UTF-16) and V8. The published
figures are on [the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs every engine's
image each night; this repository publishes none of its own.

Three rows are not like for like with an engine that is not ECMA-262's, as the price of its rules under u: `.*` (`.`
excludes CR, so the CRLF text has more matches), `Sher[a-z]+|Hol[a-z]+` under i (the search must also find the long s
and the Kelvin sign), and `[a-q][^u-z]{13}x` (a supplementary character is two units, so the distance to the `x` is
not fixed).

## 8. Differences a Pascal user will meet

- The grammar is ECMA-262's, not PCRE's or TRegExpr's: `(?i:...)` groups but no `(?i)` prefix, no possessive
  quantifiers, atomic groups, `\A`, `\z` or recursion.
- Neither `TRegEx` nor TRegExpr limits a match's time. Here a pattern without a backreference is linear in the text,
  and a pattern from outside is given a timeout.
- `Replace` replaces every match only with the `g` flag; `ReplaceAll` always does.

The [getting-started page](getting-started.md) has the full list.
