# API reference

The interface of `Corvus.Ecma262.RegularExpressions`, generated from its declarations and their comments by
`tools/docs/gen-api.ps1`. [Getting started](getting-started.md) shows it at work.

## Constants

### EcmaRegexVersion

```pascal
EcmaRegexVersion = '0.0.0';
```

EcmaRegexVersion is the version of the library.

## Types

### EEcmaRegex

```pascal
EEcmaRegex = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegex;
```

EEcmaRegex is the class of every exception the engine raises for a pattern, its flags, a text or a match.

### EEcmaRegexSyntax

```pascal
EEcmaRegexSyntax = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexSyntax;
```

EEcmaRegexSyntax is a pattern that is not valid under the grammar its flags choose. Reason is why, and Offset is the 0-based offset in the pattern's characters (UTF-16 code units without the u or v flag) where it was found.

### EEcmaRegexFlags

```pascal
EEcmaRegexFlags = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexFlags;
```

EEcmaRegexFlags is flags that are not valid: a flag that is not one of dgimsuvy, a flag given twice, or u with v.

### EEcmaRegexTooLarge

```pascal
EEcmaRegexTooLarge = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexTooLarge;
```

EEcmaRegexTooLarge is a pattern over one of the limits of size. The pattern was not read to its end, so the error says nothing of whether it is valid.

### EEcmaRegexEncoding

```pascal
EEcmaRegexEncoding = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexEncoding;
```

EEcmaRegexEncoding is a pattern or a text that is not UTF-8 (or a pattern that is not well-formed UTF-16), which is refused, never read as U+FFFD.

### EEcmaRegexTimeout

```pascal
EEcmaRegexTimeout = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexTimeout;
```

EEcmaRegexTimeout is a match that ran for longer than its pattern's match timeout. It is not an answer.

### EEcmaRegexMemory

```pascal
EEcmaRegexMemory = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexMemory;
```

EEcmaRegexMemory is a match with a timeout that needed more backtracking memory than its limit. It is not an answer.

### TEcmaRegexLimit

```pascal
TEcmaRegexLimit = Corvus.Ecma262.RegularExpressions.Errors.TEcmaRegexLimit;
```

TEcmaRegexLimit names a limit of the size of a pattern: its length in bytes of UTF-8, the depth its groups nest, and the size it has when it is read.

### TEcmaRegexFlag

```pascal
TEcmaRegexFlag = (erfHasIndices, erfGlobal, erfIgnoreCase, erfMultiline, erfDotAll, erfUnicode, erfUnicodeSets,
```

The flags of a pattern, as new RegExp(pattern, flags) reads them: d, g, i, m, s, u, v and y.

### TEcmaRegexFlags

```pascal
TEcmaRegexFlags = set of TEcmaRegexFlag;
```

### TEcmaRegexEdition

```pascal
TEcmaRegexEdition = (ereCurrent, ereEs2020);
```

The edition of ECMA-262 whose grammar a pattern is read with. ereCurrent is today's grammar, ECMAScript 2025, the default. ereEs2020 is the grammar of ECMAScript 2020 (ECMA-262, 11th edition), which JSON Schema 2020-12 names: it refuses what later editions added, and nothing else, the d and v flags, modifier groups such as (?i:...), a group name used by two groups, and a property name or value that is not in the edition's tables. A pattern it accepts has the same answers as in today's grammar, under the same version of Unicode.

### TEcmaRegexUnicodeVersion

```pascal
TEcmaRegexUnicodeVersion = (eruDefault, eru13, eru17, eru18, eruLatest);
```

The version of Unicode whose character database a pattern is read with: the members of each \p{...}, the characters of a group name, and the case folding of the i flag. It is independent of the edition. eruDefault is the version of the V8 the answers are held to, Unicode 17 today, which moves when that V8 moves; eru13 is Unicode 13.0, the version of the year of ECMAScript 2020; eru17 and eru18 are Unicode 17.0 and 18.0; eruLatest is the latest version the library carries, Unicode 18 today, which moves when a later version is added.

### TEcmaRegexOptions

```pascal
TEcmaRegexOptions = record
  MatchTimeout: Double;
  Edition: TEcmaRegexEdition;
  UnicodeVersion: TEcmaRegexUnicodeVersion;
  class function Default: TEcmaRegexOptions; static;
end;
```

A TEcmaRegexOptions is how a pattern is compiled besides its flags: its match timeout in seconds (below 0 for the default, see SetDefaultEcmaRegexMatchTimeout, and 0 for none), the edition whose grammar it is read with and the version of Unicode whose tables it is read with. Default gives the default timeout, today's grammar and V8's Unicode.

