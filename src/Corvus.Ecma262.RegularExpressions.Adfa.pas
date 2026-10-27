unit Corvus.Ecma262.RegularExpressions.Adfa;
{$I ecma262.inc}

{ An anchored, leftmost-first automaton over ASCII text, which finds where the match that starts at a position ends
  for a pattern that needs no backtracking (adfa.rs of the Rust crate): what the regex crate's DFAs do for the match,
  taken into this engine where ECMA-262's semantics allow it.

  A state is an ordered list of the pattern's states (its threads, the most preferred first, as the backtracking
  matcher would try them), with whether the unit before it was a word character and whether it is at the start of the
  text. When the match state is among the threads, a match ends here, and the threads after it, which the
  backtracking matcher would only try had this way failed, are dropped; the threads before it may still find a longer
  match, which it would prefer. So the last match found before the threads run out is the backtracking matcher's
  match, for a pattern with no lookaround, no backreference and no repetition whose body can match the empty string
  (where ECMA-262's rule for an empty iteration would differ from a thread's). A unit beyond ASCII hands the start back
  to the backtracking matcher.

  Every state is worked out when the pattern is compiled, within bounds of states and steps, so that a pattern too
  large for an automaton costs little before that is known. This unit builds the automata; the loops that read them
  over a text are in the matcher (Corvus.Ecma262.RegularExpressions.Matcher.inc). States are numbered from 0, as in
  the crate. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Maps,
  Corvus.Ecma262.RegularExpressions.Swar;

const
  { The state with no thread left: no match can end further on. }
  AdfaDead = 0;
  { Flags a transition across which a match ends before the unit, in the premultiplied table. }
  FastMatched = UInt32($80000000);
  { What a search of an automaton answers where no match starts, and where a unit beyond ASCII was reached first. }
  AdfaNone = -1;
  AdfaBail = -2;
  { The kinds of what a scan of the forward automaton found. }
  ScanMatch = 0;
  ScanIdle = 1;
  ScanBail = 2;
  ScanNone = 3;

