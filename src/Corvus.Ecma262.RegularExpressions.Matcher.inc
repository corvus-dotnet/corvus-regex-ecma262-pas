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

{ Run reports whether the program matches at the position Start. It keeps its choices on an explicit stack, so the
  depth of the search is bounded by memory and not by the stack of the thread. When it fails, every group and
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

{ Scan tries every position from Start that the first set allows, until one matches. }
function Scan(Prog: TProgram; St: PState; const T: TText; Start, N: NativeInt; out From: NativeInt): Boolean;
var
  Len, At, W: NativeInt;
  C: UInt32;
  R: Int32;
begin
  Len := T.Len;
  From := 0;
  At := Start;
  while True do begin
    if Len - At < N then
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
    if (not Prog.HasFirst or Prog.First.Contains(R)) and Run(Prog, St, T, At) then begin
      From := At;
      Exit(True);
    end;
    if St^.Stop <> StopNone then
      Exit(False);
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
  Result := Scan(Prog, St, T, Start, N, From);
end;

function ExecProg(Prog: TProgram; const T: TText; Start: NativeInt; Sticky: Boolean; Limit: Int64;
  Slots: PNativeInt; out From, To_: NativeInt): Boolean;
var
  St: PState;
  Stop: UInt8;
  K: NativeInt;
begin
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
