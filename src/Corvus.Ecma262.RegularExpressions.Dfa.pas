unit Corvus.Ecma262.RegularExpressions.Dfa;
{$I ecma262.inc}

{ A deterministic automaton over ASCII text, for the patterns that need no backtracking (dfa.rs of the Rust crate).

  The strings a schema tests are short and nearly always ASCII, and most patterns in schemas are small. For such a
  pattern every state set the text can lead to is worked out once, and a match is then one table read per unit.

  The automaton reads units below $80 only. A text with any other unit is handed back to the backtracking matcher from
  the start, so nothing here needs to know UTF-8 or the Unicode classes: a class is its ASCII members. It takes \b and
  \B (not those of a case-insensitive pattern with the u flag, which fold): a state carries whether the unit before it
  was a word character and whether it is at the start of the text, and a boundary still to pass is passed, or not,
  when the next unit is known (section 4.4 of the design of the .NET reference engine). A pattern whose automaton has
  more states than a byte can number has no automaton. The automaton is built on the first match, not when the pattern
  is compiled, so a program pays nothing for the patterns it never matches.

  States of the pattern and of the automaton are numbered from 0, as in the crate. }

interface

uses
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Maps;

const
  (* The largest program a linear matcher is asked to compile, in the instructions estimated for it before it is
    written (see Re2Cost). A counted repetition is written out, so a{1000} is a thousand instructions. *)
  MaxRe2Cost = 10000;

type
  { A TDfa is the automaton of a pattern for an unanchored search. Nothing changes it once it is built. }
  TDfa = class
  public
    { The class of each unit below 128: units the pattern does not tell apart share one. Class 0 is every unit that
      is not ASCII. }
    ClassOf: array[0..127] of Byte;
    { Trans[State shl Shift or Class] is the state after a unit. }
    Trans: array of Byte;
    Shift: Int32;
    Start: Int32;
    { For each state, whether the pattern matches if the text ends there. }
    AtEnd: array of Boolean;
    { The pattern matches the empty text. }
    Empty: Boolean;
    { IsMatch8 and IsMatch16 report whether the pattern matches Len units from P, in Matched, and report false when
      the text is not ASCII, which they do not decide. }
    function IsMatch8(P: PByte; Len: NativeInt; out Matched: Boolean): Boolean;
    function IsMatch16(P: PUInt16; Len: NativeInt; out Matched: Boolean): Boolean;
  end;

(* Re2Cost is an estimate of the number of instructions of the program a linear matcher compiles for a tree (re2.rs). A
  counted repetition is written out: x{n,m} is m copies of x, and x{n,} is n copies and a loop. The estimate stops
  counting above MaxRe2Cost. *)
function Re2Cost(N: TNode): Int64;

{ BuildDfa is the automaton of a pattern for an unanchored search, or nil when it has none. }
function BuildDfa(Root: TNode): TDfa;

implementation

const
  { The states every automaton has. DfaDead: no match can follow. DfaAccept: a match was found. DfaBail: the text is
    not ASCII. }
  DfaDead = 0;
  DfaAccept = 1;
  DfaBail = 2;
  DfaFirst = 3;

  { An automaton has at most this many states (they are numbered in a byte), built from at most this many states of
    the pattern, in at most this many steps (a step is one state of the pattern looked at while a set is made). The
    steps bound what a pattern too large for an automaton costs before that is known, to about a millisecond. }
  MaxDfaStates = 256;
  MaxNfaStates = 512;
  MaxDfaSteps = 400000;

  { The kinds of the pattern's states. KSet reads one byte of its set and goes to Out. KSplit goes to Out and to Alt,
    reading nothing. KBol and KEol go to Out at the start and at the end of the text. KWord and KNotWord go to Out
    where a word boundary holds and where it does not. }
  KSet = 0;
  KSplit = 1;
  KBol = 2;
  KEol = 3;
  KWord = 4;
  KNotWord = 5;
  KMatch = 6;

