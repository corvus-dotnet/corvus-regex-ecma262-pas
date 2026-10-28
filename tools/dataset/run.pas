program run;
{$I ../../src/ecma262.inc}

(* Runs the engine over the ECMA-262 regular expression test data (github.com/corvus-dotnet/ecma262-regex-test-data),
  as the runner of the Rust crate does (tools/src/bin/dataset.rs there), with the same judging rules.

    run <data directory> <wrong-cases output file> [file filter] [utf16|utf8|both] [--threads N] [--compliance <file>]
      [--edition current|es2020] [--unicode 13|17|18|latest]

  Each record is asked about under each grammar V8 found it valid in: the record's flags with u added (the unicode
  answers), the record's flags alone (the legacy answers) and, in the file that has them, the flags with v added (the
  unicode_sets answers). A text is matched as UTF-16 and as UTF-8; a text with a lone surrogate has no UTF-8 form and
  is matched as UTF-16 alone. Records marked v8_deviation are left out. A pattern is UTF-8, so a lone surrogate in one
  is read as U+FFFD, as the Rust runner reads it. captures.jsonl is judged on exec, the global search, the sticky
  flag, replace and split. ill-formed-utf8.jsonl holds bytes that are not UTF-8, each one answer over UTF-8 under each
  grammar the pattern is valid in, whose right answer is a refusal: an EEcmaRegexEncoding.

  exec/test262.jsonl, the exec calls of test262 (in a directory of its own), is judged last: each call one exec with
  the record's flags from its lastIndex, right when the positions of the match and of every group, the named groups
  and, with g or y, the lastIndex after are V8's; one answer over UTF-16 and, when the text holds no lone surrogate
  and lastIndex is not between the halves of a pair, one over UTF-8 with positions in bytes.

  With --edition and --unicode the engine reads every pattern with that edition's grammar and that version's tables,
  and the data is the data as node edition.js apply or node unicode.js apply writes it for them.

  With --compliance <file>, the engine's compliance object is written to the file, as the benchmark page reads it
  (docs/implementing-a-source.md in corvus-regex-ecma262-benchmarks): the counts, this runner and the calls it makes
  in each encoding, and what it leaves out, which for this library is nothing. *)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Math,
  Corvus.Ecma262.RegularExpressions;

const
  Limit = 2.0;
  Replacement: UnicodeString = '<$&|$1|$2|$10|$<a>|$$|$`|$''>';
  ExecFile = 'exec/test262.jsonl';

type
  TCounts = record
    Right, Wrong, Refused, Accepted, Limited, Errors: Int64;
  end;

  TJsonKind = (jNull, jBool, jNumber, jString, jArray, jObject);

  { A TJson is a value of a small JSON reader whose strings are UTF-16 and keep lone surrogates. }
  TJson = class
  public
    Kind: TJsonKind;
    B: Boolean;
    N: Double;
    S: UnicodeString;
    Items: array of TJson;
    Keys: array of UnicodeString;
    destructor Destroy; override;
    function Get(const Name: UnicodeString): TJson;
  end;

  TReader = record
    S: RawByteString;
    I: NativeInt;
  end;

var
  Invariant: TFormatSettings;
  AsUtf16: Boolean = True;
  AsUtf8: Boolean = True;

destructor TJson.Destroy;
var
  K: NativeInt;
begin
  for K := 0 to High(Items) do
    Items[K].Free;
  inherited;
end;

function TJson.Get(const Name: UnicodeString): TJson;
var
  K: NativeInt;
begin
  if (Self = nil) or (Kind <> jObject) then
    Exit(nil);
  for K := 0 to High(Keys) do
    if Keys[K] = Name then
      Exit(Items[K]);
  Result := nil;
end;

{ JSON }

