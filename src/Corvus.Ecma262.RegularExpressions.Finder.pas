unit Corvus.Ecma262.RegularExpressions.Finder;
{$I ecma262.inc}

{ A search for one of a set of literals in a text's bytes (Finder of search.rs of the Rust crate). Its answer is the
  leftmost occurrence at or after a position, the first literal in their order of those that start there.

  The crate takes memchr::memmem, aho-corasick and its packed searcher Teddy; Pascal has none of them, so the searches
  here are written on the searches of the Swar unit, as the Java, Go and Julia engines write them: a byte rare in text
  by IndexByte, a few literals by two of their byte positions (TPairFinder, PCRE2's search, which the crate has as
  pair8.rs and which here takes one literal too, in place of memmem's search for its two rarest bytes), and any other
  set by a table of the bytes at its rarest position (TTableFinder). }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.Ucd,
  Corvus.Ecma262.RegularExpressions.Swar;

type
  TByteLists = array of TBytes;
  TRanks = array[0..255] of Int32;
  TWordList = array of UInt16;
  TWordLists = array of TWordList;

  { A TByteFinder finds the leftmost occurrence of its literals that starts at or after From and ends at or before
    End_, which the caller has checked lies within the text: its start and end, or false for none. }
  TByteFinder = class abstract
  public
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; virtual; abstract;
  end;

var
  { ByteRank is how common each byte is in text, from 0 (rare) to 255: the table memchr::memmem ranks a needle's bytes
    by (memchr 2.8, arch/all/packedpair/default_rank.rs; MIT or Unlicense), which pair8.rs takes. }
  ByteRank: TRanks;

{ BuildByteFinder is the search for the literals, in the pattern's order, with how common each byte is (ByteRank over
  UTF-8, and the ranks of PackedRanks for the low bytes of UTF-16 units). }
function BuildByteFinder(const Literals: TByteLists; const Rank: TRanks): TByteFinder;

{ PackedRanks is how common each low byte of the units of UTF-16 literals is in the packed text: an ASCII unit's byte
  as ByteRank has it, and a byte any of the literals' units beyond ASCII packs to as common (a Cyrillic letter in
  Russian text) or nearly so (a Han character, whose low byte any of thousands share), so that neither is searched
  for alone or taken for a rare position. }
function PackedRanks(const Literals: TWordLists): TRanks;

{ UnitShare is an ASCII unit's share of English text in parts per ten thousand, and Share16 a UTF-16 code unit's, for
  the choice of the unit a search over UTF-16 looks for: an ASCII unit as UnitShare has it; a capital of another
  alphabet (Latin, Greek, Cyrillic, Armenian) as rare as an ASCII capital and its small letters as common as the
  commonest ASCII ones, since a text in that script is mostly them; anything else rare. }
function UnitShare(B: UInt32): Int32; inline;
function Share16(U: UInt16): Int32;

implementation

const
  ByteRankValues: array[0..255] of Byte = (
    55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32,
    31, 30, 29, 28, 255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224, 208, 220, 204, 187,
    183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126, 120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142,
    137, 171, 176, 185, 167, 186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223, 151, 249,
    216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244, 231, 139, 245, 243, 251, 235, 201, 196, 240,
    214, 152, 182, 205, 181, 127, 27, 212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81, 207,
    145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108, 118, 141, 113, 129, 119, 125, 165, 117,
    92, 106, 83, 72, 99, 93, 65, 79, 166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255);

  { The rank under which a byte is searched for alone (the capital letters, the digits and the rarest lower case
    letters): the search for one byte reads several times as fast as the pair search, so a byte this rare pays for
    the compares where it is found. }
  AloneRank = 200;
  { The most tests of a position of the pair search. }
  PairMostTests = 4;
  { The most bytes of the literals looked at before they are compared one by one. }
  PairChecked = 16;

var
  UnitShares: array[0..127] of Int32;

