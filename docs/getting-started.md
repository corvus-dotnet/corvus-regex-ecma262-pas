# Getting started with Object Pascal

## Introduction

`corvus-regex-ecma262-pas` is an Object Pascal engine whose patterns answer as ECMAScript does. Where Delphi's `TRegEx`
(PCRE) and TRegExpr have their own grammars and their own meaning for `\d`, `\w`, `\s`, `.`, case folding and Unicode
properties, this engine has ECMA-262's, so a pattern written for JavaScript, or taken from a JSON Schema, matches the
same texts here as it does there. It is a port of the corvus-regex-ecma262 Rust crate, held to V8's answers on the
ECMA-262 test data, with no dependencies beyond the compiler's RTL.

This guide covers:

- **Setup**: adding the source to a Free Pascal or Delphi project.
- **Patterns and flags**: the flags are ECMA-262's letters, and what each one does.
- **The edition and the version of Unicode**: the grammar of ECMAScript 2020, and the Unicode tables a pattern reads.
- **Matching**: `IsMatch`, `Match`, `Matches`, `Count`, `Replace` and `Split`, and `Exec`, which allocates nothing.
- **Timeouts**: the limit of time and of memory a match may take.
- **UTF-8 and UTF-16**: `UTF8String` and `UnicodeString`, each matched as it is held.
- **Differences from TRegEx and TRegExpr**: what to expect when they meet.

## Setup

