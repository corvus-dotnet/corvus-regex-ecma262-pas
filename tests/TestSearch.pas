program TestSearch;
{$I ../src/ecma262.inc}

(* The tests of the searches for where a match starts, and of the automata they use, ported from the Rust crate's
  tests.rs (by way of the Java, Go and Julia engines): each search finds what trying every position finds. A pattern
  is compiled here as Corvus.Ecma262.RegularExpressions compiles it, and again with NoSearch set, which makes the
  search try every position its first set allows. The program prints each failure and a final count, and exits with
  a status other than zero when anything failed. *)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Corvus.Ecma262.RegularExpressions,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Prog,
  Corvus.Ecma262.RegularExpressions.Search,
  Corvus.Ecma262.RegularExpressions.Dfa,
  Corvus.Ecma262.RegularExpressions.Vm,
  Corvus.Ecma262.RegularExpressions.Utf8,
  Corvus.Ecma262.RegularExpressions.Utf16;

type
  TSpanList = array of TPositions;

var
  Failures: Int32 = 0;
  Checks: Int32 = 0;
  Seed: UInt64;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Checks);
  if not Ok then begin
    Inc(Failures);
    if Failures <= 30 then
      WriteLn('FAIL: ', What);
  end;
end;

function Next: UInt64;
begin
  // xorshift, which wraps on purpose.
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 7);
  Seed := Seed xor (Seed shl 17);
  Result := Seed;
end;

function SyntaxOfFlags(const Flags: string): TSyntax;
var
  F: TEcmaRegexFlags;
begin
  F := ParseEcmaRegexFlags(Flags);
  Result.Unicode := (erfUnicode in F) or (erfUnicodeSets in F);
  Result.Sets := erfUnicodeSets in F;
  Result.ICase := erfIgnoreCase in F;
  Result.Multiline := erfMultiline in F;
  Result.DotAll := erfDotAll in F;
end;

{ CompileProgramOf compiles a pattern's program, recording the groups Groups says (as CompileProgram does). }
function CompileProgramOf(const Pattern: UTF8String; const Sx: TSyntax; Groups: Int32; out Count: Int32): TProgram;
var
  Arena: TNodeArena;
  Parsed: TParsed;
begin
  Arena := TNodeArena.Create;
  Result := nil;
  try
    Parsed := ParseWith(Pattern, Sx, Arena);
    Count := Parsed.GroupCount;
    if Groups = MaxInt then
      Groups := Count;
    Result := CompileProgram(Parsed.Root, Sx.Unicode, Groups, Arena);
  finally
    if (Result = nil) or (Result.Arena <> Arena) then
      Arena.Free;
  end;
end;

{ Compile builds the search of a pattern, with the search layer or (Plain) without; false for a pattern that is not
  valid. }
function Compile(const Pattern: UTF8String; const Flags: string; Plain: Boolean; out S: TSearch): Boolean;
var
  Sx: TSyntax;
  Count: Int32;
begin
  S := Default(TSearch);
  try
    Sx := SyntaxOfFlags(Flags);
  except
    Exit(False);
  end;
  NoSearch := Plain;
  try
    try
      S.Prog := CompileProgramOf(Pattern, Sx, -1, Count);
      S.Caps := CompileProgramOf(Pattern, Sx, MaxInt, Count);
    except
      on Exception do begin
        S.Prog.Free;
        S.Prog := nil;
        Exit(False);
      end;
    end;
  finally
    NoSearch := False;
  end;
  S.Groups := Count;
  S.Unicode := Sx.Unicode;
  S.Sticky := Pos('y', Flags) > 0;
  Result := True;
end;

procedure FreeSearch(var S: TSearch);
begin
  S.Prog.Free;
  S.Caps.Free;
  S.Prog := nil;
  S.Caps := nil;
end;

function SameSpans(const A, B: TSpanList): Boolean;
var
  K, J: NativeInt;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for K := 0 to High(A) do begin
    if Length(A[K]) <> Length(B[K]) then
      Exit(False);
    for J := 0 to High(A[K]) do
      if A[K][J] <> B[K][J] then
        Exit(False);
  end;
  Result := True;
end;

{ AllSpans8 and AllSpans16 are each match of a global search, with its groups with Submatch and its bounds alone
  otherwise. }
function AllSpans8(const S: TSearch; const Text: UTF8String; Submatch: Boolean): TSpanList;
var
  T: Corvus.Ecma262.RegularExpressions.Utf8.TText;
  At, From, To_: NativeInt;
  Slots: TPositions;
  P: PNativeInt;
begin
  Result := nil;
  T := Corvus.Ecma262.RegularExpressions.Utf8.MakeText(PByte(Pointer(Text)), Length(Text));
  At := 0;
  while True do begin
    SetLength(Slots, 2 * (S.Groups + 1));
    P := nil;
    if Submatch then
      P := @Slots[0];
    if not Corvus.Ecma262.RegularExpressions.Utf8.ExecSearch(S, T, At, S.Sticky, P, From, To_) then
      Break;
    if not Submatch then begin
      SetLength(Slots, 2);
      Slots[0] := From;
      Slots[1] := To_;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Slots);
    At := Corvus.Ecma262.RegularExpressions.Utf8.NextStart(S, T, From, To_);
    if At > T.Len then
      Break;
  end;
