# corvus-regex-ecma262-pas

Regular expressions with the grammar and the answers of ECMA-262, the `RegExp` of JavaScript, for Object Pascal (Free
Pascal 3.2.2 and later).

- Every flag: `d`, `g`, `i`, `m`, `s`, `u`, `v` and `y`, with the grammar of each. Without `u` or `v` a pattern is
  read by the Annex B grammar and matched by UTF-16 code unit, as ECMA-262 matches it; with them, by code point. The
  `v` flag has nested classes, the difference and the intersection of classes, strings in a class and the seven
  properties of strings.
- ECMAScript 2025: lookbehind, named groups (and a name shared between alternatives), modifier groups such as
  `(?i:...)`, and every Unicode property ECMA-262 lists, from tables of Unicode the library carries, so a pattern
  answers the same whichever compiler built it.
- The grammar of ECMAScript 2020, which JSON Schema 2020-12 names, and a choice of Unicode version, each independent
  of the other: a `TEcmaRegexOptions` holds an `Edition` (`ereCurrent`, the default, or `ereEs2020`) and a
  `UnicodeVersion` (`eruDefault` for V8's version, which is 17 today, or `eru13`, `eru17`, `eru18` or `eruLatest`,
  which is 18 today). Both are settled when a pattern is compiled and cost a match nothing. The 2020 grammar refuses
  what later editions added: the `d` and `v` flags, modifier groups, a group name used twice, and property names
  outside its tables. Unicode 13 and 18 are built when a pattern first asks for them.
- Text as UTF-8 (a `UTF8String`, a `RawByteString`, bytes from a pointer, or a `TUtf8Text`, which is checked once) or
  as UTF-16 (a `UnicodeString`, or code units from a pointer, lone surrogates and all). The type of the text chooses
  the encoding, and nothing is transcoded. Text that is not UTF-8 is refused, never read as U+FFFD. One matcher serves
  both encodings: it is written once and compiled for each.
- An `IEcmaRegex` has the methods of Delphi's `TRegEx`: `IsMatch`, `Match`, `Matches` (for a `for ... in` loop),
  `Count`, `Replace` (String.prototype.replace, with every `$` form of `GetSubstitution`), `ReplaceAll` and `Split`
  (RegExp.prototype[Symbol.split], which puts the groups between the pieces). Positions are 1-based indexes of the
  text's units, bytes or UTF-16 code units. A match into a `TEcmaCaptures` allocates nothing once the working memory
  has grown.
- A pattern without a backreference is matched in time proportional to its size times the text. A pattern can be given
  a match timeout, as a `Regex` of .NET can, which bounds the time and the backtracking memory of every match. With a
  timeout and the library's limits of pattern size, neither a pattern nor a text from outside can make a program hang.
  `SetDefaultEcmaRegexMatchTimeout` gives every pattern one. `TryCompileEcmaRegex(Pattern, Flags, Options, Regex,
  Error)` gives a pattern its own in `Options` and returns false with a `TEcmaRegexError` (its kind and message) in
  place of raising, so a validator needs neither the default nor a `try`.
- Every array read is checked. Range checking is on in every unit.
- No dependencies beyond the compiler's run-time library.

**Compliance.** Over the [ECMA-262 test data](https://github.com/corvus-dotnet/ecma262-regex-test-data) (what V8 says
about its patterns and texts, test262's patterns and `exec` calls, the global search, `replace` and `split` among them,
and texts of bytes that are not UTF-8, which it refuses), the library gives every answer right and none wrong, refuses
no valid pattern, accepts no invalid one and reaches no limit, over UTF-8 and over UTF-16. It does the same on the data
as the data's own scripts write it for Unicode 13 and 18 and for the grammar of ECMAScript 2020. CI runs all of it on
every change.

