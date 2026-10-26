unit Corvus.Ecma262.RegularExpressions.Maps;
{$I ecma262.inc}

{ A map from a list of integers to a number, which the builders of the automata use to find a state set they have
  made before (a Dict keyed by a vector in the crate). It is open addressing over the hash of the list, kept at most
  half full. }

interface

type
  TIntList = array of Int32;

  TIntListMap = record
  private
    FKeys: array of TIntList;
    FValues: array of Int32;
    FHashes: array of UInt32;
    FSlots: array of Int32;
    FCount: Int32;
    procedure Grow;
  public
    { Find returns the number of the list, or -1 when it is not in the map. }
    function Find(const Key: TIntList): Int32;
    { Add puts a list that is not in the map into it with its number. The map keeps the list it is given. }
    procedure Add(const Key: TIntList; Value: Int32);
    property Count: Int32 read FCount;
  end;

{ HashInts is the hash of a list of integers. }
function HashInts(const Key: TIntList): UInt32;

{ SameInts reports whether two lists are equal. }
function SameInts(const A, B: TIntList): Boolean;

implementation

function HashInts(const Key: TIntList): UInt32;
var
  K: NativeInt;
begin
  // FNV-1a over the numbers, which wraps on purpose.
  Result := 2166136261;
  for K := 0 to High(Key) do
    Result := UInt32((UInt64(Result xor UInt32(Key[K])) * 16777619) and $FFFFFFFF);
end;

function SameInts(const A, B: TIntList): Boolean;
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

function TIntListMap.Find(const Key: TIntList): Int32;
var
  H: UInt32;
  Mask, Slot, E: Int32;
begin
  if Length(FSlots) = 0 then
    Exit(-1);
  H := HashInts(Key);
  Mask := High(FSlots);
  Slot := Int32(H and UInt32(Mask));
  while FSlots[Slot] >= 0 do begin
    E := FSlots[Slot];
    if (FHashes[E] = H) and SameInts(FKeys[E], Key) then
      Exit(FValues[E]);
    Slot := (Slot + 1) and Mask;
  end;
  Result := -1;
end;

procedure TIntListMap.Grow;
var
  K, Slot, Mask: Int32;
begin
  // A power of two, so that a probe masked by the length visits every slot.
  if Length(FSlots) = 0 then
    SetLength(FSlots, 64)
  else
    SetLength(FSlots, 2 * Length(FSlots));
  for K := 0 to High(FSlots) do
    FSlots[K] := -1;
  Mask := High(FSlots);
  for K := 0 to FCount - 1 do begin
    Slot := Int32(FHashes[K] and UInt32(Mask));
    while FSlots[Slot] >= 0 do
      Slot := (Slot + 1) and Mask;
    FSlots[Slot] := K;
  end;
end;

procedure TIntListMap.Add(const Key: TIntList; Value: Int32);
var
  Slot, Mask: Int32;
begin
  if 2 * (FCount + 1) > Length(FSlots) then
    Grow;
  if FCount = Length(FKeys) then begin
    SetLength(FKeys, 2 * FCount + 16);
    SetLength(FValues, 2 * FCount + 16);
    SetLength(FHashes, 2 * FCount + 16);
  end;
  FKeys[FCount] := Key;
  FValues[FCount] := Value;
  FHashes[FCount] := HashInts(Key);
  Mask := High(FSlots);
  Slot := Int32(FHashes[FCount] and UInt32(Mask));
  while FSlots[Slot] >= 0 do
    Slot := (Slot + 1) and Mask;
  FSlots[Slot] := FCount;
  Inc(FCount);
end;

end.