type
  TByteSet = array[0..3] of UInt64;

  TOneFinder = class(TByteFinder)
  public
    B: Byte;
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; override;
  end;

  { A TRareFinder is one literal with a byte rare enough in text to be searched for alone: the search for it at its
    offset K, then the literal compared, as V8 searches a literal pattern for its first character. }
  TRareFinder = class(TByteFinder)
  public
    Literal: TBytes;
    K: NativeInt;
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; override;
  end;

  { A TFirstsFinder is several literals whose bytes at one position are up to four values, or more within a range,
    each byte rare enough to be searched for alone: the search for those bytes (or that range) at that position, then
    the literals with the byte found there compared in order. Sherlock|Holmes is found by an S or an H, as the regex
    crate finds Sherlock|Street by its S; the position is the one whose values are rarest. }
  TFirstsFinder = class(TByteFinder)
  public
    K: NativeInt;
    { The number of values A, B, C and D (the last repeated), or -1 for the range Lo to Hi. }
    Count: Int32;
    A, B, C, D, Lo, Hi: Byte;
    { The literals by their byte at K, in the pattern's order. }
    ByValue: array[0..255] of TByteLists;
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; override;
  end;

  (* A TPairFinder is the search for a few literals by two of their byte positions, each of whose values are a few
    tests (PositionTests): PCRE2's search before a match (fast_forward_char_pair_simd in its JIT compiler), which finds
    Sher[a-z]+|Hol[a-z]+ by an S or an H with an e or an l two bytes on, and a case-insensitive Holmes by both cases
    of two of its letters. Eight starts are tested at a time; each candidate is compared with the literals out of that
    loop, so that the loop keeps everything in registers. *)
  TPairFinder = class(TByteFinder)
  public
    Literals: TByteLists;
    { The fewest bytes of a literal. }
    Shortest: NativeInt;
    { The two positions, and the masks and values of each one's tests, broadcast. }
    I, J: NativeInt;
    MI, VI, MJ, VJ: array[0..3] of UInt64;
    NI, NJ: Int32;
    { For each of the first bytes of the literals up to PairChecked, the values they hold there. }
    Sets: array of TByteSet;
    { The literals are every sequence of the values Sets holds, all of one length (a word's cases written out): a
      candidate whose bytes pass Sets is then a literal, with nothing more to compare. }
    Every: Boolean;
    function LiteralAt(P: PByte; At, End_: NativeInt): NativeInt;
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; override;
  end;

  { A TTableFinder is any set of literals: a table of the bytes the literals hold at their rarest position, read a
    byte at a time, and the literals that start with the byte found compared in order. The search the crate makes
    with Teddy and with aho-corasick's automaton, where no two positions take few enough tests for TPairFinder. }
  TTableFinder = class(TByteFinder)
  public
    K: NativeInt;
    At: TByteSet;
    Shortest: NativeInt;
    { The literals by their first byte, in the pattern's order. }
    ByFirst: array[0..255] of TByteLists;
    function Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean; override;
  end;

function InSet(const S: TByteSet; B: Byte): Boolean; inline;
begin
  Result := ((S[B shr 6] shr (B and 63)) and 1) <> 0;
end;

procedure AddToSet(var S: TByteSet; B: Byte); inline;
begin
  S[B shr 6] := S[B shr 6] or (UInt64(1) shl (B and 63));
end;

procedure AddList(var L: TByteLists; const B: TBytes);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := B;
end;

function UnitShare(B: UInt32): Int32;
begin
  Result := UnitShares[B and $7F];
end;

function Share16(U: UInt16): Int32;
begin
  if U < $80 then
    Exit(UnitShares[U]);
  if (U < $250) or ((U >= $370) and (U < $590)) then begin
    if UcdCategory('Lu')^.Contains(U) then
      Exit(20);
    if UcdCategory('Ll')^.Contains(U) or UcdCategory('Lt')^.Contains(U) or UcdCategory('Lm')^.Contains(U) or
      UcdCategory('Lo')^.Contains(U) then
      Exit(500);
  end;
  Result := 10;
end;

{ RareByte reports whether a byte is rare enough in text for a search for it alone to pay: not a lower case letter
  (but the rarest five), a space or the commonest punctuation, nor a byte beyond ASCII, where the lead bytes of a
  script are common. }
function RareByte(B: Byte): Boolean;
begin
  if ((B >= Ord('A')) and (B <= Ord('Z'))) or ((B >= Ord('0')) and (B <= Ord('9'))) then
    Exit(True);
  if (B > $20) and (B < $7F) and not ((B >= Ord('a')) and (B <= Ord('z'))) then
    Exit(not (AnsiChar(B) in [',', '.', '''', '"', '-']));
  Result := AnsiChar(B) in ['j', 'q', 'x', 'z', 'k'];
end;

{ Alone reports whether a byte is rare enough to be searched for alone: one RareByte names (the Rust crate's rule),
  and one the ranks do not mark common (a byte a UTF-16 literal's unit beyond ASCII packs to, which PackedRanks
  marks). }
function Alone(const Rank: TRanks; B: Byte): Boolean; inline;
begin
  Result := (B < $80) and RareByte(B) and (Rank[B] <= AloneRank);
end;

{ RarestAlone is the position of the byte of a literal with the least share of text of those rare enough to be
  searched for alone, or -1 for none. }
function RarestAlone(const L: TBytes; const Rank: TRanks): NativeInt;
var
  K: NativeInt;
begin
  Result := -1;
  for K := 0 to High(L) do
    if Alone(Rank, L[K]) and ((Result < 0) or (UnitShare(L[K]) < UnitShare(L[Result]))) then
      Result := K;
end;

function ShortestOf(const Literals: TByteLists): NativeInt;
var
  K: NativeInt;
begin
  Result := Length(Literals[0]);
  for K := 1 to High(Literals) do
    if Length(Literals[K]) < Result then
      Result := Length(Literals[K]);
end;

{ PositionValues is the values a position of the literals holds, sorted and each once. }
function PositionValues(const Literals: TByteLists; K: NativeInt): TBytes;
var
  Seen: TByteSet;
  L, N: NativeInt;
  B: Int32;
begin
  Seen[0] := 0;
  Seen[1] := 0;
  Seen[2] := 0;
  Seen[3] := 0;
  for L := 0 to High(Literals) do
    AddToSet(Seen, Literals[L][K]);
  SetLength(Result, 256);
  N := 0;
  for B := 0 to 255 do
    if InSet(Seen, B) then begin
      Result[N] := B;
      Inc(N);
    end;
  SetLength(Result, N);
end;

function SameBytes(const A, B: TBytes): Boolean;
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

{ TOneFinder }

function TOneFinder.Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean;
begin
  S := IndexByte1(P, From, End_, B);
  E := S + 1;
  Result := S >= 0;
end;

{ TRareFinder }

function TRareFinder.Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean;
var
  B: Byte;
  At, Q, Start: NativeInt;
begin
  B := Literal[K];
  At := From + K;
  while At < End_ do begin
    Q := IndexByte1(P, At, End_, B);
    if Q < 0 then
      Break;
    Start := Q - K;
    if StartsWith(P, Start, End_, @Literal[0], Length(Literal)) then begin
      S := Start;
      E := Start + Length(Literal);
      Exit(True);
    end;
    At := Q + 1;
  end;
  S := -1;
  E := -1;
  Result := False;
end;

{ TFirstsFinder }

function BuildFirstsFinder(const Literals: TByteLists; const Rank: TRanks): TFirstsFinder;
var
  BestK, K, L: NativeInt;
  BestRange, IsRange, Rare: Boolean;
  BestCost, Cost: Int64;
  V: TBytes;
  X: Int32;
  F: TFirstsFinder;

  function At(Index: NativeInt): Byte;
  begin
    if Index > High(V) then
      Index := High(V);
    Result := V[Index];
  end;

begin
  BestK := -1;
  BestRange := False;
  BestCost := High(Int64);
  for K := 0 to ShortestOf(Literals) - 1 do begin
    V := PositionValues(Literals, K);
    // Up to four values are tested for exactly; more as the range from the least to the greatest, where every byte
    // in it is rare (the capital letters of a list of names), which is one test where the values would be as many.
    IsRange := Length(V) > 4;
    Cost := 0;
    Rare := True;
    if IsRange then begin
      for X := V[0] to V[High(V)] do begin
        Rare := Rare and Alone(Rank, X);
        Inc(Cost, Int64(1) shl (Rank[X] div 16));
      end;
    end else
      for L := 0 to High(V) do begin
        Rare := Rare and Alone(Rank, V[L]);
        Inc(Cost, Int64(1) shl (Rank[V[L]] div 16));
      end;
    // Exact values before a range, then the rarer.
    if IsRange then
      Inc(Cost, Int64(2) shl 20)
    else
      Inc(Cost, Int64(1) shl 20);
    if Rare and (Cost < BestCost) then begin
      BestK := K;
      BestRange := IsRange;
      BestCost := Cost;
    end;
  end;
  if BestK < 0 then
    Exit(nil);
  V := PositionValues(Literals, BestK);
  F := TFirstsFinder.Create;
  F.K := BestK;
  for X := 0 to High(V) do
    for L := 0 to High(Literals) do
      if Literals[L][BestK] = V[X] then
        AddList(F.ByValue[V[X]], Literals[L]);
  if BestRange then begin
    F.Count := -1;
    F.Lo := V[0];
    F.Hi := V[High(V)];
  end else begin
    F.Count := Length(V);
    F.A := At(0);
    F.B := At(1);
    F.C := At(2);
    F.D := At(3);
  end;
  Result := F;
end;

function TFirstsFinder.Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean;
var
  At, Q, Start, L: NativeInt;
  Lits: TByteLists;
begin
  At := From + K;
  while At < End_ do begin
    case Count of
      1: Q := IndexByte1(P, At, End_, A);
      2: Q := IndexByte2(P, At, End_, A, B);
      3, 4: Q := IndexByte4(P, At, End_, A, B, C, D);
    else
      Q := IndexBetween(P, At, End_, Lo, Hi);
    end;
    if Q < 0 then
      Break;
    Start := Q - K;
    // A byte of the range no literal holds there has no literals.
    Lits := ByValue[P[Q]];
    for L := 0 to High(Lits) do
      if StartsWith(P, Start, End_, @Lits[L][0], Length(Lits[L])) then begin
        S := Start;
        E := Start + Length(Lits[L]);
        Exit(True);
      end;
    At := Q + 1;
  end;
  S := -1;
  E := -1;
  Result := False;
end;

{ TPairFinder }

{ PositionTests is the tests of a position's values as pairs of a mask and a value, a byte x passing one where
  x or mask = value: two values that differ in one bit (the cases of an ASCII letter, the lead bytes of the cases of a
  Cyrillic letter) make one test with that bit set, any other value a test of its own. It reports false where that
  makes more than Most. }
function PositionTests(const Values: TBytes; Most: NativeInt; out Tests: TBytes): Boolean;
var
  Used: array of Boolean;
  A, B, N: NativeInt;
  Mask, Bit: Byte;
begin
  SetLength(Used, Length(Values));
  SetLength(Tests, 2 * Length(Values));
  N := 0;
  for A := 0 to High(Values) do begin
    if Used[A] then
      Continue;
    Used[A] := True;
    Mask := 0;
    for B := A + 1 to High(Values) do begin
      Bit := Values[A] xor Values[B];
      if not Used[B] and (PopCnt(Bit) = 1) then begin
        Used[B] := True;
        Mask := Bit;
        Break;
      end;
    end;
    if N = 2 * Most then
      Exit(False);
    Tests[N] := Mask;
    Tests[N + 1] := Values[A] or Mask;
    Inc(N, 2);
  end;
  SetLength(Tests, N);
  Result := True;
end;

function Disjoint(const A, B: TBytes): Boolean;
var
  X, Y: NativeInt;
begin
  for X := 0 to High(A) do
    for Y := 0 to High(B) do
      if A[X] = B[Y] then
        Exit(False);
  Result := True;
end;

{ BuildPairFinder is the search for the literals (of at least two bytes each, in the pattern's order), or nil where no
  two of their positions take PairMostTests tests or fewer each. }
function BuildPairFinder(const Literals: TByteLists; const Ranks: TRanks): TPairFinder;
var
  Shortest, X, Y, BI, BJ, Checked, K, L: NativeInt;
  Values: array of TBytes;
  Tests: array of TBytes;
  HasTests: array of Boolean;
  Rank: array of Int32;
  Best, Cost: Int64;
  Apart: Boolean;
  Product: Int64;
  F: TPairFinder;
  V: Int32;

  procedure Broadcast(const T: TBytes; var M, Vs: array of UInt64; out Count: Int32);
  var
    Q: NativeInt;
  begin
    Count := Length(T) div 2;
    for Q := 0 to Length(T) div 2 - 1 do begin
      M[Q] := Broadcast8(T[2 * Q]);
      Vs[Q] := Broadcast8(T[2 * Q + 1]);
    end;
  end;

begin
  Result := nil;
  Shortest := ShortestOf(Literals);
  if Shortest < 2 then
    Exit;
  // Each position of few enough tests, with how common its commonest value is.
  SetLength(Values, Shortest);
  SetLength(Tests, Shortest);
  SetLength(HasTests, Shortest);
  SetLength(Rank, Shortest);
  for K := 0 to Shortest - 1 do begin
    Values[K] := PositionValues(Literals, K);
    HasTests[K] := PositionTests(Values[K], PairMostTests, Tests[K]);
    Rank[K] := 0;
    for L := 0 to High(Values[K]) do
      if Ranks[Values[K][L]] > Rank[K] then
        Rank[K] := Ranks[Values[K][L]];
  end;
  // The pair of the rarest positions, their values apart where any pair has them apart (a run of one byte would pass
  // both otherwise), as PCRE2 chooses; of those as rare, the one of fewer tests.
  BI := -1;
  BJ := -1;
  Best := High(Int64);
  for Apart in [True, False] do begin
    for X := 0 to Shortest - 1 do
      for Y := X + 1 to Shortest - 1 do begin
        if not HasTests[X] or not HasTests[Y] or (Apart and not Disjoint(Values[X], Values[Y])) then
          Continue;
        Cost := (Int64(Rank[X] + Rank[Y]) shl 8) or (Length(Tests[X]) + Length(Tests[Y]));
        if Cost < Best then begin
          Best := Cost;
          BI := X;
          BJ := Y;
        end;
      end;
    if BI >= 0 then
      Break;
  end;
  if BI < 0 then
    Exit;
  F := TPairFinder.Create;
  F.Literals := Literals;
  F.Shortest := Shortest;
  F.I := BI;
  F.J := BJ;
  Checked := Shortest;
  if Checked > PairChecked then
    Checked := PairChecked;
  SetLength(F.Sets, Checked);
  for K := 0 to Checked - 1 do begin
    F.Sets[K][0] := 0;
    F.Sets[K][1] := 0;
    F.Sets[K][2] := 0;
    F.Sets[K][3] := 0;
    for L := 0 to High(Literals) do
      AddToSet(F.Sets[K], Literals[L][K]);
  end;
  F.Every := Shortest <= PairChecked;
  for L := 0 to High(Literals) do
    if Length(Literals[L]) <> Shortest then
      F.Every := False;
  Product := 1;
  K := 0;
  while (K < Shortest) and F.Every do begin
    Product := Product * Length(Values[K]);
    F.Every := Product <= Length(Literals);
    Inc(K);
  end;
  F.Every := F.Every and (Product = Length(Literals));
  Broadcast(Tests[BI], F.MI, F.VI, F.NI);
  Broadcast(Tests[BJ], F.MJ, F.VJ, F.NJ);
  Result := F;
end;

{ LiteralAt is where the literal that starts at At ends (the first in the pattern's order), or -1. }
function TPairFinder.LiteralAt(P: PByte; At, End_: NativeInt): NativeInt;
var
  N, K, L: NativeInt;
begin
  N := Length(Sets);
  if End_ - At < N then
    N := End_ - At;
  for K := 0 to N - 1 do
    if not InSet(Sets[K], P[At + K]) then
      Exit(-1);
  if Every then
    Exit(At + Shortest);
  for L := 0 to High(Literals) do
    if StartsWith(P, At, End_, @Literals[L][0], Length(Literals[L])) then
      Exit(At + Length(Literals[L]));
  Result := -1;
end;

{ Pass is the lanes of a word that pass the tests (N of them, up to four), by the cheap test of HasZero, which may
  flag a lane that does not pass but never misses one: every candidate is compared with the literals. }
function Pass(X: UInt64; const M, V: array of UInt64; N: Int32): UInt64; inline;
begin
  Result := HasZero((X or M[0]) xor V[0]);
  if N > 1 then begin
    Result := Result or HasZero((X or M[1]) xor V[1]);
    if N > 2 then begin
      Result := Result or HasZero((X or M[2]) xor V[2]);
      if N > 3 then
        Result := Result or HasZero((X or M[3]) xor V[3]);
    end;
  end;
end;

function TPairFinder.Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean;
var
  Last, At, Blocks, Q, EndAt, Far, Last16: NativeInt;
  M, MIW, VIW, MJW, VJW: UInt64;
  Lanes: UInt32;
begin
  S := -1;
  E := -1;
  Last := End_ - Shortest;
  if From > Last then
    Exit(False);
  At := From;
  // The last start whose two words are within the text.
  Far := I;
  if J > Far then
    Far := J;
  Blocks := End_ - 8 - Far;
  if (NI = 1) and (NJ = 1) then begin
    // Sixteen starts a block (PairBlock): its lanes are candidates, each compared with the literals.
    MIW := MI[0];
    VIW := VI[0];
    MJW := MJ[0];
    VJW := VJ[0];
    Last16 := End_ - 16 - Far;
    while At <= Last16 do begin
      Q := PairBlock(P, At, Last16, I, J, MIW, VIW, MJW, VJW, Lanes);
      if Q < 0 then begin
        Inc(At, ((Last16 - At) div 16 + 1) * 16);
        Break;
      end;
      while Lanes <> 0 do begin
        S := Q + NativeInt(BsfDWord(Lanes));
        if S <= Last then begin
          EndAt := LiteralAt(P, S, End_);
          if EndAt >= 0 then begin
            E := EndAt;
            Exit(True);
          end;
        end;
        Lanes := Lanes and (Lanes - 1);
      end;
      At := Q + 16;
    end;
    S := -1;
  end else
    while At <= Blocks do begin
      M := Pass(Word8(P, At + I), MI, VI, NI) and Pass(Word8(P, At + J), MJ, VJ, NJ);
      while M <> 0 do begin
        Q := At + Lane(M);
        if Q <= Last then begin
          EndAt := LiteralAt(P, Q, End_);
          if EndAt >= 0 then begin
            S := Q;
            E := EndAt;
            Exit(True);
          end;
        end;
        M := M and (M - 1);
      end;
      Inc(At, 8);
    end;
  while At <= Last do begin
    EndAt := LiteralAt(P, At, End_);
    if EndAt >= 0 then begin
      S := At;
      E := EndAt;
      Exit(True);
    end;
    Inc(At);
  end;
  Result := False;
end;

{ TTableFinder }

function BuildTableFinder(const Literals: TByteLists; const Rank: TRanks): TTableFinder;
var
  Shortest, BestK, K, L: NativeInt;
  BestCost, Cost: Int64;
  V: TBytes;
  F: TTableFinder;
begin
  Shortest := ShortestOf(Literals);
  BestK := 0;
  BestCost := High(Int64);
  for K := 0 to Shortest - 1 do begin
    V := PositionValues(Literals, K);
    Cost := 0;
    for L := 0 to High(V) do
      Inc(Cost, Int64(1) shl (Rank[V[L]] div 16));
    if Cost < BestCost then begin
      BestCost := Cost;
      BestK := K;
    end;
  end;
  F := TTableFinder.Create;
  F.K := BestK;
  F.Shortest := Shortest;
  for L := 0 to High(Literals) do begin
    AddToSet(F.At, Literals[L][BestK]);
    AddList(F.ByFirst[Literals[L][0]], Literals[L]);
  end;
  Result := F;
end;

function TTableFinder.Find(P: PByte; From, End_: NativeInt; out S, E: NativeInt): Boolean;
var
  Last, Q, L: NativeInt;
  Lits: TByteLists;
begin
  Last := End_ - Shortest;
  for Q := From to Last do
    if InSet(At, P[Q + K]) then begin
      Lits := ByFirst[P[Q]];
      for L := 0 to High(Lits) do
        if StartsWith(P, Q, End_, @Lits[L][0], Length(Lits[L])) then begin
          S := Q;
          E := Q + Length(Lits[L]);
          Exit(True);
        end;
    end;
  S := -1;
  E := -1;
  Result := False;
end;

function BuildByteFinder(const Literals: TByteLists; const Rank: TRanks): TByteFinder;
var
  Best: NativeInt;
  One: TOneFinder;
  Rare: TRareFinder;
begin
  if Length(Literals) = 1 then begin
    if Length(Literals[0]) = 1 then begin
      One := TOneFinder.Create;
      One.B := Literals[0][0];
      Exit(One);
    end;
    // The byte with the least share of text of those rare enough to be searched for alone; the pair search where
    // every byte is common. The share, not ByteRank, chooses: ByteRank ranks Sherlock's k rarest, which the Sherlock
    // Holmes text holds 3,595 times to its S's 837. IndexByte reads a vector at a time and the pair search a word, so
    // any rare byte is searched for alone, as the Java, Go and Julia engines do.
    Best := RarestAlone(Literals[0], Rank);
    if Best >= 0 then begin
      Rare := TRareFinder.Create;
      Rare.Literal := Literals[0];
      Rare.K := Best;
      Exit(Rare);
    end;
    Result := BuildPairFinder(Literals, Rank);
    if Result = nil then
      Result := BuildTableFinder(Literals, Rank);
    Exit;
  end;
  Result := BuildFirstsFinder(Literals, Rank);
  if Result = nil then
    Result := BuildPairFinder(Literals, Rank);
  if Result = nil then
    Result := BuildTableFinder(Literals, Rank);
end;

function PackedRanks(const Literals: TWordLists): TRanks;
var
  L, K: NativeInt;
  U: UInt16;
  B: Byte;
  V: Int32;
begin
  Result := ByteRank;
  for L := 0 to High(Literals) do
    for K := 0 to High(Literals[L]) do begin
      U := Literals[L][K];
      if U >= $80 then begin
        B := Byte(U and $FF);
        if (U >= $400) and (U <= $4FF) then
          V := 245
        else
          V := 230;
        if V > Result[B] then
          Result[B] := V;
      end;
    end;
end;

procedure InitTables;
const
  Lower: AnsiString = 'etaoinshrdlcumwfgypbvkjxqz';
  LowerPerMille: array[0..25] of Int32 = (102, 73, 66, 60, 56, 54, 50, 49, 48, 34, 32, 22, 22, 19, 19, 18, 16, 16, 15,
    12, 8, 6, 2, 2, 1, 1);
  Upper: AnsiString = 'ITHASWMECBNOYRLDPGFJUVKXQZ';
  UpperPerTenThousand: array[0..25] of Int32 = (65, 28, 21, 18, 16, 13, 13, 12, 10, 10, 9, 9, 8, 8, 7, 6, 6, 5, 5, 4,
    2, 2, 2, 1, 1, 1);
var
  K: Int32;
begin
  for K := 0 to 255 do
    ByteRank[K] := ByteRankValues[K];
  // Each ASCII unit's share of English text in parts per ten thousand: the small letters by their frequency (the
  // table of the .NET reference engine's needle), the capitals as measured over the Industry texts, the space and
  // the commonest punctuation, and ten for any other.
  for K := 0 to 127 do
    UnitShares[K] := 10;
  for K := 1 to 26 do
    UnitShares[Ord(Lower[K])] := LowerPerMille[K - 1] * 10;
  for K := 1 to 26 do
    UnitShares[Ord(Upper[K])] := UpperPerTenThousand[K - 1];
  UnitShares[Ord(' ')] := 1700;
  UnitShares[10] := 200;
  UnitShares[13] := 200;
  UnitShares[Ord('.')] := 70;
  UnitShares[Ord(',')] := 80;
end;

initialization
  InitTables;
end.