### TEcmaRegexErrorKind

```pascal
TEcmaRegexErrorKind = (eekNone, eekSyntax, eekFlags, eekTooLarge, eekEncoding);
```

Why TryCompileEcmaRegex did not compile a pattern: eekSyntax for a pattern that is not valid, eekFlags for flags that are not valid (or that the edition does not have), eekTooLarge for a pattern over a limit of size, eekEncoding for a pattern that is not UTF-8.

### TEcmaRegexError

```pascal
TEcmaRegexError = record
  Kind: TEcmaRegexErrorKind;
  Message: string;
end;
```

A TEcmaRegexError is the kind and the message of the error TryCompileEcmaRegex gives in place of raising it.

### TUtf8Text

```pascal
TUtf8Text = record
  { Create checks the text, and raises EEcmaRegexEncoding when it is not UTF-8. }
  class function Create(const Text: RawByteString): TUtf8Text; static;
  property Text: UTF8String read FText;
end;
```

A TUtf8Text is UTF-8 text that has been checked once, so that the calls that take it check nothing. A program that matches one text many times makes a TUtf8Text of it and pays for the check once.

### TEcmaGroup

```pascal
TEcmaGroup = record
  Success: Boolean;
  Index: NativeInt;
  Length: NativeInt;
  Value: UTF8String;
  { Name is the group's name, or empty for a group with no name. }
  Name: UTF8String;
end;
```

A TEcmaGroup is what a group of a match of UTF-8 text holds: whether it took part, its 1-based index and its length in bytes, and its text. A bound between the halves of a character of four bytes (which only a pattern without the u flag can make) is written in Value as U+FFFD.

### TEcmaGroups

```pascal
TEcmaGroups = array of TEcmaGroup;
```

### TEcmaMatch

```pascal
TEcmaMatch = record
  Success: Boolean;
  Index: NativeInt;
  Length: NativeInt;
  Value: UTF8String;
  Groups: TEcmaGroups;
  { Group is the group with the name that took part, or a group that did not when none did. }
  function Group(const Name: UTF8String): TEcmaGroup;
end;
```

A TEcmaMatch is a match of UTF-8 text: whether there is one, its 1-based index and length in bytes, its text, and its groups, Groups[0] being the whole match.

### TEcmaGroupW

```pascal
TEcmaGroupW = record
  Success: Boolean;
  Index: NativeInt;
  Length: NativeInt;
  Value: UnicodeString;
  Name: UnicodeString;
end;
```

A TEcmaGroupW is what a group of a match of UTF-16 text holds, in code units.

### TEcmaGroupsW

```pascal
TEcmaGroupsW = array of TEcmaGroupW;
```

### TEcmaMatchW

```pascal
TEcmaMatchW = record
  Success: Boolean;
  Index: NativeInt;
  Length: NativeInt;
  Value: UnicodeString;
  Groups: TEcmaGroupsW;
  function Group(const Name: UnicodeString): TEcmaGroupW;
end;
```

A TEcmaMatchW is a match of UTF-16 text, in code units.

### TEcmaMatchArray

```pascal
TEcmaMatchArray = array of TEcmaMatch;
```

### TEcmaMatchArrayW

```pascal
TEcmaMatchArrayW = array of TEcmaMatchW;
```

### TEcmaCaptures

```pascal
TEcmaCaptures = record
  function Range(G: Int32; out Index, Length: NativeInt): Boolean;
  { GroupCount is the number of groups of the last match, not counting the whole match. }
  property GroupCount: Int32 read FGroups;
end;
```

A TEcmaCaptures holds the bounds of the groups of a match, kept from one match to the next so that matching allocates nothing once it has room for the pattern's groups. Range reports the 1-based index and the length of group G (0 for the whole match), in the units of the text that was matched, and false for a group that did not take part.

### IEcmaRegex