type
  { A TNfa is the states of the pattern, as parallel arrays. }
  TNfa = record
    Kind: array of Byte;
    Set0, Set1: array of UInt64;
    Out_, Alt: TIntList;
    Count: Int32;
    { The pattern has something an automaton over bytes cannot decide, or is too large. }
    Failed: Boolean;
    function Add(K: Byte; S0, S1: UInt64; O, A: Int32): Int32;
    function Has(I, C: Int32): Boolean; inline;
    function Compile(N: TNode; Next: Int32): Int32;
  end;

  { A TDfaBuilder makes the automaton's states from sets of the pattern's states. }
  TDfaBuilder = record
    A: ^TNfa;
    { The states visited by Closure, and its stack. }
    Mark: TIntList;
    Generation: Int32;
    Stack: TIntList;
    Sp: Int32;
    { The steps left (see MaxDfaSteps). }
    Steps: Int32;
    { The states of the automaton being built. }
    Ids: TIntListMap;
    Sets: array of TIntList;
    Words, AtStarts: array of Boolean;
    StateCount: Int32;
    Trans: array of Byte;
    AtEnd: array of Boolean;
    procedure Push(I: Int32); inline;
    procedure Closure(var Set_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
      AtStart, AtEndOfText, WordsKnown, Before, After: Boolean);
    function HasMatch(const Set_: TIntList; N: Int32): Boolean;
    function Intern(Stride: Int32; const Set_: TIntList; N: Int32; Word, AtStart: Boolean): Int32;
  end;

function Re2Cost(N: TNode): Int64;
var
  K: Int32;
  Copies: Int64;
  Body: Int64;
begin
  case N.Kind of
    nkEmpty: Exit(0);
    nkCat, nkAlt, nkGroup: begin
      Result := Length(N.Subs) - 1;
      for K := 0 to High(N.Subs) do begin
        Inc(Result, Re2Cost(N.Subs[K]));
        if Result > MaxRe2Cost then
          Exit(MaxRe2Cost + 1);
      end;
      Exit;
    end;
    nkRepeat: begin
      if N.Max = Unbounded then
        Copies := N.Min
      else
        Copies := N.Max;
      if Copies < 1 then
        Copies := 1;
      // Each copy has the body and one instruction for the choice to enter it.
      Body := Re2Cost(N.Subs[0]) + 1;
      if (Copies > MaxRe2Cost) or (Body * Copies > MaxRe2Cost) then
        Exit(MaxRe2Cost + 1);
      Exit(Body * Copies);
    end;
  end;
  Result := 1;
end;

function TDfa.IsMatch8(P: PByte; Len: NativeInt; out Matched: Boolean): Boolean;
var
  S, K: NativeInt;
  U, Cls: UInt32;
begin
  if Len = 0 then begin
    Matched := Empty;
    Exit(True);
  end;
  S := Start;
  if S = DfaAccept then begin
    Matched := True;
    Exit(True);
  end;
  // K runs over the text, so P[K] is within it; Trans has a row of 1 shl Shift for every state.
  for K := 0 to Len - 1 do begin
    U := P[K];
    // A unit beyond ASCII is in class 0.
    if U < $80 then
      Cls := ClassOf[U]
    else
      Cls := 0;
    S := Trans[(S shl Shift) or NativeInt(Cls)];
    if S < DfaFirst then begin
      Matched := S = DfaAccept;
      Exit(S <> DfaBail);
    end;
  end;
  Matched := AtEnd[S];
  Result := True;
end;

function TDfa.IsMatch16(P: PUInt16; Len: NativeInt; out Matched: Boolean): Boolean;
var
  S, K: NativeInt;
  U, Cls: UInt32;
begin
  if Len = 0 then begin
    Matched := Empty;
    Exit(True);
  end;
  S := Start;
  if S = DfaAccept then begin
    Matched := True;
    Exit(True);
  end;
  for K := 0 to Len - 1 do begin
    U := P[K];
    if U < $80 then
      Cls := ClassOf[U]
    else
      Cls := 0;
    S := Trans[(S shl Shift) or NativeInt(Cls)];
    if S < DfaFirst then begin
      Matched := S = DfaAccept;
      Exit(S <> DfaBail);
    end;
  end;
  Matched := AtEnd[S];
  Result := True;
end;

{ TNfa }

function TNfa.Add(K: Byte; S0, S1: UInt64; O, A: Int32): Int32;
begin
  if Count >= MaxNfaStates then begin
    Failed := True;
    Exit(0);
  end;
  if Count = Length(Kind) then begin
    SetLength(Kind, 2 * Count + 16);
    SetLength(Set0, 2 * Count + 16);
    SetLength(Set1, 2 * Count + 16);
    SetLength(Out_, 2 * Count + 16);
    SetLength(Alt, 2 * Count + 16);
  end;
  Kind[Count] := K;
  Set0[Count] := S0;
  Set1[Count] := S1;
  Out_[Count] := O;
  Alt[Count] := A;
  Result := Count;
  Inc(Count);