type
  TStartRows = array[0..3] of UInt32;

  { A TAnchoredDfa is the anchored automaton of a pattern. Nothing changes it once it is built. }
  TAnchoredDfa = class
  public
    { The class of each unit below 128. }
    ClassOf: array[0..127] of Byte;
    Shift: Int32;
    { Fast[State * Stride + Class] is the next state, premultiplied by the stride, with FastMatched when a match ends
      before the unit. }
    Fast: array of UInt32;
    { For each state, whether a match ends at the end of the text. }
    AtEnd: array of Boolean;
    { The start state for each of: the unit before is a word character (bit 1), the start of the text (bit 0). }
    Starts: array[0..3] of Int32;
    { The start states differ (the pattern looks back at the unit before or at the start of the text). }
    Context: Boolean;
    { For the forward automaton (see BuildForwardDfa), whether each state is a start state: no thread of an earlier
      start is alive in it. }
    StartLike: array of Boolean;
    { After is the state after Prefix from each start state, premultiplied by the stride (0 where no match can start
      with it); false when a match can end inside it or it holds a byte beyond ASCII: what a search goes on from where
      a match is known to start with Prefix. }
    function After(const Prefix: array of Byte; out Rows: TStartRows): Boolean;
  end;

  (* A TSkipWin is the positions of a pattern read before a match can end: V8's Boyer-Moore lookahead
    (BoyerMooreLookahead in its regexp compiler). For a window of positions lo..hi of every match, the units each can
    be (Table for ASCII, Wide for any other) are joined; a unit at hi from a place that is none of them rules out the
    starts from that place to hi - lo units on, so the search reads one unit in hi - lo + 1 where the window's units
    are rare. *)
  TSkipWin = class
  public
    { The window's last position, the one read, and the starts one unit rules out, hi - lo + 1. }
    Hi: NativeInt;
    Len: NativeInt;
    Table: array[0..1] of UInt64;
    Wide: Boolean;
    { The bytes Hit passes over UTF-8 as up to four ranges as IndexRanges reads them (each run of the table, any
      byte beyond ASCII where Wide, the nearest runs joined until four are left, which passes more and so rules out
      no start it should not), and their number. }
    NRanges: Int32;
    RangeConsts: TBytes;
    { Hit reports whether the unit can be at some position of the window. }
    function Hit(C: UInt32): Boolean; inline;
  end;

  { A TReverseDfa is an automaton of the terms before the anchors of a search, read backwards (accepting where any of
    them can start): from an occurrence of an anchor it finds, over ASCII text, every start from which some
    alternative's terms reach it. Only terms with no assertion are taken. }
  TReverseDfa = class
  public
    ClassOf: array[0..127] of Byte;
    Shift: Int32;
    { The transitions, each the next state's row (premultiplied by the stride, so 0 is the dead state) with
      FastMatched where that state accepts. }
    Fast: array of UInt32;
    { The first state accepts (an empty run of terms). }
    AcceptFirst: Boolean;
  end;

  TNodeLists = array of TNodes;

{ BuildAdfa is the anchored automaton of a tree (after simplify), or nil when the pattern has none. }
function BuildAdfa(Root: TNode): TAnchoredDfa;

{ BuildForwardDfa is the forward automaton of a tree: the anchored automaton with a new start joined at every unit,
  behind every thread already alive (so last in preference, as the search tries later starts after earlier ones).
  Read over the text from a start, it says where the first match ends, and its start states say where no thread of an
  earlier start is alive: the leftmost match starts at or after the last of them, the forward search of the regex
  crate. }
function BuildForwardDfa(Root: TNode): TAnchoredDfa;

{ BuildReverseDfa is the reverse automaton of the prefixes of a search's anchors, or nil when one holds an assertion
  or the automaton is too large. }
function BuildReverseDfa(const Prefixes: TNodeLists): TReverseDfa;

{ SkipWindow is the window of a tree (after simplify) worth reading one unit of instead of every unit, or nil: the
  units each position before a match can end can be, from the pattern's automaton without its determinisation, and
  the window whose units are rare enough that one unit read passes over three starts or more. }
function SkipWindow(Root: TNode): TSkipWin;

implementation

const
  AdfaMaxStates = 2048;
  AdfaMaxNfa = 1024;
  AdfaMaxSteps = 2000000;
  { Flags a transition across which a match ends before the unit, in the table being built. }
  AdfaMatched = $8000;
  { The most positions looked at for a window. }
  SkipPositions = 16;

  { The kinds of the pattern's states. }
  ASet = 0;
  ASplit = 1;
  ABol = 2;
  AEol = 3;
  AWord = 4;
  ANotWord = 5;
  AMatch = 6;

type
  { A TAdfaNfa is the states of a pattern, as parallel arrays that grow. }
  TAdfaNfa = record
    Kind: array of Byte;
    Set0, Set1: array of UInt64;
    { The set holds a character beyond ASCII, which the automaton gives up at. }
    Wide: array of Boolean;
    Out_, Alt: TIntList;
    Count: Int32;
    Failed: Boolean;
    function Add(K: Byte; S0, S1: UInt64; W: Boolean; O, A: Int32): Int32;
    function AddTo(K: Byte; O: Int32): Int32; inline;
    { Split adds a split whose preferred way is first. }
    function Split(First, Second: Int32): Int32; inline;
    function Has(I, C: Int32): Boolean; inline;
    function Compile(N: TNode; Next: Int32): Int32;
    function CompileBack(N: TNode; Next: Int32): Int32;
  end;
  PAdfaNfa = ^TAdfaNfa;

  { A TAdfaDet makes the automaton's states from lists of the pattern's states. }
  TAdfaDet = record
    Nfa: PAdfaNfa;
    Mark: TIntList;
    Generation: Int32;
    Steps: Int32;
    Stack: TIntList;
    Sp: Int32;
    procedure Init(ANfa: PAdfaNfa);
    procedure Push(I: Int32); inline;
    procedure Closure(var Out_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
      AtStart, AtEndOfText, Words, Before, After: Boolean);
    procedure ClosureOn(var Out_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
      AtStart, AtEndOfText, Words, Before, After: Boolean);
    function HasKind(const Set_: TIntList; N: Int32; K: Byte): Boolean;
    function ReverseClosure(const From: TIntList; FromCount: Int32): TIntList;
  end;

  { A TAdfaTable is the states of an automaton being built, by their key. }
  TAdfaTable = record
    Ids: TIntListMap;
    Sets: array of TIntList;
    Words, AtStarts: array of Boolean;
    Count: Int32;
    Trans: TIntList;
    AtEnd: array of Boolean;
    Stride: Int32;
    function Intern(var D: TAdfaDet; const Set_: TIntList; N: Int32; Word, AtStart: Boolean; NStates: Int32): Int32;
  end;

procedure AddInt(var L: TIntList; var N: Int32; V: Int32); inline;
begin
  if N = Length(L) then
    SetLength(L, 2 * N + 16);
  L[N] := V;
  Inc(N);
end;

{ TAnchoredDfa }

function TAnchoredDfa.After(const Prefix: array of Byte; out Rows: TStartRows): Boolean;
var
  K, J: Int32;
  At, T: UInt32;
  B: Byte;
begin
  for K := 0 to 3 do begin
    At := UInt32(Starts[K]) shl Shift;
    for J := 0 to High(Prefix) do begin
      // No match from this start state begins with the prefix.
      if At = 0 then
        Break;
      B := Prefix[J];
      if B >= $80 then
        Exit(False);
      T := Fast[At + ClassOf[B]];
      if (T and FastMatched) <> 0 then
        Exit(False);
      At := T;
    end;
    Rows[K] := At;
  end;
  Result := True;
end;

{ TSkipWin }

function TSkipWin.Hit(C: UInt32): Boolean;
begin
  if C < 128 then
    Result := ((Table[C shr 6] shr (C and 63)) and 1) <> 0
  else
    Result := Wide;
end;

{ TAdfaNfa }

function TAdfaNfa.Add(K: Byte; S0, S1: UInt64; W: Boolean; O, A: Int32): Int32;
begin
  if Count >= AdfaMaxNfa then begin
    Failed := True;
    Exit(0);
  end;
  if Count = Length(Kind) then begin
    SetLength(Kind, 2 * Count + 16);
    SetLength(Set0, 2 * Count + 16);
    SetLength(Set1, 2 * Count + 16);
    SetLength(Wide, 2 * Count + 16);
    SetLength(Out_, 2 * Count + 16);
    SetLength(Alt, 2 * Count + 16);
  end;
  Kind[Count] := K;
  Set0[Count] := S0;
  Set1[Count] := S1;
  Wide[Count] := W;
  Out_[Count] := O;
  Alt[Count] := A;
  Result := Count;
  Inc(Count);
end;

function TAdfaNfa.AddTo(K: Byte; O: Int32): Int32;
begin
  Result := Add(K, 0, 0, False, O, 0);
end;

function TAdfaNfa.Split(First, Second: Int32): Int32;
begin
  Result := Add(ASplit, 0, 0, False, First, Second);
end;

function TAdfaNfa.Has(I, C: Int32): Boolean;
begin
  if C < 64 then
    Result := ((Set0[I] shr C) and 1) <> 0
  else
    Result := ((Set1[I] shr (C - 64)) and 1) <> 0;
end;

{ Compile adds the states of a node that go on to Next, and returns the state they start at. }
function TAdfaNfa.Compile(N: TNode; Next: Int32): Int32;
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
      Exit(Add(ASet, S0, S1, N.R >= 128, Next, 0));
    end;
    nkSet: Exit(Add(ASet, N.CharSet.Ascii[0], N.CharSet.Ascii[1],
      (Length(N.CharSet.Ranges) > 0) and (N.CharSet.Ranges[High(N.CharSet.Ranges)] >= 128), Next, 0));
    nkCat: begin
      for K := High(N.Subs) downto 0 do
        Next := Compile(N.Subs[K], Next);
      Exit(Next);
    end;
    nkAlt: begin
      Start := Compile(N.Subs[High(N.Subs)], Next);
      for J := High(N.Subs) - 1 downto 0 do begin
        O := Compile(N.Subs[J], Next);
        Start := Split(O, Start);
      end;
      Exit(Start);
    end;
    nkGroup: Exit(Compile(N.Subs[0], Next));
    nkRepeat: begin
      Sub := N.Subs[0];
      if (N.Max <> 0) and (N.Max <> 1) and Nullable(Sub) then begin
        // ECMA-262 refuses an empty iteration after the least count, which a thread does not know.
        Failed := True;
        Exit(0);
      end;
      if N.Max = Unbounded then begin
        Loop := Split(0, 0);
        if Failed then
          Exit(0);
        Body := Compile(Sub, Loop);
        if N.Lazy then begin
          Out_[Loop] := Next;
          Alt[Loop] := Body;
        end else begin
          Out_[Loop] := Body;
          Alt[Loop] := Next;
        end;
        Next := Loop;
      end else begin
        K := N.Min;
        while (K < N.Max) and not Failed do begin
          Body := Compile(Sub, Next);
          if N.Lazy then
            Next := Split(Next, Body)
          else
            Next := Split(Body, Next);
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
    nkBol: Exit(AddTo(ABol, Next));
    nkEol: Exit(AddTo(AEol, Next));
    nkWordBoundary:
      if not N.Fold then
        Exit(AddTo(AWord, Next));
    nkNotWordBoundary:
      if not N.Fold then
        Exit(AddTo(ANotWord, Next));
  end;
  Failed := True;
  Result := 0;
end;

{ CompileBack adds the states of a node read backwards that go on to Next. }
function TAdfaNfa.CompileBack(N: TNode; Next: Int32): Int32;
var
  K, J, Start, O, Loop, Body: Int32;
  Sub: TNode;
begin
  if Failed then
    Exit(0);
  case N.Kind of
    nkCat: begin
      for K := 0 to High(N.Subs) do
        Next := CompileBack(N.Subs[K], Next);
      Exit(Next);
    end;
    nkAlt: begin
      Start := CompileBack(N.Subs[High(N.Subs)], Next);
      for J := High(N.Subs) - 1 downto 0 do begin
        O := CompileBack(N.Subs[J], Next);
        Start := Split(O, Start);
      end;
      Exit(Start);
    end;
    nkGroup: Exit(CompileBack(N.Subs[0], Next));
    nkRepeat: begin
      Sub := N.Subs[0];
      if N.Max = Unbounded then begin
        Loop := Split(0, 0);
        if Failed then
          Exit(0);
        Body := CompileBack(Sub, Loop);
        Out_[Loop] := Body;
        Alt[Loop] := Next;
        Next := Loop;
      end else begin
        K := N.Min;
        while (K < N.Max) and not Failed do begin
          Body := CompileBack(Sub, Next);
          Next := Split(Body, Next);
          Inc(K);
        end;
      end;
      K := 0;
      while (K < N.Min) and not Failed do begin
        Next := CompileBack(Sub, Next);
        Inc(K);
      end;
      Exit(Next);
    end;
    nkEmpty, nkChar, nkSet: Exit(Compile(N, Next));
  end;
  Failed := True;
  Result := 0;
end;

{ TAdfaDet }

procedure TAdfaDet.Init(ANfa: PAdfaNfa);
begin
  Nfa := ANfa;
  SetLength(Mark, ANfa^.Count);
  Generation := 0;
  Steps := AdfaMaxSteps;
  Sp := 0;
end;

procedure TAdfaDet.Push(I: Int32);
begin
  if Sp = Length(Stack) then
    SetLength(Stack, 2 * Sp + 64);
  Stack[Sp] := I;
  Inc(Sp);
end;

(* Closure appends to Out_, in order of preference, the threads that reading nothing reaches from From, keeping the
  states that read a unit, the anchors and boundaries still to pass, and the match, after which nothing more is kept.
  Boundaries are passed or dropped with Words, and kept to pass later without it. *)
procedure TAdfaDet.Closure(var Out_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
  AtStart, AtEndOfText, Words, Before, After: Boolean);
begin
  Inc(Generation);
  ClosureOn(Out_, N, From, FromCount, AtStart, AtEndOfText, Words, Before, After);
end;

{ ClosureOn is Closure after the closure just made, leaving out the states it reached. }
procedure TAdfaDet.ClosureOn(var Out_: TIntList; var N: Int32; const From: TIntList; FromCount: Int32;
  AtStart, AtEndOfText, Words, Before, After: Boolean);
var
  I, K: Int32;
  Kind: Byte;
begin
  Sp := 0;
  for K := FromCount - 1 downto 0 do
    Push(From[K]);
  while Sp > 0 do begin
    Dec(Sp);
    I := Stack[Sp];
    Dec(Steps);
    if Mark[I] = Generation then
      Continue;
    Mark[I] := Generation;
    Kind := Nfa^.Kind[I];
    case Kind of
      ASplit: begin
        Push(Nfa^.Alt[I]);
        Push(Nfa^.Out_[I]);
      end;
      ABol:
        if AtStart then
          Push(Nfa^.Out_[I]);
      AEol:
        if AtEndOfText then
          Push(Nfa^.Out_[I])
        else
          AddInt(Out_, N, I);
      AWord, ANotWord:
        if not Words then
          AddInt(Out_, N, I)
        else if (Before <> After) = (Kind = AWord) then
          Push(Nfa^.Out_[I]);
      AMatch: begin
        AddInt(Out_, N, I);
        Exit;
      end;
    else
      AddInt(Out_, N, I);
    end;
  end;
end;

function TAdfaDet.HasKind(const Set_: TIntList; N: Int32; K: Byte): Boolean;
var
  J: Int32;
begin
  for J := 0 to N - 1 do
    if Nfa^.Kind[Set_[J]] = K then
      Exit(True);
  Result := False;
end;

{ ReverseClosure is the closure of the reverse automaton, sorted: every thread is kept (any of them reaching the match
  is a start). }
function TAdfaDet.ReverseClosure(const From: TIntList; FromCount: Int32): TIntList;
var
  I, K, J, N, V: Int32;
begin
  Result := nil;
  N := 0;
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
    if Nfa^.Kind[I] = ASplit then begin
      Push(Nfa^.Alt[I]);
      Push(Nfa^.Out_[I]);
    end else
      AddInt(Result, N, I);
  end;
  SetLength(Result, N);
  // An insertion sort: the lists are short.
  for K := 1 to N - 1 do begin
    V := Result[K];
    J := K;
    while (J > 0) and (Result[J - 1] > V) do begin
      Result[J] := Result[J - 1];
      Dec(J);
    end;
    Result[J] := V;
  end;
end;

{ UnitClasses fills ClassOf with the classes of units, those every set has both or neither of, and returns the number
  of classes. }
function UnitClasses(var ClassOf: array of Byte; const Nfa: TAdfaNfa; Words: Boolean): Int32;
var
  Signatures: TIntListMap;
  Sig: TIntList;
  C, S, N, Cls: Int32;
begin
  Signatures := Default(TIntListMap);
  for C := 0 to 127 do begin
    Sig := nil;
    N := 0;
    if Words then
      AddInt(Sig, N, Ord(IsWordByte(C)));
    for S := 0 to Nfa.Count - 1 do
      if Nfa.Kind[S] = ASet then
        AddInt(Sig, N, Ord(Nfa.Has(S, C)));
    SetLength(Sig, N);
    Cls := Signatures.Find(Sig);
    if Cls < 0 then begin
      Cls := Signatures.Count;
      Signatures.Add(Sig, Cls);
    end;
    ClassOf[C] := Cls;
  end;
  Result := Signatures.Count;
end;

{ AdfaKey is a list of threads as a key, with the bits that matter. }
function AdfaKey(const Set_: TIntList; N: Int32; Word, AtStart: Boolean): TIntList;
var
  K: Int32;
begin
  SetLength(Result, N + 2);
  for K := 0 to N - 1 do
    Result[K] := Set_[K];
  Result[N] := -1 - Ord(Word);
  Result[N + 1] := -3 - Ord(AtStart);
end;

{ DecodeThreads is the threads of a forward state with those of the current start numbered as the pattern numbers
  them. }
function DecodeThreads(const Set_: TIntList; NStates: Int32): TIntList;
var
  K: Int32;
begin
  SetLength(Result, Length(Set_));
  for K := 0 to High(Set_) do
    if Set_[K] >= NStates then
      Result[K] := Set_[K] - NStates
    else
      Result[K] := Set_[K];
end;

{ Intern gives a list of threads its state, keyed with the bits that matter, or returns -1 when there are too many. }
function TAdfaTable.Intern(var D: TAdfaDet; const Set_: TIntList; N: Int32; Word, AtStart: Boolean;
  NStates: Int32): Int32;
var
  Key, Closed, Decoded: TIntList;
  Known, NC, K: Int32;
begin
  if N = 0 then
    Exit(AdfaDead);
  Key := AdfaKey(Set_, N, Word, AtStart);
  Known := Ids.Find(Key);
  if Known >= 0 then
    Exit(Known);
  if Count >= AdfaMaxStates then
    Exit(-1);
  Result := Count;
  Decoded := DecodeThreads(Copy(Set_, 0, N), NStates);
  Closed := nil;
  NC := 0;
  D.Closure(Closed, NC, Decoded, Length(Decoded), AtStart, True, True, Word, False);
  if Count = Length(Sets) then begin
    SetLength(Sets, 2 * Count + 16);
    SetLength(Words, 2 * Count + 16);
    SetLength(AtStarts, 2 * Count + 16);
    SetLength(AtEnd, 2 * Count + 16);
  end;
  AtEnd[Result] := D.HasKind(Closed, NC, AMatch);
  Sets[Result] := Copy(Set_, 0, N);
  Words[Result] := Word;
  AtStarts[Result] := AtStart;
  Inc(Count);
  // The table grows by doubling, and a new row is zero.
  if Count * Stride > Length(Trans) then
    SetLength(Trans, 2 * Count * Stride);
  for K := Result * Stride to Count * Stride - 1 do
    Trans[K] := 0;
  Ids.Add(Key, Result);
end;

function BuildAdfaWith(Root: TNode; Forward: Boolean): TAnchoredDfa;
var
  Nfa: TAdfaNfa;
  D: TAdfaDet;
  T: TAdfaTable;
  MatchState, StartState, NStates, Classes, Shift, Stride, K, Id, Cl, C, J, Flag, ToState, NR, NM, NN, NF: Int32;
  ClassOf: array[0..127] of Byte;
  Sample: array of Int32;
  Boundaries, Anchors, Word, AtStart: Boolean;
  StartList, First, Set_, Resolved, Moved, Next, Joined: TIntList;
  Starts: array[0..3] of Int32;
  V: Int32;
  A: TAnchoredDfa;
begin
  Result := nil;
  Nfa := Default(TAdfaNfa);
  MatchState := Nfa.AddTo(AMatch, 0);
  StartState := Nfa.Compile(Root, MatchState);
  if Nfa.Failed then
    Exit;
  D := Default(TAdfaDet);
  D.Init(@Nfa);
  // In the forward automaton a thread of the start joined at the current unit is kept apart from the threads of
  // earlier starts, as its state's number plus the number of states, so that a state whose threads are all of the
  // current start (a start state) is known: no earlier start can still match.
  NStates := Nfa.Count;
  Classes := UnitClasses(ClassOf, Nfa, True);
  Shift := 0;
  while (1 shl Shift) < Classes do
    Inc(Shift);
  Stride := 1 shl Shift;
  SetLength(Sample, Classes);
  for C := 127 downto 0 do
    Sample[ClassOf[C]] := C;
  // The word bit matters only to a pattern with a boundary and the start bit only to one with a start anchor (each
  // may be reached later, behind an end anchor or a boundary still to pass, so the whole pattern is asked).
  Boundaries := False;
  Anchors := False;
  for K := 0 to Nfa.Count - 1 do begin
    if (Nfa.Kind[K] = AWord) or (Nfa.Kind[K] = ANotWord) then
      Boundaries := True;
    if Nfa.Kind[K] = ABol then
      Anchors := True;
  end;
  T := Default(TAdfaTable);
  T.Stride := Stride;
  // State 0 is the dead state, with no threads.
  T.Count := 1;
  SetLength(T.Sets, 16);
  SetLength(T.Words, 16);
  SetLength(T.AtStarts, 16);
  SetLength(T.AtEnd, 16);
  SetLength(T.Trans, Stride);
  SetLength(StartList, 1);
  StartList[0] := StartState;
  for K := 0 to 3 do begin
    Word := (K and 2) <> 0;
    AtStart := (K and 1) <> 0;
    First := nil;
    NF := 0;
    D.Closure(First, NF, StartList, 1, AtStart, False, False, False, False);
    if Forward then
      for J := 0 to NF - 1 do
        Inc(First[J], NStates);
    Starts[K] := T.Intern(D, First, NF, Word and Boundaries, AtStart and Anchors, NStates);
    if Starts[K] < 0 then
      Exit;
  end;
  Resolved := nil;
  Moved := nil;
  Next := nil;
  Joined := nil;
  Id := 1;
  while Id < T.Count do begin
    Set_ := DecodeThreads(T.Sets[Id], NStates);
    Word := T.Words[Id];
    AtStart := T.AtStarts[Id];
    for Cl := 0 to Classes - 1 do begin
      C := Sample[Cl];
      NR := 0;
      D.Closure(Resolved, NR, Set_, Length(Set_), AtStart, False, True, Word, IsWordByte(C));
      Flag := 0;
      for J := 0 to NR - 1 do
        if Nfa.Kind[Resolved[J]] = AMatch then begin
          // A match ends before this unit; only the threads it would have been tried after go on.
          Flag := AdfaMatched;
          NR := J;
          Break;
        end;
      NM := 0;
      for J := 0 to NR - 1 do
        if (Nfa.Kind[Resolved[J]] = ASet) and Nfa.Has(Resolved[J], C) then
          AddInt(Moved, NM, Nfa.Out_[Resolved[J]]);
      NN := 0;
      D.Closure(Next, NN, Moved, NM, False, False, False, False, False);
      if Forward and (Flag = 0) then begin
        NF := 0;
        D.ClosureOn(Joined, NF, StartList, 1, False, False, False, False, False);
        for J := 0 to NF - 1 do
          AddInt(Next, NN, Joined[J] + NStates);
      end;
      ToState := T.Intern(D, Next, NN, IsWordByte(C) and Boundaries, False, NStates);
      if (ToState < 0) or (D.Steps < 0) then
        Exit;
      T.Trans[Id * Stride + Cl] := ToState or Flag;
    end;
    Inc(Id);
  end;
  A := TAnchoredDfa.Create;
  Move(ClassOf[0], A.ClassOf[0], SizeOf(ClassOf));
  A.Shift := Shift;
  SetLength(A.Fast, T.Count * Stride);
  for K := 0 to T.Count * Stride - 1 do begin
    V := T.Trans[K];
    A.Fast[K] := UInt32(V and not AdfaMatched) shl Shift;
    if (V and AdfaMatched) <> 0 then
      A.Fast[K] := A.Fast[K] or FastMatched;
  end;
  A.AtEnd := Copy(T.AtEnd, 0, T.Count);
  for K := 0 to 3 do
    A.Starts[K] := Starts[K];
  A.Context := (Starts[1] <> Starts[0]) or (Starts[2] <> Starts[0]) or (Starts[3] <> Starts[0]);
  if Forward then begin
    SetLength(A.StartLike, T.Count);
    for K := 0 to T.Count - 1 do begin
      A.StartLike[K] := Length(T.Sets[K]) > 0;
      for J := 0 to High(T.Sets[K]) do
        if T.Sets[K][J] < NStates then
          A.StartLike[K] := False;
    end;
  end;
  Result := A;
end;

function BuildAdfa(Root: TNode): TAnchoredDfa;
begin
  Result := BuildAdfaWith(Root, False);
end;

function BuildForwardDfa(Root: TNode): TAnchoredDfa;
begin
  Result := BuildAdfaWith(Root, True);
end;

function BuildReverseDfa(const Prefixes: TNodeLists): TReverseDfa;
var
  B: TAdfaNfa;
  D: TAdfaDet;
  MatchState, Next, Start, K, J, Classes, Shift, Stride, Id, Cl, C, ToState, NM, SetCount: Int32;
  Starts, StartList, Moved, First, NextSet: TIntList;
  ClassOf: array[0..127] of Byte;
  Sample: array of Int32;
  Ids: TIntListMap;
  Sets: array of TIntList;
  Trans: TIntList;
  Accept: array of Boolean;
  R: TReverseDfa;
  I: Int32;
begin
  Result := nil;
  B := Default(TAdfaNfa);
  MatchState := B.AddTo(AMatch, 0);
  SetLength(Starts, Length(Prefixes));
  for K := 0 to High(Prefixes) do begin
    Next := MatchState;
    for J := 0 to High(Prefixes[K]) do
      Next := B.CompileBack(Prefixes[K][J], Next);
    Starts[K] := Next;
  end;
  if B.Failed or (Length(Starts) = 0) then
    Exit;
  Start := Starts[High(Starts)];
  for K := High(Starts) - 1 downto 0 do
    Start := B.Split(Starts[K], Start);
  if B.Failed then
    Exit;
  D := Default(TAdfaDet);
  D.Init(@B);
  Classes := UnitClasses(ClassOf, B, False);
  Shift := 0;
  while (1 shl Shift) < Classes do
    Inc(Shift);
  Stride := 1 shl Shift;
  SetLength(Sample, Classes);
  for C := 127 downto 0 do
    Sample[ClassOf[C]] := C;
  Ids := Default(TIntListMap);
  SetLength(Sets, 16);
  SetCount := 1;
  SetLength(Trans, 2 * Stride);
  SetLength(Accept, 16);
  SetLength(StartList, 1);
  StartList[0] := Start;
  First := D.ReverseClosure(StartList, 1);
  Ids.Add(First, 1);
  Accept[1] := D.HasKind(First, Length(First), AMatch);
  Sets[1] := First;
  SetCount := 2;
  Moved := nil;
  Id := 1;
  while Id < SetCount do begin
    for Cl := 0 to Classes - 1 do begin
      C := Sample[Cl];
      NM := 0;
      for J := 0 to High(Sets[Id]) do begin
        I := Sets[Id][J];
        if (B.Kind[I] = ASet) and B.Has(I, C) then
          AddInt(Moved, NM, B.Out_[I]);
      end;
      NextSet := D.ReverseClosure(Moved, NM);
      ToState := AdfaDead;
      if Length(NextSet) > 0 then begin
        ToState := Ids.Find(NextSet);
        if ToState < 0 then begin
          if SetCount >= AdfaMaxStates then
            Exit;
          ToState := SetCount;
          if SetCount = Length(Sets) then begin
            SetLength(Sets, 2 * SetCount);
            SetLength(Accept, 2 * SetCount);
          end;
          Accept[ToState] := D.HasKind(NextSet, Length(NextSet), AMatch);
          Ids.Add(NextSet, ToState);
          Sets[ToState] := NextSet;
          Inc(SetCount);
          if SetCount * Stride > Length(Trans) then
            SetLength(Trans, 2 * SetCount * Stride);
          for K := (SetCount - 1) * Stride to SetCount * Stride - 1 do
            Trans[K] := 0;
        end;
      end;
      if D.Steps < 0 then
        Exit;
      Trans[Id * Stride + Cl] := ToState;
    end;
    Inc(Id);
  end;
  R := TReverseDfa.Create;
  Move(ClassOf[0], R.ClassOf[0], SizeOf(ClassOf));
  R.Shift := Shift;
  SetLength(R.Fast, SetCount * Stride);
  for K := 0 to SetCount * Stride - 1 do begin
    R.Fast[K] := UInt32(Trans[K]) shl Shift;
    if (Trans[K] <> AdfaDead) and Accept[Trans[K]] then
      R.Fast[K] := R.Fast[K] or FastMatched;
  end;
  R.AcceptFirst := Accept[1];
  Result := R;
end;

{ UnitFrequency is how often a unit is found in text, roughly: what a window's worth is reckoned by. }
function UnitFrequency(C: Int32): Double;
begin
  if C = Ord(' ') then
    Exit(0.15);
  if (C >= Ord('a')) and (C <= Ord('z')) then
    Exit(0.06);
  if (C = 10) or (C = 13) or (C = Ord('.')) or (C = Ord(',')) then
    Exit(0.015);
  if ((C >= Ord('A')) and (C <= Ord('Z'))) or ((C >= Ord('0')) and (C <= Ord('9'))) then
    Exit(0.004);
  Result := 0.003;
end;

{ SkipClosure is the states each depth's threads are at for SkipWindow, assertions taken as passed (they only rule
  threads out); false where a match can end, so that no later position is known. }
function SkipClosure(const Nfa: TAdfaNfa; const From: TIntList; out Sets: TIntList): Boolean;
var
  Seen: array of Boolean;
  Stack: TIntList;
  Sp, NS, I: Int32;
  K: Byte;
begin
  SetLength(Seen, Nfa.Count);
  Stack := Copy(From);
  Sp := Length(Stack);
  Sets := nil;
  NS := 0;
  while Sp > 0 do begin
    Dec(Sp);
    I := Stack[Sp];
    if Seen[I] then
      Continue;
    Seen[I] := True;
    K := Nfa.Kind[I];
    if K = AMatch then
      Exit(False)
    else if K = ASet then
      AddInt(Sets, NS, I)
    else if K = ASplit then begin
      AddInt(Stack, Sp, Nfa.Out_[I]);
      AddInt(Stack, Sp, Nfa.Alt[I]);
    end else
      AddInt(Stack, Sp, Nfa.Out_[I]);
  end;
  SetLength(Sets, NS);
  Result := True;
end;

{ WindowRanges sets the ranges of a window's bytes (TSkipWin.RangeConsts). }
procedure WindowRanges(W: TSkipWin);
var
  Lo, Hi: array[0..128] of Int32;
  N, B, X, K, Best: Int32;
  Pairs: TBytes;
begin
  N := 0;
  B := 0;
  while B < $80 do begin
    if ((W.Table[B shr 6] shr (B and 63)) and 1) <> 0 then begin
      X := B;
      while (B + 1 < $80) and (((W.Table[(B + 1) shr 6] shr ((B + 1) and 63)) and 1) <> 0) do
        Inc(B);
      Lo[N] := X;
      Hi[N] := B;
      Inc(N);
    end;
    Inc(B);
  end;
  if W.Wide then begin
    Lo[N] := $80;
    Hi[N] := $FF;
    Inc(N);
  end;
  if N = 0 then
    Exit;
  while N > 4 do begin
    // The two runs with the least between them become one.
    Best := 0;
    for K := 1 to N - 2 do
      if Lo[K + 1] - Hi[K] < Lo[Best + 1] - Hi[Best] then
        Best := K;
    Hi[Best] := Hi[Best + 1];
    for K := Best + 1 to N - 2 do begin
      Lo[K] := Lo[K + 1];
      Hi[K] := Hi[K + 1];
    end;
    Dec(N);
  end;
  SetLength(Pairs, 2 * N);
  for K := 0 to N - 1 do begin
    Pairs[2 * K] := Lo[K];
    Pairs[2 * K + 1] := Hi[K] - Lo[K];
  end;
  W.NRanges := N;
  VecConsts(Pairs, W.RangeConsts);
end;

function SkipWindow(Root: TNode): TSkipWin;
type
  TTable = array[0..1] of UInt64;
var
  B: TAdfaNfa;
  MatchState, StartState, N, Lo, Hi, BestLo, BestHi, K, J: Int32;
  Tables: array of TTable;
  Wides: array of Boolean;
  Threads, Sets: TIntList;
  Table: TTable;
  Wide: Boolean;
  C: Int32;
  P, Worth, BestWorth: Double;
  W: TSkipWin;
begin
  Result := nil;
  B := Default(TAdfaNfa);
  MatchState := B.AddTo(AMatch, 0);
  StartState := B.Compile(Root, MatchState);
  if B.Failed then
    Exit;
  N := 0;
  SetLength(Tables, SkipPositions);
  SetLength(Wides, SkipPositions);
  SetLength(Threads, 1);
  Threads[0] := StartState;
  while N < SkipPositions do begin
    if not SkipClosure(B, Threads, Sets) then
      Break;
    Table[0] := 0;
    Table[1] := 0;
    Wide := False;
    for K := 0 to High(Sets) do begin
      Table[0] := Table[0] or B.Set0[Sets[K]];
      Table[1] := Table[1] or B.Set1[Sets[K]];
      Wide := Wide or B.Wide[Sets[K]];
    end;
    Tables[N] := Table;
    Wides[N] := Wide;
    Inc(N);
    // A character beyond ASCII takes more than one unit of UTF-8: the positions after it are not known.
    if Wide then
      Break;
    SetLength(Threads, Length(Sets));
    for K := 0 to High(Sets) do
      Threads[K] := B.Out_[Sets[K]];
  end;
  BestWorth := 0;
  BestLo := -1;
  BestHi := -1;
  for Lo := 0 to N - 1 do begin
    Table[0] := 0;
    Table[1] := 0;
    Wide := False;
    for Hi := Lo to N - 1 do begin
      Table[0] := Table[0] or Tables[Hi][0];
      Table[1] := Table[1] or Tables[Hi][1];
      Wide := Wide or Wides[Hi];
      if Wide then
        P := 0.1
      else
        P := 0.0;
      for C := 0 to 127 do
        if ((Table[C shr 6] shr (C and 63)) and 1) <> 0 then
          P := P + UnitFrequency(C);
      if P > 1.0 then
        P := 1.0;
      Worth := (Hi - Lo + 1) * (1.0 - P);
      if (Worth >= 3.0) and ((BestLo < 0) or (Worth > BestWorth)) then begin
        BestWorth := Worth;
        BestLo := Lo;
        BestHi := Hi;
      end;
    end;
  end;
  if BestLo < 0 then
    Exit;
  W := TSkipWin.Create;
  W.Table[0] := 0;
  W.Table[1] := 0;
  W.Wide := False;
  for J := BestLo to BestHi do begin
    W.Table[0] := W.Table[0] or Tables[J][0];
    W.Table[1] := W.Table[1] or Tables[J][1];
    W.Wide := W.Wide or Wides[J];
  end;
  W.Hi := BestHi;
  W.Len := BestHi - BestLo + 1;
  WindowRanges(W);
  Result := W;
end;

end.