```pascal
IEcmaRegex = interface
  function GetPattern: UTF8String;
  function GetFlags: TEcmaRegexFlags;
  function GetFlagsText: string;
  function GetGroupCount: Int32;
  function GetMatchTimeout: Double;
  function GetEdition: TEcmaRegexEdition;
  function GetUnicodeVersion: Int32;

  function IsMatch(const Text: UTF8String; StartIndex: NativeInt = 1): Boolean; overload;
  function IsMatch(const Text: UnicodeString; StartIndex: NativeInt = 1): Boolean; overload;
  function IsMatch(const Text: TUtf8Text; StartIndex: NativeInt = 1): Boolean; overload;

  function Match(const Text: UTF8String; StartIndex: NativeInt = 1): TEcmaMatch; overload;
  function Match(const Text: UnicodeString; StartIndex: NativeInt = 1): TEcmaMatchW; overload;
  function Match(const Text: TUtf8Text; StartIndex: NativeInt = 1): TEcmaMatch; overload;

  function Matches(const Text: UTF8String): TEcmaMatches; overload;
  function Matches(const Text: UnicodeString): TEcmaMatchesW; overload;
  function Matches(const Text: TUtf8Text): TEcmaMatches; overload;

  function Count(const Text: UTF8String): NativeInt; overload;
  function Count(const Text: UnicodeString): NativeInt; overload;
  function Count(const Text: TUtf8Text): NativeInt; overload;

  function Replace(const Text, Replacement: UTF8String): UTF8String; overload;
  function Replace(const Text, Replacement: UnicodeString): UnicodeString; overload;
  function ReplaceAll(const Text, Replacement: UTF8String): UTF8String; overload;
  function ReplaceAll(const Text, Replacement: UnicodeString): UnicodeString; overload;

  function Split(const Text: UTF8String; Limit: NativeInt = -1): TEcmaGroups; overload;
  function Split(const Text: UnicodeString; Limit: NativeInt = -1): TEcmaGroupsW; overload;

  function Exec(const Text: UTF8String; var Captures: TEcmaCaptures; StartIndex: NativeInt = 1): Boolean; overload;
  function Exec(const Text: UnicodeString; var Captures: TEcmaCaptures;
    StartIndex: NativeInt = 1): Boolean; overload;
  function Exec(const Text: TUtf8Text; var Captures: TEcmaCaptures; StartIndex: NativeInt = 1): Boolean; overload;
  { The pointer forms take Len units from Text: bytes of UTF-8, which are checked, or UTF-16 code units. }
  function Exec(Text: PByte; Len: NativeInt; var Captures: TEcmaCaptures;
    StartIndex: NativeInt = 1): Boolean; overload;
  function Exec(Text: PWideChar; Len: NativeInt; var Captures: TEcmaCaptures;
    StartIndex: NativeInt = 1): Boolean; overload;

  { GroupName is the name of group G (from 1), or empty for a group with no name. GroupNumbers is the groups with
    the name, which is more than one where groups in separate alternatives share it; empty for none. }
  function GroupName(G: Int32): UTF8String;
  function GroupNumbers(const Name: UTF8String): TGroupList;

  property Pattern: UTF8String read GetPattern;
  property Flags: TEcmaRegexFlags read GetFlags;
  { FlagsText is the flags as RegExp writes them, in the order dgimsuvy. }
  property FlagsText: string read GetFlagsText;
  property GroupCount: Int32 read GetGroupCount;
  { MatchTimeout is the time each match may take in seconds, or 0 for no limit. }
  property MatchTimeout: Double read GetMatchTimeout;
  { Edition is the edition of ECMA-262 whose grammar the pattern was read with. }
  property Edition: TEcmaRegexEdition read GetEdition;
  { UnicodeVersion is the major number of the version of Unicode whose tables the pattern was read with, resolved:
    13, 17 or 18. }
  property UnicodeVersion: Int32 read GetUnicodeVersion;
end;
```

An IEcmaRegex is a compiled pattern. It is safe to share between threads.

IsMatch, Match and Count search from a 1-based StartIndex (1 by default); with the sticky flag a match must start there. Matches is the global search, which moves on past an empty match by a character (a code point with the u or v flag, a code unit without). Replace is String.prototype.replace: the first match replaced, or every match with the g flag, with the $ forms of the replacement ($$, $&, $`, $', $n, $nn and $<name>) replaced; ReplaceAll replaces every match whatever the flags. Split is RegExp.prototype[Symbol.split]: the pieces between the matches, with the groups of each match after the piece before it (Success false for a group that did not take part, which JavaScript gives as undefined), and at most Limit items (all when Limit is below 0). Exec matches into a TEcmaCaptures, which allocates nothing.

### TEcmaMatchEnumerator

```pascal
TEcmaMatchEnumerator = record
  function MoveNext: Boolean;
  property Current: TEcmaMatch read FCurrent;
end;
```

A TEcmaMatches is the matches of a global search of UTF-8 text, for a for ... in loop.

### TEcmaMatches

```pascal
TEcmaMatches = record
  function GetEnumerator: TEcmaMatchEnumerator;
  { ToArray is every match. }
  function ToArray: TEcmaMatchArray;
end;
```

### TEcmaMatchEnumeratorW

```pascal
TEcmaMatchEnumeratorW = record
  function MoveNext: Boolean;
  property Current: TEcmaMatchW read FCurrent;
end;
```

### TEcmaMatchesW

```pascal
TEcmaMatchesW = record
  function GetEnumerator: TEcmaMatchEnumeratorW;
  function ToArray: TEcmaMatchArrayW;
end;
```

## Functions

### ParseEcmaRegexFlags

```pascal
function ParseEcmaRegexFlags(const Flags: string): TEcmaRegexFlags;
```

ParseEcmaRegexFlags reads flags written as new RegExp reads them, such as 'giu'. A flag that is not one of dgimsuvy, a flag given twice, or u with v, raises EEcmaRegexFlags.

### EcmaRegexFlagsText

```pascal
function EcmaRegexFlagsText(Flags: TEcmaRegexFlags): string;
```

EcmaRegexFlagsText is the flags as RegExp writes them, in the order dgimsuvy.

### CompileEcmaRegex

```pascal
function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string = '';
  MatchTimeout: Double = -1): IEcmaRegex; overload;
