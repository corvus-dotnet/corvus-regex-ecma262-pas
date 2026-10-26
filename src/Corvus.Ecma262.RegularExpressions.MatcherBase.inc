{ The reads of the text and the unit buffer, which the functions of an encoding and the matcher both use. }

function MakeText(P: PUnit; N: NativeInt): TText;
begin
  Result.P := P;
  Result.Len := N;
end;

{ U is the unit at the 0-based position. A position outside the text raises ERangeError. }
function U(const T: TText; Pos: NativeInt): UInt32; inline;
begin
  if NativeUInt(Pos) >= NativeUInt(T.Len) then
    RaiseRange;
  Result := T.P[Pos];
end;

procedure TUnitBuffer.Add(U: TUnit);
begin
  if Count = Length(Data) then
    SetLength(Data, 2 * Count + 64);
  Data[Count] := U;
  Inc(Count);
end;

procedure TUnitBuffer.AddRun(P: PUnit; N: NativeInt);
begin
  if N <= 0 then
    Exit;
  if Count + N > Length(Data) then
    SetLength(Data, 2 * (Count + N) + 64);
  Move(P^, Data[Count], N * SizeOf(TUnit));
  Inc(Count, N);
end;