end;

function TNfa.Has(I, C: Int32): Boolean;
begin
  if C < 64 then
    Result := ((Set0[I] shr C) and 1) <> 0
  else
    Result := ((Set1[I] shr (C - 64)) and 1) <> 0;
end;

{ Compile adds the states of a node that go on to Next, and returns the state they start at. }
function TNfa.Compile(N: TNode; Next: Int32): Int32;
var
  K, J, Start, O, Loop, Body: Int32;
  S0, S1: UInt64;
  Sub: TNode;
begin
  if Failed then
    Exit(0);
  case N.Kind of
    nkEmpty: Exit(Next);
    nkChar: begin
      S0 := 0;
      S1 := 0;
      if (N.R >= 0) and (N.R < 64) then
        S0 := UInt64(1) shl N.R
      else if (N.R >= 64) and (N.R < 128) then
        S1 := UInt64(1) shl (N.R - 64);
      Exit(Add(KSet, S0, S1, Next, 0));
    end;
    nkSet: Exit(Add(KSet, N.CharSet.Ascii[0], N.CharSet.Ascii[1], Next, 0));
    nkCat: begin
      for K := High(N.Subs) downto 0 do
        Next := Compile(N.Subs[K], Next);
      Exit(Next);
    end;
    nkAlt: begin
      Start := Compile(N.Subs[High(N.Subs)], Next);
      for J := High(N.Subs) - 1 downto 0 do begin
        O := Compile(N.Subs[J], Next);
        Start := Add(KSplit, 0, 0, O, Start);
      end;
      Exit(Start);
    end;
    nkGroup: Exit(Compile(N.Subs[0], Next));
    nkRepeat: begin
      Sub := N.Subs[0];
      if N.Max = Unbounded then begin
        // The loop, then the copies that must match before it.
        Loop := Add(KSplit, 0, 0, 0, Next);
        if Failed then
          Exit(0);
        Body := Compile(Sub, Loop);
        Out_[Loop] := Body;
        Next := Loop;
      end else begin
        // The copies that may match, innermost last.
        K := N.Min;
        while (K < N.Max) and not Failed do begin
          O := Compile(Sub, Next);
          Next := Add(KSplit, 0, 0, O, Next);
          Inc(K);
        end;
      end;
      K := 0;
      while (K < N.Min) and not Failed do begin
        Next := Compile(Sub, Next);
        Inc(K);
      end;
      Exit(Next);
    end;
    nkBol: Exit(Add(KBol, 0, 0, Next, 0));
    nkEol: Exit(Add(KEol, 0, 0, Next, 0));
    nkWordBoundary:
      if not N.Fold then
        Exit(Add(KWord, 0, 0, Next, 0));
    nkNotWordBoundary:
      if not N.Fold then
        Exit(Add(KNotWord, 0, 0, Next, 0));
  end;
  // A word boundary that folds, or anything that needs the backtracking matcher.
  Failed := True;
  Result := 0;
end;

{ TDfaBuilder }

procedure TDfaBuilder.Push(I: Int32);
begin
  if Sp = Length(Stack) then
    SetLength(Stack, 2 * Sp + 64);
  Stack[Sp] := I;
  Inc(Sp);
end;

procedure AddTo(var Set_: TIntList; var N: Int32; I: Int32); inline;
begin
  if N = Length(Set_) then
    SetLength(Set_, 2 * N + 16);
  Set_[N] := I;
  Inc(N);
end;

(* Closure adds to Set_ (from N) every state that reading nothing reaches from the states in From, keeping the
  states that read a unit, the anchors and boundaries still to pass, and the match. A start anchor is passed only
  AtStart, and an end anchor only AtEndOfText. A word boundary is kept to pass later when WordsKnown is false, and
  otherwise (whether the units before and after the position are word characters) is passed or dropped. *)
procedure TDfaBuilder.Closure(var Set_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
  AtStart, AtEndOfText, WordsKnown, Before, After: Boolean);
var
  I, K: Int32;
  Kind: Byte;
