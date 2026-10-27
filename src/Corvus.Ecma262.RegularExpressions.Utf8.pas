unit Corvus.Ecma262.RegularExpressions.Utf8;
{$I ecma262.inc}

{ The matcher over UTF-8 text, and reading UTF-8 (units.rs of the Rust crate).

  ECMA-262 matches a pattern that has no u flag a code unit at a time. A character of one, two or three bytes of
  UTF-8 is one code unit. A character of four bytes is two, a high surrogate and a low one, so the matcher has to be
  able to stand between them. That position is written as the offset of the character's third byte. Each half then
  spans two bytes, every position is still an offset into the text, a group is still a pair of offsets, and no UTF-16
  copy of the text is made.

  The third byte of a character is a continuation byte, which is no position at all when matching by code point, so
  the two readings cannot be confused. Only a text with a character of four bytes differs between the two, and the
  instructions that compare bytes (a literal run, a word boundary, a line terminator) need no change: none of them
  can hold at the position between the halves, and all of them are right at every other. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Prog,
  Corvus.Ecma262.RegularExpressions.Vm;

type
  TUnit = Byte;
  PUnit = PByte;

{$I Corvus.Ecma262.RegularExpressions.MatcherIntf.inc}

implementation

uses
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Swar,
  Corvus.Ecma262.RegularExpressions.Literals,
  Corvus.Ecma262.RegularExpressions.Adfa,
  Corvus.Ecma262.RegularExpressions.Search;

{$I Corvus.Ecma262.RegularExpressions.MatcherBase.inc}

const
  IsUtf8 = True;
  { The first byte value that is not a character by itself. }
  RuneSelf = $80;

function Continuation(B: UInt32): Boolean; inline;
begin
  Result := (B and $C0) = $80;
end;

{ DecodeRune is the code point at Pos of the bytes before Stop, with its width in bytes in W: RuneError and 1 for
  bytes that are not UTF-8, and RuneError and 0 for no bytes. }
function DecodeRune(const T: TText; Pos, Stop: NativeInt; out W: NativeInt): Int32;
var
  P0, P1, Lo, Hi: UInt32;
  N: NativeInt;
begin
  if Pos >= Stop then begin
    W := 0;
    Exit(RuneError);
  end;
  P0 := U(T, Pos);
  if P0 < RuneSelf then begin
    W := 1;
    Exit(P0);
  end;
  N := Stop - Pos;
  W := 1;
  Result := RuneError;
  if (P0 >= $C2) and (P0 <= $DF) then begin
    if (N >= 2) and Continuation(U(T, Pos + 1)) then begin
      W := 2;
      Result := Int32(((P0 and $1F) shl 6) or (U(T, Pos + 1) and $3F));
    end;
  end else if (P0 >= $E0) and (P0 <= $EF) then begin
    if (N >= 3) and Continuation(U(T, Pos + 2)) then begin
      if P0 = $E0 then Lo := $A0 else Lo := $80;
      if P0 = $ED then Hi := $9F else Hi := $BF;
      P1 := U(T, Pos + 1);
      if (P1 >= Lo) and (P1 <= Hi) then begin
        W := 3;
        Result := Int32(((P0 and $0F) shl 12) or ((P1 and $3F) shl 6) or (U(T, Pos + 2) and $3F));
      end;
    end;
  end else if (P0 >= $F0) and (P0 <= $F4) then begin
    if (N >= 4) and Continuation(U(T, Pos + 2)) and Continuation(U(T, Pos + 3)) then begin
      if P0 = $F0 then Lo := $90 else Lo := $80;
      if P0 = $F4 then Hi := $8F else Hi := $BF;
      P1 := U(T, Pos + 1);
      if (P1 >= Lo) and (P1 <= Hi) then begin
        W := 4;
        Result := Int32(((P0 and $07) shl 18) or ((P1 and $3F) shl 12) or ((U(T, Pos + 2) and $3F) shl 6) or
          (U(T, Pos + 3) and $3F));
      end;
    end;
  end;
end;

{ DecodeLastRune is the code point that ends at Stop of the bytes from From, with its width in bytes in W. }
function DecodeLastRune(const T: TText; From, Stop: NativeInt; out W: NativeInt): Int32;
var
  Last: UInt32;
  Lim, Start: NativeInt;
begin
  if Stop <= From then begin
    W := 0;
    Exit(RuneError);
  end;
  Last := U(T, Stop - 1);
  if Last < RuneSelf then begin
    W := 1;
    Exit(Last);
  end;
  // A character is four bytes at most, so its first byte is one of the last four.
  Lim := Stop - 4;
  if Lim < From then
    Lim := From;
  Start := Stop - 1;
  while Start > Lim do begin
    Dec(Start);
    if not Continuation(U(T, Start)) then
      Break;
  end;
  Result := DecodeRune(T, Start, Stop, W);
  if Start + W <> Stop then begin
    W := 1;
    Result := RuneError;
  end;
end;

{ UnitAt is the UTF-16 code unit at the position, with the number of bytes it spans in W. }
function UnitAt(const T: TText; Pos: NativeInt; out W: NativeInt): Int32;
var
  C: UInt32;
  R: Int32;
begin
  C := U(T, Pos);
  if C >= $F0 then begin
    R := DecodeRune(T, Pos, T.Len, W);
    if W = 4 then begin
      W := 2;
      Exit(HighSurrogate(R));
    end;
    W := 1;
    Exit(RuneError);
  end;
  if (C >= $80) and (C < $C0) and (Pos >= 2) and (U(T, Pos - 2) >= $F0) then begin
    // Between the halves of the character that starts two bytes back.
    R := DecodeRune(T, Pos - 2, T.Len, W);
    if W = 4 then begin
      W := 2;
      Exit(LowSurrogate(R));
    end;
  end;
  Result := DecodeRune(T, Pos, T.Len, W);
end;

{ UnitBefore is the UTF-16 code unit that ends at the position, with the number of bytes it spans in W. }
function UnitBefore(const T: TText; Pos: NativeInt; out W: NativeInt): Int32;
var
  R: Int32;
  W2: NativeInt;
begin
  Result := DecodeLastRune(T, 0, Pos, W);
  if W = 4 then begin
    W := 2;
    Exit(LowSurrogate(Result));
  end;
  if (W = 1) and (Result = RuneError) and (Pos >= 2) and (T.Len - Pos >= 2) and (U(T, Pos - 2) >= $F0) then begin
    // Between the halves of the character that starts two bytes back.
    R := DecodeRune(T, Pos - 2, T.Len, W2);
    if W2 = 4 then begin
      W := 2;
      Exit(HighSurrogate(R));
    end;
  end;
end;

{ Decode is the code point at the position, with its width in W. }
function Decode(const T: TText; Pos: NativeInt; out W: NativeInt): Int32; inline;
begin
  Result := DecodeRune(T, Pos, T.Len, W);
end;

{ DecodeLast is the code point that ends at the position, with its width in W. }
function DecodeLast(const T: TText; Pos: NativeInt; out W: NativeInt): Int32; inline;
begin
  Result := DecodeLastRune(T, 0, Pos, W);
end;

{ ReadAt is the character at the position: a code unit with Units set, and a code point otherwise. }
function ReadAt(const T: TText; Pos: NativeInt; Units: Boolean; out W: NativeInt): Int32; inline;
begin
  if Units then
    Result := UnitAt(T, Pos, W)
  else
    Result := DecodeRune(T, Pos, T.Len, W);
end;

{ ReadLast is ReadAt for the character that ends at the position. }
function ReadLast(const T: TText; Pos: NativeInt; Units: Boolean; out W: NativeInt): Int32; inline;
begin
  if Units then
    Result := UnitBefore(T, Pos, W)
  else
    Result := DecodeLastRune(T, 0, Pos, W);
end;

{ GiveBack is the width of the last character of the units From..Pos, read as it was read going forward from From. }
function GiveBack(const T: TText; From, Pos: NativeInt; Units: Boolean): NativeInt;
begin
  if U(T, Pos - 1) < RuneSelf then
    Exit(1);
  if Units then
    UnitBefore(T, Pos, Result)
  else
    DecodeLastRune(T, From, Pos, Result);
end;

function LineTerminatorAt(const T: TText; Pos: NativeInt): Boolean;
var
  C: UInt32;
begin
  C := U(T, Pos);
  if (C = 10) or (C = 13) then
    Exit(True);
  if C = $E2 then
    Exit((Pos + 2 < T.Len) and (U(T, Pos + 1) = $80) and ((U(T, Pos + 2) = $A8) or (U(T, Pos + 2) = $A9)));
  Result := False;
end;

{ LineTerminatorBefore reports whether a line terminator ends at the position. U+2028 and U+2029 are E2 80 A8 and
  E2 80 A9. }
function LineTerminatorBefore(const T: TText; Pos: NativeInt): Boolean;
var
  C: UInt32;
begin
  C := U(T, Pos - 1);
  if (C = 10) or (C = 13) then
    Exit(True);
  if (C = $A8) or (C = $A9) then
    Exit((Pos >= 3) and (U(T, Pos - 3) = $E2) and (U(T, Pos - 2) = $80));
  Result := False;
end;

{ Whole reports whether the units From..To_, compared equal to a group's, are the same code points. Over UTF-8 they
  always are. }
function Whole(const T: TText; From, To_: NativeInt): Boolean; inline;
begin
  Result := True;
end;

function InsideFour(const T: TText; Pos: NativeInt): Boolean;
var
  W: NativeInt;
begin
  if (Pos < 2) or (Pos >= T.Len) or not Continuation(U(T, Pos)) or (U(T, Pos - 2) < $F0) then
    Exit(False);
  DecodeRune(T, Pos - 2, T.Len, W);
  Result := W = 4;
end;

procedure AppendLossy(var Out_: TUnitBuffer; const T: TText; From, To_: NativeInt);
const
  Replacement: array[0..2] of Byte = ($EF, $BF, $BD);
var
  Tail: Boolean;
begin
  if From >= To_ then
    Exit;
  if InsideFour(T, From) then begin
    Out_.AddRun(@Replacement[0], 3);
    Inc(From, 2);
  end;
  Tail := (To_ < T.Len) and InsideFour(T, To_);
  if Tail then
    Dec(To_, 2);
  if From < To_ then begin
    if (From < 0) or (To_ > T.Len) then
      RaiseRange;
    Out_.AddRun(@T.P[From], To_ - From);
  end;
  if Tail then
    Out_.AddRun(@Replacement[0], 3);
end;

{ NormalizeStart is the position a search from Start begins at. With the u flag a position inside a character means
  the character (RegExpBuiltinExec reads the text as code points); without it every code unit is a position, which
  over UTF-8 is a character's first byte or the third byte of a character of four. }
function NormalizeStart(const T: TText; Start: NativeInt; Unicode: Boolean): NativeInt;
var
  Lead: NativeInt;
begin
  if (Start = 0) or (Start >= T.Len) or not Continuation(U(T, Start)) then
    Exit(Start);
  Lead := Start;
  while (Lead > 0) and Continuation(U(T, Lead)) do
    Dec(Lead);
  if not Unicode and (U(T, Lead) >= $F0) and (Start = Lead + 2) then
    Exit(Start);
  Result := Lead;
end;

{ AdvancePos is the position after the character at Pos (AdvanceStringIndex): a code point with the u flag and a
  code unit without it. }
function AdvancePos(const T: TText; Pos: NativeInt; Unicode: Boolean): NativeInt;
var
  W: NativeInt;
begin
  if Pos >= T.Len then
    Exit(Pos + 1);
  if Unicode then
    DecodeRune(T, Pos, T.Len, W)
  else
    UnitAt(T, Pos, W);
  Result := Pos + W;
end;

{ IsWordUnit reports whether a code unit is one of the 63 ASCII word characters. }
function IsWordUnit(C: UInt32): Boolean; inline;
begin
  Result := (C < $80) and IsWordByte(C);
end;

{ LastOfBack is the position of the last of the ASCII bytes Back in the units From..To_, or From when there is none:
  the give-back of a greedy single character loop (see SetBack), which finds where what follows it can start. }
function LastOfBack(const T: TText; From, To_: NativeInt; const Back: TBytes): NativeInt;
var
  P, K: NativeInt;
  B, C: UInt32;
begin
  P := To_ - 1;
  if Length(Back) = 1 then begin
    B := Back[0];
    while P >= From do begin
      if U(T, P) = B then
        Exit(P);
      Dec(P);
    end;
  end else
    while P >= From do begin
      C := U(T, P);
      for K := 0 to High(Back) do
        if C = Back[K] then
          Exit(P);
      Dec(P);
    end;
  Result := From;
end;

procedure LitOf(I: PInst; out P: PUnit; out N: NativeInt); inline;
begin
  N := Length(I^.Lit8);
  P := @I^.Lit8[0];
end;

function NeedOf(I: PInst): NativeInt; inline;
begin
  Result := I^.Need8;
end;

function IterOf(I: PInst): NativeInt; inline;
begin
  Result := I^.Iter8;
end;

function ProgNeed(Prog: TProgram): NativeInt; inline;
begin
  Result := Prog.Need8;
end;

{ NameIs reports whether the units From..To_ of a template are the name. }
function NameIs(const N: TGroupNameUnits; const T: TText; From, To_: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if To_ - From <> Length(N.Name8) then
    Exit(False);
  for K := 0 to To_ - From - 1 do
    if U(T, From + K) <> Byte(N.Name8[K + 1]) then
      Exit(False);
  Result := True;
end;

function IsValidText(const T: TText): Boolean;
var
  Pos, W: NativeInt;
  R: Int32;
begin
  Pos := 0;
  while Pos < T.Len do begin
    if T.P[Pos] < RuneSelf then begin
      Inc(Pos);
      Continue;
    end;
    R := DecodeRune(T, Pos, T.Len, W);
    if (R = RuneError) and (W = 1) then
      Exit(False);
    Inc(Pos, W);
  end;
  Result := True;
end;

{ The parts of the searches of the matcher that differ between the encodings beyond the unit. }

{ FirstFind is the first position at or after At whose unit a member of the first set can start with, or -1; At
  itself where the search has no first units. FirstStart is FirstFind for the scan. }
function FirstFind(Prog: TProgram; const T: TText; At: NativeInt): NativeInt;
var
  F: ^TFirstBytes;
  N, K: NativeInt;
begin
  if not Prog.Search.HasFirstBytes then
    Exit(At);
  F := @Prog.Search.FirstBytes;
  N := T.Len;
  case F^.Count of
    1: Exit(IndexByte1(T.P, At, N, F^.A));
    2: Exit(IndexByte2(T.P, At, N, F^.A, F^.B));
    3: Exit(IndexByte4(T.P, At, N, F^.A, F^.B, F^.C, F^.C));
  end;
  for K := At to N - 1 do
    if ((F^.Table[T.P[K] shr 6] shr (T.P[K] and 63)) and 1) <> 0 then
      Exit(K);
  Result := -1;
end;

function FirstStart(Prog: TProgram; const T: TText; At: NativeInt): NativeInt; inline;
begin
  Result := FirstFind(Prog, T, At);
end;

{ MidPair reports whether the position is between the halves of a surrogate pair, which UTF-8 has no position for. }
function MidPair(const T: TText; At: NativeInt): Boolean; inline;
begin
  Result := False;
end;

{ RunEndOf is the end of the run of the loop's members that starts at At, or -1 to find it a member at a time. }
function RunEndOf(S: TSearchPlan; const T: TText; At: NativeInt): NativeInt;
var
  N, F, J: NativeInt;
begin
  N := T.Len;
  case S.RunEnd of
    reAll: Exit(N);
    reStops: begin
      case S.NStops of
        1: F := IndexByte1(T.P, At, N, S.Stops[0]);
        2: F := IndexByte2(T.P, At, N, S.Stops[0], S.Stops[1]);
      else
        F := IndexByte4(T.P, At, N, S.Stops[0], S.Stops[1], S.Stops[2], S.Stops[2]);
      end;
      if F < 0 then
        Exit(N);
      Exit(F);
    end;
    reLine: begin
      J := At;
      while True do begin
        J := IndexByte4(T.P, J, N, 10, 13, $E2, $E2);
        if J < 0 then
          Exit(N);
        if (U(T, J) <> $E2) or ((J + 2 < N) and (U(T, J + 1) = $80) and ((U(T, J + 2) or 1) = $A9)) then
          Exit(J);
        Inc(J);
      end;
    end;
  end;
  Result := -1;
end;

{ AfterFind is where the match that starts at Q ends, for a pattern every match of which starts with the one literal
  found at Q: the anchored automaton goes on after it. Or AdfaNone, or AdfaBail where the matcher decides. }
function AfterFind(Prog: TProgram; const T: TText; Q: NativeInt): NativeInt; forward;

{ FindLiterals is the leftmost occurrence of the search's literals at or after From, and FindWithin the one that
  starts at or before Last. }
function FindLiterals(L: TLiterals; const T: TText; From: NativeInt; out S, E: NativeInt): Boolean; inline;
begin
  Result := L.Find8(T.P, T.Len, From, S, E);
end;

function FindWithin(L: TLiterals; const T: TText; From, Last: NativeInt): NativeInt; inline;
begin
  Result := L.FindWithin8(T.P, T.Len, From, Last);
end;

{$I Corvus.Ecma262.RegularExpressions.Matcher.inc}

function AfterFind(Prog: TProgram; const T: TText; Q: NativeInt): NativeInt;
begin
  if not Prog.HasAfter then
    Exit(AdfaBail);
  Result := FindAfterDfa(Prog.AnchoredDfa, T, Q, Q + Prog.AfterLength, Prog.AfterLiteral);
end;

end.
