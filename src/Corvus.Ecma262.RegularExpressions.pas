unit Corvus.Ecma262.RegularExpressions;
{$I ecma262.inc}

(* Regular expressions with the grammar and the answers of ECMA-262, the RegExp of JavaScript, over UTF-8 (a
  UTF8String or RawByteString, or a TUtf8Text, which is checked once) and UTF-16 (a UnicodeString, lone surrogates
  and all). Nothing is transcoded, and text that is not UTF-8 is refused, never read as U+FFFD.

    Re := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'u');
    Re.IsMatch('on 2026-10-25');                       // True
    Re.Replace('2026-10-25', '$<month>/$<year>');      // '10/2026-25'

  The encoding of a call is the type of its text. A UTF8String, a RawByteString or an AnsiString (which the compiler
  converts to UTF-8) is matched as UTF-8, and the positions of a match are 1-based indexes of its bytes. A
  UnicodeString, and a string literal, is matched as UTF-16, and the positions are 1-based indexes of its code units.
  A match of UTF-8 text is a TEcmaMatch and of UTF-16 text a TEcmaMatchW.

  A TEcmaRegexOptions reads a pattern with the grammar of ECMAScript 2020 (ereEs2020), the grammar JSON Schema 2020-12
  names, and with the tables of Unicode 13, 17 or 18 (TEcmaRegexUnicodeVersion), each chosen on its own. Both are read
  when the pattern is compiled, so a match costs the same whichever is chosen.

  The engine is a port of the Rust crate corvus-regex-ecma262, unit for unit (the Syntax unit is parse.rs, the Prog
  unit is compile.rs, and so on), held to the same ECMA-262 test data. *)

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.Errors,
  Corvus.Ecma262.RegularExpressions.Vm;

const
  { EcmaRegexVersion is the version of the library. }
  EcmaRegexVersion = '0.0.0';