begin
  Inc(Generation);
  Sp := 0;
  for K := 0 to FromCount - 1 do
    Push(From[K]);
  while Sp > 0 do begin
    Dec(Sp);
    I := Stack[Sp];
    Dec(Steps);
    if Mark[I] = Generation then
      Continue;
    Mark[I] := Generation;
    Kind := A^.Kind[I];
    case Kind of
      KSplit: begin
        Push(A^.Out_[I]);
        Push(A^.Alt[I]);
      end;
      KBol:
        if AtStart then
          Push(A^.Out_[I]);
      KEol:
        if AtEndOfText then
          Push(A^.Out_[I])
        else
          AddTo(Set_, N, I);
      KWord, KNotWord:
        if not WordsKnown then
          AddTo(Set_, N, I)
        else if (Before <> After) = (Kind = KWord) then
          Push(A^.Out_[I]);
    else
      AddTo(Set_, N, I);
    end;
  end;
end;

function TDfaBuilder.HasMatch(const Set_: TIntList; N: Int32): Boolean;
var
  K: Int32;
begin
  for K := 0 to N - 1 do
    if A^.Kind[Set_[K]] = KMatch then
      Exit(True);
  Result := False;
end;

{ DfaKey is a state of the automaton as a key: its states in increasing order, then whether the unit before it was
  a word character and whether it is at the start of the text. }
function DfaKey(const Set_: TIntList; N: Int32; Word, AtStart: Boolean): TIntList;
var
  K, J, V: Int32;
begin
  SetLength(Result, N + 1);
  for K := 0 to N - 1 do begin
    V := Set_[K];
    J := K;
    while (J > 0) and (Result[J - 1] > V) do begin
      Result[J] := Result[J - 1];
      Dec(J);
    end;
    Result[J] := V;
  end;
  V := 0;
  if Word then
    V := 2;
  if AtStart then
    V := V or 1;
  Result[N] := V - 4;
end;

{ Intern gives a set its state, or returns -1 when there are too many. }
function TDfaBuilder.Intern(Stride: Int32; const Set_: TIntList; N: Int32; Word, AtStart: Boolean): Int32;
var
  Key, Closed: TIntList;
  Id, K, NC: Int32;
begin
  if HasMatch(Set_, N) then
    Exit(DfaAccept);
  if N = 0 then
    Exit(DfaDead);
  Key := DfaKey(Set_, N, Word, AtStart);
  Id := Ids.Find(Key);
  if Id >= 0 then
    Exit(Id);
  if StateCount >= MaxDfaStates then
    Exit(-1);
  Id := StateCount;
  Ids.Add(Key, Id);
  if StateCount = Length(Sets) then begin
    SetLength(Sets, 2 * StateCount + 8);
    SetLength(Words, 2 * StateCount + 8);
    SetLength(AtStarts, 2 * StateCount + 8);
    SetLength(AtEnd, 2 * StateCount + 8);
  end;
  Sets[Id] := Copy(Set_, 0, N);
  Words[Id] := Word;
  AtStarts[Id] := AtStart;
  Inc(StateCount);
  // The table grows by doubling, and a new row is zero.
  if StateCount * Stride > Length(Trans) then
    SetLength(Trans, 2 * StateCount * Stride);
  for K := Id * Stride to StateCount * Stride - 1 do
    Trans[K] := 0;
  // At the end of the text the end anchors are passed, and a boundary is between a unit and none.
  Closed := nil;
  NC := 0;
  Closure(Closed, NC, Set_, N, AtStart, True, True, Word, False);
  AtEnd[Id] := HasMatch(Closed, NC);
  Result := Id;
end;

function BuildDfa(Root: TNode): TDfa;
var
  A: TNfa;
  B: TDfaBuilder;
  MatchState, StartState, Classes, Cls, S, C, Shift, Stride, S0, Id, Cl, ToState, K: Int32;
  Signatures: TIntListMap;
  Signature: TIntList;
  ClassOf: array[0..127] of Byte;
  Sample: array[0..128] of Int32;
  StartList, Restart, First, Resolved, Moved, Next: TIntList;
  NRestart, NFirst, NResolved, NMoved, NNext: Int32;
  EmptyText: Boolean;
