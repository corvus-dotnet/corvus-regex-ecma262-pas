{ The backtracking matcher (vm.rs of the Rust crate) and the searches of a compiled pattern (regex.rs and
  replace.rs), written once over the units of a text and compiled for each encoding: Corvus.Ecma262.RegularExpressions
  .Utf8 includes it with a byte for TUnit, and .Utf16 with a UTF-16 code unit. Each unit gives it the reads of its
  encoding first (Decode, ReadAt, GiveBack and the rest), so each is the matcher of one encoding with no branch on the
  encoding inside it. Positions are 0-based offsets in the units of the text, as in the crate. }

{$IFDEF FPC}{$GOTO ON}{$ENDIF}

procedure Push(St: PState; Kind: UInt8; Pc: Int32; Pos, A: NativeInt); inline;
begin
  if St^.Sp = Length(St^.Stack) then
    GrowStack(St^);
  St^.Stack[St^.Sp].Kind := Kind;
  St^.Stack[St^.Sp].Pc := Pc;
  St^.Stack[St^.Sp].Pos := Pos;
  St^.Stack[St^.Sp].A := A;
  Inc(St^.Sp);
end;

{ Allows reports whether a way can go on from the position. }
function Allows(const Q: TQuick; const T: TText; Pos: NativeInt): Boolean; inline;
var
  C: UInt32;
begin
  if Pos >= T.Len then
    Exit(Q.AtEnd);
  if Q.Mid then
    Exit(True);
  C := U(T, Pos);
  if C < $80 then begin
    if C < 64 then
      Exit(((Q.Ascii0 shr C) and 1) <> 0);
    Exit(((Q.Ascii1 shr (C and 63)) and 1) <> 0);
  end;
  Result := Q.Other;
end;

{ EqualAt reports whether the N units from Lit are at Pos of the text (which has them all). }
function EqualAt(const T: TText; Pos: NativeInt; Lit: PUnit; N: NativeInt): Boolean; inline;
var
  K: NativeInt;
begin
  for K := 0 to N - 1 do
    if U(T, Pos + K) <> Lit[K] then
      Exit(False);
  Result := True;
end;

{ EqualRuns reports whether the N units at A and at B of the text are the same. }
function EqualRuns(const T: TText; A, B, N: NativeInt): Boolean; inline;
var
  K: NativeInt;
begin
  for K := 0 to N - 1 do
    if U(T, A + K) <> U(T, B + K) then
      Exit(False);
  Result := True;
end;

