# Getting started with Object Pascal

`corvus-regex-ecma262-pas` is an Object Pascal engine, with no dependencies, whose patterns have the grammar and the
answers of JavaScript's `RegExp`, held to V8's answers on the ECMA-262 test data, over UTF-8 (`UTF8String`) and UTF-16
(`UnicodeString`). It is built and tested with Free Pascal 3.2.2, and written to compile with Delphi too.

## Install

Each [release](https://github.com/corvus-dotnet/corvus-regex-ecma262-pas/releases) is a source archive. Unpack it and
give the compiler its `src` directory for units and include files:

```
fpc -Fucorvus-regex-ecma262-pas/src -Ficorvus-regex-ecma262-pas/src yourprogram.pas
```

With Delphi, add `src` to the project's search path. The library uses only the compiler's own RTL.

## Compile a pattern

`CompileEcmaRegex` takes a pattern and its flags as `new RegExp(pattern, flags)` takes them: `d`, `g`, `i`, `m`, `s`,
`u`, `v` and `y`, and returns an `IEcmaRegex`. Without `u` or `v` a pattern is read by the Annex B grammar and matched
by UTF-16 code unit, as ECMA-262 reads it; with them, by code point. A pattern that is not valid raises
`EEcmaRegexSyntax` (or `EEcmaRegexFlags`, or `EEcmaRegexTooLarge`); `TryCompileEcmaRegex` gives the error in place of
raising it.

```pascal
program CompileExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Date, Re: IEcmaRegex;
  Err: TEcmaRegexError;
  Raised: Boolean;
begin
  Date := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'gu');
  if Date.GroupCount <> 2 then raise Exception.Create('two groups');

  Raised := False;
  try
    CompileEcmaRegex('a{2,1}', 'u');
  except
    on EEcmaRegexSyntax do Raised := True;
  end;
  if not Raised then raise Exception.Create('a pattern that is not valid was compiled');

  if TryCompileEcmaRegex('a', 'uv', TEcmaRegexOptions.Default, Re, Err) or (Err.Kind <> eekFlags) then
    raise Exception.Create('u with v is not valid');
end.
```

## Match

Positions are 1-based, as Pascal indexes a string: bytes of a `UTF8String`, code units of a `UnicodeString`. A match
is a `TEcmaMatch`, with its groups; `Groups[0]` is the whole match, and a group that did not take part has `Success`
false.

```pascal
program MatchExample;
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
  if Found <> '2026-10 2027-01 ' then raise Exception.Create('the global search');

  // Replace replaces every match with the g flag, and the first without it, with every $ form of ECMA-262.
  if Date.Replace(Text, UTF8String('$<month>/$1')) <> 'due 10/2026, then 01/2027' then
    raise Exception.Create('replace');

  // Split puts what the groups captured between the pieces.
  Pieces := CompileEcmaRegex('\s*(;)\s*').Split(UTF8String('a ; b;c'));
  if (Length(Pieces) <> 5) or (Pieces[1].Value <> ';') or (Pieces[4].Value <> 'c') then
    raise Exception.Create('split');
end.
```

## UTF-8 and UTF-16

A `UTF8String` (or a `RawByteString`) is UTF-8, and is checked before it is read: text that is not UTF-8 raises
`EEcmaRegexEncoding`, and is never matched or read as U+FFFD. `TUtf8Text.Create` checks a text once, for a text matched
many times. A `UnicodeString` is UTF-16, lone surrogates and all, with positions in code units.

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

## Patterns and texts from outside

A match has no limit by default. A program that matches a pattern or a text it did not write gives the pattern a match
timeout in seconds, as a .NET `Regex` has: a match that runs past it raises `EEcmaRegexTimeout`, and one whose
backtracking memory reaches its cap `EEcmaRegexMemory`. No pattern can overflow the stack.
`SetDefaultEcmaRegexMatchTimeout` sets the timeout of every pattern compiled after it.

```pascal
program LimitsExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Slow: IEcmaRegex;
  Raised: Boolean;
begin
  Slow := CompileEcmaRegex('^(?:(a+)\1*)+$', '', 0.1);
  Raised := False;
  try
    Slow.IsMatch(UTF8String(StringOfChar('a', 60) + 'b'));
  except
    on EEcmaRegexTimeout do Raised := True;
  end;
  if not Raised then raise Exception.Create('the match did not stop at its timeout');
end.
```

## The edition and the version of Unicode

JSON Schema 2020-12 names the grammar of ECMAScript 2020. `ereEs2020` refuses what later editions added: the `d` and
`v` flags, modifier groups, a group name used twice, and property names outside the 2020 tables. The version of Unicode
is chosen apart from it: `eru13`, `eru17`, `eru18`, `eruLatest` (18) or `eruDefault` (V8's, 17). Both are set in a
`TEcmaRegexOptions` and read when the pattern is compiled, so a match costs the same whatever they are.

```pascal
program EditionExample;
{$IFDEF FPC}{$MODE DELPHI}{$CODEPAGE UTF8}{$ENDIF}{$H+}

uses
  SysUtils, Corvus.Ecma262.RegularExpressions;

var
  Options: TEcmaRegexOptions;
  Greek: IEcmaRegex;
begin
  Options := TEcmaRegexOptions.Default;
  Options.MatchTimeout := 1;
  Options.Edition := ereEs2020;
  Options.UnicodeVersion := eru13;
  Greek := CompileEcmaRegex('^\p{Script=Greek}+$', 'u', Options);
  if not Greek.IsMatch(UTF8String('αβγ')) then raise Exception.Create('Greek');

  // Vithkuqi is in Unicode 14 and later, so not in Unicode 13.
  if IsValidEcmaRegex('\p{Script=Vithkuqi}', 'u', Options) then raise Exception.Create('no Vithkuqi in Unicode 13');
end.
```

## Differences from TRegEx and RegExpr

- The grammar is ECMA-262's, not PCRE's (Delphi's `TRegEx`) or TRegExpr's. The flags are a string as `RegExp` takes
  them, and `(?i:...)` groups set them inside a pattern; there is no `(?i)` prefix for the whole pattern, no
  possessive quantifiers, no atomic groups, no `\A` or `\z`, and no recursion.
- `\d` is `[0-9]`, `\w` the 63 ASCII word characters, `\s` ECMAScript's white space and line terminators, and `.`
  excludes LF, CR, U+2028 and U+2029.
- A replacement template writes a group as `$1` or `$<name>`, and `$&`, `` $` `` and `$'` are the match and the text
  before and after it.
- `Replace` replaces every match only with the `g` flag; `ReplaceAll` always does.
- `Split` puts what the groups captured between the pieces, as JavaScript's does.
- Neither has a limit on a match's time. Here a pattern without a backreference is matched in time linear in the text,
  and a pattern from outside should be given a timeout, which bounds every match.

## Where next

- [The API reference](api.md), generated from the interface of `Corvus.Ecma262.RegularExpressions`.
- [The README](../README.md).
- [The benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), with every engine measured nightly.