Each [release](https://github.com/corvus-dotnet/corvus-regex-ecma262-pas/releases) is a source archive. Unpack it and
give the compiler its `src` directory for units and include files:

```
fpc -Fucorvus-regex-ecma262-pas/src -Ficorvus-regex-ecma262-pas/src yourprogram.pas
```

It is built and tested with Free Pascal 3.2.2 on Linux, macOS and Windows, and written to compile with Delphi too: add
`src` to the project's search path. A program uses the one unit:

```pascal
uses
  Corvus.Ecma262.RegularExpressions;
```

## Patterns and flags

A pattern is written as it would be in JavaScript, and the flags are the letters `RegExp` takes, as a string or as a
`TEcmaRegexFlags` set:

| Flag | `TEcmaRegexFlag` | Meaning |
|---|---|---|
| `d` | `erfHasIndices` | Accepted for completeness; indices are always kept. |
| `g` | `erfGlobal` | `Replace` replaces every match; without it, the first, as `String.prototype.replace` does. |
| `i` | `erfIgnoreCase` | Canonicalize of the mode in force: simple case folding with `u` or `v`, `toUpperCase` without. Never the locale. |
| `m` | `erfMultiline` | `^` and `$` at line terminators. |
| `s` | `erfDotAll` | The dot matches line terminators. |
| `u` | `erfUnicode` | The `u` flag grammar; matched by code point. |
| `v` | `erfUnicodeSets` | Set notation and properties of strings; matched by code point. `u` and `v` together is an error, as in ECMA-262. |
| `y` | `erfSticky` | A match only at the start position. |

```pascal
program PatternsExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  A, B, C: IEcmaRegex;
begin
  A := CompileEcmaRegex('\p{Script=Greek}+', 'u');
  B := CompileEcmaRegex('[[a-z]--[aeiou]]+', 'v');
  C := CompileEcmaRegex('^(?<year>\d{4})-(?<month>\d{2})$', 'u');

  if not A.IsMatch(UTF8String('αβγ')) then raise Exception.Create('Greek');
  if not B.IsMatch(UTF8String('rhythm')) then raise Exception.Create('no vowels');
  if (C.GroupName(1) <> 'year') or (C.GroupName(2) <> 'month') then raise Exception.Create('the names');
end.
```

With no flag the pattern is read with the Annex B grammar and matched by UTF-16 code unit, which is what ECMA-262 does
with no flag. JSON Schema's reading, the `u` flag first and Annex B when that refuses, is two calls of
`TryCompileEcmaRegex`, which raises nothing and takes the match timeout in its options, so no default timeout is needed:

```pascal
program SchemaExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

function SchemaPattern(const Pattern: UTF8String): IEcmaRegex;
var
  Options: TEcmaRegexOptions;
  Err: TEcmaRegexError;
begin
  Options := TEcmaRegexOptions.Default;
  Options.MatchTimeout := 1;
  if not TryCompileEcmaRegex(Pattern, 'u', Options, Result, Err) and
     not TryCompileEcmaRegex(Pattern, '', Options, Result, Err) then
    raise Exception.Create(Err.Message);
end;

begin
  if SchemaPattern('^\p{L}+$').FlagsText <> 'u' then raise Exception.Create('read with u');
  // An identity escape, which only Annex B allows.
  if SchemaPattern('\-').FlagsText <> '' then raise Exception.Create('read with Annex B');
end.
```

A pattern that is not valid raises `EEcmaRegexSyntax`, whose `Reason` says why and whose `Offset` says where; invalid
flags raise `EEcmaRegexFlags`. Every pattern has deterministic limits of size, and `EEcmaRegexTooLarge` says when one
is passed. `TryCompileEcmaRegex` gives the same error as a `TEcmaRegexError`, with its `Kind` and `Message`.

```pascal
program ErrorsExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Re: IEcmaRegex;
  Err: TEcmaRegexError;
  Raised: Boolean;
begin
  Raised := False;
  try
    CompileEcmaRegex('a{2,1}', 'u');
  except
    on E: EEcmaRegexSyntax do Raised := E.Offset >= 0;
  end;
  if not Raised then raise Exception.Create('a pattern that is not valid was compiled');

  if TryCompileEcmaRegex('a', 'uv', TEcmaRegexOptions.Default, Re, Err) or (Err.Kind <> eekFlags) then
    raise Exception.Create('u with v is not valid');
end.
```

## The edition and the version of Unicode

JSON Schema 2020-12 names the grammar of ECMAScript 2020. `ereEs2020` refuses what later editions added, and nothing
else: the `d` and `v` flags, modifier groups such as `(?i:...)`, a group name used by two groups, and a property name
or value that is not in the 2020 tables (such as `\p{Script=Yezidi}`). A pattern it accepts has the same answers as in
today's grammar.

The version of Unicode is chosen apart from the edition: `eru13`, `eru17`, `eru18`, `eruLatest` (18 today) or
`eruDefault`, the version of the V8 the answers are held to (17 today). It decides the members of each `\p{...}`, the
characters of a group name and the case folding of the `i` flag. The `UnicodeVersion` property reports the version a
pattern was compiled with. Both are set in a `TEcmaRegexOptions` and read when the pattern is compiled, so a match
costs the same whichever is chosen.

```pascal
program EditionExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Options: TEcmaRegexOptions;
  Greek: IEcmaRegex;
begin
  // ECMAScript 2020 as its edition was published, with the Unicode of its year.
  Options := TEcmaRegexOptions.Default;
  Options.MatchTimeout := 1;
  Options.Edition := ereEs2020;
  Options.UnicodeVersion := eru13;
  Greek := CompileEcmaRegex('^\p{Script=Greek}+$', 'u', Options);
  if not Greek.IsMatch(UTF8String('αβγ')) or (Greek.UnicodeVersion <> 13) then raise Exception.Create('Greek');

  // Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
  if IsValidEcmaRegex('\p{Script=Vithkuqi}', 'u', Options) then raise Exception.Create('no Vithkuqi in Unicode 13');
end.
```

## Matching

The methods are those of a `RegExp`, with the position as `StartIndex` where JavaScript keeps `lastIndex`. Positions
are 1-based, as Pascal indexes a string. A match is a `TEcmaMatch`, with its groups; `Groups[0]` is the whole match,
and a group that did not take part has `Success` false.

```pascal
program MatchingExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Date: IEcmaRegex;
  M: TEcmaMatch;
  Pieces: TEcmaGroups;
  Found: string;
const
  Text: UTF8String = 'due 2026-10, then 2027-01';
begin
  Date := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'gu');
  if not Date.IsMatch(Text) then raise Exception.Create('a match');

  M := Date.Match(Text);
  if (M.Index <> 5) or (M.Length <> 7) or (M.Value <> '2026-10') then raise Exception.Create('the first match');
  if (M.Group('year').Value <> '2026') or (M.Groups[2].Value <> '10') then raise Exception.Create('its groups');

  // Every match of a global search, as matchAll makes it.
  Found := '';
  for M in Date.Matches(Text) do
    Found := Found + string(M.Value) + ' ';
  if (Found <> '2026-10 2027-01 ') or (Date.Count(Text) <> 2) then raise Exception.Create('the global search');

  // Replace replaces every match with the g flag, and the first without it, with every $ form of ECMA-262.
  if Date.Replace(Text, UTF8String('$<month>/$1')) <> 'due 10/2026, then 01/2027' then
    raise Exception.Create('replace');

  // Split puts what the groups captured between the pieces; a group that did not take part has Success false.
  Pieces := CompileEcmaRegex('\s*(;)\s*').Split(UTF8String('a ; b;c'));
  if (Length(Pieces) <> 5) or (Pieces[1].Value <> ';') or (Pieces[4].Value <> 'c') then
    raise Exception.Create('split');
end.
```

`Match(Text, StartIndex)` is `exec` with `lastIndex` set, and `y` anchors it there. `Match`, `Matches`, `Replace` and
`Split` allocate what they return. `IsMatch`, `Count` and `Exec`, which writes a match's groups into a `TEcmaCaptures`
made once, allocate nothing once it has room for the pattern's groups:

```pascal
program ExecExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Date: IEcmaRegex;
  Captures: TEcmaCaptures;
  Index, Len: NativeInt;
begin
  Date := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'u');
  if not Date.Exec(UTF8String('due 2026-10'), Captures) then raise Exception.Create('a match');
  if not Captures.Range(1, Index, Len) or (Index <> 5) or (Len <> 4) then raise Exception.Create('the year');
end.
```

A compiled pattern holds no mutable state, so one `IEcmaRegex` is shared between threads.

## Timeouts

A match has no limit by default. A pattern compiled with a match timeout (in seconds) abandons a match that reaches it
with `EEcmaRegexTimeout`, and one that reaches the cap on backtracking memory the timeout brings with
`EEcmaRegexMemory`, whatever the pattern:

```pascal
program TimeoutsExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Slow: IEcmaRegex;
  Raised: Boolean;
begin
  Slow := CompileEcmaRegex('^(?:(a+)\1*)+$', '', 0.1);
  if Abs(Slow.MatchTimeout - 0.1) > 1e-6 then raise Exception.Create('the timeout');
  Raised := False;
  try
    Slow.IsMatch(UTF8String(StringOfChar('a', 60) + 'b'));
  except
    on EEcmaRegexTimeout do Raised := True;
  end;
  if not Raised then raise Exception.Create('the match did not stop at its timeout');
end.
```

A pattern compiled without a timeout takes the default timeout, which is none unless
`SetDefaultEcmaRegexMatchTimeout` sets it. A program that matches patterns or texts from outside should set one, for
example with `SetDefaultEcmaRegexMatchTimeout(1)` when it starts.

A pattern without a backreference is matched in time linear in the text, and no pattern can overflow the stack, so the
timeout is what bounds the others.

## UTF-8 and UTF-16

A `UTF8String` (or a `RawByteString`) is UTF-8, matched as its bytes with no transcoding, and positions are bytes. It
is checked before it is read: text that is not UTF-8 raises `EEcmaRegexEncoding`, and is never matched or read as
U+FFFD. `TUtf8Text.Create` checks a text once, for a text matched many times. A `UnicodeString` is UTF-16, lone
surrogates and all, with positions in code units, and its matches are `TEcmaMatchW`.

```pascal
program EncodingsExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  DotB: IEcmaRegex;
  M8: TEcmaMatch;
  M16: TEcmaMatchW;
  Raised: Boolean;
begin
  DotB := CompileEcmaRegex('.b', 'u');

  M8 := DotB.Match(UTF8String('a😀b'));
  if (M8.Index <> 2) or (M8.Length <> 5) then raise Exception.Create('bytes of UTF-8');

  M16 := DotB.Match(UnicodeString('a😀b'));
  if (M16.Index <> 2) or (M16.Length <> 3) then raise Exception.Create('UTF-16 code units');

  if not DotB.IsMatch(TUtf8Text.Create('a😀b')) then raise Exception.Create('a text checked once');

  Raised := False;
  try
    DotB.IsMatch(UTF8String(#$FF));
  except
    on EEcmaRegexEncoding do Raised := True;
  end;
  if not Raised then raise Exception.Create('text that is not UTF-8 was matched');
end.
```

Under the `u` and `v` flags a character is a code point in both encodings, so a class, a dot or a quantifier takes a
four-byte sequence as one character. With no flag ECMA-262 matches by UTF-16 code unit; over UTF-8 the engine keeps
that meaning, so a match can start or end between the halves of a character beyond the Basic Multilingual Plane, at
the character's third byte.

## Differences from TRegEx and TRegExpr

The methods follow `RegExp`; the meaning follows ECMA-262. The differences a user coming from Delphi's `TRegEx` or
TRegExpr will meet:

- **The grammar.** No `(?i)` inline option (ECMA-262 has `(?i:...)` groups), no atomic groups, no possessive
  quantifiers, no `\A` and `\z`, no conditionals and no recursion.
- **The character classes.** `\d` is `[0-9]`, `\w` is the 63 ASCII word characters, `\s` is ECMAScript's white space
  and line terminators, and `.` excludes the four line terminators (LF, CR, U+2028, U+2029).
- **Replacement.** A template writes a group as `$1` or `$<name>`, and `$&`, `` $` `` and `$'` are the match and the
  text before and after it; `Replace` replaces every match only with the `g` flag, and `ReplaceAll` always does.
- **Split.** `Split` is JavaScript's, which puts what the groups captured between the pieces.
- **Timeouts.** Neither has a limit on a match's time. Here a pattern without a backreference is matched in time linear
  in the text, and a timeout bounds the others.
