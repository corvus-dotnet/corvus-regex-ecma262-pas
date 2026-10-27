unit Corvus.Ecma262.RegularExpressions.Swar;
{$I ecma262.inc}

{ The searches the Rust crate takes from memchr. One byte is the run-time library's IndexByte, which is assembler on
  x86_64; two to four bytes, a range of bytes, and units of UTF-16 text are SWAR: eight bytes of a UInt64 read at a
  time and tested together. A lane test is exact (no lane is flagged that does not pass), so the first flagged lane is
  the first unit that passes.

  Every function takes the text as a pointer and the end of what it may read, N, which the caller has checked lies
  within the text (the matcher checks it once against the length of the text). Each reads only below N: a word of
  eight bytes is read at a position at most N - 8. }

interface

{$IFDEF ENDIAN_BIG}
  {$ERROR The searches read words of the text in little-endian order.}
{$ENDIF}

const
  Ones = UInt64($0101010101010101);
  Low7 = UInt64($7F7F7F7F7F7F7F7F);
  Highs = UInt64($8080808080808080);

{ Word8 is the eight bytes at P[At], the first in the low byte. }
function Word8(P: PByte; At: NativeInt): UInt64; inline;
{ Broadcast8 is a byte in every lane. }
function Broadcast8(B: Byte): UInt64; inline;
{ Zeros8 is the high bit of each lane of X that is zero. }
function Zeros8(X: UInt64): UInt64; inline;
{ Eq8 is the high bit of each lane of X that equals the broadcast byte V. }
function Eq8(X, V: UInt64): UInt64; inline;
{ Lane is the lane of the lowest flagged high bit. }
function Lane(Flags: UInt64): NativeInt; inline;
{ HasZero is the cheap test of whether some lane of X is zero: it flags every zero lane but may also flag a lane of 1
  above a zero lane. The loops use it to know that a block holds a byte they look for, and Zeros8 to find which; a
  finder that tests candidates can take its flags as they are. }
function HasZero(X: UInt64): UInt64; inline;

{ IndexByte1 is the first position at or after From and before N whose byte is B, or -1. }
function IndexByte1(P: PByte; From, N: NativeInt; B: Byte): NativeInt; inline;
{ IndexByte2 is the first position at or after From and before N whose byte is A or B, or -1. }
function IndexByte2(P: PByte; From, N: NativeInt; A, B: Byte): NativeInt;
{ IndexByte4 is the first position at or after From and before N whose byte is one of four (which may repeat), or
  -1. }
function IndexByte4(P: PByte; From, N: NativeInt; A, B, C, D: Byte): NativeInt;
{ IndexBetween is the first position at or after From and before N whose byte is from Lo to Hi (both below $80), or
  -1. }
function IndexBetween(P: PByte; From, N: NativeInt; Lo, Hi: Byte): NativeInt;
{ StartsWith reports whether the Len bytes from Lit are at P[At], before End_. }
function StartsWith(P: PByte; At, End_: NativeInt; Lit: PByte; Len: NativeInt): Boolean; inline;

{ IndexUnit is the first position at or after From and before N whose UTF-16 unit is V, or -1. }
function IndexUnit(P: PUInt16; From, N: NativeInt; V: UInt16): NativeInt;
{ HasUnits16 reports whether the Len units from Lit are at P[At] of a text of N units. }
function HasUnits16(P: PUInt16; At, N: NativeInt; Lit: PUInt16; Len: NativeInt): Boolean; inline;

implementation

function Word8(P: PByte; At: NativeInt): UInt64;
begin
  Result := PUInt64(@P[At])^;
end;

function Broadcast8(B: Byte): UInt64;
begin
  Result := UInt64(B) * Ones;
end;

function Zeros8(X: UInt64): UInt64;
begin
  Result := not (((X and Low7) + Low7) or X or Low7);
end;

function Eq8(X, V: UInt64): UInt64;
begin
  Result := Zeros8(X xor V);
end;

function Lane(Flags: UInt64): NativeInt;
begin
  Result := BsfQWord(Flags) shr 3;
end;

function HasZero(X: UInt64): UInt64;
begin
  // The subtraction wraps on purpose.
  Result := (X - Ones) and not X and Highs;
end;

function IndexByte1(P: PByte; From, N: NativeInt; B: Byte): NativeInt;
var
  K: SizeInt;
begin
  if From >= N then
    Exit(-1);
  K := IndexByte(P[From], N - From, B);
  if K < 0 then
    Exit(-1);
  Result := From + K;
end;

function IndexByte2(P: PByte; From, N: NativeInt; A, B: Byte): NativeInt;
var
  VA, VB, W0, W1, X, Z: UInt64;
  At: NativeInt;
begin
  VA := Broadcast8(A);
  VB := Broadcast8(B);
  At := From;
  while At <= N - 16 do begin
    W0 := Word8(P, At);
    W1 := Word8(P, At + 8);
    if (HasZero(W0 xor VA) or HasZero(W0 xor VB) or HasZero(W1 xor VA) or HasZero(W1 xor VB)) <> 0 then begin
      Z := Eq8(W0, VA) or Eq8(W0, VB);
      if Z <> 0 then
        Exit(At + Lane(Z));
      Z := Eq8(W1, VA) or Eq8(W1, VB);
      if Z <> 0 then
        Exit(At + 8 + Lane(Z));
    end;
    Inc(At, 16);
  end;
  while At <= N - 8 do begin
    W0 := Word8(P, At);
    X := Eq8(W0, VA) or Eq8(W0, VB);
    if X <> 0 then
      Exit(At + Lane(X));
    Inc(At, 8);
  end;
  while At < N do begin
    if (P[At] = A) or (P[At] = B) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