end;

function AllSpans16(const S: TSearch; const Text: UnicodeString; Submatch: Boolean): TSpanList;
var
  T: Corvus.Ecma262.RegularExpressions.Utf16.TText;
  At, From, To_: NativeInt;
  Slots: TPositions;
  P: PNativeInt;
begin
  Result := nil;
  T := Corvus.Ecma262.RegularExpressions.Utf16.MakeText(PUInt16(Pointer(Text)), Length(Text));
  At := 0;
  while True do begin
    SetLength(Slots, 2 * (S.Groups + 1));
    P := nil;
    if Submatch then
      P := @Slots[0];
    if not Corvus.Ecma262.RegularExpressions.Utf16.ExecSearch(S, T, At, S.Sticky, P, From, To_) then
      Break;
    if not Submatch then begin
      SetLength(Slots, 2);
      Slots[0] := From;
      Slots[1] := To_;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Slots);
    At := Corvus.Ecma262.RegularExpressions.Utf16.NextStart(S, T, From, To_);
    if At > T.Len then
      Break;
  end;
end;

function Utf16Of(const S: UTF8String): UnicodeString;
begin
  Result := UTF8Decode(S);
end;

procedure CompareOn(const Searched, Plain: TSearch; const Pattern: UTF8String; const Flags: string;
  const Text: UTF8String);
var
  Submatch: Boolean;
begin
  for Submatch in [True, False] do begin
    Check(SameSpans(AllSpans8(Plain, Text, Submatch), AllSpans8(Searched, Text, Submatch)),
      Format('/%s/%s over UTF-8 %s differs from every position', [Pattern, Flags, Text]));
    Check(SameSpans(AllSpans16(Plain, Utf16Of(Text), Submatch), AllSpans16(Searched, Utf16Of(Text), Submatch)),
      Format('/%s/%s over UTF-16 %s differs from every position', [Pattern, Flags, Text]));
  end;
end;

