unit Corvus.Ecma262.RegularExpressions.Utf16;
{$I ecma262.inc}

{ The matcher over UTF-16 text, and reading UTF-16 (units.rs of the Rust crate). A text is code units, which may hold
  lone surrogates: with the u flag a surrogate pair is one code point and a lone surrogate is a code point of its
  own, and without it every code unit is a character. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Prog,
  Corvus.Ecma262.RegularExpressions.Vm;

type
  TUnit = UInt16;
  PUnit = PUInt16;

{$I Corvus.Ecma262.RegularExpressions.MatcherIntf.inc}

implementation

{$I Corvus.Ecma262.RegularExpressions.MatcherBase.inc}

const
  IsUtf8 = False;

function IsHigh(C: UInt32): Boolean; inline;
begin
  Result := (C >= $D800) and (C <= $DBFF);
end;

function IsLow(C: UInt32): Boolean; inline;
begin
  Result := (C >= $DC00) and (C <= $DFFF);
end;

{ Decode is the code point at the position, with its width in units in W: with the u flag a surrogate pair is one
  code point and a lone surrogate is a code point of its own. }
function Decode(const T: TText; Pos: NativeInt; out W: NativeInt): Int32; inline;
var
  C: UInt32;
begin
  C := U(T, Pos);
  if IsHigh(C) and (Pos + 1 < T.Len) and IsLow(U(T, Pos + 1)) then begin
    W := 2;
    Exit($10000 + Int32((C - $D800) shl 10) + Int32(U(T, Pos + 1) - $DC00));
  end;
  W := 1;
  Result := C;
end;

{ DecodeLast is the code point that ends at the position, with its width in W. }
function DecodeLast(const T: TText; Pos: NativeInt; out W: NativeInt): Int32; inline;
var
  C: UInt32;
begin
  C := U(T, Pos - 1);
  if IsLow(C) and (Pos >= 2) and IsHigh(U(T, Pos - 2)) then begin
    W := 2;
    Exit($10000 + Int32((U(T, Pos - 2) - $D800) shl 10) + Int32(C - $DC00));
  end;
  W := 1;
  Result := C;
end;

function ReadAt(const T: TText; Pos: NativeInt; Units: Boolean; out W: NativeInt): Int32; inline;
begin
  if Units then begin
    W := 1;
    Result := U(T, Pos);
  end else
    Result := Decode(T, Pos, W);
end;

function ReadLast(const T: TText; Pos: NativeInt; Units: Boolean; out W: NativeInt): Int32; inline;
begin
  if Units then begin
    W := 1;
    Result := U(T, Pos - 1);
  end else
    Result := DecodeLast(T, Pos, W);
end;

function GiveBack(const T: TText; From, Pos: NativeInt; Units: Boolean): NativeInt;
begin
  if not Units and IsLow(U(T, Pos - 1)) and (Pos >= From + 2) and IsHigh(U(T, Pos - 2)) then
    Exit(2);
  Result := 1;
end;

function IsLineTerminatorUnit(C: UInt32): Boolean; inline;
begin
  Result := (C = $0A) or (C = $0D) or (C = $2028) or (C = $2029);
end;

function LineTerminatorAt(const T: TText; Pos: NativeInt): Boolean;
begin
  Result := IsLineTerminatorUnit(U(T, Pos));
end;

function LineTerminatorBefore(const T: TText; Pos: NativeInt): Boolean;
begin
  Result := IsLineTerminatorUnit(U(T, Pos - 1));
end;

{ Whole reports whether the units From..To_, compared equal to a group's, are the same code points: false only when
  the comparison ends inside a surrogate pair of the text, which the u flag reads as one code point. }
function Whole(const T: TText; From, To_: NativeInt): Boolean;
var
  StartsInside, EndsInside: Boolean;
begin
  StartsInside := (From > 0) and (From < T.Len) and IsLow(U(T, From)) and IsHigh(U(T, From - 1));
  EndsInside := (To_ > From) and (To_ < T.Len) and IsHigh(U(T, To_ - 1)) and IsLow(U(T, To_));
  Result := not (StartsInside or EndsInside);
end;

function InsideFour(const T: TText; Pos: NativeInt): Boolean;
begin
  Result := False;
end;

procedure AppendLossy(var Out_: TUnitBuffer; const T: TText; From, To_: NativeInt);
begin
  if From >= To_ then
    Exit;
  if (From < 0) or (To_ > T.Len) then
    RaiseRange;
  Out_.AddRun(@T.P[From], To_ - From);
end;

function NormalizeStart(const T: TText; Start: NativeInt; Unicode: Boolean): NativeInt;
begin
  if Unicode and (Start > 0) and (Start < T.Len) and IsLow(U(T, Start)) and IsHigh(U(T, Start - 1)) then
    Exit(Start - 1);
  Result := Start;
end;

function AdvancePos(const T: TText; Pos: NativeInt; Unicode: Boolean): NativeInt;
begin
  Result := Pos + 1;
  // With the u flag a surrogate pair is one character.
  if Unicode and (Pos + 1 < T.Len) and IsHigh(U(T, Pos)) and IsLow(U(T, Pos + 1)) then
    Result := Pos + 2;
end;

function IsWordUnit(C: UInt32): Boolean; inline;
begin
  Result := (C < $80) and IsWordByte(C);
end;

{ LastOfBack is never taken: the give-back search is over UTF-8 alone. }
function LastOfBack(const T: TText; From, To_: NativeInt; const Back: TBytes): NativeInt;
begin
  Result := To_;
end;

procedure LitOf(I: PInst; out P: PUnit; out N: NativeInt); inline;
begin
  N := Length(I^.Lit16);
  P := @I^.Lit16[0];
end;

function NeedOf(I: PInst): NativeInt; inline;
begin
  Result := I^.Need16;
end;

function IterOf(I: PInst): NativeInt; inline;
begin
  Result := I^.Iter16;
end;

function ProgNeed(Prog: TProgram): NativeInt; inline;
begin
  Result := Prog.Need16;
end;

function NameIs(const N: TGroupNameUnits; const T: TText; From, To_: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if To_ - From <> Length(N.Name16) then
    Exit(False);
  for K := 0 to To_ - From - 1 do
    if U(T, From + K) <> Ord(N.Name16[K + 1]) then
      Exit(False);
  Result := True;
end;

function IsValidText(const T: TText): Boolean;
begin
  Result := True;
end;

{$I Corvus.Ecma262.RegularExpressions.Matcher.inc}

end.
