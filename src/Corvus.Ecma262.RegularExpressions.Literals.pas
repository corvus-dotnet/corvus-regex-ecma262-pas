unit Corvus.Ecma262.RegularExpressions.Literals;
{$I ecma262.inc}

{ The literals of a search, over UTF-8 and over UTF-16 (Literals of search.rs of the Rust crate): a search for the
  leftmost occurrence of any of them, the first in the pattern's order of those that start there. And the sets of
  UTF-16 code units the searches look for (simd16.rs, which the Java engine has as UnitSearch).

  Every search takes the text as a pointer and its length, which the matcher has checked, and reads only within it. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Swar,
  Corvus.Ecma262.RegularExpressions.Finder;

type
  TIntArray = array of Int32;

  { A TLiterals is the search for the literals of a search plan. Nothing changes it once it is built. }
  TLiterals = class
  public
    { The search over UTF-8, and the one literal over UTF-8 when there is one. }
    Utf8: TByteFinder;
    Single8: TBytes;
    HasSingle8: Boolean;
    { The bytes the UTF-8 literals start with. }
    Firsts: array[0..3] of UInt64;
    { The most code units of a literal. }
    Longest: NativeInt;
    { Every literal over UTF-16, in the pattern's order. }
    All16: TWordLists;
    { One literal over UTF-16 with a rare unit, OneUnit, at OneAt in it: the search for that unit, then a compare of
      the literal, when HasOne16. }
    One16: array of UInt16;
    HasOne16: Boolean;
    OneUnit: UInt16;
    OneAt: NativeInt;
    { The rare unit up to four literals over UTF-16 all start with, when HasShared16. }
    Shared16: UInt16;
    HasShared16: Boolean;
    { The search of the low bytes of several literals over UTF-16 (see FindPacked), or nil. }
    Packed16: TByteFinder;
    { Create builds the search for the literals, each a sequence of code points, with the most bytes of each written
      out over UTF-8 (see Utf8Cuts of the Search unit). }
    constructor Create(const Lits: TRuneLists; const Cuts: TIntArray);
    destructor Destroy; override;
    { Find8 is the leftmost occurrence at or after From in UTF-8 text, and Find16 in UTF-16 text. }
    function Find8(P: PByte; Len, From: NativeInt; out S, E: NativeInt): Boolean;
    function Find16(P: PUInt16; Len, From: NativeInt; out S, E: NativeInt): Boolean;
    { FindWithin8 is the leftmost occurrence that starts at or after From and at or before Last, in UTF-8 text, or
      -1. The few bytes between are looked at one at a time for a literal's first byte before a search is called,
      since a call on so short a text costs more than reading it. FindWithin16 is the same in UTF-16 text: each start
      between is looked at, as they are few. }
    function FindWithin8(P: PByte; Len, From, Last: NativeInt): NativeInt;
    function FindWithin16(P: PUInt16; Len, From, Last: NativeInt): NativeInt;
    { LiteralAt16 is where the first literal in order that starts at Pos of UTF-16 text ends, or -1. }
    function LiteralAt16(P: PUInt16; Len, Pos: NativeInt): NativeInt;
  private
    function FindPacked(P: PUInt16; Len, From: NativeInt; out S, E: NativeInt): Boolean;
  end;

  TUnitBlock = array[0..3] of UInt64;

  { A TUnitSet is a set of code units as ranges (inclusive pairs), for the units a match can start with and for the
    units that end a run of a loop: one unit by the search for it, one range by a compare, and any other set by a
    table of bits a unit at a time: a block of 256 bits for each high byte of a unit, the blocks the set has nothing
    in shared, so that a test is two loads and a shift. }
  TUnitSet = class
  public
    Ranges: TRunes;
    { The one unit of a set of one, or -1. }
    One: Int32;
    { For a set of more than one range (HasBlocks), the block of bits of each high byte: Blocks[BlockOf[high byte]].
      The high bytes the set has nothing in share block 0, which is empty. }
    HasBlocks: Boolean;
    BlockOf: array[0..255] of UInt16;
    Blocks: array of TUnitBlock;
    constructor Create(const ARanges: TRunes);
    function Contains(U: UInt16): Boolean; inline;
    { Find is the first unit at or after From in the set, or -1. }
    function Find(P: PUInt16; Len, From: NativeInt): NativeInt;
  end;

{ ReleaseLiteralBuffers frees the buffer of the packed search the calling thread has used. }
procedure ReleaseLiteralBuffers;

implementation

const
  { The most units of a literal the packed search takes, so that the chunks' overlap stays short. }
  PackedLongest = 64;
  { The most share of text (in parts per ten thousand, Share16) a unit may have for the UTF-16 search to look for it
    alone. }
  IndexAlone = 40;
  { The most units packed into bytes at a time for the packed search, and the first chunk packed: each chunk after it
    is twice the one before, up to PackChunk, so that a search whose occurrence is near packs little more than it
    reads. }
  PackChunk = 4096;
  FirstPack = 256;

threadvar
  { The buffer of the packed search, kept from one search to the next. }
  PackBuffer: TBytes;

procedure ReleaseLiteralBuffers;
begin
  PackBuffer := nil;
end;

function IsSurrogate(U: UInt32): Boolean; inline;
begin
  Result := (U >= $D800) and (U <= $DFFF);
end;

function Utf8Bytes(const R: TRunes): TBytes;
var
  K, N, C: Int32;
begin
  SetLength(Result, 4 * Length(R));
  N := 0;
  for K := 0 to High(R) do begin
    C := R[K];
    if C < $80 then begin
      Result[N] := C;
      Inc(N);
    end else if C < $800 then begin
      Result[N] := $C0 or (C shr 6);
      Result[N + 1] := $80 or (C and $3F);
      Inc(N, 2);
    end else if C < $10000 then begin
      Result[N] := $E0 or (C shr 12);
      Result[N + 1] := $80 or ((C shr 6) and $3F);
      Result[N + 2] := $80 or (C and $3F);
      Inc(N, 3);
    end else begin
      Result[N] := $F0 or (C shr 18);
      Result[N + 1] := $80 or ((C shr 12) and $3F);
      Result[N + 2] := $80 or ((C shr 6) and $3F);
      Result[N + 3] := $80 or (C and $3F);
      Inc(N, 4);
    end;
  end;
  SetLength(Result, N);
end;

function Utf16Units(const R: TRunes): TWordList;
var
  K, N, C: Int32;
begin
  SetLength(Result, 2 * Length(R));
  N := 0;
  for K := 0 to High(R) do begin
    C := R[K];
    if C > $FFFF then begin
      Result[N] := $D800 + ((C - $10000) shr 10);
      Result[N + 1] := $DC00 + ((C - $10000) and $3FF);
      Inc(N, 2);
    end else begin
      Result[N] := C;
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function SameUnits(const A, B: TWordList): Boolean;
var
  K: NativeInt;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for K := 0 to High(A) do
    if A[K] <> B[K] then
      Exit(False);
  Result := True;
end;

function SameByteList(const A, B: TBytes): Boolean;
var
  K: NativeInt;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for K := 0 to High(A) do
    if A[K] <> B[K] then
      Exit(False);
  Result := True;
end;

{ TLiterals }

constructor TLiterals.Create(const Lits: TRuneLists; const Cuts: TIntArray);
var
  U8, Low: TByteLists;
  K, J, At, Cut: NativeInt;
  B, Bl: TBytes;
  Units, S: TWordList;
  Covered, Shared, Seen: Boolean;
  First: UInt16;
  Prefix: Boolean;
begin
  inherited Create;
  // A literal cut to fewer bytes finds the same starts, and one that an earlier literal begins with finds no start
  // the earlier one does not.
  U8 := nil;
  SetLength(All16, Length(Lits));
  Longest := 0;
  for K := 0 to High(Lits) do begin
    Units := Utf16Units(Lits[K]);
    All16[K] := Units;
    if Length(Units) > Longest then
      Longest := Length(Units);
    B := Utf8Bytes(Lits[K]);
    // A cut inside a character is not made: measured in the Rust crate, the Cyrillic letters with a three-byte form
    // cut so made the search 1.2 times slower.
    Cut := Cuts[K];
    if (Cut < Length(B)) and ((B[Cut] and $C0) <> $80) then
      SetLength(B, Cut);
    Covered := False;
    for J := 0 to High(U8) do
      if Length(B) >= Length(U8[J]) then begin
        Prefix := True;
        for At := 0 to High(U8[J]) do
          if B[At] <> U8[J][At] then begin
            Prefix := False;
            Break;
          end;
        if Prefix then begin
          Covered := True;
          Break;
        end;
      end;
    if not Covered then begin
      SetLength(U8, Length(U8) + 1);
      U8[High(U8)] := B;
    end;
  end;
  for K := 0 to High(U8) do
    Firsts[U8[K][0] shr 6] := Firsts[U8[K][0] shr 6] or (UInt64(1) shl (U8[K][0] and 63));
  Utf8 := BuildByteFinder(U8, ByteRank);
  HasSingle8 := Length(U8) = 1;
  if HasSingle8 then
    Single8 := U8[0];
  if Length(All16) = 1 then begin
    S := All16[0];
    At := -1;
    for K := 0 to High(S) do
      if not IsSurrogate(S[K]) and ((At < 0) or (Share16(S[K]) < Share16(S[At]))) then
        At := K;
    if (At >= 0) and (Share16(S[At]) <= IndexAlone) then begin
      One16 := S;
      HasOne16 := True;
      OneAt := At;
      OneUnit := S[At];
    end;
  end;
  First := All16[0][0];
  Shared := (Length(All16) > 1) and (Length(All16) <= 4) and not IsSurrogate(First) and
    (Share16(First) <= IndexAlone);
  for K := 1 to High(All16) do
    if All16[K][0] <> First then
      Shared := False;
  Shared16 := First;
  HasShared16 := Shared;
  if Longest < PackedLongest then begin
    // The low byte of each unit, as the packed text holds it.
    Low := nil;
    for K := 0 to High(All16) do begin
      SetLength(Bl, Length(All16[K]));
      for J := 0 to High(All16[K]) do
        Bl[J] := Byte(All16[K][J] and $FF);
      Seen := False;
      for J := 0 to High(Low) do
        if SameByteList(Low[J], Bl) then
          Seen := True;
      if not Seen then begin
        SetLength(Low, Length(Low) + 1);
        Low[High(Low)] := Copy(Bl);
      end;
    end;
    Packed16 := BuildByteFinder(Low, PackedRanks(All16));
  end;
end;

destructor TLiterals.Destroy;
begin
  Utf8.Free;
  Packed16.Free;
  inherited;
end;

function TLiterals.Find8(P: PByte; Len, From: NativeInt; out S, E: NativeInt): Boolean;
begin
  if From > Len then begin
    S := -1;
    E := -1;
    Exit(False);
  end;
  Result := Utf8.Find(P, From, Len, S, E);
end;

function TLiterals.LiteralAt16(P: PUInt16; Len, Pos: NativeInt): NativeInt;
var
  C: UInt16;
  K: NativeInt;
begin
  C := P[Pos];
  for K := 0 to High(All16) do
    if (All16[K][0] = C) and HasUnits16(P, Pos, Len, @All16[K][0], Length(All16[K])) then
      Exit(Pos + Length(All16[K]));
  Result := -1;
end;

function TLiterals.Find16(P: PUInt16; Len, From: NativeInt; out S, E: NativeInt): Boolean;
var
  At, Q, Start, K: NativeInt;
begin
  S := -1;
  E := -1;
  if From < 0 then
    From := 0;
  if HasOne16 then begin
    At := From + OneAt;
    while True do begin
      Q := IndexUnit(P, At, Len, OneUnit);
      if Q < 0 then
        Exit(False);
      Start := Q - OneAt;
      if HasUnits16(P, Start, Len, @One16[0], Length(One16)) then begin
        S := Start;
        E := Start + Length(One16);
        Exit(True);
      end;
      At := Q + 1;
    end;
  end;
  if HasShared16 then begin
    At := From;
    while True do begin
      Q := IndexUnit(P, At, Len, Shared16);
      if Q < 0 then
        Exit(False);
      for K := 0 to High(All16) do
        if HasUnits16(P, Q, Len, @All16[K][0], Length(All16[K])) then begin
          S := Q;
          E := Q + Length(All16[K]);
          Exit(True);
        end;
      At := Q + 1;
    end;
  end;
  if Packed16 <> nil then
    Exit(FindPacked(P, Len, From, S, E));
  for Q := From to Len - 1 do begin
    Start := LiteralAt16(P, Len, Q);
    if Start >= 0 then begin
      S := Q;
      E := Start;
      Exit(True);
    end;
  end;
  Result := False;
end;

(* FindPacked is the leftmost occurrence at or after From of one of the literals (in the pattern's order, the first
  of those that start there): the low bytes of a chunk of units packed into bytes and searched for the low bytes of
  the literals, each candidate then compared with the literals themselves (a unit beyond ASCII packs to a byte an
  ASCII unit has too). The .NET reference engine's packed search, which the crate makes with the ASCII units alone;
  the low byte keeps the search one for every literal. An occurrence that starts so near the end of a chunk that a
  literal could start before it and end beyond the chunk is looked for again in the next chunk, which starts that far
  back. The first chunk is small, and each after it twice the one before up to the most, so that a search packs at
  most about twice what it reads. *)
function TLiterals.FindPacked(P: PUInt16; Len, From: NativeInt; out S, E: NativeInt): Boolean;
var
  Overlap, Size, At, End_, N, Limit, K, C, CE, I, Start, L: NativeInt;
  Last: Boolean;
  Buf: PByte;
begin
  S := -1;
  E := -1;
  if From > Len then
    Exit(False);
  Overlap := Longest - 1;
  if Overlap < 0 then
    Overlap := 0;
  if Length(PackBuffer) < PackChunk then
    SetLength(PackBuffer, PackChunk);
  Buf := @PackBuffer[0];
  Size := FirstPack;
  At := From;
  End_ := From + Size;
  if End_ > Len then
    End_ := Len;
  while True do begin
    N := End_ - At;
    for I := 0 to N - 1 do
      Buf[I] := Byte(P[At + I] and $FF);
    Last := End_ = Len;
    if Last then
      Limit := N
    else
      Limit := N - Overlap;
    K := 0;
    while Packed16.Find(Buf, K, N, C, CE) and (C < Limit) do begin
      Start := At + C;
      for L := 0 to High(All16) do
        if HasUnits16(P, Start, Len, @All16[L][0], Length(All16[L])) then begin
          S := Start;
          E := Start + Length(All16[L]);
          Exit(True);
        end;
      K := C + 1;
    end;
    if Last then
      Exit(False);
    At := End_ - Overlap;
    Size := 2 * Size;
    if Size > PackChunk then
      Size := PackChunk;
    End_ := At + Size;
    if End_ > Len then
      End_ := Len;
  end;
end;

function TLiterals.FindWithin8(P: PByte; Len, From, Last: NativeInt): NativeInt;
var
  Q, Reach, S, E: NativeInt;
  B: Byte;
begin
  if Last > Len - 1 then
    Last := Len - 1;
  if From > Last then
    Exit(-1);
  if HasSingle8 then begin
    B := Single8[0];
    for Q := From to Last do
      if (P[Q] = B) and StartsWith(P, Q, Len, @Single8[0], Length(Single8)) then
        Exit(Q);
    Exit(-1);
  end;
  Q := From;
  while (Q <= Last) and (((Firsts[P[Q] shr 6] shr (P[Q] and 63)) and 1) = 0) do
    Inc(Q);
  if Q > Last then
    Exit(-1);
  Reach := Last + 3 * Longest;
  if Reach > Len then
    Reach := Len;
  if Utf8.Find(P, Q, Reach, S, E) and (S <= Last) then
    Exit(S);
  Result := -1;
end;

function TLiterals.FindWithin16(P: PUInt16; Len, From, Last: NativeInt): NativeInt;
var
  Q: NativeInt;
begin
  if Last > Len - 1 then
    Last := Len - 1;
  for Q := From to Last do
    if LiteralAt16(P, Len, Q) >= 0 then
      Exit(Q);
  Result := -1;
end;

{ TUnitSet }

constructor TUnitSet.Create(const ARanges: TRunes);
var
  K, U, Hi, H, J, N: Int32;
  All: array[0..255] of TUnitBlock;
  Found: Boolean;
begin
  inherited Create;
  Ranges := ARanges;
  One := -1;
  if (Length(Ranges) = 2) and (Ranges[0] = Ranges[1]) then
    One := Ranges[0];
  if Length(Ranges) > 2 then begin
    HasBlocks := True;
    FillChar(All, SizeOf(All), 0);
    K := 0;
    while K < Length(Ranges) do begin
      Hi := Ranges[K + 1];
      if Hi > $FFFF then
        Hi := $FFFF;
      for U := Ranges[K] to Hi do
        All[U shr 8][(U shr 6) and 3] := All[U shr 8][(U shr 6) and 3] or (UInt64(1) shl (U and 63));
      Inc(K, 2);
    end;
    // Each distinct block is kept once (most high bytes of a large set are all in it or all out of it), block 0
    // being the empty one.
    SetLength(Blocks, 1);
    FillChar(Blocks[0], SizeOf(TUnitBlock), 0);
    N := 1;
    for H := 0 to 255 do begin
      Found := False;
      for J := 0 to N - 1 do
        if (Blocks[J][0] = All[H][0]) and (Blocks[J][1] = All[H][1]) and (Blocks[J][2] = All[H][2]) and
          (Blocks[J][3] = All[H][3]) then begin
          BlockOf[H] := J;
          Found := True;
          Break;
        end;
      if not Found then begin
        if N = Length(Blocks) then
          SetLength(Blocks, 2 * N);
        Blocks[N] := All[H];
        BlockOf[H] := N;
        Inc(N);
      end;
    end;
    SetLength(Blocks, N);
  end;
end;

function TUnitSet.Contains(U: UInt16): Boolean;
begin
  if HasBlocks then
    Exit(((Blocks[BlockOf[U shr 8]][(U shr 6) and 3] shr (U and 63)) and 1) <> 0);
  Result := (U >= Ranges[0]) and (U <= Ranges[1]);
end;

function TUnitSet.Find(P: PUInt16; Len, From: NativeInt): NativeInt;
var
  At: NativeInt;
  C: UInt16;
  Lo, Width: Int32;
begin
  if One >= 0 then
    Exit(IndexUnit(P, From, Len, UInt16(One)));
  if HasBlocks then begin
    for At := From to Len - 1 do begin
      C := P[At];
      if ((Blocks[BlockOf[C shr 8]][(C shr 6) and 3] shr (C and 63)) and 1) <> 0 then
        Exit(At);
    end;
    Exit(-1);
  end;
  Lo := Ranges[0];
  Width := Ranges[1] - Ranges[0];
  for At := From to Len - 1 do
    if (Int32(P[At]) - Lo >= 0) and (Int32(P[At]) - Lo <= Width) then
      Exit(At);
  Result := -1;
end;

end.