procedure TestSearchesFindWhatEveryPositionFinds;
const
  Patterns: array[0..81] of UTF8String = (
    'Sherlock', '', 'Sherlock|Street', '', 'Sherlock|Holmes|Watson|Irene|Adler|John|Baker', 'i',
    'Sher[a-z]+|Hol[a-z]+', 'i', '[a-q][^u-z]{13}x', '', '[a-zA-Z]+ing', '', '\s[a-zA-Z]{0,12}ing\s', '',
    '\w+\s+Holmes', '', '\w+\s+Holmes\s+\w+', '', '\b\w+n\b', '', '\w+n\b', '', '.*$', '', '(?:.)??$', '',
    '.*\s', '', 'abcd|bc', '', '(?:x|y)*z|q', '', '\b(?:the|he)\b', 'i', 'Holmes.{0,25}Watson|Watson.{0,25}Holmes',
    '', 'Tom.{1,5}er|er.{1,5}Tom', '', '\w+n(?=\s)', '', '[a-z]+n\B', 'i', '\w+\s+Holmes$', 'm', '[a-z]+ing\b|x', '',
    '.{0,2}(Tom|Sawyer|Huckleberry|Finn)', '', '.{2,4}(Tom|Sawyer|Huckleberry|Finn)', '',
    'Tom.{10,25}river|river.{10,25}Tom', '', '([A-Za-z]awyer|[A-Za-z]inn)\s', '', '[\w\.+-]+@[\w\.-]+\.[\w\.-]+', '',
    '\p{Sm}', '', '(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])', '',
    'Шерлок Холмс|Джон Уотсон', 'i', '夏洛克|福尔摩斯', '', 'sk', 'i', 'ks', 'i', '\u{1F600}a|b\u{10400}', '',
    'a\u{1F600}', '', '\ud83d', '', 'x*y', '', '[a-c]*b+c', '', '(?:ab)?c', '', '\béé\w*', '');
  More: array[0..75] of UTF8String = (
    '(?<=a)b|c', '', '[\p{L}--[a-z]]+t', 'v', '[\q{abc|de}x]y', 'v', '\w+', '', '.*', '', '.+', 's', '[^\n]*', '',
    '[^\n.]+', '', '\p{L}', '', '[\ud800-\udfff]', '', 'Tom|river|Tomas', '', 'ab|a', '', 'sherlock|holmes|k', 'i',
    '\u{1F600}|Ш', '', '(|([^a]|[^a][^a]){2,4}){2}(\3){3,5}?x', '', '[^a]{0,3}(?:xx|x)', '',
    '\s[a-zA-Z]{0,12}ing\s', '', '\d{3}-\d{4}', '', '[0-9]+\.[0-9]+', '', '(?:\d+\.){3}\d+', '',
    '\b\d\d:\d\d\b', '', '[A-Z]{2}\d{2}', '', '(?:1|22|333)\.5\.\d', '', '\d{2}[é5]\d', 'u', '\d{3}[éèêë5]', 'u',
    '^abc', 'm', 'x{0}^abc', '', '\babc\b', '', 'abc\s+\w+', '', 'Sherlock\s+\w+', '', 'a|bc|def', '',
    'colou?r|grey', 'i', '[^a]+b', '', '(?:a|b)+c', '', '\d+', '', '[\d,]+', '', 'x(?:y|z)w', '', 'ab*c|d', '');
  Alphabet: array[0..60] of UTF8String = (
    'a', 'b', 'c', 'e', 'i', 'k', 'n', 's', 't', 'x', 'y', 'g', 'S', 'K', ' ', #10, '.', '@', '1', '2', '5', '+',
    '=', 'ſ', 'K', 'é', 'Ш', 'е', 'р', 'л', 'о', 'к', 'Х', '夏', '洛', '克', '😀', '𐐀', 'ing', 'Tom', 'river',
    'Holmes', 'Sherlock', 'sherLOCK', 'awyer', 'inn', 'Watson', 'Шерлок Холмс', '夏洛克', 'abc', 'de', '0', '25',
    '255.', '192.168.', '333.5.', '12:34', '555-1234', 'AB12', '123é', 'def');
var
  Texts: array[0..59] of UTF8String;
  K, J, N: NativeInt;
  All: array of UTF8String;
  Pattern: UTF8String;
  Base, Flags, Mode: string;
  Searched, Plain: TSearch;
begin
  Seed := $2545F4914F6CDD1D;
  for K := 0 to High(Texts) do begin
    Texts[K] := '';
    N := 1 + NativeInt(Next mod 300);
    for J := 1 to N do
      Texts[K] := Texts[K] + Alphabet[Next mod Length(Alphabet)];
  end;
  SetLength(All, Length(Patterns) + Length(More));
  for K := 0 to High(Patterns) do
    All[K] := Patterns[K];
  for K := 0 to High(More) do
    All[Length(Patterns) + K] := More[K];
  K := 0;
  while K < Length(All) do begin
    Pattern := All[K];
    Base := string(All[K + 1]);
    for Mode in ['', 'u'] do begin
      if Base = 'v' then
        Flags := 'v'
      else
        Flags := Base + Mode;
      if not Compile(Pattern, Flags, False, Searched) then
        Continue;
      Compile(Pattern, Flags, True, Plain);
      Check(Plain.Prog.Search.Plan = pkScan, Format('/%s/%s without the search scans', [Pattern, Flags]));
      for J := 0 to High(Texts) do
        CompareOn(Searched, Plain, Pattern, Flags, Texts[J]);
      FreeSearch(Searched);
      FreeSearch(Plain);
    end;
    Inc(K, 2);
  end;