function IndexByte4(P: PByte; From, N: NativeInt; A, B, C, D: Byte): NativeInt;
var
  VA, VB, VC, VD, W, Z: UInt64;
  At: NativeInt;
  X: Byte;
begin
  VA := Broadcast8(A);
  VB := Broadcast8(B);
  VC := Broadcast8(C);
  VD := Broadcast8(D);
  At := From;
  while At <= N - 8 do begin
    W := Word8(P, At);
    if (HasZero(W xor VA) or HasZero(W xor VB) or HasZero(W xor VC) or HasZero(W xor VD)) <> 0 then begin
      Z := Eq8(W, VA) or Eq8(W, VB) or Eq8(W, VC) or Eq8(W, VD);
      if Z <> 0 then
        Exit(At + Lane(Z));
    end;
    Inc(At, 8);
  end;
  while At < N do begin
    X := P[At];
    if (X = A) or (X = B) or (X = C) or (X = D) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

(* Between is the high bit of each lane of X that is an ASCII byte from lo to hi (both below $80), given the
  constants Lo = Broadcast8($80 - lo) and Hi = Broadcast8($7F - hi): exact, since the seven low bits of a lane plus a
  constant below $80 cannot carry into the next lane. *)
function Between(X, Lo, Hi: UInt64): UInt64; inline;
var
  T: UInt64;
begin
  T := X and Low7;
  Result := (T + Lo) and not (T + Hi) and not X and Highs;
end;

function IndexBetween(P: PByte; From, N: NativeInt; Lo, Hi: Byte): NativeInt;
var
  VL, VH, Z0, Z1: UInt64;
  At: NativeInt;
  X: Byte;
begin
  VL := Broadcast8($80 - Lo);
  VH := Broadcast8($7F - Hi);
  At := From;
  while At <= N - 16 do begin
    Z0 := Between(Word8(P, At), VL, VH);
    Z1 := Between(Word8(P, At + 8), VL, VH);
    if (Z0 or Z1) <> 0 then begin
      if Z0 <> 0 then
        Exit(At + Lane(Z0));
      Exit(At + 8 + Lane(Z1));
    end;
    Inc(At, 16);
  end;
  while At <= N - 8 do begin
    Z0 := Between(Word8(P, At), VL, VH);
    if Z0 <> 0 then
      Exit(At + Lane(Z0));
    Inc(At, 8);
  end;
  while At < N do begin
    X := P[At];
    if (X >= Lo) and (X <= Hi) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

function StartsWith(P: PByte; At, End_: NativeInt; Lit: PByte; Len: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if (At < 0) or (End_ - At < Len) then
    Exit(False);
  for K := 0 to Len - 1 do
    if P[At + K] <> Lit[K] then
      Exit(False);
  Result := True;
end;

{ The same over UTF-16: four units of a UInt64. }

const
  Ones16 = UInt64($0001000100010001);
  Low15 = UInt64($7FFF7FFF7FFF7FFF);
  Highs16 = UInt64($8000800080008000);

function Word16(P: PUInt16; At: NativeInt): UInt64; inline;
begin
  Result := PUInt64(@P[At])^;
end;

function Zeros16(X: UInt64): UInt64; inline;
begin
  Result := not (((X and Low15) + Low15) or X or Low15);
end;

function HasZero16(X: UInt64): UInt64; inline;
begin
  Result := (X - Ones16) and not X and Highs16;
end;

function IndexUnit(P: PUInt16; From, N: NativeInt; V: UInt16): NativeInt;
var
  VV, W0, W1, W2, W3, Z: UInt64;
  At: NativeInt;
begin
  VV := UInt64(V) * Ones16;
  At := From;
  while At <= N - 16 do begin
    W0 := Word16(P, At) xor VV;
    W1 := Word16(P, At + 4) xor VV;
    W2 := Word16(P, At + 8) xor VV;
    W3 := Word16(P, At + 12) xor VV;
    if (HasZero16(W0) or HasZero16(W1) or HasZero16(W2) or HasZero16(W3)) <> 0 then begin
      Z := Zeros16(W0);
      if Z <> 0 then
        Exit(At + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W1);
      if Z <> 0 then
        Exit(At + 4 + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W2);
      if Z <> 0 then
        Exit(At + 8 + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W3);
      if Z <> 0 then
        Exit(At + 12 + NativeInt(BsfQWord(Z) shr 4));
    end;
    Inc(At, 16);
  end;
  while At <= N - 4 do begin
    Z := Zeros16(Word16(P, At) xor VV);
    if Z <> 0 then
      Exit(At + NativeInt(BsfQWord(Z) shr 4));
    Inc(At, 4);
  end;
  while At < N do begin
    if P[At] = V then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

function HasUnits16(P: PUInt16; At, N: NativeInt; Lit: PUInt16; Len: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if (At < 0) or (N - At < Len) then
    Exit(False);
  for K := 0 to Len - 1 do
    if P[At + K] <> Lit[K] then
      Exit(False);
  Result := True;
end;

end.