type
  EEcmaRegex = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegex;
  EEcmaRegexSyntax = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexSyntax;
  EEcmaRegexFlags = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexFlags;
  EEcmaRegexTooLarge = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexTooLarge;
  EEcmaRegexEncoding = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexEncoding;
  EEcmaRegexTimeout = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexTimeout;
  EEcmaRegexMemory = Corvus.Ecma262.RegularExpressions.Errors.EEcmaRegexMemory;
  TEcmaRegexLimit = Corvus.Ecma262.RegularExpressions.Errors.TEcmaRegexLimit;

  { The flags of a pattern, as new RegExp(pattern, flags) reads them: d, g, i, m, s, u, v and y. }
  TEcmaRegexFlag = (erfHasIndices, erfGlobal, erfIgnoreCase, erfMultiline, erfDotAll, erfUnicode, erfUnicodeSets,
    erfSticky);
  TEcmaRegexFlags = set of TEcmaRegexFlag;

  { The edition of ECMA-262 whose grammar a pattern is read with. ereCurrent is today's grammar, ECMAScript 2025, the
    default. ereEs2020 is the grammar of ECMAScript 2020 (ECMA-262, 11th edition), which JSON Schema 2020-12 names: it
    refuses what later editions added, and nothing else, the d and v flags, modifier groups such as (?i:...), a group
    name used by two groups, and a property name or value that is not in the edition's tables. A pattern it accepts
    has the same answers as in today's grammar, under the same version of Unicode. }
  TEcmaRegexEdition = (ereCurrent, ereEs2020);

  (* The version of Unicode whose character database a pattern is read with: the members of each \p{...}, the
    characters of a group name, and the case folding of the i flag. It is independent of the edition. eruDefault is
    the version of the V8 the answers are held to, Unicode 17 today, which moves when that V8 moves; eru13 is Unicode
    13.0, the version of the year of ECMAScript 2020; eru17 and eru18 are Unicode 17.0 and 18.0; eruLatest is the
    latest version the library carries, Unicode 18 today, which moves when a later version is added. *)
  TEcmaRegexUnicodeVersion = (eruDefault, eru13, eru17, eru18, eruLatest);

  { A TEcmaRegexOptions is how a pattern is compiled besides its flags: its match timeout in seconds (below 0 for the
    default, see SetDefaultEcmaRegexMatchTimeout, and 0 for none), the edition whose grammar it is read with and the
    version of Unicode whose tables it is read with. Default gives the default timeout, today's grammar and V8's
    Unicode. }
  TEcmaRegexOptions = record
    MatchTimeout: Double;
    Edition: TEcmaRegexEdition;
    UnicodeVersion: TEcmaRegexUnicodeVersion;
    class function Default: TEcmaRegexOptions; static;
  end;

  { Why TryCompileEcmaRegex did not compile a pattern: eekSyntax for a pattern that is not valid, eekFlags for flags
    that are not valid (or that the edition does not have), eekTooLarge for a pattern over a limit of size, eekEncoding
    for a pattern that is not UTF-8. }
  TEcmaRegexErrorKind = (eekNone, eekSyntax, eekFlags, eekTooLarge, eekEncoding);

  { A TEcmaRegexError is the kind and the message of the error TryCompileEcmaRegex gives in place of raising it. }
  TEcmaRegexError = record
    Kind: TEcmaRegexErrorKind;
    Message: string;
  end;

  { A TUtf8Text is UTF-8 text that has been checked once, so that the calls that take it check nothing. A program
    that matches one text many times makes a TUtf8Text of it and pays for the check once. }
  TUtf8Text = record
  private
    FText: UTF8String;
  public
    { Create checks the text, and raises EEcmaRegexEncoding when it is not UTF-8. }
    class function Create(const Text: RawByteString): TUtf8Text; static;
    property Text: UTF8String read FText;
  end;

  { A TEcmaGroup is what a group of a match of UTF-8 text holds: whether it took part, its 1-based index and its
    length in bytes, and its text. A bound between the halves of a character of four bytes (which only a pattern
    without the u flag can make) is written in Value as U+FFFD. }
  TEcmaGroup = record
    Success: Boolean;
    Index: NativeInt;
    Length: NativeInt;
    Value: UTF8String;
    { Name is the group's name, or empty for a group with no name. }
    Name: UTF8String;
  end;
  TEcmaGroups = array of TEcmaGroup;

  { A TEcmaMatch is a match of UTF-8 text: whether there is one, its 1-based index and length in bytes, its text, and
    its groups, Groups[0] being the whole match. }
  TEcmaMatch = record
    Success: Boolean;
    Index: NativeInt;
    Length: NativeInt;
    Value: UTF8String;
    Groups: TEcmaGroups;
    { Group is the group with the name that took part, or a group that did not when none did. }
    function Group(const Name: UTF8String): TEcmaGroup;
  end;

  { A TEcmaGroupW is what a group of a match of UTF-16 text holds, in code units. }
  TEcmaGroupW = record
    Success: Boolean;
    Index: NativeInt;
    Length: NativeInt;
    Value: UnicodeString;
    Name: UnicodeString;
  end;
  TEcmaGroupsW = array of TEcmaGroupW;

  { A TEcmaMatchW is a match of UTF-16 text, in code units. }
  TEcmaMatchW = record
    Success: Boolean;
    Index: NativeInt;
    Length: NativeInt;
    Value: UnicodeString;
    Groups: TEcmaGroupsW;
    function Group(const Name: UnicodeString): TEcmaGroupW;
  end;

  TEcmaMatchArray = array of TEcmaMatch;
  TEcmaMatchArrayW = array of TEcmaMatchW;

  (* A TEcmaCaptures holds the bounds of the groups of a match, kept from one match to the next so that matching
    allocates nothing once it has room for the pattern's groups. Range reports the 1-based index and the length of
    group G (0 for the whole match), in the units of the text that was matched, and false for a group that did not
    take part. *)
  TEcmaCaptures = record
  private
    FSlots: TPositions;
    FGroups: Int32;
  public
    function Range(G: Int32; out Index, Length: NativeInt): Boolean;
    { GroupCount is the number of groups of the last match, not counting the whole match. }
    property GroupCount: Int32 read FGroups;
  end;

  IEcmaRegex = interface;

  { A TEcmaMatches is the matches of a global search of UTF-8 text, for a for ... in loop. }
  TEcmaMatchEnumerator = record
  private
    FRegex: IEcmaRegex;
    FImpl: TObject;
    FText: UTF8String;
    FAt: NativeInt;
    FCurrent: TEcmaMatch;
  public
    function MoveNext: Boolean;
    property Current: TEcmaMatch read FCurrent;
  end;

  TEcmaMatches = record
  private
    FRegex: IEcmaRegex;
    FImpl: TObject;
    FText: UTF8String;
  public
    function GetEnumerator: TEcmaMatchEnumerator;
    { ToArray is every match. }
    function ToArray: TEcmaMatchArray;
  end;

  TEcmaMatchEnumeratorW = record
  private
    FRegex: IEcmaRegex;
    FImpl: TObject;
    FText: UnicodeString;
    FAt: NativeInt;
    FCurrent: TEcmaMatchW;
  public
    function MoveNext: Boolean;
    property Current: TEcmaMatchW read FCurrent;
  end;

  TEcmaMatchesW = record
  private
    FRegex: IEcmaRegex;
    FImpl: TObject;
    FText: UnicodeString;
  public
    function GetEnumerator: TEcmaMatchEnumeratorW;
    function ToArray: TEcmaMatchArrayW;
  end;

  (* An IEcmaRegex is a compiled pattern. It is safe to share between threads.

    IsMatch, Match and Count search from a 1-based StartIndex (1 by default); with the sticky flag a match must start
    there. Matches is the global search, which moves on past an empty match by a character (a code point with the u
    or v flag, a code unit without). Replace is String.prototype.replace: the first match replaced, or every match
    with the g flag, with the $ forms of the replacement ($$, $&, $`, $', $n, $nn and $<name>) replaced; ReplaceAll
    replaces every match whatever the flags. Split is RegExp.prototype[Symbol.split]: the pieces between the matches,
    with the groups of each match after the piece before it (Success false for a group that did not take part, which
    JavaScript gives as undefined), and at most Limit items (all when Limit is below 0). Exec matches into a
    TEcmaCaptures, which allocates nothing. *)
  IEcmaRegex = interface
    ['{6C1F3B0E-2A7D-4F0B-9E57-3C1D7A40B2E9}']
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

{ ParseEcmaRegexFlags reads flags written as new RegExp reads them, such as 'giu'. A flag that is not one of
  dgimsuvy, a flag given twice, or u with v, raises EEcmaRegexFlags. }
function ParseEcmaRegexFlags(const Flags: string): TEcmaRegexFlags;

{ EcmaRegexFlagsText is the flags as RegExp writes them, in the order dgimsuvy. }
function EcmaRegexFlagsText(Flags: TEcmaRegexFlags): string;

(* CompileEcmaRegex compiles a pattern as new RegExp(pattern, flags) compiles it: with the u or v flag by the grammar
  of the u flag and matched by code point; with neither by the Annex B grammar and matched by UTF-16 code unit. The i,
  m and s flags are the modifiers in force at the start of the pattern, which a modifier group such as (?i:...)
  changes for part of it.

  A pattern can have a match timeout in seconds, as a Regex of .NET has: the time each match may take, which brings a
  cap on the memory of its backtracking with it. A match that reaches a limit raises EEcmaRegexTimeout or
  EEcmaRegexMemory. A pattern without a timeout never reaches a limit. A MatchTimeout below 0 takes the default (see
  SetDefaultEcmaRegexMatchTimeout), and 0 is no timeout.

  An invalid pattern raises EEcmaRegexSyntax, a pattern over a limit of size EEcmaRegexTooLarge, a pattern that is
  not UTF-8 (or, given as a UnicodeString, not well-formed UTF-16) EEcmaRegexEncoding, and invalid flags
  EEcmaRegexFlags. *)
function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string = '';
  MatchTimeout: Double = -1): IEcmaRegex; overload;
function CompileEcmaRegex(const Pattern: UnicodeString; const Flags: string = '';
  MatchTimeout: Double = -1): IEcmaRegex; overload;
function CompileEcmaRegex(const Pattern: UTF8String; Flags: TEcmaRegexFlags;
  MatchTimeout: Double = -1): IEcmaRegex; overload;

{ CompileEcmaRegex with Options compiles a pattern with the settings besides its flags (see TEcmaRegexOptions). Under
  ereEs2020 the d and v flags raise EEcmaRegexFlags. }
function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string;
  const Options: TEcmaRegexOptions): IEcmaRegex; overload;

{ TryCompileEcmaRegex is CompileEcmaRegex with Options that gives its error in place of raising it: it returns true
  with the pattern in Regex, or false with why in Error. A validator that compiles patterns from outside takes this
  form, and gives each a match timeout of its own in Options. }
function TryCompileEcmaRegex(const Pattern: UTF8String; const Flags: string; const Options: TEcmaRegexOptions;
  out Regex: IEcmaRegex; out Error: TEcmaRegexError): Boolean;

{ IsValidEcmaRegex reports whether a pattern is valid with the flags, and with Options, in the grammar of its edition
  and under its version of Unicode (the match timeout is not read). }
function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string = ''): Boolean; overload;
function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string;
  const Options: TEcmaRegexOptions): Boolean; overload;

{ EcmaRegexUnicodeMajor is the major number of the version of Unicode a TEcmaRegexUnicodeVersion stands for: 13, 17
  or 18. }
function EcmaRegexUnicodeMajor(V: TEcmaRegexUnicodeVersion): Int32;

{ SetDefaultEcmaRegexMatchTimeout gives every pattern compiled after it, without a timeout of its own, the match
  timeout in seconds. 0 is no timeout. DefaultEcmaRegexMatchTimeout is the timeout such a pattern takes now. }
procedure SetDefaultEcmaRegexMatchTimeout(Seconds: Double);
function DefaultEcmaRegexMatchTimeout: Double;

{ ReleaseEcmaRegexThreadState frees the working memory the calling thread's matches have used. A thread that has
  matched and is about to end should call it: neither Free Pascal nor Delphi frees that memory when a thread ends. }
procedure ReleaseEcmaRegexThreadState;

implementation

uses
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Prog,
  Corvus.Ecma262.RegularExpressions.Dfa,
  Corvus.Ecma262.RegularExpressions.Utf8,
  Corvus.Ecma262.RegularExpressions.Utf16;

type
  { The text and the unit buffer of each encoding, by shorter names. }
  TText8 = Corvus.Ecma262.RegularExpressions.Utf8.TText;
  TText16 = Corvus.Ecma262.RegularExpressions.Utf16.TText;
  TBuffer8 = Corvus.Ecma262.RegularExpressions.Utf8.TUnitBuffer;
  TBuffer16 = Corvus.Ecma262.RegularExpressions.Utf16.TUnitBuffer;

const
  FlagLetters: string = 'dgimsuvy';

const
  { What FDfa holds for a pattern that has no automaton. }
  NoDfa = Pointer(1);

var
  { The default match timeout in nanoseconds, read and written whole. }
  DefaultTimeout: Int64 = 0;

type
  TEcmaRegex = class(TInterfacedObject, IEcmaRegex)
  private
    FPattern: UTF8String;
    FFlags: TEcmaRegexFlags;
    FSyntax: TSyntax;
    FGroupCount: Int32;
    FGroupNames: array of UTF8String;
    FSearch: TSearch;
    { The pattern needs no backtracking and is small enough for a linear matcher (Re2Cost), so a test from the start
      of a text can be answered by the automaton over ASCII (see the Dfa unit). FDfa is nil until the first such test
      builds it, and then the automaton, or NoDfa for none. }
    FRegular: Boolean;
    FDfa: Pointer;
    function Automaton: TDfa;
    { EnsureCaps builds the program that records every group, on the first match that reports them. }
    procedure EnsureCaps;
    function Text8(const Text: UTF8String): TText8; inline;
    function Checked8(const Text: UTF8String): TText8;
    function Text16(const Text: UnicodeString): TText16; inline;
    function Test8(const T: TText8; Start: NativeInt): Boolean;
    function Test16(const T: TText16; Start: NativeInt): Boolean;
    function Match8(const Text: UTF8String; const T: TText8; Start: NativeInt; out Next: NativeInt): TEcmaMatch;
    function Match16(const Text: UnicodeString; Start: NativeInt; out Next: NativeInt): TEcmaMatchW;
    function Exec8(const T: TText8; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
    function Exec16(const T: TText16; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
    function Replace8(const Text, Replacement: UTF8String; All: Boolean): UTF8String;
    function Replace16(const Text, Replacement: UnicodeString; All: Boolean): UnicodeString;
  public
    constructor Create(const Pattern: UTF8String; Flags: TEcmaRegexFlags; Timeout: Int64;
      Edition: TEcmaRegexEdition = ereCurrent; UnicodeVersion: TEcmaRegexUnicodeVersion = eruDefault);
    destructor Destroy; override;
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
    function Exec(Text: PByte; Len: NativeInt; var Captures: TEcmaCaptures;
      StartIndex: NativeInt = 1): Boolean; overload;
    function Exec(Text: PWideChar; Len: NativeInt; var Captures: TEcmaCaptures;
      StartIndex: NativeInt = 1): Boolean; overload;
    function GroupName(G: Int32): UTF8String;
    function GroupNumbers(const Name: UTF8String): TGroupList;
  end;

{ The functions of each encoding, by shorter names. }

procedure AppendLossy8(var Out_: TBuffer8; const T: TText8; From, To_: NativeInt); inline;
begin
  Corvus.Ecma262.RegularExpressions.Utf8.AppendLossy(Out_, T, From, To_);
end;

function CountAll8(const S: TSearch; const T: TText8): NativeInt; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.CountAll(S, T);
end;

function CountAll16(const S: TSearch; const T: TText16): NativeInt; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.CountAll(S, T);
end;

function ExecSearch8(const S: TSearch; const T: TText8; Start: NativeInt; Sticky: Boolean; Slots: PNativeInt;
  out From, To_: NativeInt): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.ExecSearch(S, T, Start, Sticky, Slots, From, To_);
end;

function ExecSearch16(const S: TSearch; const T: TText16; Start: NativeInt; Sticky: Boolean; Slots: PNativeInt;
  out From, To_: NativeInt): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.ExecSearch(S, T, Start, Sticky, Slots, From, To_);
end;

function InsideFour8(const T: TText8; Pos: NativeInt): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.InsideFour(T, Pos);
end;

function IsValidText8(const T: TText8): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.IsValidText(T);
end;

function MakeText8(P: PByte; N: NativeInt): TText8; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.MakeText(P, N);
end;

function MakeText16(P: PUInt16; N: NativeInt): TText16; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.MakeText(P, N);
end;

function NextStart8(const S: TSearch; const T: TText8; From, To_: NativeInt): NativeInt; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.NextStart(S, T, From, To_);
end;

function NextStart16(const S: TSearch; const T: TText16; From, To_: NativeInt): NativeInt; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.NextStart(S, T, From, To_);
end;

function ReplaceUnits8(const S: TSearch; const T, Template: TText8; All: Boolean; Count: NativeInt;
  var Out_: TBuffer8): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.ReplaceUnits(S, T, Template, All, Count, Out_);
end;

function ReplaceUnits16(const S: TSearch; const T, Template: TText16; All: Boolean; Count: NativeInt;
  var Out_: TBuffer16): Boolean; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.ReplaceUnits(S, T, Template, All, Count, Out_);
end;

function SplitUnits8(const S: TSearch; const T: TText8; Limit: NativeInt): TSpans; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf8.SplitUnits(S, T, Limit);
end;

function SplitUnits16(const S: TSearch; const T: TText16; Limit: NativeInt): TSpans; inline;
begin
  Result := Corvus.Ecma262.RegularExpressions.Utf16.SplitUnits(S, T, Limit);
end;

{ Flags }

function ParseEcmaRegexFlags(const Flags: string): TEcmaRegexFlags;
var
  I, K: Int32;
  F: TEcmaRegexFlag;
begin
  Result := [];
  for I := 1 to Length(Flags) do begin
    K := Pos(Flags[I], FlagLetters);
    if K = 0 then
      raise EEcmaRegexFlags.CreateFmt('invalid flag ''%s'' in ''%s''', [Flags[I], Flags]);
    F := TEcmaRegexFlag(K - 1);
    if F in Result then
      raise EEcmaRegexFlags.CreateFmt('the flag ''%s'' is given twice in ''%s''', [Flags[I], Flags]);
    Include(Result, F);
  end;
  if (erfUnicode in Result) and (erfUnicodeSets in Result) then
    raise EEcmaRegexFlags.CreateFmt('the flags u and v are given together in ''%s''', [Flags]);
end;

function EcmaRegexFlagsText(Flags: TEcmaRegexFlags): string;
var
  F: TEcmaRegexFlag;
begin
  Result := '';
  for F := Low(TEcmaRegexFlag) to High(TEcmaRegexFlag) do
    if F in Flags then
      Result := Result + FlagLetters[Ord(F) + 1];
end;

class function TEcmaRegexOptions.Default: TEcmaRegexOptions;
begin
  Result.MatchTimeout := -1;
  Result.Edition := ereCurrent;
  Result.UnicodeVersion := eruDefault;
end;

function EcmaRegexUnicodeMajor(V: TEcmaRegexUnicodeVersion): Int32;
begin
  case V of
    eru13: Result := 13;
    eru18, eruLatest: Result := 18;
  else
    Result := 17;
  end;
end;

function SyntaxOf(Flags: TEcmaRegexFlags; Edition: TEcmaRegexEdition = ereCurrent;
  UnicodeVersion: TEcmaRegexUnicodeVersion = eruDefault): TSyntax;
begin
  // The grammar of ECMAScript 2020 has no d flag (2022) and no v flag (2024), and refuses them as flags that are not
  // valid.
  if (Edition = ereEs2020) and ((erfHasIndices in Flags) or (erfUnicodeSets in Flags)) then
    raise EEcmaRegexFlags.Create('the flags ''' + EcmaRegexFlagsText(Flags) +
      ''' have d or v, which ECMAScript 2020 does not have');
  Result := Default(TSyntax);
  Result.Es2020 := Edition = ereEs2020;
  Result.UnicodeVersion := EcmaRegexUnicodeMajor(UnicodeVersion);
  Result.Unicode := (erfUnicode in Flags) or (erfUnicodeSets in Flags);
  Result.Sets := erfUnicodeSets in Flags;
  Result.ICase := erfIgnoreCase in Flags;
  Result.Multiline := erfMultiline in Flags;
  Result.DotAll := erfDotAll in Flags;
end;

procedure SetDefaultEcmaRegexMatchTimeout(Seconds: Double);
var
  Ns: Int64;
begin
  if Seconds <= 0 then
    Ns := 0
  else
    Ns := Round(Seconds * 1E9);
  InterlockedExchange64(DefaultTimeout, Ns);
end;

function DefaultEcmaRegexMatchTimeout: Double;
begin
  Result := InterlockedCompareExchange64(DefaultTimeout, 0, 0) / 1E9;
end;

procedure ReleaseEcmaRegexThreadState;
begin
  Corvus.Ecma262.RegularExpressions.Vm.ReleaseEcmaRegexThreadState;
end;

{ Text }

class function TUtf8Text.Create(const Text: RawByteString): TUtf8Text;
begin
  if not IsValidText8(MakeText8(PByte(Pointer(Text)), System.Length(Text))) then
    raise EEcmaRegexEncoding.Create('the text is not UTF-8');
  Result.FText := Text;
  SetCodePage(RawByteString(Result.FText), CP_UTF8, False);
end;

{ Utf16Of is the UTF-16 of UTF-8 text that is known to be well formed. }
function Utf16Of(const S: UTF8String): UnicodeString;
var
  Runes: TRunes;
  K, N: NativeInt;
begin
  DecodeUtf8(S, Runes);
  SetLength(Result, 2 * System.Length(Runes));
  N := 0;
  for K := 0 to High(Runes) do
    if Runes[K] > $FFFF then begin
      Result[N + 1] := WideChar(HighSurrogate(Runes[K]));
      Result[N + 2] := WideChar(LowSurrogate(Runes[K]));
      Inc(N, 2);
    end else begin
      Result[N + 1] := WideChar(Runes[K]);
      Inc(N);
    end;
  SetLength(Result, N);
end;

function Utf8Of(const S: UnicodeString): UTF8String; forward;

{ RunesUtf8 is the UTF-8 of code points. }
function RunesUtf8(const R: TRunes): UTF8String;
var
  W: UnicodeString;
  K, N: NativeInt;
begin
  SetLength(W, 2 * System.Length(R));
  N := 0;
  for K := 0 to High(R) do
    if R[K] > $FFFF then begin
      W[N + 1] := WideChar(HighSurrogate(R[K]));
      W[N + 2] := WideChar(LowSurrogate(R[K]));
      Inc(N, 2);
    end else begin
      W[N + 1] := WideChar(R[K]);
      Inc(N);
    end;
  SetLength(W, N);
  Result := Utf8Of(W);
end;

{ Utf8Of is the UTF-8 of UTF-16 text. It raises EEcmaRegexEncoding for a lone surrogate. }
function Utf8Of(const S: UnicodeString): UTF8String;
var
  K, N: NativeInt;
  C, D: UInt32;
begin
  SetLength(Result, 3 * System.Length(S));
  N := 0;
  K := 1;
  while K <= System.Length(S) do begin
    C := Ord(S[K]);
    if (C >= $D800) and (C <= $DBFF) and (K < System.Length(S)) and (Ord(S[K + 1]) >= $DC00) and
      (Ord(S[K + 1]) <= $DFFF) then begin
      D := Ord(S[K + 1]);
      C := $10000 + ((C - $D800) shl 10) + (D - $DC00);
      Inc(K);
    end else if (C >= $D800) and (C <= $DFFF) then
      raise EEcmaRegexEncoding.Create('the pattern is not well-formed UTF-16');
    if C < $80 then begin
      Result[N + 1] := AnsiChar(C);
      Inc(N);
    end else if C < $800 then begin
      Result[N + 1] := AnsiChar($C0 or (C shr 6));
      Result[N + 2] := AnsiChar($80 or (C and $3F));
      Inc(N, 2);
    end else if C < $10000 then begin
      Result[N + 1] := AnsiChar($E0 or (C shr 12));
      Result[N + 2] := AnsiChar($80 or ((C shr 6) and $3F));
      Result[N + 3] := AnsiChar($80 or (C and $3F));
      Inc(N, 3);
    end else begin
      Result[N + 1] := AnsiChar($F0 or (C shr 18));
      Result[N + 2] := AnsiChar($80 or ((C shr 12) and $3F));
      Result[N + 3] := AnsiChar($80 or ((C shr 6) and $3F));
      Result[N + 4] := AnsiChar($80 or (C and $3F));
      Inc(N, 4);
    end;
    Inc(K);
  end;
  SetLength(Result, N);
end;

{ Piece8 is the text From..To_ of UTF-8 text as a string, with U+FFFD for a half character at a bound between the
  halves of a character of four bytes. }
function Piece8(const Text: UTF8String; const T: TText8; From, To_: NativeInt): UTF8String;
var
  Buf: TBuffer8;
begin
  if InsideFour8(T, From) or ((To_ < T.Len) and InsideFour8(T, To_)) then begin
    Buf.Count := 0;
    AppendLossy8(Buf, T, From, To_);
    SetLength(Result, Buf.Count);
    if Buf.Count > 0 then
      Move(Buf.Data[0], Result[1], Buf.Count);
    Exit;
  end;
  Result := Copy(Text, From + 1, To_ - From);
end;

{ TEcmaMatch }

function TEcmaMatch.Group(const Name: UTF8String): TEcmaGroup;
var
  K: Int32;
begin
  Result := Default(TEcmaGroup);
  for K := 1 to High(Groups) do
    if Groups[K].Name = Name then begin
      Result := Groups[K];
      if Result.Success then
        Exit;
    end;
end;

function TEcmaMatchW.Group(const Name: UnicodeString): TEcmaGroupW;
var
  K: Int32;
begin
  Result := Default(TEcmaGroupW);
  for K := 1 to High(Groups) do
    if Groups[K].Name = Name then begin
      Result := Groups[K];
      if Result.Success then
        Exit;
    end;
end;

{ TEcmaCaptures }

function TEcmaCaptures.Range(G: Int32; out Index, Length: NativeInt): Boolean;
begin
  if (G < 0) or (G > FGroups) or (FSlots[2 * G] < 0) then begin
    Index := 0;
    Length := 0;
    Exit(False);
  end;
  Index := FSlots[2 * G] + 1;
  Length := FSlots[2 * G + 1] - FSlots[2 * G];
  Result := True;
end;

{ Enumerators }

function TEcmaMatchEnumerator.MoveNext: Boolean;
var
  Re: TEcmaRegex;
begin
  Re := TEcmaRegex(FImpl);
  if FAt < 0 then
    Exit(False);
  if FAt > System.Length(FText) then begin
    FAt := -1;
    Exit(False);
  end;
  FCurrent := Re.Match8(FText, Re.Text8(FText), FAt, FAt);
  if not FCurrent.Success then
    FAt := -1;
  Result := FCurrent.Success;
end;

function TEcmaMatches.GetEnumerator: TEcmaMatchEnumerator;
begin
  // The text was checked when the matches were made.
  Result.FRegex := FRegex;
  Result.FImpl := FImpl;
  Result.FText := FText;
  Result.FAt := 0;
  Result.FCurrent := Default(TEcmaMatch);
end;

function TEcmaMatches.ToArray: TEcmaMatchArray;
var
  M: TEcmaMatch;
  N: NativeInt;
begin
  Result := nil;
  N := 0;
  for M in Self do begin
    if N = System.Length(Result) then
      SetLength(Result, 2 * N + 4);
    Result[N] := M;
    Inc(N);
  end;
  SetLength(Result, N);
end;

function TEcmaMatchEnumeratorW.MoveNext: Boolean;
var
  Re: TEcmaRegex;
begin
  Re := TEcmaRegex(FImpl);
  if FAt < 0 then
    Exit(False);
  if FAt > System.Length(FText) then begin
    FAt := -1;
    Exit(False);
  end;
  FCurrent := Re.Match16(FText, FAt, FAt);
  if not FCurrent.Success then
    FAt := -1;
  Result := FCurrent.Success;
end;

function TEcmaMatchesW.GetEnumerator: TEcmaMatchEnumeratorW;
begin
  Result.FRegex := FRegex;
  Result.FImpl := FImpl;
  Result.FText := FText;
  Result.FAt := 0;
  Result.FCurrent := Default(TEcmaMatchW);
end;

function TEcmaMatchesW.ToArray: TEcmaMatchArrayW;
var
  M: TEcmaMatchW;
  N: NativeInt;
begin
  Result := nil;
  N := 0;
  for M in Self do begin
    if N = System.Length(Result) then
      SetLength(Result, 2 * N + 4);
    Result[N] := M;
    Inc(N);
  end;
  SetLength(Result, N);
end;

{ TEcmaRegex }

constructor TEcmaRegex.Create(const Pattern: UTF8String; Flags: TEcmaRegexFlags; Timeout: Int64;
  Edition: TEcmaRegexEdition; UnicodeVersion: TEcmaRegexUnicodeVersion);
var
  Arena: TNodeArena;
  Parsed: TParsed;
  K, J: Int32;
begin
  inherited Create;
  FPattern := Pattern;
  FFlags := Flags;
  FSyntax := SyntaxOf(Flags, Edition, UnicodeVersion);
  Arena := TNodeArena.Create;
  try
    try
      Parsed := ParseWith(Pattern, FSyntax, Arena);
    except
      on E: ESyntax do
        raise EEcmaRegexSyntax.Create(Pattern, E.Message, E.Offset);
    end;
    FGroupCount := Parsed.GroupCount;
    FRegular := not Parsed.NeedsBacktracking and (Re2Cost(Parsed.Root) <= MaxRe2Cost);
    SetLength(FGroupNames, FGroupCount + 1);
    SetLength(FSearch.Names, System.Length(Parsed.Names));
    for K := 0 to High(Parsed.Names) do begin
      FSearch.Names[K].Name8 := RunesUtf8(Parsed.Names[K].Name);
      FSearch.Names[K].Name16 := Utf16Of(FSearch.Names[K].Name8);
      FSearch.Names[K].Groups := Parsed.Names[K].Groups;
      for J := 0 to High(Parsed.Names[K].Groups) do
        FGroupNames[Parsed.Names[K].Groups[J]] := FSearch.Names[K].Name8;
    end;
    FSearch.Prog := CompileProgram(Parsed.Root, FSyntax.Unicode, -1, Arena);
  finally
    // A program that builds its forward automaton later keeps the tree, and has taken the arena.
    if (FSearch.Prog = nil) or (FSearch.Prog.Arena <> Arena) then
      Arena.Free;
  end;
  FSearch.Groups := FGroupCount;
  FSearch.Unicode := FSyntax.Unicode;
  FSearch.Sticky := erfSticky in Flags;
  FSearch.Limit := Timeout;
  if FSearch.Prog.Groups = FGroupCount then
    FSearch.Caps := FSearch.Prog
  else
    FSearch.Caps := nil;
end;

destructor TEcmaRegex.Destroy;
begin
  if (FDfa <> nil) and (FDfa <> NoDfa) then
    TDfa(FDfa).Free;
  if FSearch.Caps <> FSearch.Prog then
    FSearch.Caps.Free;
  FSearch.Prog.Free;
  inherited;
end;

function TEcmaRegex.Automaton: TDfa;
var
  Arena: TNodeArena;
  Built: Pointer;
begin
  Built := FDfa;
  if Built = nil then begin
    Arena := TNodeArena.Create;
    try
      Built := BuildDfa(ParseWith(FPattern, FSyntax, Arena).Root);
    finally
      Arena.Free;
    end;
    if Built = nil then
      Built := NoDfa;
    // Two threads that race both build the automaton, and the one that loses frees its copy.
    if InterlockedCompareExchangePointer(FDfa, Built, nil) <> nil then begin
      if Built <> NoDfa then
        TDfa(Built).Free;
      Built := FDfa;
    end;
  end;
  if Built = NoDfa then
    Result := nil
  else
    Result := TDfa(Built);
end;

procedure TEcmaRegex.EnsureCaps;
var
  Arena: TNodeArena;
  Parsed: TParsed;
  Built: TProgram;
begin
  if FSearch.Caps <> nil then
    Exit;
  Arena := TNodeArena.Create;
  Built := nil;
  try
    Parsed := ParseWith(FPattern, FSyntax, Arena);
    Built := CompileProgram(Parsed.Root, FSyntax.Unicode, FGroupCount, Arena);
  finally
    if (Built = nil) or (Built.Arena <> Arena) then
      Arena.Free;
  end;
  // Two threads that race both build the program, and the one that loses frees its copy.
  if InterlockedCompareExchangePointer(Pointer(FSearch.Caps), Pointer(Built), nil) <> nil then
    Built.Free;
end;

function TEcmaRegex.Text8(const Text: UTF8String): TText8;
begin
  Result := MakeText8(PByte(Pointer(Text)), System.Length(Text));
end;

function TEcmaRegex.Checked8(const Text: UTF8String): TText8;
begin
  Result := Text8(Text);
  if not IsValidText8(Result) then
    raise EEcmaRegexEncoding.Create('the text is not UTF-8');
end;

function TEcmaRegex.Text16(const Text: UnicodeString): TText16;
begin
  Result := MakeText16(PUInt16(Pointer(Text)), System.Length(Text));
end;

function TEcmaRegex.GetPattern: UTF8String;
begin
  Result := FPattern;
end;

function TEcmaRegex.GetFlags: TEcmaRegexFlags;
begin
  Result := FFlags;
end;

function TEcmaRegex.GetFlagsText: string;
begin
  Result := EcmaRegexFlagsText(FFlags);
end;

function TEcmaRegex.GetGroupCount: Int32;
begin
  Result := FGroupCount;
end;

function TEcmaRegex.GetMatchTimeout: Double;
begin
  Result := FSearch.Limit / 1E9;
end;

function TEcmaRegex.GetEdition: TEcmaRegexEdition;
begin
  if FSyntax.Es2020 then
    Result := ereEs2020
  else
    Result := ereCurrent;
end;

function TEcmaRegex.GetUnicodeVersion: Int32;
begin
  Result := FSyntax.UnicodeVersion;
end;

function TEcmaRegex.GroupName(G: Int32): UTF8String;
begin
  if (G < 1) or (G > FGroupCount) then
    Exit('');
  Result := FGroupNames[G];
end;

function TEcmaRegex.GroupNumbers(const Name: UTF8String): TGroupList;
var
  K: Int32;
begin
  for K := 0 to High(FSearch.Names) do
    if FSearch.Names[K].Name8 = Name then
      Exit(Copy(FSearch.Names[K].Groups));
  Result := nil;
end;

(* Test8 and Test16 report whether the pattern matches at or after Start (at Start alone with the y flag): from the
  start of an ASCII text by the automaton where the pattern has one, and otherwise by the matcher. *)
function TEcmaRegex.Test8(const T: TText8; Start: NativeInt): Boolean;
var
  From, To_: NativeInt;
  D: TDfa;
begin
  if (Start = 0) and not FSearch.Sticky and FRegular then begin
    D := Automaton;
    if (D <> nil) and D.IsMatch8(T.P, T.Len, Result) then
      Exit;
  end;
  Result := ExecSearch8(FSearch, T, Start, FSearch.Sticky, nil, From, To_);
end;

function TEcmaRegex.Test16(const T: TText16; Start: NativeInt): Boolean;
var
  From, To_: NativeInt;
  D: TDfa;
begin
  if (Start = 0) and not FSearch.Sticky and FRegular then begin
    D := Automaton;
    if (D <> nil) and D.IsMatch16(T.P, T.Len, Result) then
      Exit;
  end;
  Result := ExecSearch16(FSearch, T, Start, FSearch.Sticky, nil, From, To_);
end;

function TEcmaRegex.IsMatch(const Text: UTF8String; StartIndex: NativeInt): Boolean;
begin
  Result := Test8(Checked8(Text), StartIndex - 1);
end;

function TEcmaRegex.IsMatch(const Text: UnicodeString; StartIndex: NativeInt): Boolean;
begin
  Result := Test16(Text16(Text), StartIndex - 1);
end;

function TEcmaRegex.IsMatch(const Text: TUtf8Text; StartIndex: NativeInt): Boolean;
begin
  Result := Test8(Text8(Text.FText), StartIndex - 1);
end;

function TEcmaRegex.Match8(const Text: UTF8String; const T: TText8; Start: NativeInt;
  out Next: NativeInt): TEcmaMatch;
var
  Slots: TPositions;
  From, To_: NativeInt;
  G: Int32;
begin
  Result := Default(TEcmaMatch);
  Next := -1;
  EnsureCaps;
  SetLength(Slots, 2 * (FGroupCount + 1));
  if not ExecSearch8(FSearch, T, Start, FSearch.Sticky, @Slots[0], From, To_) then
    Exit;
  Next := NextStart8(FSearch, T, From, To_);
  SetLength(Result.Groups, FGroupCount + 1);
  for G := 0 to FGroupCount do begin
    Result.Groups[G].Name := FGroupNames[G];
    if Slots[2 * G] < 0 then
      Continue;
    Result.Groups[G].Success := True;
    Result.Groups[G].Index := Slots[2 * G] + 1;
    Result.Groups[G].Length := Slots[2 * G + 1] - Slots[2 * G];
    Result.Groups[G].Value := Piece8(Text, T, Slots[2 * G], Slots[2 * G + 1]);
  end;
  Result.Success := True;
  Result.Index := Result.Groups[0].Index;
  Result.Length := Result.Groups[0].Length;
  Result.Value := Result.Groups[0].Value;
end;

function TEcmaRegex.Match16(const Text: UnicodeString; Start: NativeInt; out Next: NativeInt): TEcmaMatchW;
var
  Slots: TPositions;
  From, To_: NativeInt;
  G: Int32;
  T: TText16;
begin
  Result := Default(TEcmaMatchW);
  Next := -1;
  EnsureCaps;
  T := Text16(Text);
  SetLength(Slots, 2 * (FGroupCount + 1));
  if not ExecSearch16(FSearch, T, Start, FSearch.Sticky, @Slots[0], From, To_) then
    Exit;
  Next := NextStart16(FSearch, T, From, To_);
  SetLength(Result.Groups, FGroupCount + 1);
  for G := 0 to FGroupCount do begin
    Result.Groups[G].Name := Utf16Of(FGroupNames[G]);
    if Slots[2 * G] < 0 then
      Continue;
    Result.Groups[G].Success := True;
    Result.Groups[G].Index := Slots[2 * G] + 1;
    Result.Groups[G].Length := Slots[2 * G + 1] - Slots[2 * G];
    Result.Groups[G].Value := Copy(Text, Slots[2 * G] + 1, Slots[2 * G + 1] - Slots[2 * G]);
  end;
  Result.Success := True;
  Result.Index := Result.Groups[0].Index;
  Result.Length := Result.Groups[0].Length;
  Result.Value := Result.Groups[0].Value;
end;

function TEcmaRegex.Match(const Text: UTF8String; StartIndex: NativeInt): TEcmaMatch;
var
  Next: NativeInt;
begin
  Result := Match8(Text, Checked8(Text), StartIndex - 1, Next);
end;

function TEcmaRegex.Match(const Text: UnicodeString; StartIndex: NativeInt): TEcmaMatchW;
var
  Next: NativeInt;
begin
  Result := Match16(Text, StartIndex - 1, Next);
end;

function TEcmaRegex.Match(const Text: TUtf8Text; StartIndex: NativeInt): TEcmaMatch;
var
  Next: NativeInt;
begin
  Result := Match8(Text.FText, Text8(Text.FText), StartIndex - 1, Next);
end;

function TEcmaRegex.Matches(const Text: UTF8String): TEcmaMatches;
begin
  Checked8(Text);
  Result.FRegex := Self;
  Result.FImpl := Self;
  Result.FText := Text;
end;

function TEcmaRegex.Matches(const Text: UnicodeString): TEcmaMatchesW;
begin
  Result.FRegex := Self;
  Result.FImpl := Self;
  Result.FText := Text;
end;

function TEcmaRegex.Matches(const Text: TUtf8Text): TEcmaMatches;
begin
  Result.FRegex := Self;
  Result.FImpl := Self;
  Result.FText := Text.FText;
end;

function TEcmaRegex.Count(const Text: UTF8String): NativeInt;
begin
  Result := CountAll8(FSearch, Checked8(Text));
end;

function TEcmaRegex.Count(const Text: UnicodeString): NativeInt;
begin
  Result := CountAll16(FSearch, Text16(Text));
end;

function TEcmaRegex.Count(const Text: TUtf8Text): NativeInt;
begin
  Result := CountAll8(FSearch, Text8(Text.FText));
end;

function TEcmaRegex.Replace8(const Text, Replacement: UTF8String; All: Boolean): UTF8String;
var
  Buf: TBuffer8;
  Template: TText8;
begin
  EnsureCaps;
  Template := Text8(Replacement);
  if not IsValidText8(Template) then
    raise EEcmaRegexEncoding.Create('the replacement is not UTF-8');
  Buf.Count := 0;
  if not ReplaceUnits8(FSearch, Checked8(Text), Template, All, -1, Buf) then
    Exit(Text);
  SetLength(Result, Buf.Count);
  if Buf.Count > 0 then
    Move(Buf.Data[0], Result[1], Buf.Count);
end;

function TEcmaRegex.Replace16(const Text, Replacement: UnicodeString; All: Boolean): UnicodeString;
var
  Buf: TBuffer16;
begin
  EnsureCaps;
  Buf.Count := 0;
  if not ReplaceUnits16(FSearch, Text16(Text), Text16(Replacement), All, -1, Buf) then
    Exit(Text);
  SetLength(Result, Buf.Count);
  if Buf.Count > 0 then
    Move(Buf.Data[0], Result[1], 2 * Buf.Count);
end;

function TEcmaRegex.Replace(const Text, Replacement: UTF8String): UTF8String;
begin
  Result := Replace8(Text, Replacement, erfGlobal in FFlags);
end;

function TEcmaRegex.Replace(const Text, Replacement: UnicodeString): UnicodeString;
begin
  Result := Replace16(Text, Replacement, erfGlobal in FFlags);
end;

function TEcmaRegex.ReplaceAll(const Text, Replacement: UTF8String): UTF8String;
begin
  Result := Replace8(Text, Replacement, True);
end;

function TEcmaRegex.ReplaceAll(const Text, Replacement: UnicodeString): UnicodeString;
begin
  Result := Replace16(Text, Replacement, True);
end;

function TEcmaRegex.Split(const Text: UTF8String; Limit: NativeInt): TEcmaGroups;
var
  Spans: TSpans;
  T: TText8;
  K: NativeInt;
begin
  EnsureCaps;
  T := Checked8(Text);
  Spans := SplitUnits8(FSearch, T, Limit);
  // A managed result can come in holding the caller's last value, and a piece that did not take part is not
  // written.
  Result := nil;
  SetLength(Result, System.Length(Spans));
  for K := 0 to High(Spans) do
    if Spans[K].From >= 0 then begin
      Result[K].Success := True;
      Result[K].Index := Spans[K].From + 1;
      Result[K].Length := Spans[K].To_ - Spans[K].From;
      Result[K].Value := Piece8(Text, T, Spans[K].From, Spans[K].To_);
    end;
end;

function TEcmaRegex.Split(const Text: UnicodeString; Limit: NativeInt): TEcmaGroupsW;
var
  Spans: TSpans;
  K: NativeInt;
begin
  EnsureCaps;
  Spans := SplitUnits16(FSearch, Text16(Text), Limit);
  Result := nil;
  SetLength(Result, System.Length(Spans));
  for K := 0 to High(Spans) do
    if Spans[K].From >= 0 then begin
      Result[K].Success := True;
      Result[K].Index := Spans[K].From + 1;
      Result[K].Length := Spans[K].To_ - Spans[K].From;
      Result[K].Value := Copy(Text, Spans[K].From + 1, Spans[K].To_ - Spans[K].From);
    end;
end;

function TEcmaRegex.Exec8(const T: TText8; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
var
  From, To_: NativeInt;
begin
  EnsureCaps;
  if System.Length(Captures.FSlots) < 2 * (FGroupCount + 1) then
    SetLength(Captures.FSlots, 2 * (FGroupCount + 1));
  Captures.FGroups := FGroupCount;
  Result := ExecSearch8(FSearch, T, StartIndex - 1, FSearch.Sticky, @Captures.FSlots[0], From, To_);
  if not Result then
    Captures.FSlots[0] := -1;
end;

function TEcmaRegex.Exec16(const T: TText16; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
var
  From, To_: NativeInt;
begin
  EnsureCaps;
  if System.Length(Captures.FSlots) < 2 * (FGroupCount + 1) then
    SetLength(Captures.FSlots, 2 * (FGroupCount + 1));
  Captures.FGroups := FGroupCount;
  Result := ExecSearch16(FSearch, T, StartIndex - 1, FSearch.Sticky, @Captures.FSlots[0], From, To_);
  if not Result then
    Captures.FSlots[0] := -1;
end;

function TEcmaRegex.Exec(const Text: UTF8String; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
begin
  Result := Exec8(Checked8(Text), Captures, StartIndex);
end;

function TEcmaRegex.Exec(const Text: UnicodeString; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
begin
  Result := Exec16(Text16(Text), Captures, StartIndex);
end;

function TEcmaRegex.Exec(const Text: TUtf8Text; var Captures: TEcmaCaptures; StartIndex: NativeInt): Boolean;
begin
  Result := Exec8(Text8(Text.FText), Captures, StartIndex);
end;

function TEcmaRegex.Exec(Text: PByte; Len: NativeInt; var Captures: TEcmaCaptures;
  StartIndex: NativeInt): Boolean;
var
  T: TText8;
begin
  T := MakeText8(Text, Len);
  if not IsValidText8(T) then
    raise EEcmaRegexEncoding.Create('the text is not UTF-8');
  Result := Exec8(T, Captures, StartIndex);
end;

function TEcmaRegex.Exec(Text: PWideChar; Len: NativeInt; var Captures: TEcmaCaptures;
  StartIndex: NativeInt): Boolean;
begin
  Result := Exec16(MakeText16(PUInt16(Text), Len), Captures, StartIndex);
end;

{ Compiling }

function TimeoutOf(MatchTimeout: Double): Int64;
begin
  if MatchTimeout < 0 then
    Result := InterlockedCompareExchange64(DefaultTimeout, 0, 0)
  else if MatchTimeout = 0 then
    Result := 0
  else
    Result := Round(MatchTimeout * 1E9);
end;

function CompileEcmaRegex(const Pattern: UTF8String; Flags: TEcmaRegexFlags; MatchTimeout: Double): IEcmaRegex;
begin
  Result := TEcmaRegex.Create(Pattern, Flags, TimeoutOf(MatchTimeout));
end;

function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string; MatchTimeout: Double): IEcmaRegex;
begin
  Result := TEcmaRegex.Create(Pattern, ParseEcmaRegexFlags(Flags), TimeoutOf(MatchTimeout));
end;

function CompileEcmaRegex(const Pattern: UnicodeString; const Flags: string; MatchTimeout: Double): IEcmaRegex;
begin
  Result := TEcmaRegex.Create(Utf8Of(Pattern), ParseEcmaRegexFlags(Flags), TimeoutOf(MatchTimeout));
end;

function CompileEcmaRegex(const Pattern: UTF8String; const Flags: string;
  const Options: TEcmaRegexOptions): IEcmaRegex;
begin
  Result := TEcmaRegex.Create(Pattern, ParseEcmaRegexFlags(Flags), TimeoutOf(Options.MatchTimeout), Options.Edition,
    Options.UnicodeVersion);
end;

function TryCompileEcmaRegex(const Pattern: UTF8String; const Flags: string; const Options: TEcmaRegexOptions;
  out Regex: IEcmaRegex; out Error: TEcmaRegexError): Boolean;
begin
  Regex := nil;
  Error.Kind := eekNone;
  Error.Message := '';
  try
    Regex := CompileEcmaRegex(Pattern, Flags, Options);
  except
    on E: EEcmaRegexSyntax do begin
      Error.Kind := eekSyntax;
      Error.Message := E.Message;
    end;
    on E: EEcmaRegexFlags do begin
      Error.Kind := eekFlags;
      Error.Message := E.Message;
    end;
    on E: EEcmaRegexTooLarge do begin
      Error.Kind := eekTooLarge;
      Error.Message := E.Message;
    end;
    on E: EEcmaRegexEncoding do begin
      Error.Kind := eekEncoding;
      Error.Message := E.Message;
    end;
  end;
  Result := Error.Kind = eekNone;
end;

function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string): Boolean;
begin
  Result := IsValidEcmaRegex(Pattern, Flags, TEcmaRegexOptions.Default);
end;

function IsValidEcmaRegex(const Pattern: UTF8String; const Flags: string; const Options: TEcmaRegexOptions): Boolean;
var
  F: TEcmaRegexFlags;
  Sx: TSyntax;
  Arena: TNodeArena;
begin
  try
    F := ParseEcmaRegexFlags(Flags);
    Sx := SyntaxOf(F, Options.Edition, Options.UnicodeVersion);
  except
    on EEcmaRegexFlags do
      Exit(False);
  end;
  Arena := TNodeArena.Create;
  try
    try
      ParseWith(Pattern, Sx, Arena);
      Result := True;
    except
      on ESyntax do
        Result := False;
      on EEcmaRegexTooLarge do
        Result := False;
      on EEcmaRegexEncoding do
        Result := False;
    end;
  finally
    Arena.Free;
  end;
end;

end.