end;

procedure TestStartsTheFuzzerFound;
const
  Cases: array[0..56] of UTF8String = (
    '\b\w+n\b', '', 'a nation', '\b\w+n\b', '', 'an nation nn nan noon', '\w+\s+Holmes', '', 'Holmes Holmes',
    '\b\d*\s*a\b', '', ' a', '\b\d*\W*x\b', 's', ' ééx', '\b\d*\W*x', '', 'a1 x', '\b\d*\W+\w+ab', '', 'ab0 aab',
    '\b\w*[\u{1F600}-\u{1F64F}]*S\B', 'u', '😀S_n😀S', '\W+[a-z]*\W*a', 'm', ' a', '[a-zéè]+\d*[a-z]+on', 'i',
    ' ONaON', '\w+?[^\w\s]*\d+?n', 'im', '000n', '\w*\W+-$', '', ' a'#$C2#$A0'-a--', '\w*[^\w\s]+k$', '',
    '---_-ka.k', '\b[0-9a-f]*ét', '', #10'ét0aét', '.{1,3}(?:on|\.).', '', '😀😀😀ona on',
    '\b[^\n]{1,3}(?:k|\.)\b', 'im', 'k 😀nk', '[^\n]{1,3}(?:é|a)', '', '中中中a', '\B[^\w\s]{1,3}(?:a|n)', '',
    'a😀a',
    // A later occurrence more than Hi units on, and within Hi characters, allows an earlier start than the one an
    // occurrence's window holds.
    '(|([^a]|[^a][^a]){2,4}){2}(\3){3,5}?x', '', 'bxſſſſſſſſx');
var
  K: NativeInt;
  Mode, Flags: string;
  Searched, Plain: TSearch;
begin
  K := 0;
  while K < Length(Cases) do begin
    for Mode in ['', 'u'] do begin
      Flags := string(Cases[K + 1]) + Mode;
      if not Compile(Cases[K], Flags, False, Searched) then
        Continue;
      Compile(Cases[K], Flags, True, Plain);
      CompareOn(Searched, Plain, Cases[K], Flags, Cases[K + 2]);
      FreeSearch(Searched);
      FreeSearch(Plain);
    end;
    Inc(K, 3);
  end;
end;

procedure TestRareLiteral;
const
  // Twain, Tw and aIa are searched for with a second byte (a T or an I is common), over texts longer than a block.
  Literals: array[0..8] of UTF8String = ('zqj', 'aqj', 'qq', 'Xa', 'abZ', 'jj j', 'Twain', 'Tw', 'aIa');
  Letters: AnsiString = 'abqjzZX TwinI';
var
  L, R, K, N, I: NativeInt;
  Re: IEcmaRegex;
  Text: UTF8String;
  Want, Got8, Got16: TPositions;
  M: TEcmaMatch;
  W: TEcmaMatchW;