procedure Space(var R: TReader);
begin
  while (R.I <= Length(R.S)) and (R.S[R.I] in [' ', #9, #10, #13]) do
    Inc(R.I);
end;

procedure Expect(var R: TReader; C: AnsiChar);
begin
  if (R.I > Length(R.S)) or (R.S[R.I] <> C) then
    raise Exception.CreateFmt('expected %s at %d', [C, R.I]);
  Inc(R.I);
end;

function JsonString(var R: TReader): UnicodeString;
var
  Out_: UnicodeString;
  N: NativeInt;
  C: AnsiChar;
  B0: Byte;
  Cp: UInt32;
  Need: Int32;

  procedure Add(U: UInt32);
  begin
    if N = Length(Out_) then
      SetLength(Out_, 2 * N + 16);
    Out_[N + 1] := WideChar(U);
    Inc(N);
  end;

begin
  Expect(R, '"');
  SetLength(Out_, 16);
  N := 0;
  while True do begin
    C := R.S[R.I];
    if C = '"' then begin
      Inc(R.I);
      Break;
    end;
    if C <> '\' then begin
      B0 := Byte(C);
      if B0 < $80 then begin
        Add(B0);
        Inc(R.I);
        Continue;
      end;
      if B0 >= $F0 then begin
        Need := 3;
        Cp := B0 and $07;
      end else if B0 >= $E0 then begin
        Need := 2;
        Cp := B0 and $0F;
      end else begin
        Need := 1;
        Cp := B0 and $1F;
      end;
      Inc(R.I);
      while Need > 0 do begin
        Cp := (Cp shl 6) or (Byte(R.S[R.I]) and $3F);
        Inc(R.I);
        Dec(Need);
      end;
      if Cp > $FFFF then begin
        Add($D800 + ((Cp - $10000) shr 10));
        Add($DC00 + ((Cp - $10000) and $3FF));
      end else
        Add(Cp);
      Continue;
    end;
    C := R.S[R.I + 1];
    Inc(R.I, 2);
    case C of
      'n': Add($0A);
      't': Add($09);
      'r': Add($0D);
      'b': Add($08);
      'f': Add($0C);
      'u': begin
        Add(StrToInt('$' + string(Copy(R.S, R.I, 4))));
        Inc(R.I, 4);
      end;
    else
      Add(Ord(C));
    end;
  end;
  SetLength(Out_, N);
  Result := Out_;
end;

function Value(var R: TReader): TJson;
var
  C: AnsiChar;
  Start, K: NativeInt;
  Num: string;
begin
  Space(R);
  Result := TJson.Create;
  C := R.S[R.I];
  case C of
    '{': begin
      Result.Kind := jObject;
      Inc(R.I);
      Space(R);
      if R.S[R.I] = '}' then begin
        Inc(R.I);
        Exit;
      end;
      while True do begin
        Space(R);
        K := Length(Result.Keys);
        SetLength(Result.Keys, K + 1);
        SetLength(Result.Items, K + 1);
        Result.Keys[K] := JsonString(R);
        Space(R);
        Expect(R, ':');
        Result.Items[K] := Value(R);
        Space(R);
        if R.S[R.I] = ',' then begin
          Inc(R.I);
          Continue;
        end;
        Expect(R, '}');
        Exit;
      end;
    end;
    '[': begin
      Result.Kind := jArray;
      Inc(R.I);
      Space(R);
      if R.S[R.I] = ']' then begin
        Inc(R.I);
        Exit;
      end;
      while True do begin
        K := Length(Result.Items);
        SetLength(Result.Items, K + 1);
        Result.Items[K] := Value(R);
        Space(R);
        if R.S[R.I] = ',' then begin
          Inc(R.I);
          Continue;
        end;
        Expect(R, ']');
        Exit;
      end;
    end;
    '"': begin
      Result.Kind := jString;
      Result.S := JsonString(R);
    end;
    't': begin
      Result.Kind := jBool;
      Result.B := True;
      Inc(R.I, 4);
    end;
    'f': begin
      Result.Kind := jBool;
      Inc(R.I, 5);
    end;
    'n': begin
      Result.Kind := jNull;
      Inc(R.I, 4);
    end;
  else
    Start := R.I;
    while (R.I <= Length(R.S)) and (R.S[R.I] in ['+', '-', '0'..'9', '.', 'e', 'E']) do
      Inc(R.I);
    Num := string(Copy(R.S, Start, R.I - Start));
    Result.Kind := jNumber;
    Result.N := StrToFloat(Num, Invariant);
  end;
end;

function ParseJson(const Line: RawByteString): TJson;
var
  R: TReader;
begin
  R.S := Line;
  R.I := 1;
  Result := Value(R);
end;

function Str(J: TJson): UnicodeString;
begin
  if (J <> nil) and (J.Kind = jString) then
    Result := J.S
  else
    Result := '';
end;

function IsTrue(J: TJson): Boolean;
begin
  Result := (J <> nil) and (J.Kind = jBool) and J.B;
end;

function IsFalse(J: TJson): Boolean;
begin
  Result := (J <> nil) and (J.Kind = jBool) and not J.B;
end;

{ Text }

function HasLoneSurrogate(const S: UnicodeString): Boolean;
var
  K: NativeInt;
  C: Word;
begin
  K := 1;
  while K <= Length(S) do begin
    C := Ord(S[K]);
    if (C >= $D800) and (C <= $DBFF) then begin
      if (K < Length(S)) and (Ord(S[K + 1]) >= $DC00) and (Ord(S[K + 1]) <= $DFFF) then begin
        Inc(K, 2);
        Continue;
      end;
      Exit(True);
    end;
    if (C >= $DC00) and (C <= $DFFF) then
      Exit(True);
    Inc(K);
  end;
  Result := False;
end;

{ Lossy is the UTF-8 of UTF-16 units, each lone surrogate written as U+FFFD. }
function Lossy(const S: UnicodeString): UTF8String;
var
  K, N: NativeInt;
  C: UInt32;

  procedure Put(B: UInt32);
  begin
    Result[N + 1] := AnsiChar(B);
    Inc(N);
  end;

begin
  SetLength(Result, 3 * Length(S));
  N := 0;
  K := 1;
  while K <= Length(S) do begin
    C := Ord(S[K]);
    if (C >= $D800) and (C <= $DBFF) and (K < Length(S)) and (Ord(S[K + 1]) >= $DC00) and
      (Ord(S[K + 1]) <= $DFFF) then begin
      C := $10000 + ((C - $D800) shl 10) + (Ord(S[K + 1]) - $DC00);
      Inc(K);
    end else if (C >= $D800) and (C <= $DFFF) then
      C := $FFFD;
    if C < $80 then
      Put(C)
    else if C < $800 then begin
      Put($C0 or (C shr 6));
      Put($80 or (C and $3F));
    end else if C < $10000 then begin
      Put($E0 or (C shr 12));
      Put($80 or ((C shr 6) and $3F));
      Put($80 or (C and $3F));
    end else begin
      Put($F0 or (C shr 18));
      Put($80 or ((C shr 12) and $3F));
      Put($80 or ((C shr 6) and $3F));
      Put($80 or (C and $3F));
    end;
    Inc(K);
  end;
  SetLength(Result, N);
end;

function Escape(const S: UnicodeString): string;
var
  K: NativeInt;
  C: Word;
begin
  Result := '';
  for K := 1 to Length(S) do begin
    C := Ord(S[K]);
    if (C >= $20) and (C < $7F) and (C <> Ord('\')) then
      Result := Result + Chr(C)
    else
      Result := Result + '\u' + LowerCase(IntToHex(C, 4));
  end;
end;

function FirstLine(const S: string): string;
var
  K: NativeInt;
begin
  K := Pos(#10, S);
  if K = 0 then
    Result := S
  else
    Result := Copy(S, 1, K - 1);
end;

{ ByteOffsets is, for each UTF-16 index of a text (and the index past its end), the byte offset in UTF-8. }
function ByteOffsets(const S: UnicodeString): TArray<NativeInt>;
var
  K, B: NativeInt;
  C: Word;
begin
  SetLength(Result, Length(S) + 1);
  B := 0;
  K := 1;
  while K <= Length(S) do begin
    Result[K - 1] := B;
    C := Ord(S[K]);
    if (C >= $D800) and (C <= $DBFF) and (K < Length(S)) and (Ord(S[K + 1]) >= $DC00) and
      (Ord(S[K + 1]) <= $DFFF) then begin
      Result[K] := B + 2;
      Inc(B, 4);
      Inc(K, 2);
      Continue;
    end;
    if C < $80 then
      Inc(B)
    else if C < $800 then
      Inc(B, 2)
    else
      Inc(B, 3);
    Inc(K);
  end;
  Result[Length(S)] := B;
end;

var
  { The edition and the version of Unicode the engine reads every pattern with (--edition, --unicode), with the limit
    of each answer. }
  Settings: TEcmaRegexOptions;

function Compile(const Pattern: UTF8String; const Flags: string): IEcmaRegex;
begin
  Result := CompileEcmaRegex(Pattern, Flags, Settings);
end;

function LimitKind(E: Exception): string;
begin
  if E is EEcmaRegexTimeout then
    Result := 'time'
  else if E is EEcmaRegexMemory then
    Result := 'memory'
  else
    Result := '';
end;

type
  TMode = record
    Add: string;
    Answers: UnicodeString;
    Valid: TJson;
  end;

function Modes(R: TJson): TArray<TMode>;
var
  Valid, V: TJson;
begin
  Valid := R.Get('valid');
  SetLength(Result, 2);
  Result[0].Add := 'u';
  Result[0].Answers := 'unicode';
  Result[0].Valid := Valid.Get('unicode');
  Result[1].Add := '';
  Result[1].Answers := 'legacy';
  Result[1].Valid := Valid.Get('legacy');
  V := Valid.Get('unicode_sets');
  if V <> nil then begin
    SetLength(Result, 3);
    Result[2].Add := 'v';
    Result[2].Answers := 'unicode_sets';
    Result[2].Valid := V;
  end;
end;

type
  { A TJudge holds the counts and the wrong cases of one thread. }
  TJudge = class
  public
    C: TCounts;
    Wrong: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Record_(const Name: string; R: TJson);
    procedure JudgeTests(const Name: string; R: TJson; const Pattern: UTF8String);
    procedure JudgeIllFormed(R: TJson; const Pattern: UTF8String);
    procedure JudgeCaptures(R: TJson; const Pattern: UTF8String);
    procedure JudgeExec(R: TJson; const Pattern: UTF8String);
    procedure Check(const Where: string; Expected, Got: Boolean; Err: Exception);
    procedure Verdict(const Where, What: string; Ok: Boolean; Err: Exception);
  end;

constructor TJudge.Create;
begin
  Wrong := TStringList.Create;
end;

destructor TJudge.Destroy;
begin
  Wrong.Free;
  inherited;
end;

procedure TJudge.Record_(const Name: string; R: TJson);
var
  Pattern: UTF8String;
begin
  Pattern := Lossy(Str(R.Get('pattern')));
  if Name = ExecFile then
    JudgeExec(R, Pattern)
  else if Name = 'captures.jsonl' then begin
    if AsUtf16 then
      JudgeCaptures(R, Pattern);
  end else if Name = 'ill-formed-utf8.jsonl' then begin
    if AsUtf8 then
      JudgeIllFormed(R, Pattern);
  end else
    JudgeTests(Name, R, Pattern);
end;

procedure TJudge.Check(const Where: string; Expected, Got: Boolean; Err: Exception);
begin
  if (Err = nil) and (Got = Expected) then
    Inc(C.Right)
  else if Err = nil then begin
    Inc(C.Wrong);
    Wrong.Add('WRONG' + #9 + Where + #9 + 'expected ' + LowerCase(BoolToStr(Expected, True)));
  end else if LimitKind(Err) <> '' then begin
    Inc(C.Limited);
    Wrong.Add('LIMIT' + #9 + Where + #9 + LimitKind(Err));
  end else begin
    Inc(C.Errors);
    Wrong.Add('ERROR' + #9 + Where + #9 + Err.ClassName + ': ' + Err.Message);
  end;
end;

procedure TJudge.Verdict(const Where, What: string; Ok: Boolean; Err: Exception);
begin
  if Err <> nil then begin
    Inc(C.Limited);
    Wrong.Add('LIMIT' + #9 + Where + #9 + What);
  end else if Ok then
    Inc(C.Right)
  else begin
    Inc(C.Wrong);
    Wrong.Add('WRONG' + #9 + Where + #9 + What);
  end;
end;

procedure TJudge.JudgeTests(const Name: string; R: TJson; const Pattern: UTF8String);
var
  Flags, ModeFlags, Shown, Msg, Where: string;
  M: TMode;
  Re: IEcmaRegex;
  Tests, T, Expected: TJson;
  K: NativeInt;
  Text: UnicodeString;
  Got: Boolean;
begin
  Flags := string(Lossy(Str(R.Get('flags'))));
  Shown := Escape(UTF8Decode(Pattern));
  for M in Modes(R) do begin
    ModeFlags := Flags + M.Add;
    try
      Re := Compile(Pattern, ModeFlags);
    except
      on E: Exception do begin
        if E is EEcmaRegexSyntax then
          Msg := 'PARSE: ' + E.Message
        else if E is EEcmaRegexTooLarge then
          Msg := 'TOO-LARGE: ' + E.Message
        else if E is EEcmaRegexFlags then
          // The flags of a grammar the edition does not have (the v flag of ECMAScript 2020): a refusal.
          Msg := 'FLAGS: ' + E.Message
        else begin
          Inc(C.Errors);
          Msg := 'ERROR: ' + E.Message;
        end;
        if IsTrue(M.Valid) then begin
          Inc(C.Refused);
          Wrong.Add('REFUSED' + #9 + Name + #9 + '/' + Shown + '/' + ModeFlags + #9 + FirstLine(Msg));
        end;
        Continue;
      end;
    end;
    if not IsTrue(M.Valid) then begin
      Inc(C.Accepted);
      Wrong.Add('ACCEPTED-INVALID' + #9 + Name + #9 + '/' + Shown + '/' + ModeFlags);
      Continue;
    end;
    Tests := R.Get('tests');
    if Tests = nil then
      Continue;
    for K := 0 to High(Tests.Items) do begin
      T := Tests.Items[K];
      Expected := T.Get(M.Answers);
      if (Expected = nil) or (Expected.Kind <> jBool) then
        Continue;
      Text := Str(T.Get('text'));
      Where := Name + #9 + '/' + Shown + '/' + ModeFlags + #9 + Escape(Text);
      if AsUtf16 then
        try
          Got := Re.IsMatch(Text);
          Check(Where + #9 + 'utf16', Expected.B, Got, nil);
        except
          on E: Exception do
            Check(Where + #9 + 'utf16', Expected.B, False, E);
        end;
      if AsUtf8 and not HasLoneSurrogate(Text) then
        try
          Got := Re.IsMatch(Lossy(Text));
          Check(Where + #9 + 'utf8', Expected.B, Got, nil);
        except
          on E: Exception do
            Check(Where + #9 + 'utf8', Expected.B, False, E);
        end;
    end;
  end;
end;

procedure TJudge.JudgeIllFormed(R: TJson; const Pattern: UTF8String);
const
  Name = 'ill-formed-utf8.jsonl';
var
  Flags, ModeFlags, Shown, Head, Hex: string;
  M: TMode;
  Re: IEcmaRegex;
  Tests: TJson;
  K, J: NativeInt;
  Bytes: RawByteString;
  Got: Boolean;
begin
  Flags := string(Lossy(Str(R.Get('flags'))));
  Shown := Escape(UTF8Decode(Pattern));
  for M in Modes(R) do begin
    ModeFlags := Flags + M.Add;
    Head := Name + #9 + '/' + Shown + '/' + ModeFlags;
    try
      Re := Compile(Pattern, ModeFlags);
    except
      on E: Exception do begin
        if IsTrue(M.Valid) then begin
          Inc(C.Refused);
          Wrong.Add('REFUSED' + #9 + Head + #9 + FirstLine(E.Message));
        end;
        Continue;
      end;
    end;
    if not IsTrue(M.Valid) then begin
      Inc(C.Accepted);
      Wrong.Add('ACCEPTED-INVALID' + #9 + Head);
      Continue;
    end;
    Tests := R.Get('tests');
    if Tests = nil then
      Continue;
    for K := 0 to High(Tests.Items) do begin
      Hex := string(Lossy(Str(Tests.Items[K].Get('bytes'))));
      SetLength(Bytes, Length(Hex) div 2);
      for J := 0 to Length(Hex) div 2 - 1 do
        Bytes[J + 1] := AnsiChar(StrToInt('$' + Copy(Hex, 2 * J + 1, 2)));
      try
        Got := Re.IsMatch(UTF8String(Bytes));
        Inc(C.Wrong);
        Wrong.Add('WRONG' + #9 + Head + #9 + Hex + #9 + 'utf8' + #9 + 'read as UTF-8 (' +
          LowerCase(BoolToStr(Got, True)) + '), not refused');
      except
        on E: Exception do
          if LimitKind(E) <> '' then begin
            Inc(C.Limited);
            Wrong.Add('LIMIT' + #9 + Head + #9 + Hex + #9 + 'utf8');
          end else if E is EEcmaRegexEncoding then
            Inc(C.Right)
          else begin
            Inc(C.Errors);
            Wrong.Add('ERROR' + #9 + Head + #9 + Hex + #9 + 'utf8' + #9 + E.Message);
          end;
      end;
    end;
  end;
end;

{ A TSlots is the bounds of each group of a match, 0-based, -1 for one that did not take part; nil for no match. }
type
  TSlots = TArray<NativeInt>;
  TSlotsList = TArray<TSlots>;
  TByteAt = TArray<NativeInt>;

{ Submatch is the slots of the first match at or after Start (0-based, in the text's units), or nil. }
function Submatch16(const Re: IEcmaRegex; const Text: UnicodeString; Start: NativeInt): TSlots;
var
  Caps: TEcmaCaptures;
  G: Int32;
  Index, Len: NativeInt;
begin
  Caps := Default(TEcmaCaptures);
  if not Re.Exec(Text, Caps, Start + 1) then
    Exit(nil);
  SetLength(Result, 2 * (Re.GroupCount + 1));
  for G := 0 to Re.GroupCount do
    if Caps.Range(G, Index, Len) then begin
      Result[2 * G] := Index - 1;
      Result[2 * G + 1] := Index - 1 + Len;
    end else begin
      Result[2 * G] := -1;
      Result[2 * G + 1] := -1;
    end;
end;

function Submatch8(const Re: IEcmaRegex; const Text: UTF8String; Start: NativeInt): TSlots;
var
  Caps: TEcmaCaptures;
  G: Int32;
  Index, Len: NativeInt;
begin
  Caps := Default(TEcmaCaptures);
  if not Re.Exec(Text, Caps, Start + 1) then
    Exit(nil);
  SetLength(Result, 2 * (Re.GroupCount + 1));
  for G := 0 to Re.GroupCount do
    if Caps.Range(G, Index, Len) then begin
      Result[2 * G] := Index - 1;
      Result[2 * G + 1] := Index - 1 + Len;
    end else begin
      Result[2 * G] := -1;
      Result[2 * G + 1] := -1;
    end;
end;

{ At maps a UTF-16 index of the data to the units of the text matched: itself, or a byte offset. }
function At(const ByteAt: TByteAt; K: NativeInt): NativeInt; inline;
begin
  if ByteAt = nil then
    Result := K
  else
    Result := ByteAt[K];
end;

{ SameSpan compares a span of the answer (null, or [start, end]) with group G of the engine's slots. }
function SameSpan(E: TJson; const Slots: TSlots; G: NativeInt; const ByteAt: TByteAt): Boolean;
var
  Took: Boolean;
begin
  Took := (G >= 0) and (Slots[2 * G] >= 0);
  if (E = nil) or (E.Kind <> jArray) then
    Exit(not Took);
  Result := Took and (At(ByteAt, Round(E.Items[0].N)) = Slots[2 * G]) and
    (At(ByteAt, Round(E.Items[1].N)) = Slots[2 * G + 1]);
end;

{ SameSlots compares an exec answer (null for no match, or each group's span) with the engine's slots. }
function SameSlots(Expected: TJson; const Got: TSlots; const ByteAt: TByteAt): Boolean;
var
  K: NativeInt;
begin
  if (Expected = nil) or (Expected.Kind <> jArray) or (Got = nil) then
    Exit(((Expected = nil) or (Expected.Kind <> jArray)) and (Got = nil));
  if Length(Expected.Items) <> Length(Got) div 2 then
    Exit(False);
  for K := 0 to High(Expected.Items) do
    if not SameSpan(Expected.Items[K], Got, K, ByteAt) then
      Exit(False);
  Result := True;
end;

{ SameAll compares a global search with the data's, which keeps the first twenty matches only: found has at most
  21, and one more than the data has is right only when the data kept twenty. With Bounds only the bounds of each
  whole match are compared. }
function SameAll(All: TJson; const Found: TSlotsList; const ByteAt: TByteAt; Bounds: Boolean): Boolean;
var
  N, Have: NativeInt;
  E: TJson;
begin
  if (All = nil) or (All.Kind <> jArray) then
    Have := 0
  else
    Have := Length(All.Items);
  for N := 0 to High(Found) do begin
    if N >= Have then
      Exit(Have = 20);
    E := All.Items[N];
    if Bounds then begin
      if (E = nil) or (E.Kind <> jArray) or not SameSpan(E.Items[0], Found[N], 0, ByteAt) then
        Exit(False);
    end else if not SameSlots(E, Found[N], ByteAt) then
      Exit(False);
  end;
  Result := not (((Have < 20) and (Length(Found) <> Have)) or ((Have = 20) and (Length(Found) < 20)));
end;

function FindAll16(const Re: IEcmaRegex; const Text: UnicodeString; N: NativeInt): TSlotsList;
var
  M: TEcmaMatchW;
  G, K: NativeInt;
begin
  Result := nil;
  K := 0;
  for M in Re.Matches(Text) do begin
    SetLength(Result, K + 1);
    SetLength(Result[K], 2 * Length(M.Groups));
    for G := 0 to High(M.Groups) do
      if M.Groups[G].Success then begin
        Result[K][2 * G] := M.Groups[G].Index - 1;
        Result[K][2 * G + 1] := M.Groups[G].Index - 1 + M.Groups[G].Length;
      end else begin
        Result[K][2 * G] := -1;
        Result[K][2 * G + 1] := -1;
      end;
    Inc(K);
    if K = N then
      Break;
  end;
end;

function FindAll8(const Re: IEcmaRegex; const Text: UTF8String; N: NativeInt): TSlotsList;
var
  M: TEcmaMatch;
  K: NativeInt;
begin
  Result := nil;
  K := 0;
  for M in Re.Matches(Text) do begin
    SetLength(Result, K + 1);
    SetLength(Result[K], 2);
    Result[K][0] := M.Index - 1;
    Result[K][1] := M.Index - 1 + M.Length;
    Inc(K);
    if K = N then
      Break;
  end;
end;

function SameSplit(Expected: TJson; const Got: TEcmaGroupsW): Boolean;
var
  K: NativeInt;
begin
  if (Expected = nil) or (Expected.Kind <> jArray) or (Length(Expected.Items) <> Length(Got)) then
    Exit(False);
  for K := 0 to High(Got) do
    if Expected.Items[K].Kind <> jString then begin
      if Got[K].Success then
        Exit(False);
    end else if not Got[K].Success or (Got[K].Value <> Expected.Items[K].S) then
      Exit(False);
  Result := True;
end;

procedure TJudge.JudgeCaptures(R: TJson; const Pattern: UTF8String);
const
  ModeNames: array[0..1] of UnicodeString = ('unicode', 'legacy');
var
  Flags, ModeFlags, Shown, Where: string;
  Valid, Tests, T, A: TJson;
  K, MI: NativeInt;
  Text, Out16: UnicodeString;
  Re, G, Y: IEcmaRegex;
  Lone: Boolean;
  U8, Out8: UTF8String;
  ByteAt: TByteAt;
  Got: TSlots;
  Found: TSlotsList;
  Pieces: TEcmaGroupsW;

  function Make(const F: string): IEcmaRegex;
  begin
    try
      Result := Compile(Pattern, F);
    except
      Result := nil;
    end;
  end;

begin
  Flags := string(Lossy(Str(R.Get('flags'))));
  Valid := R.Get('valid');
  Shown := Escape(UTF8Decode(Pattern));
  Tests := R.Get('tests');
  if Tests = nil then
    Exit;
  // A grammar the data finds the pattern not valid in, as an overlay may, must be refused here too.
  for MI := 0 to 1 do begin
    if MI = 0 then
      ModeFlags := Flags + 'u'
    else
      ModeFlags := Flags;
    if IsFalse(Valid.Get(ModeNames[MI])) and (Make(ModeFlags) <> nil) then begin
      Inc(C.Accepted);
      Wrong.Add('ACCEPTED-INVALID' + #9 + 'captures.jsonl' + #9 + '/' + Shown + '/' + ModeFlags);
    end;
  end;
  for MI := 0 to 1 do begin
    if not IsTrue(Valid.Get(ModeNames[MI])) then
      Continue;
    if MI = 0 then
      ModeFlags := Flags + 'u'
    else
      ModeFlags := Flags;
    Re := Make(ModeFlags);
    G := Make(ModeFlags + 'g');
    Y := Make(ModeFlags + 'y');
    for K := 0 to High(Tests.Items) do begin
      T := Tests.Items[K];
      if IsTrue(T.Get('v8_deviation')) then
        Continue;
      A := T.Get(ModeNames[MI]);
      if A = nil then
        Continue;
      Text := Str(T.Get('text'));
      Where := '/' + Shown + '/' + ModeFlags + #9 + Escape(Text);
      if (Re = nil) or (G = nil) or (Y = nil) then begin
        Inc(C.Refused);
        Wrong.Add('REFUSED' + #9 + 'captures.jsonl' + #9 + Where);
        Continue;
      end;
      Where := 'captures.jsonl' + #9 + Where;
      Lone := HasLoneSurrogate(Text);
      if not Lone then begin
        U8 := Lossy(Text);
        ByteAt := ByteOffsets(Text);
      end;

      // exec
      try
        Got := Submatch16(Re, Text, 0);
      except
        on E: Exception do begin
          Inc(C.Limited);
          Wrong.Add('LIMIT' + #9 + Where);
          Continue;
        end;
      end;
      Verdict(Where, 'exec', SameSlots(A.Get('exec'), Got, nil), nil);
      if not Lone then
        try
          Verdict(Where, 'exec-utf8', SameSlots(A.Get('exec'), Submatch8(Re, U8, 0), ByteAt), nil);
        except
          on E: Exception do
            Verdict(Where, 'exec-utf8', False, E);
        end;

      // all
      try
        Found := FindAll16(G, Text, 21);
        Verdict(Where, 'all', SameAll(A.Get('all'), Found, nil, False), nil);
      except
        on E: Exception do
          Verdict(Where, 'all', False, E);
      end;
      if not Lone then
        try
          Found := FindAll8(G, U8, 21);
          Verdict(Where, 'all-utf8', SameAll(A.Get('all'), Found, ByteAt, True), nil);
        except
          on E: Exception do
            Verdict(Where, 'all-utf8', False, E);
        end;

      // sticky at 1
      if Text <> '' then begin
        try
          Verdict(Where, 'sticky', SameSlots(A.Get('sticky'), Submatch16(Y, Text, 1), nil), nil);
        except
          on E: Exception do
            Verdict(Where, 'sticky', False, E);
        end;
        if not Lone and not ((Ord(Text[1]) >= $D800) and (Ord(Text[1]) <= $DBFF)) then
          try
            Verdict(Where, 'sticky-utf8', SameSlots(A.Get('sticky'), Submatch8(Y, U8, ByteAt[1]), ByteAt), nil);
          except
            on E: Exception do
              Verdict(Where, 'sticky-utf8', False, E);
          end;
      end;

      // replace
      try
        Out16 := Re.Replace(Text, Replacement);
        Verdict(Where, 'replace', Out16 = Str(A.Get('replace')), nil);
      except
        on E: Exception do
          Verdict(Where, 'replace', False, E);
      end;
      try
        Out16 := G.Replace(Text, Replacement);
        Verdict(Where, 'replaceAll', Out16 = Str(A.Get('replaceAll')), nil);
      except
        on E: Exception do
          Verdict(Where, 'replaceAll', False, E);
      end;
      if not Lone then begin
        // Over UTF-8 a half character is written as U+FFFD, which is what a lossy conversion of V8's answer writes
        // for it.
        try
          Out8 := Re.Replace(U8, Lossy(Replacement));
          Verdict(Where, 'replace-utf8', Out8 = Lossy(Str(A.Get('replace'))), nil);
        except
          on E: Exception do
            Verdict(Where, 'replace-utf8', False, E);
        end;
        try
          Out8 := G.Replace(U8, Lossy(Replacement));
          Verdict(Where, 'replaceAll-utf8', Out8 = Lossy(Str(A.Get('replaceAll'))), nil);
        except
          on E: Exception do
            Verdict(Where, 'replaceAll-utf8', False, E);
        end;
      end;

      // split
      try
        Pieces := Re.Split(Text, -1);
        Verdict(Where, 'split', SameSplit(A.Get('split'), Pieces), nil);
      except
        on E: Exception do
          Verdict(Where, 'split', False, E);
      end;
      try
        Pieces := Re.Split(Text, 3);
        Verdict(Where, 'split3', SameSplit(A.Get('split3'), Pieces), nil);
      except
        on E: Exception do
          Verdict(Where, 'split3', False, E);
      end;
    end;
  end;
end;

{ LastIndexOf is a call's lastIndex. Past the end of the text exec gives null; test262 sets it as far as 2^53 - 1 and
  Number.MAX_VALUE, so anything past the end reads as the text's length plus one. }
function LastIndexOf(T: TJson; Len: NativeInt): NativeInt;
var
  V: Double;
begin
  V := T.Get('lastIndex').N;
  if V > Len then
    Result := Len + 1
  else
    Result := Trunc(V);
end;

{ InsidePair reports whether a position is between the halves of a surrogate pair, where UTF-8 has no position. }
function InsidePair(const S: UnicodeString; At: NativeInt): Boolean;
begin
  Result := (At > 0) and (At < Length(S)) and (Ord(S[At + 1]) >= $DC00) and (Ord(S[At + 1]) <= $DFFF) and
    (Ord(S[At]) >= $D800) and (Ord(S[At]) <= $DBFF);
end;

{ NamedGroup is the group with the name that took part in the match, or -1. }
function NamedGroup(const Re: IEcmaRegex; const Slots: TSlots; const Name: UTF8String): NativeInt;
var
  G: Int32;
begin
  for G in Re.GroupNumbers(Name) do
    if Slots[2 * G] >= 0 then
      Exit(G);
  Result := -1;
end;

{ SameExec reports whether an engine's match (nil for none) is the call's answer: both null, or the same groups, the
  same named groups (present exactly when the pattern has names) and, with g or y, a lastIndex after at the match's
  end. }
function SameExec(Answer: TJson; const Re: IEcmaRegex; const Slots: TSlots; const Names: TStringList;
  Carries: Boolean; const ByteAt: TByteAt): Boolean;
var
  Captures, Groups: TJson;
  G, K: NativeInt;
  Name: UTF8String;
begin
  if (Answer = nil) or (Answer.Kind = jNull) or (Slots = nil) then
    Exit(((Answer = nil) or (Answer.Kind = jNull)) and (Slots = nil));
  Captures := Answer.Get('captures');
  if (Captures = nil) or (Captures.Kind <> jArray) or (Length(Captures.Items) <> Length(Slots) div 2) then
    Exit(False);
  for G := 0 to High(Captures.Items) do
    if not SameSpan(Captures.Items[G], Slots, G, ByteAt) then
      Exit(False);
  Groups := Answer.Get('groups');
  if (Groups = nil) or (Groups.Kind <> jObject) then begin
    if Names.Count > 0 then
      Exit(False);
  end else begin
    if Length(Groups.Keys) <> Names.Count then
      Exit(False);
    for K := 0 to High(Groups.Keys) do begin
      Name := Lossy(Groups.Keys[K]);
      if (Names.IndexOf(string(Name)) < 0) or
        not SameSpan(Groups.Items[K], Slots, NamedGroup(Re, Slots, Name), ByteAt) then
        Exit(False);
    end;
  end;
  Result := not Carries or (At(ByteAt, Round(Answer.Get('lastIndex').N)) = Slots[1]);
end;

procedure TJudge.JudgeExec(R: TJson; const Pattern: UTF8String);
var
  Flags, Shown, Where, LiText: string;
  Re: IEcmaRegex;
  Carries: Boolean;
  Names: TStringList;
  Tests, T, Answer: TJson;
  K, Start: NativeInt;
  G: Int32;
  Text: UnicodeString;
  Slots: TSlots;
  ByteAt: TByteAt;
  Li: Double;
  Err: Boolean;
begin
  Flags := string(Lossy(Str(R.Get('flags'))));
  Shown := Escape(UTF8Decode(Pattern));
  try
    Re := Compile(Pattern, Flags);
  except
    on E: Exception do begin
      Inc(C.Refused);
      Wrong.Add('REFUSED' + #9 + ExecFile + #9 + '/' + Shown + '/' + Flags + #9 + FirstLine(E.Message));
      Exit;
    end;
  end;
  Carries := (Pos('g', Flags) > 0) or (Pos('y', Flags) > 0);
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    Names.CaseSensitive := True;
    for G := 1 to Re.GroupCount do
      if Re.GroupName(G) <> '' then
        Names.Add(string(Re.GroupName(G)));
    Tests := R.Get('tests');
    if Tests = nil then
      Exit;
    for K := 0 to High(Tests.Items) do begin
      T := Tests.Items[K];
      if IsTrue(T.Get('v8_deviation')) then
        Continue;
      Text := Str(T.Get('text'));
      if Carries then
        Start := LastIndexOf(T, Length(Text))
      else
        Start := 0;
      Answer := T.Get('answer');
      Li := T.Get('lastIndex').N;
      if (Frac(Li) = 0) and (Abs(Li) < 1E15) then
        LiText := IntToStr(Trunc(Li))
      else
        LiText := FloatToStr(Li, Invariant);
      Where := '/' + Shown + '/' + Flags + #9 + Escape(Text) + #9 + LiText;
      if AsUtf16 then begin
        Err := False;
        Slots := nil;
        try
          if Start <= Length(Text) then
            Slots := Submatch16(Re, Text, Start);
        except
          Err := True;
        end;
        if Err then begin
          Inc(C.Limited);
          Wrong.Add('LIMIT' + #9 + ExecFile + #9 + Where + #9 + 'utf16');
        end else if SameExec(Answer, Re, Slots, Names, Carries, nil) then
          Inc(C.Right)
        else begin
          Inc(C.Wrong);
          Wrong.Add('WRONG' + #9 + ExecFile + #9 + Where + #9 + 'utf16');
        end;
      end;
      if AsUtf8 and not HasLoneSurrogate(Text) and not InsidePair(Text, Start) then begin
        ByteAt := ByteOffsets(Text);
        Err := False;
        Slots := nil;
        try
          if Start <= Length(Text) then
            Slots := Submatch8(Re, Lossy(Text), ByteAt[Start]);
        except
          Err := True;
        end;
        if Err then begin
          Inc(C.Limited);
          Wrong.Add('LIMIT' + #9 + ExecFile + #9 + Where + #9 + 'utf8');
        end else if SameExec(Answer, Re, Slots, Names, Carries, ByteAt) then
          Inc(C.Right)
        else begin
          Inc(C.Wrong);
          Wrong.Add('WRONG' + #9 + ExecFile + #9 + Where + #9 + 'utf8');
        end;
      end;
    end;
  finally
    Names.Free;
  end;
end;

{ The run. }

type
  TWorker = class(TThread)
  public
    Name: string;
    Lines: TStringList;
    Next: PInteger;
    Judge: TJudge;
    Records, Skipped: Int64;
    procedure Execute; override;
  end;

procedure TWorker.Execute;
var
  K: Integer;
  R: TJson;
begin
  while True do begin
    K := InterLockedIncrement(Next^) - 1;
    if K >= Lines.Count then
      Break;
    R := ParseJson(RawByteString(Lines[K]));
    try
      if IsTrue(R.Get('v8_deviation')) then begin
        Inc(Skipped);
        Continue;
      end;
      Inc(Records);
      Judge.Record_(Name, R);
    finally
      R.Free;
    end;
  end;
  ReleaseEcmaRegexThreadState;
end;

procedure AddCounts(var C: TCounts; const O: TCounts);
begin
  Inc(C.Right, O.Right);
  Inc(C.Wrong, O.Wrong);
  Inc(C.Refused, O.Refused);
  Inc(C.Accepted, O.Accepted);
  Inc(C.Limited, O.Limited);
  Inc(C.Errors, O.Errors);
end;

function Matches(const Name, Filter: string): Boolean;
begin
  if Filter = '*.jsonl' then
    Exit(True);
  if (Length(Filter) > 0) and (Filter[Length(Filter)] = '*') then
    Exit(Copy(Name, 1, Length(Filter) - 1) = Copy(Filter, 1, Length(Filter) - 1));
  if (Length(Filter) > 0) and (Filter[1] = '*') then
    Exit(Copy(Name, Length(Name) - Length(Filter) + 2, MaxInt) = Copy(Filter, 2, MaxInt));
  Result := Name = Filter;
end;

procedure WriteCompliance(const Path: string; const T: TCounts);
var
  Calls: string;
  F: TextFile;
begin
  Calls := '';
  if AsUtf16 then
    Calls := '"utf16":["IEcmaRegex.IsMatch","IEcmaRegex.Exec","IEcmaRegex.Matches","IEcmaRegex.Replace",' +
      '"IEcmaRegex.Split"]';
  if AsUtf8 then begin
    if Calls <> '' then
      Calls := Calls + ',';
    Calls := Calls + '"utf8":["IEcmaRegex.IsMatch","IEcmaRegex.Exec","IEcmaRegex.Matches","IEcmaRegex.Replace"]';
  end;
  AssignFile(F, Path);
  Rewrite(F);
  WriteLn(F, Format('{"right":%d,"wrong":%d,"refused":%d,"acceptedInvalid":%d,"limited":%d,"judge":{"runner":' +
    '"https://github.com/corvus-dotnet/corvus-regex-ecma262-pas/blob/main/tools/dataset/run.pas",' +
    '"calls":{%s}},"excludes":[]}', [T.Right, T.Wrong, T.Refused, T.Accepted, T.Limited + T.Errors, Calls]));
  CloseFile(F);
end;

var
  Args: TStringList;
  Directory, WrongPath, Filter, Encodings, Compliance, Name: string;
  Files, Lines, AllWrong: TStringList;
  SR: TSearchRec;
  Threads, K, W: Integer;
  Workers: array of TWorker;
  Total, C: TCounts;
  Records, Skipped: Int64;
  Clock: QWord;
  Next: Integer;
  Out_: TextFile;
begin
  Invariant := DefaultFormatSettings;
  Invariant.DecimalSeparator := '.';
  Invariant.ThousandSeparator := #0;
  Args := TStringList.Create;
  for K := 1 to ParamCount do
    Args.Add(ParamStr(K));
  Compliance := '';
  K := Args.IndexOf('--compliance');
  if K >= 0 then begin
    Compliance := Args[K + 1];
    Args.Delete(K + 1);
    Args.Delete(K);
  end;
  Settings := TEcmaRegexOptions.Default;
  Settings.MatchTimeout := Limit;
  K := Args.IndexOf('--edition');
  if K >= 0 then begin
    if Args[K + 1] = 'es2020' then
      Settings.Edition := ereEs2020
    else if Args[K + 1] <> 'current' then begin
      WriteLn(StdErr, 'the edition is current or es2020, not ', Args[K + 1]);
      Halt(2);
    end;
    Args.Delete(K + 1);
    Args.Delete(K);
  end;
  K := Args.IndexOf('--unicode');
  if K >= 0 then begin
    if (Args[K + 1] = '13') or (Args[K + 1] = '13.0') then
      Settings.UnicodeVersion := eru13
    else if (Args[K + 1] = '17') or (Args[K + 1] = '17.0') then
      Settings.UnicodeVersion := eru17
    else if (Args[K + 1] = '18') or (Args[K + 1] = '18.0') then
      Settings.UnicodeVersion := eru18
    else if Args[K + 1] = 'latest' then
      Settings.UnicodeVersion := eruLatest
    else begin
      WriteLn(StdErr, 'the Unicode version is 13, 17, 18 or latest, not ', Args[K + 1]);
      Halt(2);
    end;
    Args.Delete(K + 1);
    Args.Delete(K);
  end;
  Threads := 4;
  K := Args.IndexOf('--threads');
  if K >= 0 then begin
    Threads := StrToInt(Args[K + 1]);
    Args.Delete(K + 1);
    Args.Delete(K);
  end;
  if Args.Count < 2 then begin
    WriteLn(StdErr, 'usage: run <data directory> <wrong-cases output file> [file filter] [utf16|utf8|both] ' +
      '[--threads N] [--compliance <file>] [--edition current|es2020] [--unicode 13|17|18|latest]');
    Halt(2);
  end;
  Directory := Args[0];
  WrongPath := Args[1];
  Filter := '*.jsonl';
  if Args.Count > 2 then
    Filter := Args[2];
  Encodings := 'both';
  if Args.Count > 3 then
    Encodings := Args[3];
  AsUtf16 := (Encodings = 'both') or (Encodings = 'utf16');
  AsUtf8 := (Encodings = 'both') or (Encodings = 'utf8');

  Files := TStringList.Create;
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.jsonl', faAnyFile, SR) = 0 then begin
    repeat
      if Matches(SR.Name, Filter) then
        Files.Add(SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  Files.Sort;
  // The exec calls of test262: with the default filter, or one that names them.
  if ((Filter = '*.jsonl') or (Copy(Filter, 1, 4) = 'exec')) and
    FileExists(IncludeTrailingPathDelimiter(Directory) + ExecFile) then
    Files.Add(ExecFile);

  Total := Default(TCounts);
  Records := 0;
  Skipped := 0;
  AllWrong := TStringList.Create;
  Clock := GetTickCount64;
  for Name in Files do begin
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(IncludeTrailingPathDelimiter(Directory) + Name);
      for K := Lines.Count - 1 downto 0 do
        if Trim(Lines[K]) = '' then
          Lines.Delete(K);
      Next := 0;
      SetLength(Workers, Threads);
      for W := 0 to Threads - 1 do begin
        Workers[W] := TWorker.Create(True);
        Workers[W].Name := Name;
        Workers[W].Lines := Lines;
        Workers[W].Next := @Next;
        Workers[W].Judge := TJudge.Create;
        Workers[W].FreeOnTerminate := False;
        Workers[W].Start;
      end;
      C := Default(TCounts);
      for W := 0 to Threads - 1 do begin
        Workers[W].WaitFor;
        if Workers[W].FatalException <> nil then begin
          WriteLn(StdErr, Name, ': ', Exception(Workers[W].FatalException).ClassName, ': ',
            Exception(Workers[W].FatalException).Message);
          Halt(3);
        end;
        AddCounts(C, Workers[W].Judge.C);
        AllWrong.AddStrings(Workers[W].Judge.Wrong);
        Inc(Records, Workers[W].Records);
        Inc(Skipped, Workers[W].Skipped);
        Workers[W].Judge.Free;
        Workers[W].Free;
      end;
      WriteLn(Format('%-24s right %10d  wrong %6d  refused-valid %4d  accepted-invalid %4d  limit %4d  %6.1fs',
        [Name, C.Right, C.Wrong, C.Refused, C.Accepted, C.Limited, (GetTickCount64 - Clock) / 1000]));
      AddCounts(Total, C);
    finally
      Lines.Free;
    end;
  end;
  AllWrong.Sort;
  AssignFile(Out_, WrongPath);
  Rewrite(Out_);
  for K := 0 to AllWrong.Count - 1 do
    WriteLn(Out_, AllWrong[K]);
  CloseFile(Out_);
  if Compliance <> '' then
    WriteCompliance(Compliance, Total);
  WriteLn;
  WriteLn(Format('records %d (skipped %d deviations)  right %d  wrong %d  refused-valid %d  accepted-invalid %d  ' +
    'limit %d  errors %d  in %.1fs', [Records, Skipped, Total.Right, Total.Wrong, Total.Refused, Total.Accepted,
    Total.Limited, Total.Errors, (GetTickCount64 - Clock) / 1000]));
  if Total.Wrong + Total.Refused + Total.Accepted + Total.Errors + Total.Limited <> 0 then
    Halt(1);
end.