It is a port of the Rust crate [corvus-regex-ecma262](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs), and it
follows the design of the .NET engine [Corvus.Regex.Ecma262](https://github.com/corvus-dotnet/Corvus.Regex.Ecma262).
The source is in the Delphi dialect and written to be Delphi-compatible, but it has not been compiled with Delphi.

```pascal
uses
  Corvus.Ecma262.RegularExpressions;

var
  Re: IEcmaRegex;
  M: TEcmaMatch;
  W: TEcmaMatchW;
  C: TEcmaCaptures;
  Text: TUtf8Text;
  Index, Len: NativeInt;
  Options: TEcmaRegexOptions;
  Error: TEcmaRegexError;
begin
  Re := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'u');
  Re.IsMatch(UTF8String('on 2026-10-25'));                              // True
  Re.Replace(UTF8String('2026-10-25'), UTF8String('$<month>/$<year>')); // '10/2026-25'

  M := Re.Match(UTF8String('on 2026-10-25'));
  WriteLn(M.Group('month').Value, ' ', M.Index);                       // 10 4

  C := Default(TEcmaCaptures);                                         // matches into it allocate nothing
  Text := TUtf8Text.Create('on 2026-10-25');                           // checked once
  if Re.Exec(Text, C) and C.Range(2, Index, Len) then
    WriteLn(Index, ' ', Len);                                          // 9 2

  // Over UTF-16, in code units.
  for W in CompileEcmaRegex('\p{Lu}', 'u').Matches(UnicodeString('Ab Cd')) do
    WriteLn(W.Index);                                                  // 1, then 4

  // ECMAScript 2020 as its edition was published, with the Unicode of its year, and a match timeout of its own.
  Options := TEcmaRegexOptions.Default;
  Options.MatchTimeout := 1;
  Options.Edition := ereEs2020;
  Options.UnicodeVersion := eru13;
  if not TryCompileEcmaRegex('^\p{Script=Greek}+$', 'u', Options, Re, Error) then
    WriteLn(Error.Message);
end;
```

Errors are exceptions, all under `EEcmaRegex`: `EEcmaRegexSyntax`, `EEcmaRegexFlags` and `EEcmaRegexTooLarge` from a
pattern, `EEcmaRegexEncoding` from text that is not UTF-8, and `EEcmaRegexTimeout` or `EEcmaRegexMemory` from a match
that reaches its limit.

The working memory of a match belongs to its thread and is kept from one match to the next. Neither Free Pascal nor
Delphi frees it when a thread ends, so a thread that has matched and is about to end should call
`ReleaseEcmaRegexThreadState`.

## Status

0.1.0 is the first release. The parser, the compiler, the matcher and the crate's search layer (where a match can
start, and the automata) are in, the whole test data passes, and the central benchmark site runs the harness each
night. `docs/port-checklist.md` lists every optimisation of the search layer and how this port has it. Over x86_64 the
searches read 16 to 64 bytes at a time through kernels of inline assembler (SSE2, with SSSE3 and AVX2 where the
processor has them), so the library still has no dependency; any other processor takes their SWAR fallbacks.

## Installing

A release is a source archive on the repository's GitHub releases, tagged `v<version>`. The archive (a `.zip` or a
`.tar.gz`) unpacks to `corvus-regex-ecma262-pas-<version>`. Give the compiler its `src` directory for units and include
files:

```sh
fpc -Fucorvus-regex-ecma262-pas-0.1.0/src -Ficorvus-regex-ecma262-pas-0.1.0/src yourprogram.pas
```

The one unit a program names in its `uses` clause is `Corvus.Ecma262.RegularExpressions`.

## Benchmarks

The [central benchmark site](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/) runs this repository's harness
image, `ghcr.io/corvus-dotnet/corvus-regex-ecma262-pas`, each night beside the engines of every other source: this
library over UTF-8 and UTF-16, TRegExpr over UTF-8 and over UTF-16 (`uRegExpr`), which do not claim ECMA-262, and V8,
over the Industry workloads of dotnet/performance, with each ECMA-262 engine's compliance over the test data. This
repository publishes no figures of its own. `tools/benchmarks/run.sh <workloads.json> <texts> <out.json>` runs the same
harness anywhere (see the script for what it needs).

## Building and testing

```
pwsh tools/build.ps1
bin/TestEngine
bin/TestSearch
bin/TestAllocations
bin/stackprobe
bin/run <ecma262-regex-test-data>/data wrong-cases.tsv --threads 4
```

`CORVUS_REGEX_MEMO_FROM_THE_START=1` makes every match take its memory of failed places from its first step, which CI
does for a second run of both. The Unicode tables of each version (the units
`src/Corvus.Ecma262.RegularExpressions.Ucd<major>.pas`, with `src/Corvus.Ecma262.RegularExpressions.Strings<major>.inc`)
and the property names of ECMAScript 2020 (`src/Corvus.Ecma262.RegularExpressions.Es2020.pas`) are written from the
Rust crate's by `tools/unicode`, and CI checks them against the crate.

## Releasing

Every pull request merged into main without the `no_release` label releases the library with the next patch version
(`.github/workflows/auto-release.yml`, `tools/release`): a `v<version>` tag on a commit of the merge with the version
written into `EcmaRegexVersion` in `src/Corvus.Ecma262.RegularExpressions.pas`, which main keeps at 0.0.0.
`.github/workflows/pascal-publish.yml` then adds the source archives to the release. A pull request that needs a minor
or major version sets `nextVersion` in `.github/release.json`.

## License

Apache 2.0.