begin
  Seed := $2F6B1C3D;
  for L := 0 to High(Literals) do begin
    Re := CompileEcmaRegex(Literals[L], 'g');
    for R := 1 to 200 do begin
      N := Next mod 400;
      SetLength(Text, N);
      for K := 1 to N do
        Text[K] := Letters[1 + Next mod NativeUInt(Length(Letters))];
      Want := nil;
      I := Pos(Literals[L], Text);
      while I > 0 do begin
        SetLength(Want, Length(Want) + 1);
        Want[High(Want)] := I;
        I := Pos(Literals[L], Text, I + Length(Literals[L]));
      end;
      Got8 := nil;
      for M in Re.Matches(Text) do begin
        SetLength(Got8, Length(Got8) + 1);
        Got8[High(Got8)] := M.Index;
      end;
      Got16 := nil;
      for W in Re.Matches(UnicodeString(Text)) do begin
        SetLength(Got16, Length(Got16) + 1);
        Got16[High(Got16)] := W.Index;
      end;
      Check((Length(Got8) = Length(Want)) and (Length(Got16) = Length(Want)) and
        ((Length(Want) = 0) or (CompareMem(@Got8[0], @Want[0], Length(Want) * SizeOf(NativeInt)) and
        CompareMem(@Got16[0], @Want[0], Length(Want) * SizeOf(NativeInt)))),
        Format('the literal %s in %s', [Literals[L], Text]));
    end;
  end;
  // Twain at every offset of the first blocks of its search (Eq2Block): each lane of a block finds it.
  Re := CompileEcmaRegex('Twain', '');
  for K := 0 to 140 do begin
    Text := UTF8String(StringOfChar('a', K)) + 'Twain' + UTF8String(StringOfChar('T', 200 - K));
    M := Re.Match(Text);
    Check(M.Success and (M.Index = K + 1), Format('Twain at %d', [K]));
  end;
end;

procedure TestDotAllRun;
const
  FlagSets: array[0..4] of string = ('s', 'su', 'sv', 'sy', 'suy');
var
  Texts: array[0..5] of UnicodeString;
  F, K, Start, From: NativeInt;
  Flags: string;
  Unicode: Boolean;
  Shortcut, Matcher, Plus, PlusMatcher: TSearch;

  function Span(const S: TSearch; const T: UnicodeString; At: NativeInt; out A, B: NativeInt): Boolean;
  var
    X: Corvus.Ecma262.RegularExpressions.Utf16.TText;
    Slots: TPositions;
  begin
    X := Corvus.Ecma262.RegularExpressions.Utf16.MakeText(PUInt16(Pointer(T)), Length(T));
    SetLength(Slots, 2 * (S.Groups + 1));
    Result := Corvus.Ecma262.RegularExpressions.Utf16.ExecSearch(S, X, At, S.Sticky, @Slots[0], A, B);
  end;

  function MidPair(const T: UnicodeString; At: NativeInt): Boolean;
  begin
    Result := (At > 0) and (At < Length(T)) and (Ord(T[At + 1]) >= $DC00) and (Ord(T[At + 1]) <= $DFFF) and
      (Ord(T[At]) >= $D800) and (Ord(T[At]) <= $DBFF);
  end;

var
  A1, B1, A2, B2: NativeInt;
  G1, G2: Boolean;
begin
  Texts[0] := '';
  Texts[1] := 'a'#$D800;
  Texts[2] := 'a'#$DC00;
  Texts[3] := #$DC00'a'#$D83D#$DE00;
  Texts[4] := #$D83D#$DE00;
  Texts[5] := #$DC00'b'#$D83D#$DE00#$D800'c'#$DBFF;
  for F := 0 to High(FlagSets) do begin
    Flags := FlagSets[F];
    Unicode := (Pos('u', Flags) > 0) or (Pos('v', Flags) > 0);
    Compile('.*', Flags, False, Shortcut);
    Compile('(.*)', Flags, False, Matcher);
    Compile('.+', Flags, False, Plus);
    Compile('(.+)', Flags, False, PlusMatcher);
    Check(Shortcut.Prog.Search.Shape = shLoop, '.* is the loop shape with ' + Flags);
    for K := 0 to High(Texts) do
      for Start := 0 to Length(Texts[K]) do begin
        From := Start;
        if Unicode and MidPair(Texts[K], Start) then
          From := Start - 1;
        G1 := Span(Shortcut, Texts[K], Start, A1, B1);
        G2 := Span(Matcher, Texts[K], Start, A2, B2);
        Check(G1 and G2 and (A1 = A2) and (B1 = B2) and (A1 = From) and (B1 = Length(Texts[K])),
          Format('.* with %s from %d of text %d', [Flags, Start, K]));
        G1 := Span(Plus, Texts[K], Start, A1, B1);
        G2 := Span(PlusMatcher, Texts[K], Start, A2, B2);
        if From < Length(Texts[K]) then
          Check(G1 and G2 and (A1 = A2) and (B1 = B2) and (A1 = From) and (B1 = Length(Texts[K])),
            Format('.+ with %s from %d of text %d', [Flags, Start, K]))
        else
          Check(not G1 and not G2, Format('.+ with %s from %d of text %d finds nothing', [Flags, Start, K]));
      end;
    FreeSearch(Shortcut);
    FreeSearch(Matcher);
    FreeSearch(Plus);
    FreeSearch(PlusMatcher);
  end;