{ OneOf is the width of the character when the instruction's character or class matches it, and 0 otherwise. }
function OneOf(I: PInst; R: Int32; W: NativeInt): NativeInt; inline;
begin
  if I^.HasSet then begin
    if not I^.CharSet.Contains(R) then
      Exit(0);
  end else if R <> I^.R then
    Exit(0);
  Result := W;
end;

{ OneWidth is the width of the character at the position At when the instruction's character or class matches it,
  and 0 otherwise. The character is a code unit with Units set. }
function OneWidth(I: PInst; const T: TText; At: NativeInt; Units: Boolean): NativeInt; inline;
var
  C: UInt32;
  R: Int32;
  W: NativeInt;
begin
  if At >= T.Len then
    Exit(0);
  C := U(T, At);
  R := C;
  W := 1;
  if C >= $80 then
    R := ReadAt(T, At, Units, W);
  Result := OneOf(I, R, W);
end;

{ The readers of the automata of the Adfa unit. Each loop reads units at positions below the length of the text. }

{ StartState is the start state at Start: where the pattern has no boundary or anchor that looks back, the one. }
function StartState(A: TAnchoredDfa; const T: TText; Start: NativeInt): Int32; inline;
var
  K: Int32;
  C: UInt32;
begin
  if not A.Context then
    Exit(A.Starts[0]);
  K := 0;
  if Start > 0 then begin
    C := U(T, Start - 1);
    if (C < $80) and IsWordByte(C) then
      K := 2;
  end else
    K := 1;
  Result := A.Starts[K];
end;

{ RunDfa reads the automaton from the row At: the end of the last match found, or AdfaNone or AdfaBail. }
function RunDfa(A: TAnchoredDfa; const T: TText; From: NativeInt; At: UInt32): NativeInt;
var
  Last, P, N: NativeInt;
  C, Tr: UInt32;
begin
  Last := AdfaNone;
  P := From;
  N := T.Len;
  if (P < 0) or (P > N) then
    RaiseRange;
  while P < N do begin
    C := T.P[P];
    if C >= $80 then
      Exit(AdfaBail);
    Tr := A.Fast[At + A.ClassOf[C]];
    if (Tr and FastMatched) <> 0 then
      Last := P;
    At := Tr and not FastMatched;
    if At = 0 then
      Exit(Last);
    Inc(P);
  end;
  if A.AtEnd[At shr A.Shift] then
    Exit(P);
  Result := Last;
end;

{ FindDfa is where the match that starts at Start ends, or AdfaNone where no match starts there, or AdfaBail where a
  unit beyond ASCII was reached and the backtracking matcher decides. }
function FindDfa(A: TAnchoredDfa; const T: TText; Start: NativeInt): NativeInt;
var
  S: Int32;
begin
  S := StartState(A, T, Start);
  if S = AdfaDead then
    Exit(AdfaNone);
  // The state is kept premultiplied by the stride, so a step is one load and an add.
  Result := RunDfa(A, T, Start, UInt32(S) shl A.Shift);
end;

{ FindAfterDfa is FindDfa from Start where the units from Start to From are a prefix whose states Rows holds (see
  TAnchoredDfa.After). }
function FindAfterDfa(A: TAnchoredDfa; const T: TText; Start, From: NativeInt; const Rows: TStartRows): NativeInt;
var
  K: Int32;
  C, Row: UInt32;
begin
  K := 0;
  if A.Context then begin
    if Start > 0 then begin
      C := U(T, Start - 1);
      if (C < $80) and IsWordByte(C) then
        K := 2;
    end else
      K := 1;
  end;
  Row := Rows[K];
  if Row = 0 then
    Exit(AdfaNone);
  Result := RunDfa(A, T, From, Row);
end;

{ MatchesAt reports whether any match starts at Start, found at the first place one ends: 1 or 0, or AdfaBail when a
  unit beyond ASCII is reached first. }
function MatchesAt(A: TAnchoredDfa; const T: TText; Start: NativeInt): NativeInt;
var
  S: Int32;
  P: NativeInt;
  At, C, Tr: UInt32;
begin
  S := StartState(A, T, Start);
  if S = AdfaDead then
    Exit(0);
  At := UInt32(S) shl A.Shift;
  if (Start < 0) or (Start > T.Len) then
    RaiseRange;
  for P := Start to T.Len - 1 do begin
    C := T.P[P];
    if C >= $80 then
      Exit(AdfaBail);
    Tr := A.Fast[At + A.ClassOf[C]];
    if (Tr and FastMatched) <> 0 then
      Exit(1);
    At := Tr;
    if At = 0 then
      Exit(0);
  end;
  if A.AtEnd[At shr A.Shift] then
    Result := 1
  else
    Result := 0;
end;

{ ScanDfa reads the forward automaton from a start state at From, and reports the first place at or after From where
  a match ends (ScanMatch), or where a start state is reached again first, so that no match starts before it
  (ScanIdle), or the unit beyond ASCII reached first (ScanBail); ScanNone at the end of the text with no match. }
function ScanDfa(A: TAnchoredDfa; const T: TText; From: NativeInt; out Place: NativeInt): Int32;
var
  P, N: NativeInt;
  Row, C, Tr: UInt32;
begin
  Row := UInt32(StartState(A, T, From)) shl A.Shift;
  P := From;
  N := T.Len;
  if (P < 0) or (P > N) then
    RaiseRange;
  while P < N do begin
    C := T.P[P];
    if C >= $80 then begin
      Place := P;
      Exit(ScanBail);
    end;
    Tr := A.Fast[Row + A.ClassOf[C]];
    if (Tr and FastMatched) <> 0 then begin
      Place := P;
      Exit(ScanMatch);
    end;
    Row := Tr;
    Inc(P);
    if A.StartLike[Row shr A.Shift] then begin
      Place := P;
      Exit(ScanIdle);
    end;
  end;
  Place := P;
  if A.AtEnd[Row shr A.Shift] then
    Result := ScanMatch
  else
    Result := ScanNone;
end;

{ StartsBefore finds the starts before Q, as a mask of their distances (bit d of Lo, Hi is the start Q - d), that the
  terms allow, looking no further back than Most units nor before Floor; false when a unit beyond ASCII is reached. }
function StartsBefore(R: TReverseDfa; const T: TText; Q, Most, Floor: NativeInt; out Lo, Hi: UInt64): Boolean;
var
  Reach, D: NativeInt;
  At, C, Tr: UInt32;
begin
  if R.AcceptFirst then
    Lo := 1
  else
    Lo := 0;
  Hi := 0;
  At := UInt32(1) shl R.Shift;
  Reach := Q - Floor;
  if Reach < 0 then
    Reach := 0;
  if Most < Reach then
    Reach := Most;
  for D := 1 to Reach do begin
    C := U(T, Q - D);
    if C >= $80 then begin
      Lo := 0;
      Hi := 0;
      Exit(False);
    end;
    Tr := R.Fast[At + R.ClassOf[C]];
    if Tr = 0 then
      Break;
    if (Tr and FastMatched) <> 0 then begin
      if D < 64 then
        Lo := Lo or (UInt64(1) shl D)
      else
        Hi := Hi or (UInt64(1) shl (D - 64));
    end;
    At := Tr and not FastMatched;
  end;
  Result := True;
end;

{ SkipAhead is the first place at or after At that the window does not rule out: one unit read rules out the starts
  of a window none of whose positions it can be. }
function SkipAhead(S: TSkipWin; const T: TText; At: NativeInt): NativeInt;
var
  N: NativeInt;
begin
  N := T.Len;
  while (At + S.Hi < N) and not S.Hit(U(T, At + S.Hi)) do
    Inc(At, S.Len);
  Result := At;
end;

{ Run reports whether the program matches at the position Start: by the anchored automaton where the program has one
  and the text it reads is ASCII, and otherwise by the matcher. The matcher keeps its choices on an explicit stack, so
  the depth of the search is bounded by memory and not by the stack of the thread. When it fails, every group and
  counter is back to the value it had on entry. It counts its steps, and when a check says the match has reached a
  limit it returns false with the reason in St^.Stop. }
function Run(Prog: TProgram; St: PState; const T: TText; Start: NativeInt): Boolean;
label
  Backtrack;
var
  Insts: TInsts;
  Quick: TQuicks;
  Units, Memo, Before, After, Ok, Last, Pass, Marked: Boolean;
  Len, Pos, At, N, Floor, From, To_, Taken, Idx, F, Keep, K, Left, W, W2, G: NativeInt;
  Pc, A: Int32;
  Steps: NativeInt;
  I, Rep: PInst;
  C: UInt32;
  R, Want, Got: Int32;
  E: TEntry;
  Lit: PUnit;
begin
  if Prog.AnchoredDfa <> nil then begin
    // Where the program has the anchored automaton and the text it reads is ASCII, the automaton decides.
    At := FindDfa(Prog.AnchoredDfa, T, Start);
    if At >= 0 then begin
      St^.EndPos := At;
      Exit(True);
    end;
    if At = AdfaNone then
      Exit(False);
  end;
  St^.Sp := 0;
  Insts := Prog.Insts;
  Quick := Prog.Quick;
  // The text is matched by UTF-16 code unit.
  Units := Prog.Units;
  Len := T.Len;
  Pc := 0;
  Pos := Start;
  Steps := St^.Steps;
  // The match has taken the memory of failed places into use.
  Memo := St^.MemoOn;
  while True do begin
    Dec(Steps);
    if Steps < 0 then begin
      if not CheckState(St^) then begin
        St^.Steps := 0;
        Exit(False);
      end;
      Steps := CheckEvery;
      Memo := St^.MemoOn;
    end;
    I := @Insts[Pc];
    case I^.Op of
      opChar:
        if Pos < Len then begin
          C := U(T, Pos);
          if C < $80 then begin
            if Int32(C) = I^.R then begin
              Inc(Pos);
              Inc(Pc);
              Continue;
            end;
          end else begin
            R := ReadAt(T, Pos, Units, W);
            if R = I^.R then begin
              Inc(Pos, W);
              Inc(Pc);
              Continue;
            end;
          end;
        end;
      opSet:
        if Pos < Len then begin
          C := U(T, Pos);
          if C < $80 then begin
            if I^.CharSet.HasAscii(C) then begin
              Inc(Pos);
              Inc(Pc);
              Continue;
            end;
          end else begin
            R := ReadAt(T, Pos, Units, W);
            if I^.CharSet.Contains(R) then begin
              Inc(Pos, W);
              Inc(Pc);
              Continue;
            end;
          end;
        end;
      opLit: begin
        LitOf(I, Lit, N);
        if (Len - Pos >= N) and EqualAt(T, Pos, Lit, N) then begin
          Inc(Pos, N);
          Inc(Pc);
          Continue;
        end;
      end;
      opCharBack, opSetBack:
        if Pos > 0 then begin
          C := U(T, Pos - 1);
          R := C;
          W := 1;
          if C >= $80 then
            R := ReadLast(T, Pos, Units, W);
          if ((I^.Op = opCharBack) and (R = I^.R)) or ((I^.Op = opSetBack) and I^.CharSet.Contains(R)) then begin
            Dec(Pos, W);
            Inc(Pc);
            Continue;
          end;
        end;
      opFail: ;
      opBol:
        if Pos = 0 then begin
          Inc(Pc);
          Continue;
        end;
      opEol:
        if Pos = Len then begin
          Inc(Pc);
          Continue;
        end;
      opWordBoundary, opNotWordBoundary: begin
        Before := (Pos > 0) and IsWordUnit(U(T, Pos - 1));
        After := (Pos < Len) and IsWordUnit(U(T, Pos));
        if (Before <> After) = (I^.Op = opWordBoundary) then begin
          Inc(Pc);
          Continue;
        end;
      end;
      opLineStart:
        if (Pos = 0) or LineTerminatorBefore(T, Pos) then begin
          Inc(Pc);
          Continue;
        end;
      opLineEnd:
        if (Pos = Len) or LineTerminatorAt(T, Pos) then begin
          Inc(Pc);
          Continue;
        end;
      opWordBoundaryFold, opNotWordBoundaryFold: begin
        Before := (Pos > 0) and IsFoldWordRune(DecodeLast(T, Pos, W));
        After := (Pos < Len) and IsFoldWordRune(Decode(T, Pos, W));
        if (Before <> After) = (I^.Op = opWordBoundaryFold) then begin
          Inc(Pc);
          Continue;
        end;
      end;
      opJmp: begin
        Pc := I^.X;
        Continue;
      end;
      opSplit: begin
        // A place from which every way has failed before fails at once. The mark is under whatever comes of this
        // place, a choice or not, so that the place is remembered when it has all failed.
        if Memo and (I^.M <> 0) then begin
          Idx := MemoIndex(Prog, St^, I^.M, Pos);
          if MemoHas(St^, Idx) then
            goto Backtrack;
          if St^.Sp < MaxMarkDepth then
            Push(St, EMark, 0, Idx, 0);
        end;
        // A way the next character rules out is not taken, and no choice is kept for it.
        if not Allows(Quick[I^.Y], T, Pos) then begin
          if not Allows(Quick[I^.X], T, Pos) then
            goto Backtrack;
          Pc := I^.X;
          Continue;
        end;
        if not Allows(Quick[I^.X], T, Pos) then begin
          Pc := I^.Y;
          Continue;
        end;
        Push(St, EChoice, I^.Y, Pos, 0);
        Pc := I^.X;
        Continue;
      end;
      opSaveTmp: begin
        A := I^.A;
        Push(St, ETmp, A, St^.Tmp[A], 0);
        St^.Tmp[A] := Pos;
        Inc(Pc);
        Continue;
      end;
      opCapture: begin
        A := I^.A;
        Push(St, ECap, A, St^.Caps[2 * A], St^.Caps[2 * A + 1]);
        if I^.Flag then begin
          St^.Caps[2 * A] := Pos;
          St^.Caps[2 * A + 1] := St^.Tmp[A];
        end else begin
          St^.Caps[2 * A] := St^.Tmp[A];
          St^.Caps[2 * A + 1] := Pos;
        end;
        Inc(Pc);
        Continue;
      end;
      opClear: begin
        Dec(Steps, I^.B - I^.A);
        for G := I^.A to I^.B do
          if St^.Caps[2 * G] <> None then begin
            Push(St, ECap, G, St^.Caps[2 * G], St^.Caps[2 * G + 1]);
            St^.Caps[2 * G] := None;
            St^.Caps[2 * G + 1] := None;
          end;
        Inc(Pc);
        Continue;
      end;
      opBackref: begin
        // A group that has not taken part matches the empty string.
        A := I^.A;
        From := St^.Caps[2 * A];
        To_ := St^.Caps[2 * A + 1];
        if From = None then begin
          Inc(Pc);
          Continue;
        end;
        N := To_ - From;
        if (Len - Pos >= N) and EqualRuns(T, Pos, From, N) and Whole(T, Pos, Pos + N) then begin
          Dec(Steps, N shr 3);
          Inc(Pos, N);
          Inc(Pc);
          Continue;
        end;
      end;
      opBackrefBack: begin
        A := I^.A;
        From := St^.Caps[2 * A];
        To_ := St^.Caps[2 * A + 1];
        if From = None then begin
          Inc(Pc);
          Continue;
        end;
        N := To_ - From;
        if (Pos >= N) and EqualRuns(T, Pos - N, From, N) and Whole(T, Pos - N, Pos) then begin
          Dec(Steps, N shr 3);
          Dec(Pos, N);
          Inc(Pc);
          Continue;
        end;
      end;
      opBackrefFold, opBackrefUnits: begin
        // A character at a time: to fold case, or because a group matched by code unit can begin or end between the
        // halves of a character, where its bytes do not say what it holds.
        A := I^.A;
        From := St^.Caps[2 * A];
        To_ := St^.Caps[2 * A + 1];
        if From = None then begin
          Inc(Pc);
          Continue;
        end;
        Dec(Steps, (To_ - From) shr 3);
        At := Pos;
        Ok := True;
        while (From < To_) and Ok do begin
          Want := ReadAt(T, From, Units, W);
          Inc(From, W);
          if At >= Len then begin
            Ok := False;
            Break;
          end;
          Got := ReadAt(T, At, Units, W2);
          Inc(At, W2);
          Ok := (Got = Want) or ((I^.Op = opBackrefFold) and
            (Canonicalize(Got, I^.Flag) = Canonicalize(Want, I^.Flag)));
        end;
        if Ok then begin
          Pos := At;
          Inc(Pc);
          Continue;
        end;
      end;
      opBackrefFoldBack, opBackrefUnitsBack: begin
        A := I^.A;
        From := St^.Caps[2 * A];
        To_ := St^.Caps[2 * A + 1];
        if From = None then begin
          Inc(Pc);
          Continue;
        end;
        Dec(Steps, (To_ - From) shr 3);
        At := Pos;
        Ok := True;
        while (From < To_) and Ok do begin
          Want := ReadLast(T, To_, Units, W);
          Dec(To_, W);
          if At = 0 then begin
            Ok := False;
            Break;
          end;
          Got := ReadLast(T, At, Units, W2);
          Dec(At, W2);
          Ok := (Got = Want) or ((I^.Op = opBackrefFoldBack) and
            (Canonicalize(Got, I^.Flag) = Canonicalize(Want, I^.Flag)));
        end;
        if Ok then begin
          Pos := At;
          Inc(Pc);
          Continue;
        end;
      end;
      opLook:
        // What follows a lookaround starts where the lookaround does, and so does the body of a lookahead.
        if Allows(Quick[Pc], T, Pos) then begin
          if I^.Flag then
            Push(St, ELookNeg, I^.X, Pos, 0)
          else
            Push(St, ELook, I^.X, Pos, 0);
          Inc(Pc);
          Continue;
        end;
      opLookOk: begin
        // The body matched. A lookaround is atomic, so the choices made inside it are dropped. The undo entries
        // stay, because the groups it set remain set until something below this point is retried.
        F := St^.Sp - 1;
        while St^.Stack[F].Kind <> ELook do
          Dec(F);
        Pos := St^.Stack[F].Pos;
        Keep := F;
        for K := F + 1 to St^.Sp - 1 do
          if St^.Stack[K].Kind >= ETmp then begin
            St^.Stack[Keep] := St^.Stack[K];
            Inc(Keep);
          end;
        St^.Sp := Keep;
        Inc(Pc);
        Continue;
      end;
      opLookFail:
        // The body of a negative lookaround matched, so the lookaround fails and everything it did is undone.
        while St^.Sp > 0 do begin
          Dec(St^.Sp);
          E := St^.Stack[St^.Sp];
          if E.Kind = ELookNeg then
            Break;
          Undo(St^, E);
        end;
      opRep: begin
        At := Pos;
        N := 0;
        Floor := Pos;
        if I^.HasSet then begin
          while (N <> I^.Max) and (At < Len) do begin
            C := U(T, At);
            if C < $80 then begin
              if not I^.CharSet.HasAscii(C) then
                Break;
              Inc(At);
            end else begin
              R := ReadAt(T, At, Units, W);
              if not I^.CharSet.Contains(R) then
                Break;
              Inc(At, W);
            end;
            Inc(N);
            if N = I^.Min then
              Floor := At;
          end;
        end else begin
          while (N <> I^.Max) and (At < Len) do begin
            C := U(T, At);
            R := C;
            W := 1;
            if C >= $80 then
              R := ReadAt(T, At, Units, W);
            if R <> I^.R then
              Break;
            Inc(At, W);
            Inc(N);
            if N = I^.Min then
              Floor := At;
          end;
        end;
        Dec(Steps, (At - Pos) shr 3);
        if N >= I^.Min then begin
          if Memo and (I^.M <> 0) then begin
            Idx := MemoIndex(Prog, St^, I^.M, At);
            if MemoHas(St^, Idx) then begin
              // What follows the loop has failed from here before. The loop gives a character back.
              if At > Floor then
                Push(St, ERep, Pc + 1, At, Floor);
              goto Backtrack;
            end;
            if (At = Floor) and (St^.Sp < MaxMarkDepth) then
              Push(St, EMark, 0, Idx, 0);
          end;
          if At > Floor then
            Push(St, ERep, Pc + 1, At, Floor);
          Pos := At;
          Inc(Pc);
          Continue;
        end;
      end;
      opRepLazy: begin
        At := Pos;
        N := 0;
        while N < I^.Min do begin
          W := OneWidth(I, T, At, Units);
          if W = 0 then
            Break;
          Inc(At, W);
          Inc(N);
        end;
        Dec(Steps, N shr 3);
        if N = I^.Min then begin
          if Memo and (I^.M <> 0) then begin
            Idx := MemoIndex(Prog, St^, I^.M, At);
            if MemoHas(St^, Idx) then begin
              // What follows the loop has failed from here before. The loop takes one more character.
              if N <> I^.Max then
                Push(St, ERepLazy, Pc, At, N);
              goto Backtrack;
            end;
            if (N = I^.Max) and (St^.Sp < MaxMarkDepth) then
              Push(St, EMark, 0, Idx, 0);
          end;
          if N <> I^.Max then
            Push(St, ERepLazy, Pc, At, N);
          Pos := At;
          Inc(Pc);
          Continue;
        end;
      end;
      opLoopInit: begin
        A := I^.A;
        Push(St, ECounter, A, St^.Counts[2 * A], St^.Counts[2 * A + 1]);
        St^.Counts[2 * A] := 0;
        St^.Counts[2 * A + 1] := None;
        Inc(Pc);
        Continue;
      end;
      opLoop: begin
        A := I^.A;
        N := St^.Counts[2 * A];
        Left := Len - Pos;
        // Fewer units are left than any way from here to a match consumes: what follows the loop, and the
        // iterations it has still to make.
        if (Left < NeedOf(I)) or ((N < I^.Min) and (IterOf(I) <> 0) and
          (Left - NeedOf(I) < (I^.Min - N) * IterOf(I))) then
          goto Backtrack;
        // Once the minimum is met, ECMA-262 rejects an iteration that consumed nothing. That is what stops a loop
        // over a body that can be empty.
        if (N > I^.Min) and (Pos = St^.Counts[2 * A + 1]) then
          goto Backtrack;
        if N < I^.Min then begin
          Inc(Pc);
          Continue;
        end;
        if (I^.Max >= 0) and (N >= I^.Max) then begin
          Pc := I^.X;
          Continue;
        end;
        // The loop may be left or entered from here. A place from which both have failed before fails at once.
        if Memo and (I^.M <> 0) then begin
          Idx := MemoIndex(Prog, St^, I^.M, Pos);
          if MemoHas(St^, Idx) then
            goto Backtrack;
          if St^.Sp < MaxMarkDepth then
            Push(St, EMark, 0, Idx, 0);
        end;
        if not Allows(Quick[I^.X], T, Pos) then
          // The next character rules out leaving the loop, so there is no choice.
          Inc(Pc)
        else if not Allows(Quick[Pc + 1], T, Pos) then
          Pc := I^.X
        else if I^.Flag then begin
          Push(St, EChoice, Pc + 1, Pos, 0);
          Pc := I^.X;
        end else begin
          Push(St, EChoice, I^.X, Pos, 0);
          Inc(Pc);
        end;
        Continue;
      end;
      opLoopIter: begin
        A := I^.A;
        Push(St, ECounter, A, St^.Counts[2 * A], St^.Counts[2 * A + 1]);
        Inc(St^.Counts[2 * A]);
        St^.Counts[2 * A + 1] := Pos;
        Inc(Pc);
        Continue;
      end;
      opMatch: begin
        St^.Steps := Steps;
        St^.EndPos := Pos;
        Exit(True);
      end;
    end;
  Backtrack:
    // The instruction failed. Take up the most recent choice, undoing what was recorded since.
    while True do begin
      if St^.Sp = 0 then begin
        St^.Steps := Steps;
        Exit(False);
      end;
      E := St^.Stack[St^.Sp - 1];
      case E.Kind of
        EChoice: begin
          Pc := E.Pc;
          Pos := E.Pos;
          Dec(St^.Sp);
          Break;
        end;
        ERep: begin
          // What followed the loop from the position it stood at has failed.
          Rep := @Insts[E.Pc - 1];
          Marked := Memo and (Rep^.M <> 0);
          if Marked then
            MemoSet(St^, MemoIndex(Prog, St^, Rep^.M, E.Pos));
          // Give back the last character taken. The characters between A and Pos were decoded going forward, and
          // decoding the last of them going backward finds the same boundary.
          At := E.Pos - GiveBack(T, E.A, E.Pos, Units);
          if IsUtf8 and (Length(Rep^.Back) > 0) and (At > E.A) and not Allows(Quick[E.Pc], T, At) then
            // What follows the loop can only start with one of a few ASCII bytes: the last of them before here is
            // found by a search back, and the positions after it are passed over at once.
            At := LastOfBack(T, E.A, At, Rep^.Back);
          St^.Stack[St^.Sp - 1].Pos := At;
          Pc := E.Pc;
          Pos := At;
          Last := At <= E.A;
          // A position from which what follows the loop cannot go on is passed over, and so is one from which it
          // has failed before.
          Pass := not Allows(Quick[Pc], T, Pos);
          if Marked and not Pass then begin
            Idx := MemoIndex(Prog, St^, Rep^.M, Pos);
            if MemoHas(St^, Idx) then
              Pass := True
            else if Last then begin
              // The loop has nothing more to give back. The entry stays to note this last way.
              St^.Stack[St^.Sp - 1].Kind := EMark;
              St^.Stack[St^.Sp - 1].Pc := 0;
              St^.Stack[St^.Sp - 1].Pos := Idx;
              Break;
            end;
          end;
          if Last then
            Dec(St^.Sp);
          if Pass then begin
            Dec(Steps);
            Continue;
          end;
          Break;
        end;
        ERepLazy: begin
          // What followed the loop from the position it stood at has failed.
          Rep := @Insts[E.Pc];
          Marked := Memo and (Rep^.M <> 0);
          if Marked then
            MemoSet(St^, MemoIndex(Prog, St^, Rep^.M, E.Pos));
          W := OneWidth(Rep, T, E.Pos, Units);
          if W = 0 then begin
            Dec(St^.Sp);
            Continue;
          end;
          At := E.Pos + W;
          Taken := E.A + 1;
          St^.Stack[St^.Sp - 1].Pos := At;
          St^.Stack[St^.Sp - 1].A := Taken;
          Pc := E.Pc + 1;
          Pos := At;
          Last := Taken = Rep^.Max;
          if Marked then begin
            Idx := MemoIndex(Prog, St^, Rep^.M, Pos);
            if MemoHas(St^, Idx) then begin
              if Last then
                Dec(St^.Sp);
              Dec(Steps);
              Continue;
            end;
            if Last then begin
              St^.Stack[St^.Sp - 1].Kind := EMark;
              St^.Stack[St^.Sp - 1].Pc := 0;
              St^.Stack[St^.Sp - 1].Pos := Idx;
              Break;
            end;
          end;
          if Last then
            Dec(St^.Sp);
          Break;
        end;
        EMark: begin
          // Every way from a memo point has failed.
          MemoSet(St^, E.Pos);
          Dec(St^.Sp);
        end;
        ELook:
          // The body of a positive lookaround has no way left to match.
          Dec(St^.Sp);
        ELookNeg: begin
          // The body of a negative lookaround has no way to match, so the lookaround holds.
          Pc := E.Pc;
          Pos := E.Pos;
          Dec(St^.Sp);
          Break;
        end;
      else
        Undo(St^, E);
        Dec(St^.Sp);
      end;
    end;
  end;
end;

{ WidthAt is the width of the character at a position before the end. }
function WidthAt(Prog: TProgram; const T: TText; At: NativeInt): NativeInt; inline;
begin
  if U(T, At) < $80 then
    Exit(1);
  ReadAt(T, At, Prog.Units, Result);
end;

{ EndOfRun is the end of the run of members of the set from At. }
function EndOfRun(Prog: TProgram; const CS: TCharSet; const T: TText; At: NativeInt): NativeInt;
var
  C: UInt32;
  R: Int32;
  W: NativeInt;
begin
  while At < T.Len do begin
    C := U(T, At);
    if C < $80 then begin
      if not CS.HasAscii(C) then
        Break;
      Inc(At);
    end else begin
      R := ReadAt(T, At, Prog.Units, W);
      if not CS.Contains(R) then
        Break;
      Inc(At, W);
    end;
  end;
  Result := At;
end;

{ NextMember is the first member of the set at or after At, with its width in W, or -1. }
function NextMember(Prog: TProgram; const CS: TCharSet; const T: TText; At: NativeInt; out W: NativeInt): NativeInt;
var
  C: UInt32;
  R: Int32;
begin
  W := 0;
  while True do begin
    At := FirstFind(Prog, T, At);
    if (At < 0) or (At >= T.Len) then
      Exit(-1);
    C := U(T, At);
    if C < $80 then begin
      if CS.HasAscii(C) then begin
        W := 1;
        Exit(At);
      end;
      Inc(At);
    end else begin
      R := ReadAt(T, At, Prog.Units, W);
      if CS.Contains(R) then
        Exit(At);
      Inc(At, W);
    end;
  end;
end;

{ FormsMatch is the first match at or after Start of the shape of an alternation of literals with forms. }
function FormsMatch(Prog: TProgram; const T: TText; Start: NativeInt; out From, To_: NativeInt): Boolean;
var
  S: TSearchPlan;
  Next, Q, QE, EndAt, At, A, K, W: NativeInt;
  Ok: Boolean;
  C: UInt32;
  R: Int32;
  Alt: TRuneLists;

  function InForms(const F: TRunes; X: Int32): Boolean;
  var
    J: NativeInt;
  begin
    for J := 0 to High(F) do
      if F[J] = X then
        Exit(True);
    Result := False;
  end;

begin
  S := Prog.Search;
  Next := Start;
  From := 0;
  To_ := 0;
  while True do begin
    if not FindLiterals(S.Literals, T, Next, Q, QE) then
      Exit(False);
    // The automaton compares several alternatives at once where the text is ASCII; one is compared faster as it is.
    if (Prog.AnchoredDfa <> nil) and (Length(S.Forms) > 1) then begin
      EndAt := FindDfa(Prog.AnchoredDfa, T, Q);
      if EndAt >= 0 then begin
        From := Q;
        To_ := EndAt;
        Exit(True);
      end;
      if EndAt = AdfaNone then begin
        Next := Q + WidthAt(Prog, T, Q);
        Continue;
      end;
    end;
    for A := 0 to High(S.Forms) do begin
      Alt := S.Forms[A];
      At := Q;
      Ok := True;
      for K := 0 to High(Alt) do begin
        if At >= T.Len then begin
          Ok := False;
          Break;
        end;
        C := U(T, At);
        R := C;
        W := 1;
        if C >= $80 then
          R := ReadAt(T, At, Prog.Units, W);
        if not InForms(Alt[K], R) then begin
          Ok := False;
          Break;
        end;
        Inc(At, W);
      end;
      if Ok then begin
        From := Q;
        To_ := At;
        Exit(True);
      end;
    end;
    Next := Q + WidthAt(Prog, T, Q);
  end;
end;

{ LoopMatch is the first match at or after Start of the shape of one greedy loop of a class. }
function LoopMatch(Prog: TProgram; const T: TText; Start: NativeInt; out From, To_: NativeInt): Boolean;
var
  S: TSearchPlan;
  W: NativeInt;
begin
  S := Prog.Search;
  From := Start;
  To_ := 0;
  if S.ShapeMin <> 0 then begin
    From := NextMember(Prog, S.ShapeSet, T, Start, W);
    if From < 0 then
      Exit(False);
  end;
  To_ := RunEndOf(S, T, From);
  if To_ < 0 then
    To_ := EndOfRun(Prog, S.ShapeSet, T, From);
  Result := True;
end;

{ ShapeSearch is the first match at or after Start of a pattern of a simple shape. }
function ShapeSearch(Prog: TProgram; const T: TText; Start: NativeInt; out From, To_: NativeInt): Boolean;
var
  S: TSearchPlan;
  W: NativeInt;
begin
  S := Prog.Search;
  From := 0;
  To_ := 0;
  if (Start > T.Len) or (T.Len - Start < ProgNeed(Prog)) then
    Exit(False);
  case S.Shape of
    shLiterals: Exit(FindLiterals(S.Literals, T, Start, From, To_));
    shForms: Exit(FormsMatch(Prog, T, Start, From, To_));
    shSet: begin
      From := NextMember(Prog, S.ShapeSet, T, Start, W);
      To_ := From + W;
      Exit(From >= 0);
    end;
  end;
  Result := LoopMatch(Prog, T, Start, From, To_);
end;

{ FirstAllows reports whether a start passes the first set. }
function FirstAllows(Prog: TProgram; const T: TText; At: NativeInt): Boolean; inline;
var
  C: UInt32;
  W: NativeInt;
begin
  if not Prog.HasFirst then
    Exit(True);
  if At >= T.Len then
    Exit(False);
  C := U(T, At);
  if C < $80 then
    Exit(Prog.First.HasAscii(C));
  Result := Prog.First.Contains(ReadAt(T, At, Prog.Units, W));
end;

{ TryAt reports whether the program matches at the start, with the reason for stopping in St^.Stop. }
function TryAt(Prog: TProgram; St: PState; const T: TText; At: NativeInt): Boolean; inline;
begin
  Result := FirstAllows(Prog, T, At) and Run(Prog, St, T, At);
end;

{ RulesOut reports whether nothing from the occurrence at Q on can match, by the check's automaton while it pays. }
function RulesOut(R: TRestCheck; const T: TText; Q: NativeInt): Boolean;
begin
  if (R = nil) or not R.Pays then
    Exit(False);
  Result := MatchesAt(R.Dfa, T, Q) = 0;
  R.Count(Result);
end;

{ WalkBack is the position N characters before At, not before Floor (the furthest it gets when there are fewer),
  with the characters it went back over in K. }
function WalkBack(Prog: TProgram; const T: TText; At, N, Floor: NativeInt; out K: NativeInt): NativeInt;
var
  W: NativeInt;
begin
  K := 0;
  while (K < N) and (At > Floor) do begin
    ReadLast(T, At, Prog.Units, W);
    if At - W < Floor then
      Break;
    Dec(At, W);
    Inc(K);
  end;
  Result := At;
end;

{ AsciiRun reports whether every unit from From to before To_ (or the end of the text) is ASCII. }
function AsciiRun(const T: TText; From, To_: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if To_ > T.Len then
    To_ := T.Len;
  for K := From to To_ - 1 do
    if U(T, K) >= $80 then
      Exit(False);
  Result := True;
end;

(* SearchReverse is SearchWindows with the terms before the anchors read backwards from each occurrence, so that only
  the starts they allow are tried; Decided is false when a unit beyond ASCII is reached, for the plain search to be
  made. A start is tried only once no later occurrence could allow an earlier one (it is before the next occurrence's
  window), so the starts are tried in order across occurrences and the first match is the leftmost. *)
function SearchReverse(Prog: TProgram; St: PState; const T: TText; Start, Need: NativeInt; out From: NativeInt;
  out Decided: Boolean): Boolean;
var
  S: TSearchPlan;
  Lo, Hi, Len, Base, Tried, Q, QE, NewBase, Shift, D, At, B, After, K, Q2: NativeInt;
  Pend0, Pend1, M0, M1: UInt64;
  Taken: Boolean;
begin
  S := Prog.Search;
  Lo := S.Lo;
  Hi := S.Hi;
  Len := T.Len;
  From := 0;
  Decided := True;
  // The starts waiting to be tried, as two words of bits: bit k is the position Base + k.
  Pend0 := 0;
  Pend1 := 0;
  Base := Start;
  // Every start at or before this has been tried, or can no longer be allowed.
  Tried := -1;
  if not FindLiterals(S.Literals, T, Start, Q, QE) then
    Exit(False);
  while True do begin
    // The starts this occurrence's terms allow join those waiting.
    NewBase := Q - Hi;
    if NewBase < Start then
      NewBase := Start;
    if NewBase > Base then begin
      Shift := NewBase - Base;
      if Shift >= 128 then begin
        Pend0 := 0;
        Pend1 := 0;
      end else if Shift >= 64 then begin
        Pend0 := Pend1 shr (Shift - 64);
        Pend1 := 0;
      end else begin
        Pend0 := (Pend0 shr Shift) or (Pend1 shl (64 - Shift));
        Pend1 := Pend1 shr Shift;
      end;
      Base := NewBase;
    end;
    // An occurrence from which nothing can match allows no start.
    M0 := 0;
    M1 := 0;
    if not RulesOut(S.Rest, T, Q) then
      if not StartsBefore(S.Reverse, T, Q, Hi, Start, M0, M1) then begin
        Decided := False;
        Exit(False);
      end;
    // No start nearer than Lo characters.
    if Lo >= 64 then begin
      M0 := 0;
      M1 := M1 and (High(UInt64) shl (Lo - 64));
    end else if Lo > 0 then
      M0 := M0 and (High(UInt64) shl Lo);
    while (M0 or M1) <> 0 do begin
      if M1 <> 0 then begin
        D := 64 + BsrQWord(M1);
        M1 := M1 and not (UInt64(1) shl (D - 64));
      end else begin
        D := BsrQWord(M0);
        M0 := M0 and not (UInt64(1) shl D);
      end;
      At := Q - D;
      if (At >= Base) and (At > Tried) then begin
        B := At - Base;
        if B < 64 then
          Pend0 := Pend0 or (UInt64(1) shl B)
        else
          Pend1 := Pend1 or (UInt64(1) shl (B - 64));
      end;
    end;
    After := Q + WidthAt(Prog, T, Q);
    // The earliest waiting start is tried once no occurrence before it plus the window could allow an earlier one:
    // an occurrence within that reach is taken in first, which looks no further than the reach.
    Taken := False;
    while (Pend0 or Pend1) <> 0 do begin
      if Pend0 <> 0 then
        K := BsfQWord(Pend0)
      else
        K := 64 + BsfQWord(Pend1);
      At := Base + K;
      // The window is Hi characters, and the search counts units: the two agree over ASCII alone. Where the reach
      // holds a unit beyond ASCII, an occurrence more than Hi units on can be within Hi characters and allow an
      // earlier start than this one, so the plain search decides.
      if not AsciiRun(T, At, At + Hi) then begin
        Decided := False;
        Exit(False);
      end;
      if After <= At + Hi then begin
        Q2 := FindWithin(S.Literals, T, After, At + Hi);
        if Q2 >= 0 then begin
          Q := Q2;
          Taken := True;
          Break;
        end;
      end;
      if K < 64 then
        Pend0 := Pend0 and not (UInt64(1) shl K)
      else
        Pend1 := Pend1 and not (UInt64(1) shl (K - 64));
      Tried := At;
      if Len - At < Need then
        Exit(False);
      if TryAt(Prog, St, T, At) then begin
        From := At;
        Exit(True);
      end;
      if St^.Stop <> StopNone then
        Exit(False);
    end;
    if not Taken then
      if not FindLiterals(S.Literals, T, After, Q, QE) then
        Exit(False);
  end;
end;

{ SearchWindows is the search of a pattern each of whose matches holds one of the literals Lo to Hi characters after
  its start: each occurrence opens the window of starts that could reach it, tried in order and never twice. }
function SearchWindows(Prog: TProgram; St: PState; const T: TText; Start, Need: NativeInt;
  out From: NativeInt): Boolean;
var
  S: TSearchPlan;
  Len, Lo, Hi, Next, Untried, Q, QE, EndAt, Last, K, At: NativeInt;
  Decided: Boolean;
begin
  S := Prog.Search;
  From := 0;
  if (S.Reverse <> nil) and (S.Hi < 127) then begin
    Result := SearchReverse(Prog, St, T, Start, Need, From, Decided);
    if Decided then
      Exit;
  end;
  Len := T.Len;
  Lo := S.Lo;
  Hi := S.Hi;
  Next := Start;
  // Every start before this has been tried.
  Untried := Start;
  while True do begin
    if not FindLiterals(S.Literals, T, Next, Q, QE) then
      Exit(False);
    Next := Q + WidthAt(Prog, T, Q);
    if Hi = 0 then begin
      // Every alternative starts with its literal: the match starts at the occurrence or not at all.
      if Len - Q < Need then
        Exit(False);
      // The occurrence is the literal every match starts with: the automaton goes on after it.
      EndAt := AfterFind(Prog, T, Q);
      if EndAt >= 0 then begin
        St^.EndPos := EndAt;
        From := Q;
        Exit(True);
      end;
      if EndAt = AdfaNone then
        Continue;
      if TryAt(Prog, St, T, Q) then begin
        From := Q;
        Exit(True);
      end;
      if St^.Stop <> StopNone then
        Exit(False);
      Continue;
    end;
    Last := WalkBack(Prog, T, Q, Lo, Start, K);
    if (K < Lo) or (Last < Untried) or RulesOut(S.Rest, T, Q) then
      Continue;
    At := WalkBack(Prog, T, Q, Hi, Start, K);
    while At <= Last do begin
      if At >= Untried then begin
        if Len - At < Need then
          Exit(False);
        if TryAt(Prog, St, T, At) then begin
          From := At;
          Exit(True);
        end;
        if St^.Stop <> StopNone then
          Exit(False);
      end;
      if At = Len then
        Break;
      Inc(At, WidthAt(Prog, T, At));
    end;
    if At > Untried then
      Untried := At;
  end;
end;

(* SearchAfterLoops is the search of a pattern each of whose matches is runs of the loops' sets, then the literal:
  the runs before each occurrence are walked back to the earliest start, which is tried. From that start the loops
  reach every place a later start of the run could, so the later starts fail with it; the occurrence itself is not in
  the run and may start a match, so it is tried next where every loop may be empty, and is the floor for the walk
  back from later occurrences otherwise. A start before an occurrence can reach a later one through it (the literal
  can be in a loop's set), so an occurrence ruled out does not move the floor. *)
function SearchAfterLoops(Prog: TProgram; St: PState; const T: TText; Start, Need: NativeInt;
  out From: NativeInt): Boolean;
var
  S: TSearchPlan;
  Len, Next, Low, Q, QE, At, RunStart, W, K, E: NativeInt;
  AllEmpty, Skip: Boolean;
  C: UInt32;
  R: Int32;
begin
  S := Prog.Search;
  Len := T.Len;
  From := 0;
  Next := Start;
  // The floor below which no start is tried again.
  Low := Start;
  AllEmpty := True;
  for K := 0 to High(S.Mins) do
    if S.Mins[K] <> 0 then
      AllEmpty := False;
  while True do begin
    if not FindLiterals(S.Literals, T, Next, Q, QE) then
      Exit(False);
    Next := Q + WidthAt(Prog, T, Q);
    // A loop that needs a member must have one just before the occurrence: a test of one character, made before the
    // rest is checked.
    if S.Mins[High(S.Mins)] = 1 then begin
      if Q <= Low then
        Continue;
      C := U(T, Q - 1);
      if C < $80 then
        R := C
      else
        R := ReadLast(T, Q, Prog.Units, W);
      if not S.Sets[High(S.Sets)].Contains(R) then
        Continue;
    end;
    if RulesOut(S.Rest, T, Q) then
      Continue;
    At := Q;
    Skip := False;
    for K := High(S.Sets) downto 0 do begin
      RunStart := At;
      while At > Low do begin
        C := U(T, At - 1);
        R := C;
        W := 1;
        if C >= $80 then
          R := ReadLast(T, At, Prog.Units, W);
        if not S.Sets[K].Contains(R) or (At - W < Low) then
          Break;
        Dec(At, W);
      end;
      if (S.Mins[K] = 1) and (At = RunStart) then begin
        Skip := True;
        Break;
      end;
    end;
    if Skip then
      Continue;
    if Len - At < Need then
      Exit(False);
    if TryAt(Prog, St, T, At) then begin
      From := At;
      Exit(True);
    end;
    if St^.Stop <> StopNone then
      Exit(False);
    if At < Q then begin
      // The occurrence itself (\b[0-9a-f]*ét over "0aét", where the walk back gives 0).
      Low := Q;
      if AllEmpty then begin
        if Len - Q < Need then
          Exit(False);
        if TryAt(Prog, St, T, Q) then begin
          From := Q;
          Exit(True);
        end;
        if St^.Stop <> StopNone then
          Exit(False);
        Low := Next;
      end;
    end else
      Low := Next;
    if Length(S.Sets) = 1 then begin
      // Every occurrence in the rest of the loop's run walks back to the start just tried.
      E := EndOfRun(Prog, S.Sets[0], T, Q);
      if E > Next then
        Next := E;
    end;
  end;
end;

{ TryStarts tries the starts from At to Last in order, as the plain search would: true with the start that matched in
  At, Over when the search is over without one, or else false with At where the starts ran out. }
function TryStarts(Prog: TProgram; St: PState; const T: TText; var At: NativeInt; Last: NativeInt;
  out Over: Boolean): Boolean;
var
  Len, W: NativeInt;
  C: UInt32;
  R: Int32;
begin
  Len := T.Len;
  Over := False;
  while (At <= Last) and (At <= Len) do begin
    if not Prog.Units and MidPair(T, At) then begin
      Inc(At);
      Continue;
    end;
    if At = Len then begin
      if not Prog.HasFirst and Run(Prog, St, T, At) then
        Exit(True);
      Over := True;
      Exit(False);
    end;
    C := U(T, At);
    R := C;
    W := 1;
    if C >= $80 then
      R := ReadAt(T, At, Prog.Units, W);
    if (not Prog.HasFirst or Prog.First.Contains(R)) and Run(Prog, St, T, At) then
      Exit(True);
    if St^.Stop <> StopNone then begin
      Over := True;
      Exit(False);
    end;
    Inc(At, W);
  end;
  Result := False;
end;

{ Scan tries every start from Start that the first set allows. }
function Scan(Prog: TProgram; St: PState; const T: TText; Start, Need: NativeInt; out From: NativeInt): Boolean;
var
  S: TSearchPlan;
  Fwd: TAnchoredDfa;
  Len, At, W, Place, E: NativeInt;
  Kind: Int32;
  C: UInt32;
  R: Int32;
  Over: Boolean;
begin
  Len := T.Len;
  S := Prog.Search;
  Fwd := Prog.Forward;
  From := 0;
  At := Start;
  while True do begin
    if Prog.Skip <> nil then
      At := SkipAhead(Prog.Skip, T, At);
    // Every match starts with a member of the first set, which starts with one of the first bytes or units.
    At := FirstStart(Prog, T, At);
    if At < 0 then
      Exit(False);
    // With the u or v flag the trail half of a pair is not a character a match can start at; the place after it
    // goes back through the skip.
    if not Prog.Units and (S.FirstUnits <> nil) and MidPair(T, At) then begin
      Inc(At);
      Continue;
    end;
    if Len - At < Need then
      Exit(False);
    if At = Len then begin
      From := At;
      Exit(not Prog.HasFirst and Run(Prog, St, T, At));
    end;
    C := U(T, At);
    R := C;
    W := 1;
    if C >= $80 then
      R := ReadAt(T, At, Prog.Units, W);
    if S.LeadingWordBoundary and (At > 0) and IsWordUnit(U(T, At - 1)) then begin
      // Inside a word, where \b cannot hold: the rest of the word is passed over.
      E := EndOfRun(Prog, Prog.First, T, At);
      if E < At + W then
        E := At + W;
      At := E;
      Continue;
    end;
    if Fwd <> nil then begin
      // One pass of the forward automaton from here says where a match first ends, or that none starts before a
      // place where no thread is alive; only then are starts tried, from here to there.
      Kind := ScanDfa(Fwd, T, At, Place);
      if Kind = ScanNone then
        Exit(False);
      if Kind = ScanIdle then begin
        At := Place;
        Continue;
      end;
      if TryStarts(Prog, St, T, At, Place, Over) then begin
        From := At;
        Exit(True);
      end;
      if Over then
        Exit(False);
      Continue;
    end;
    if (not Prog.HasFirst or Prog.First.Contains(R)) and Run(Prog, St, T, At) then begin
      From := At;
      Exit(True);
    end;
    if St^.Stop <> StopNone then
      Exit(False);
    if S.HasSkipRun and S.SkipRun.Contains(R) then begin
      // The start failed after its leading loop ate the run from here: every start in the rest of the run fails the
      // same way.
      E := EndOfRun(Prog, S.SkipRun, T, At + W);
      if E < At + W then
        E := At + W;
      At := E;
      Continue;
    end;
    Inc(At, W);
  end;
end;

function SearchProg(Prog: TProgram; St: PState; const T: TText; Start: NativeInt; Sticky: Boolean;
  out From: NativeInt): Boolean;
var
  Len, N: NativeInt;
begin
  Len := T.Len;
  N := ProgNeed(Prog);
  From := 0;
  if (Start > Len) or (Len - Start < N) then
    Exit(False);
  if Sticky or Prog.Anchored then begin
    if Prog.Anchored and (Start > 0) then
      Exit(False);
    From := Start;
    Exit(Run(Prog, St, T, Start));
  end;
  case Prog.Search.Plan of
    pkWindows: Exit(SearchWindows(Prog, St, T, Start, N, From));
    pkAfterLoops: Exit(SearchAfterLoops(Prog, St, T, Start, N, From));
  end;
  Result := Scan(Prog, St, T, Start, N, From);
end;

function ExecProg(Prog: TProgram; const T: TText; Start: NativeInt; Sticky: Boolean; Limit: Int64;
  Slots: PNativeInt; out From, To_: NativeInt): Boolean;
var
  St: PState;
  Stop: UInt8;
  K: NativeInt;
begin
  // A pattern of a simple shape with no group is answered by the search alone, with nothing of the matcher's.
  if (Prog.Groups = 0) and not Sticky and not Prog.Anchored and (Prog.Search.Shape <> shNone) then
    Exit(ShapeSearch(Prog, T, Start, From, To_));
  St := ThreadState;
  ResetState(St^, Prog, T.Len, Limit);
  Result := SearchProg(Prog, St, T, Start, Sticky, From);
  To_ := St^.EndPos;
  Stop := St^.Stop;
  if Result and (Slots <> nil) then
    for K := 0 to 2 * Prog.Groups - 1 do
      Slots[2 + K] := St^.Caps[K];
  ReleaseState(St^);
  RaiseStop(Stop, Limit);
end;

function ExecSearch(const S: TSearch; const T: TText; Start: NativeInt; Sticky: Boolean; Slots: PNativeInt;
  out From, To_: NativeInt): Boolean;
begin
  if Start < 0 then
    Start := 0;
  Start := NormalizeStart(T, Start, S.Unicode);
  if Slots = nil then
    Exit(ExecProg(S.Prog, T, Start, Sticky, S.Limit, nil, From, To_));
  Result := ExecProg(S.Caps, T, Start, Sticky, S.Limit, Slots, From, To_);
  if Result then begin
    Slots[0] := From;
    Slots[1] := To_;
  end;
end;

function NextStart(const S: TSearch; const T: TText; From, To_: NativeInt): NativeInt;
begin
  if To_ = From then
    Result := AdvancePos(T, To_, S.Unicode)
  else
    Result := To_;
end;

function CountAll(const S: TSearch; const T: TText): NativeInt;
var
  At, From, To_: NativeInt;
begin
  Result := 0;
  At := 0;
  while At <= T.Len do begin
    if not ExecSearch(S, T, At, S.Sticky, nil, From, To_) then
      Break;
    Inc(Result);
    At := NextStart(S, T, From, To_);
  end;
end;

{ NamedGroups is the groups of the name From..To_ of a template, which is in the units of the text. }
function NamedGroups(const S: TSearch; const Template: TText; From, To_: NativeInt): TGroupList;
var
  K: NativeInt;
begin
  for K := 0 to High(S.Names) do
    if NameIs(S.Names[K], Template, From, To_) then
      Exit(S.Names[K].Groups);
  Result := nil;
end;

{ Substitute appends the template with each $ form replaced (GetSubstitution). }
procedure Substitute(const S: TSearch; var Out_: TUnitBuffer; const T: TText; Slots: PNativeInt;
  const Template: TText);
var
  N, K, J, Close, D1, D2, Groups: NativeInt;
  Next: UInt32;
  Named: TGroupList;

  function Digit(At: NativeInt): NativeInt;
  begin
    if (At < N) and (U(Template, At) >= Ord('0')) and (U(Template, At) <= Ord('9')) then
      Result := U(Template, At) - Ord('0')
    else
      Result := -1;
  end;

  procedure Group(G: NativeInt);
  begin
    if Slots[2 * G] <> None then
      AppendLossy(Out_, T, Slots[2 * G], Slots[2 * G + 1]);
  end;

begin
  N := Template.Len;
  Groups := S.Groups;
  K := 0;
  while K < N do begin
    if (U(Template, K) <> Ord('$')) or (K + 1 >= N) then begin
      Out_.Add(U(Template, K));
      Inc(K);
      Continue;
    end;
    Next := U(Template, K + 1);
    if Next = Ord('$') then begin
      Out_.Add(U(Template, K));
      Inc(K, 2);
    end else if Next = Ord('&') then begin
      AppendLossy(Out_, T, Slots[0], Slots[1]);
      Inc(K, 2);
    end else if Next = Ord('`') then begin
      AppendLossy(Out_, T, 0, Slots[0]);
      Inc(K, 2);
    end else if Next = Ord('''') then begin
      AppendLossy(Out_, T, Slots[1], T.Len);
      Inc(K, 2);
    end else if (Next >= Ord('0')) and (Next <= Ord('9')) then begin
      D1 := Digit(K + 1);
      D2 := Digit(K + 2);
      if (D2 >= 0) and (D1 * 10 + D2 >= 1) and (D1 * 10 + D2 <= Groups) then begin
        Group(D1 * 10 + D2);
        Inc(K, 3);
      end else if (D1 >= 1) and (D1 <= Groups) then begin
        Group(D1);
        Inc(K, 2);
      end else begin
        Out_.Add(U(Template, K));
        Inc(K);
      end;
    end else if Next = Ord('<') then begin
      // Without a named group $< is itself. With one, the name runs to the next >; a name that is no group's is the
      // empty string, and a < with no > after it is itself.
      Close := -1;
      for J := K + 2 to N - 1 do
        if U(Template, J) = Ord('>') then begin
          Close := J;
          Break;
        end;
      if (Close < 0) or (Length(S.Names) = 0) then begin
        Out_.Add(U(Template, K));
        Inc(K);
        Continue;
      end;
      Named := NamedGroups(S, Template, K + 2, Close);
      for J := 0 to High(Named) do
        if Slots[2 * Named[J]] <> None then begin
          Group(Named[J]);
          Break;
        end;
      K := Close + 1;
    end else begin
      Out_.Add(U(Template, K));
      Inc(K);
    end;
  end;
end;

function ReplaceUnits(const S: TSearch; const T, Template: TText; All: Boolean; Count: NativeInt;
  var Out_: TUnitBuffer): Boolean;
var
  Slots: TPositions;
  Last, At, From, To_, Done: NativeInt;
begin
  SetLength(Slots, 2 * (S.Groups + 1));
  Result := False;
  Last := 0;
  At := 0;
  Done := 0;
  while (At <= T.Len) and ((Count < 0) or (Done < Count)) do begin
    if not ExecSearch(S, T, At, S.Sticky, @Slots[0], From, To_) then
      Break;
    Result := True;
    Inc(Done);
    AppendLossy(Out_, T, Last, From);
    Substitute(S, Out_, T, @Slots[0], Template);
    Last := To_;
    if not All then
      Break;
    At := NextStart(S, T, From, To_);
  end;
  if Result then
    AppendLossy(Out_, T, Last, T.Len);
end;

function SplitUnits(const S: TSearch; const T: TText; Limit: NativeInt): TSpans;
var
  Size, P, Q, From, To_, E, G, N: NativeInt;
  Slots: TPositions;
  Spans: TSpans;
  Full: Boolean;

  { Add appends a span, and reports whether the limit is reached. }
  function Add(A, B: NativeInt): Boolean;
  begin
    if N = Length(Spans) then
      SetLength(Spans, 2 * N + 8);
    Spans[N].From := A;
    Spans[N].To_ := B;
    Inc(N);
    Result := N = Limit;
  end;

begin
  Spans := nil;
  N := 0;
  Size := T.Len;
  Full := Limit = 0;
  SetLength(Slots, 2 * (S.Groups + 1));
  if Full then
    // No pieces at all.
  else if Size = 0 then begin
    if not ExecSearch(S, T, 0, True, @Slots[0], From, To_) then
      Add(0, 0);
  end else begin
    P := 0;
    Q := 0;
    while Q < Size do begin
      if not ExecSearch(S, T, Q, False, @Slots[0], From, To_) or (From >= Size) then
        Break;
      E := To_;
      if E > Size then
        E := Size;
      if E = P then begin
        Q := AdvancePos(T, From, S.Unicode);
        Continue;
      end;
      Full := Add(P, From);
      P := E;
      G := 1;
      while not Full and (G <= S.Groups) do begin
        if Slots[2 * G] = None then
          Full := Add(None, None)
        else
          Full := Add(Slots[2 * G], Slots[2 * G + 1]);
        Inc(G);
      end;
      if Full then
        Break;
      Q := P;
    end;
    if not Full then
      Add(P, Size);
  end;
  SetLength(Spans, N);
  Result := Spans;
end;