begin
  Result := nil;
  A := Default(TNfa);
  MatchState := A.Add(KMatch, 0, 0, 0, 0);
  StartState := A.Compile(Root, MatchState);
  if A.Failed then
    Exit;

  // The classes of units: two units are in one class when every set of the pattern has both or neither, and both or
  // neither is a word character. Class 0 is the units that are not ASCII.
  Classes := 1;
  Signatures := Default(TIntListMap);
  for C := 0 to 127 do begin
    Signature := nil;
    SetLength(Signature, 1);
    Signature[0] := Ord(IsWordByte(C));
    for S := 0 to A.Count - 1 do
      if A.Kind[S] = KSet then begin
        SetLength(Signature, Length(Signature) + 1);
        Signature[High(Signature)] := Ord(A.Has(S, C));
      end;
    Cls := Signatures.Find(Signature);
    if Cls < 0 then begin
      Cls := Classes;
      Inc(Classes);
      Signatures.Add(Signature, Cls);
    end;
    ClassOf[C] := Cls;
  end;
  Shift := 0;
  while (1 shl Shift) < Classes do
    Inc(Shift);
  // One unit of each class, to move a set by.
  for C := 0 to 128 do
    Sample[C] := 0;
  for C := 127 downto 0 do
    Sample[ClassOf[C]] := C;
  Stride := 1 shl Shift;

  B := Default(TDfaBuilder);
  B.A := @A;
  SetLength(B.Mark, A.Count);
  B.Steps := MaxDfaSteps;
  B.StateCount := DfaFirst;
  SetLength(B.Sets, DfaFirst);
  SetLength(B.Words, DfaFirst);
  SetLength(B.AtStarts, DfaFirst);
  SetLength(B.AtEnd, DfaFirst);
  SetLength(B.Trans, DfaFirst * Stride);

  // The search is unanchored: a match may start at any position, so after every unit the states the pattern starts
  // in (not at the start of the text) join the set.
  SetLength(StartList, 1);
  StartList[0] := StartState;
  Restart := nil;
  NRestart := 0;
  B.Closure(Restart, NRestart, StartList, 1, False, False, False, False, False);
  for Cl := 0 to Stride - 1 do begin
    B.Trans[DfaAccept * Stride + Cl] := DfaAccept;
    B.Trans[DfaBail * Stride + Cl] := DfaBail;
  end;
  First := nil;
  NFirst := 0;
  B.Closure(First, NFirst, StartList, 1, True, False, False, False, False);
  S0 := B.Intern(Stride, First, NFirst, False, True);
  if S0 < 0 then
    Exit;
  EmptyText := (S0 = DfaAccept) or B.AtEnd[S0];
  Resolved := nil;
  Moved := nil;
  Next := nil;
  Id := DfaFirst;
  while Id < B.StateCount do begin
    for Cl := 0 to Stride - 1 do begin
      if (Cl = 0) or (Cl >= Classes) then begin
        // Not ASCII (or no such class).
        B.Trans[Id * Stride + Cl] := DfaBail;
        Continue;
      end;
      C := Sample[Cl];
      // The boundaries at this position are passed now that the unit after it is known.
      NResolved := 0;
      B.Closure(Resolved, NResolved, B.Sets[Id], Length(B.Sets[Id]), B.AtStarts[Id], False, True, B.Words[Id],
        IsWordByte(C));
      if B.HasMatch(Resolved, NResolved) then begin
        B.Trans[Id * Stride + Cl] := DfaAccept;
        Continue;
      end;
      NMoved := 0;
      for K := 0 to NResolved - 1 do
        if (A.Kind[Resolved[K]] = KSet) and A.Has(Resolved[K], C) then
          AddTo(Moved, NMoved, A.Out_[Resolved[K]]);
      for K := 0 to NRestart - 1 do
        AddTo(Moved, NMoved, Restart[K]);
      NNext := 0;
      B.Closure(Next, NNext, Moved, NMoved, False, False, False, False, False);
      ToState := B.Intern(Stride, Next, NNext, IsWordByte(C), False);
      if (ToState < 0) or (B.Steps < 0) then
        Exit;
      B.Trans[Id * Stride + Cl] := ToState;
    end;
    Inc(Id);
  end;
  Result := TDfa.Create;
  Move(ClassOf[0], Result.ClassOf[0], SizeOf(ClassOf));
  Result.Trans := Copy(B.Trans, 0, B.StateCount * Stride);
  Result.Shift := Shift;
  Result.Start := S0;
  Result.AtEnd := Copy(B.AtEnd, 0, B.StateCount);
  Result.Empty := EmptyText;
end;

end.