end;

procedure TestForwardKept;
var
  S: TSearch;
begin
  Compile('(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])', '', False, S);
  Check(S.Prog.Forward <> nil, 'the forward automaton is built for the scan');
  Check(S.Prog.Skip <> nil, 'the skip window is found');
  FreeSearch(S);
  Compile('\d{3}-\d{4}', '', True, S);
  Check(S.Prog.Forward = nil, 'no forward automaton without the search');
  FreeSearch(S);
end;

procedure TestRareUnit16;
const
  Cases: array[0..23] of UTF8String = ('Twain', 'u', 'Twi Twa Twain Twain Twai', 'aqj', 'u', 'q aq aqj qj aqjaqj',
    'zqj', '', 'zq zqj', 'Шерлок', 'u', 'Ш Шерлок шерлок', '夏洛克', 'u', '夏洛 夏洛克夏洛克', 'a😀b', 'u',
    'a😀 a😀b', 'Sherlock|Street', 'u', 'Sher Street Sherlock St', 'Sherlock|Street', 'y', 'Street');
var
  K, From: NativeInt;
  Searched, Plain: TSearch;
  Text: UnicodeString;
  X: Corvus.Ecma262.RegularExpressions.Utf16.TText;
  A1, B1, A2, B2: NativeInt;
  F1, F2: Boolean;
begin
  K := 0;
  while K < Length(Cases) do begin
    Compile(Cases[K], string(Cases[K + 1]) + 'g', False, Searched);
    Compile(Cases[K], string(Cases[K + 1]) + 'g', True, Plain);
    Text := Utf16Of(Cases[K + 2]);
    Check(SameSpans(AllSpans16(Plain, Text, False), AllSpans16(Searched, Text, False)),
      'the UTF-16 search for ' + string(Cases[K]));
    X := Corvus.Ecma262.RegularExpressions.Utf16.MakeText(PUInt16(Pointer(Text)), Length(Text));
    for From := 0 to Length(Text) do begin
      F1 := Corvus.Ecma262.RegularExpressions.Utf16.ExecSearch(Searched, X, From, Searched.Sticky, nil, A1, B1);
      F2 := Corvus.Ecma262.RegularExpressions.Utf16.ExecSearch(Plain, X, From, Plain.Sticky, nil, A2, B2);
      Check((F1 = F2) and (not F1 or ((A1 = A2) and (B1 = B2))),
        Format('the UTF-16 search for %s from %d', [Cases[K], From]));
    end;
    FreeSearch(Searched);
    FreeSearch(Plain);
    Inc(K, 3);
  end;
end;

procedure TestPlans;
type
  TPlanCase = record
    Pattern: UTF8String;
    Flags: string;
    Plan: TPlanKind;
    Shape: TShape;
    Reverse: Boolean;
  end;
const
  Cases: array[0..5] of TPlanCase = (
    (Pattern: 'Sherlock'; Flags: ''; Plan: pkWindows; Shape: shLiterals; Reverse: False),
    (Pattern: 'Sherlock|Holmes|Watson'; Flags: 'i'; Plan: pkWindows; Shape: shForms; Reverse: False),
    (Pattern: '[a-zA-Z]+ing'; Flags: ''; Plan: pkAfterLoops; Shape: shNone; Reverse: False),
    (Pattern: '.{0,2}(Tom|Sawyer|Huckleberry|Finn)'; Flags: ''; Plan: pkWindows; Shape: shNone; Reverse: True),
    (Pattern: '\w+'; Flags: ''; Plan: pkScan; Shape: shLoop; Reverse: False),
    (Pattern: '\p{Sm}'; Flags: 'u'; Plan: pkScan; Shape: shSet; Reverse: False));