function CompileEcmaRegex(const Pattern: UnicodeString; const Flags: string = '';
  MatchTimeout: Double = -1): IEcmaRegex; overload;
function CompileEcmaRegex(const Pattern: UTF8String; Flags: TEcmaRegexFlags;
  MatchTimeout: Double = -1): IEcmaRegex; overload;
function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string;
  const Options: TEcmaRegexOptions): IEcmaRegex; overload;
```

CompileEcmaRegex compiles a pattern as new RegExp(pattern, flags) compiles it: with the u or v flag by the grammar of the u flag and matched by code point; with neither by the Annex B grammar and matched by UTF-16 code unit. The i, m and s flags are the modifiers in force at the start of the pattern, which a modifier group such as (?i:...) changes for part of it.

A pattern can have a match timeout in seconds, as a Regex of .NET has: the time each match may take, which brings a cap on the memory of its backtracking with it. A match that reaches a limit raises EEcmaRegexTimeout or EEcmaRegexMemory. A pattern without a timeout never reaches a limit. A MatchTimeout below 0 takes the default (see SetDefaultEcmaRegexMatchTimeout), and 0 is no timeout.

An invalid pattern raises EEcmaRegexSyntax, a pattern over a limit of size EEcmaRegexTooLarge, a pattern that is not UTF-8 (or, given as a UnicodeString, not well-formed UTF-16) EEcmaRegexEncoding, and invalid flags EEcmaRegexFlags.

CompileEcmaRegex with Options compiles a pattern with the settings besides its flags (see TEcmaRegexOptions). Under ereEs2020 the d and v flags raise EEcmaRegexFlags.

### TryCompileEcmaRegex

```pascal
function TryCompileEcmaRegex(const Pattern: UTF8String; const Flags: string; const Options: TEcmaRegexOptions;
  out Regex: IEcmaRegex; out Error: TEcmaRegexError): Boolean;
```

TryCompileEcmaRegex is CompileEcmaRegex with Options that gives its error in place of raising it: it returns true with the pattern in Regex, or false with why in Error. A validator that compiles patterns from outside takes this form, and gives each a match timeout of its own in Options.

### IsValidEcmaRegex

```pascal
function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string = ''): Boolean; overload;
function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string;
  const Options: TEcmaRegexOptions): Boolean; overload;
```

IsValidEcmaRegex reports whether a pattern is valid with the flags, and with Options, in the grammar of its edition and under its version of Unicode (the match timeout is not read).

### EcmaRegexUnicodeMajor

```pascal
function EcmaRegexUnicodeMajor(V: TEcmaRegexUnicodeVersion): Int32;
```

EcmaRegexUnicodeMajor is the major number of the version of Unicode a TEcmaRegexUnicodeVersion stands for: 13, 17 or 18.

### SetDefaultEcmaRegexMatchTimeout

```pascal
procedure SetDefaultEcmaRegexMatchTimeout(Seconds: Double);
```

SetDefaultEcmaRegexMatchTimeout gives every pattern compiled after it, without a timeout of its own, the match timeout in seconds. 0 is no timeout. DefaultEcmaRegexMatchTimeout is the timeout such a pattern takes now.

### DefaultEcmaRegexMatchTimeout

```pascal
function DefaultEcmaRegexMatchTimeout: Double;
```

### ReleaseEcmaRegexThreadState

```pascal
procedure ReleaseEcmaRegexThreadState;
```

ReleaseEcmaRegexThreadState frees the working memory the calling thread's matches have used. A thread that has matched and is about to end should call it: neither Free Pascal nor Delphi frees that memory when a thread ends.