var
  K: NativeInt;
  S: TSearch;
begin
  for K := 0 to High(Cases) do begin
    Compile(Cases[K].Pattern, Cases[K].Flags, False, S);
    Check((S.Prog.Search.Plan = Cases[K].Plan) and (S.Prog.Search.Shape = Cases[K].Shape) and
      ((S.Prog.Search.Reverse <> nil) = Cases[K].Reverse), 'the plan of ' + string(Cases[K].Pattern));
    FreeSearch(S);
  end;
  Compile('Sherlock\s+\w+', '', False, S);
  Check(S.Prog.HasAfter and (S.Prog.AnchoredDfa <> nil), 'the automaton goes on after the literal');
  FreeSearch(S);
  Compile('\b\w+n\b', '', False, S);
  Check(S.Prog.Search.LeadingWordBoundary, 'a leading word boundary is passed over inside a word');
  FreeSearch(S);
end;

(* The automaton over ASCII agrees with the matcher over ASCII texts, for patterns it takes, and decides every ASCII
  text. *)
procedure TestAutomaton;
const
  Patterns: array[0..19] of UTF8String = ('^[a-z]+\d*$', '', '\bfoo\b', '', '\Bo+\B', 'u', '(a|ab)(c|bcd)(d*)', '',
    'colou?r', 'i', '^$', '', 'x{2,4}y', '', '[^\s]+@[^\s]+', 'u', 'a|', '', '(?:ab)*c', '');
  Texts: array[0..14] of UTF8String = ('', 'a', 'abc123', 'foo', 'a foo b', 'food', 'xxy', 'xxxxxy', 'COLOR',
    'colour', 'a@b', 'abcd', 'ababc', 'éfoo', ' oo ');
var
  K, J: NativeInt;
  Arena: TNodeArena;
  Parsed: TParsed;
  D: TDfa;
  Re: IEcmaRegex;
  Want, Got, Ascii: Boolean;
  Text16: UnicodeString;
  C: Int32;
begin
  K := 0;
  while K < Length(Patterns) do begin
    Arena := TNodeArena.Create;
    try
      Parsed := ParseWith(Patterns[K], SyntaxOfFlags(string(Patterns[K + 1])), Arena);
      Check(not Parsed.NeedsBacktracking and (Re2Cost(Parsed.Root) <= MaxRe2Cost),
        'the automaton takes ' + string(Patterns[K]));
      D := BuildDfa(Parsed.Root);
    finally
      Arena.Free;
    end;
    Check(D <> nil, 'an automaton for ' + string(Patterns[K]));
    if D <> nil then begin
      // Match asks the matcher, and never the automaton.
      Re := CompileEcmaRegex(Patterns[K], string(Patterns[K + 1]));
      for J := 0 to High(Texts) do begin
        Want := Re.Match(Texts[J]).Success;
        Ascii := True;
        for C := 1 to Length(Texts[J]) do
          if Ord(Texts[J][C]) >= $80 then
            Ascii := False;
        if D.IsMatch8(PByte(Pointer(Texts[J])), Length(Texts[J]), Got) then
          Check(Got = Want, Format('the automaton of %s over %s', [Patterns[K], Texts[J]]))
        else
          // A text beyond ASCII may still be decided before its first such unit (a|, which accepts at once).
          Check(not Ascii, Format('the automaton of %s decides %s', [Patterns[K], Texts[J]]));
        Text16 := Utf16Of(Texts[J]);
        if D.IsMatch16(PUInt16(Pointer(Text16)), Length(Text16), Got) then
          Check(Got = Want, Format('the automaton of %s over UTF-16 %s', [Patterns[K], Texts[J]]));
      end;
      D.Free;
    end;
    Inc(K, 2);
  end;
end;

begin
  TestSearchesFindWhatEveryPositionFinds;
  TestStartsTheFuzzerFound;
  TestRareLiteral;
  TestDotAllRun;
  TestForwardKept;
  TestRareUnit16;
  TestPlans;
  TestAutomaton;
  WriteLn(Format('%d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
