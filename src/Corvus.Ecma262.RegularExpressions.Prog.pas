unit Corvus.Ecma262.RegularExpressions.Prog;
{$I ecma262.inc}

{ The compiler: a syntax tree to a program of the backtracking matcher, with what the matcher needs to give up early
  (compile.rs of the Rust crate).

  Instructions are numbered from 0, and a jump names the number of the instruction it goes to. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Adfa,
  Corvus.Ecma262.RegularExpressions.Search;

type
  TOp = (
    { opChar and opSet consume one code point going forward. The Back forms consume the one before the position,
      which is how the body of a lookbehind runs. }
    opChar, opCharBack, opSet, opSetBack,
    { Consumes a run of literal units going forward. }
    opLit,
    opFail, opBol, opEol, opWordBoundary, opNotWordBoundary,
    { ^ and $ with the m modifier. The Fold forms of the word boundaries and of the backreferences belong to a
      case-insensitive group. }
    opLineStart, opLineEnd, opWordBoundaryFold, opNotWordBoundaryFold,
    opJmp,
    { Continues at X and leaves Y as the alternative. }
    opSplit,
    { opSaveTmp notes where a group was entered. opCapture records the group once it has closed. }
    opSaveTmp, opCapture,
    { Resets the groups A to B, as ECMA-262 does at the start of each iteration of a quantified body. }
    opClear,
    opBackref, opBackrefBack, opBackrefFold, opBackrefFoldBack,
    { Compare a group a code unit at a time, for a pattern matched by code unit. }
    opBackrefUnits, opBackrefUnitsBack,
    { opLook opens a lookaround. opLookOk ends the body of a positive one and opLookFail the body of a negative
      one. }
    opLook, opLookOk, opLookFail,
    { Repeat one character or class without entering the general loop. }
    opRep, opRepLazy,
    { Run a counted or possibly empty quantified body. }
    opLoopInit, opLoop, opLoopIter,
    opMatch);

  TWords = array of UInt16;

  { A TInst is one instruction of the backtracking matcher. }
  TInst = record
    Op: TOp;
    { Marks a lazy opLoop, a backward opCapture, a negative opLook, and an opBackrefFold that folds case as the u
      flag grammar does. }
    Flag: Boolean;
    { The character of an opChar or of an opRep of one character, and whether the instruction has a class instead. }
    HasSet: Boolean;
    R: Int32;
    CharSet: TCharSet;
    { The literal run of an opLit, in UTF-8 and in UTF-16. }
    Lit8: TBytes;
    Lit16: TWords;
    { For an opRep, the ASCII bytes (up to three) what follows it can start with, when those are all it can start
      with: its give-back looks for them with a search back (see SetBack). }
    Back: TBytes;
    { Jump targets. }
    X: Int32;
    Y: Int32;
    { A group, a loop or a range of groups, depending on the instruction. }
    A: Int32;
    B: Int32;
    { Bound a repetition. A max of -1 is no bound. }
    Min: Int32;
    Max: Int32;
    { Need8 is the least number of bytes of text that every way from this instruction to a match consumes going
      forward (see SetNeeds). It is set for an opLoop, and counts none of the iterations the loop has still to make.
      Need16 is the same in UTF-16 code units. }
    Need8: Int32;
    Need16: Int32;
    { The least number of bytes one iteration of the body of an opLoop consumes going forward, and of UTF-16 code
      units. }
    Iter8: Int32;
    Iter16: Int32;
    { The number of the instruction's memo point, counted from 1, or 0 when it has none (see TMemoPoint). It is set
      for an opSplit, an opLoop, an opRep and an opRepLazy. }
    M: Int32;
  end;
  PInst = ^TInst;
  TInsts = array of TInst;

const
  { The number of loops whose state a memo point can tell apart. }
  MaxMemoLoops = 2;

type
  { A TMemoPoint is a place where the matcher makes a choice and can remember that the choice has failed: a split, a
    loop that may be entered or left, and what follows a single character loop that gives characters back or takes
    more. Whether a way from such a place leads to a match depends on the place and the position alone when nothing
    else the matcher keeps can change what follows. So a pattern with a backreference has no memo points (what a
    group holds changes what follows), and neither has a place inside a loop that counts its iterations up to a
    bound. Inside a loop with no upper bound and a least count of zero or one, one thing more decides what follows:
    whether the loop would refuse the iteration as empty if it ended here. That is one bit for each such loop the
    place is in (Loops, innermost last, -1 for none), and a place in more than MaxMemoLoops of them has no memo
    point. }
  TMemoPoint = record
    Loops: array[0..MaxMemoLoops - 1] of Int32;
    Mins: array[0..MaxMemoLoops - 1] of Int32;
  end;
  TMemoPoints = array of TMemoPoint;

  { A TQuick is what can come next on a way from an instruction to the end of its match, which is the end of the
    pattern or of the lookaround the instruction is in. The matcher looks at it before it takes a way: when the next
    character of the text is none that the way can start with, and the way cannot end without one, the way fails, so
    it is not taken, and where it was one of two no choice is kept for it. V8 makes the same check ("quick check") at
    its choices. It is what keeps a choice between ways that need different characters from being a choice.

    Ascii0 and Ascii1 are the characters below 128 a way can consume next, and Other says it can consume a character
    that is not ASCII. Mid says a way reaches the end of its match consuming nothing more while text is left, and
    AtEnd that one does at the end of the text. }
  TQuick = record
    Ascii0: UInt64;
    Ascii1: UInt64;
    Other: Boolean;
    Mid: Boolean;
    AtEnd: Boolean;
  end;
  TQuicks = array of TQuick;

  { A TProgram is a pattern compiled for the backtracking matcher. Nothing changes it once it is compiled, so any
    number of threads can match with it. }
  TProgram = class
  public
    Insts: TInsts;
    { The number of groups the program records (every capturing group, or those some backreference names), and the
      number of counted loops. }
    Groups: Int32;
    Loops: Int32;
    { The pattern was read without the u flag, so the text is matched by UTF-16 code unit. }
    Units: Boolean;
    { Every match starts at the start of the text. }
    Anchored: Boolean;
    { The least number of bytes a match consumes (see SetNeeds), and of UTF-16 code units. }
    Need8: Int32;
    Need16: Int32;
    { The memo points of the program (see TMemoPoint). }
    Points: TMemoPoints;
    { For each instruction, which characters can come next on a way from it to the end of its match (see
      SetQuick). }
    Quick: TQuicks;
    { Every code point a match can start with, when HasFirst; a match can be empty, or the set is not known,
      otherwise. }
    HasFirst: Boolean;
    First: TCharSet;
    { How the search finds where a match can start (see the Search unit). }
    Search: TSearchPlan;
    { The anchored automaton that finds where a match from a start ends, for a program that records no group and
      needs no backtracking (see the Adfa unit), or nil. }
    AnchoredDfa: TAnchoredDfa;
    { The tree of a pattern whose search tries every start its first set allows, from which the forward automaton
      (see BuildForwardDfa) is built on the first search that wants it, or nil; and the arena that holds it, which the
      program then owns. FForward is nil until then, and then the automaton or NoForward for none. }
    ForwardRoot: TNode;
    Arena: TNodeArena;
    FForward: Pointer;
    { For the same patterns, the window of positions read one unit at a time before the first set is searched for
      (see TSkipWin), or nil. }
    Skip: TSkipWin;
    { For a pattern every match of which starts with one literal (a window at distance 0 of one literal over UTF-8),
      the anchored automaton's states after it (see After), and its length, when HasAfter: an occurrence goes on from
      there, its units not read again. }
    HasAfter: Boolean;
    AfterLiteral: TStartRows;
    AfterLength: NativeInt;
    destructor Destroy; override;
    { Forward is the forward automaton, built on the first search that wants it, or nil when there is none. }
    function Forward: TAnchoredDfa;
  end;

const
  { The need of an instruction from which no way leads to a match. Every need is capped at it. }
  NoMatch = 1 shl 30;

{ CompileProgram compiles a tree, changing it in place, with the nodes it makes going to the arena. With Groups at 0
  or more the program records every one of that many capturing groups, group g in slot g - 1, so that a match can
  report what each captured; with Groups below 0, only the groups some backreference names. A program whose search
  builds the forward automaton later keeps the tree, and takes the arena (Result.Arena is it): the caller frees the
  arena only when the program has not taken it. }
function CompileProgram(Root: TNode; Unicode: Boolean; Groups: Int32; Arena: TNodeArena): TProgram;

{ Unrolling says whether small counted repetitions are written out. The tests of the loops' needs and memo points turn
  it off, to keep every counted repetition a loop. }
var
  Unrolling: Boolean = True;

implementation

type
  { A TLoopContext is one counted loop that the instruction being written is inside of: its number, its least count,
    and whether its state is one bit to a memo point (no upper bound, and a least count of zero or one). }
  TLoopContext = record
    Loop: Int32;
    Min: Int32;
    Simple: Boolean;
  end;
  TLoopContexts = array of TLoopContext;

  TCompiler = class
  public
    Insts: TInsts;
    Count: Int32;
    { A capturing group's number to its slot (from 0), or -1 for a group that is not recorded. }
    Tracked: TInts;
    TrackedCount: Int32;
    Loops: Int32;
    { The pattern was read with the u flag grammar, which decides how a backreference folds case. }
    Unicode: Boolean;
    { Memo says the pattern has no backreference, so its choices can have memo points. Open lists the counted loops
      around the instruction being written, outermost first, inside the innermost lookaround: what a lookaround's
      body does depends on nothing outside it. Points collects the memo points. }
    Memo: Boolean;
    Open: TLoopContexts;
    OpenCount: Int32;
    Points: TMemoPoints;
    PointCount: Int32;
    Arena: TNodeArena;
    function Add(const I: TInst): Int32;
    function Pc: Int32; inline;
    function Point: Int32;
    procedure GroupRange(N: TNode; var Lo, Hi: Int32; var Found: Boolean);
    procedure Emit(N: TNode; Back: Boolean);
    procedure EmitBody(Body: TNode; Back: Boolean; Lo, Hi: Int32; Clear: Boolean);
    function Split: Int32;
    procedure SetSplit(Lazy: Boolean; At, Enter, Leave: Int32);
    procedure EmitRepeat(N: TNode; Back: Boolean);
  end;

const
  QuickNone: TQuick = (Ascii0: 0; Ascii1: 0; Other: False; Mid: False; AtEnd: False);
  QuickAll: TQuick = (Ascii0: High(UInt64); Ascii1: High(UInt64); Other: True; Mid: True; AtEnd: True);

function NewInst(Op: TOp): TInst;
begin
  Result := Default(TInst);
  Result.Op := Op;
end;

function AddRune(const Q: TQuick; R: Int32): TQuick;
begin
  Result := Q;
  if (R >= 0) and (R < $80) then begin
    if R < 64 then
      Result.Ascii0 := Result.Ascii0 or (UInt64(1) shl R)
    else
      Result.Ascii1 := Result.Ascii1 or (UInt64(1) shl (R - 64));
  end else
    Result.Other := True;
end;

function AddSet(const Q: TQuick; const S: TCharSet): TQuick;
begin
  Result := Q;
  Result.Other := Q.Other or ((Length(S.Ranges) > 0) and (S.Ranges[High(S.Ranges)] >= $80));
  Result.Ascii0 := Q.Ascii0 or S.Ascii[0];
  Result.Ascii1 := Q.Ascii1 or S.Ascii[1];
end;

function QuickUnion(const Q, O: TQuick): TQuick;
begin
  Result.Ascii0 := Q.Ascii0 or O.Ascii0;
  Result.Ascii1 := Q.Ascii1 or O.Ascii1;
  Result.Other := Q.Other or O.Other;
  Result.Mid := Q.Mid or O.Mid;
  Result.AtEnd := Q.AtEnd or O.AtEnd;
end;

function SameQuick(const Q, O: TQuick): Boolean;
begin
  Result := (Q.Ascii0 = O.Ascii0) and (Q.Ascii1 = O.Ascii1) and (Q.Other = O.Other) and (Q.Mid = O.Mid) and
    (Q.AtEnd = O.AtEnd);
end;

{ Consumes reports whether N can match one character or more. It errs towards true. }
function Consumes(N: TNode): Boolean;
var
  K: Int32;
begin
  case N.Kind of
    nkChar, nkSet, nkBackref: Exit(True);
    nkCat, nkAlt, nkGroup: begin
      for K := 0 to High(N.Subs) do
        if Consumes(N.Subs[K]) then
          Exit(True);
      Exit(False);
    end;
    nkRepeat: Exit((N.Max <> 0) and Consumes(N.Subs[0]));
  end;
  Result := False;
end;

{ HasCapture reports whether a node holds a capturing group, a backreference or a lookaround. }
function HasCapture(N: TNode): Boolean;
var
  K: Int32;
begin
  if ((N.Kind = nkGroup) and (N.Group > 0)) or (N.Kind = nkBackref) or (N.Kind = nkLook) then
    Exit(True);
  for K := 0 to High(N.Subs) do
    if HasCapture(N.Subs[K]) then
      Exit(True);
  Result := False;
end;

{ TreeSize is the number of nodes of a tree, counted up to Limit. }
function TreeSize(N: TNode; Limit: Int32): Int32;
var
  K: Int32;
begin
  Result := 1;
  for K := 0 to High(N.Subs) do begin
    Inc(Result, TreeSize(N.Subs[K], Limit));
    if Result > Limit then
      Exit;
  end;
end;

procedure CollectBackrefs(var Out_: TInts; var N_: Int32; N: TNode);
var
  K: Int32;
begin
  if N.Kind = nkBackref then
    for K := 0 to High(N.Groups) do begin
      if N_ = Length(Out_) then
        SetLength(Out_, 2 * N_ + 8);
      Out_[N_] := N.Groups[K];
      Inc(N_);
    end;
  for K := 0 to High(N.Subs) do
    CollectBackrefs(Out_, N_, N.Subs[K]);
end;

(* Unroll writes out a counted repetition (see Simplify): X{2,4} is X X (X (X)?)?, the optional copies one inside the
  other, so that a copy is tried only when the one before it matched. *)
function Unroll(N: TNode; Arena: TNodeArena): TNode;
var
  Body, Optional, Inner: TNode;
  Terms, Flat: TNodes;
  K, T, F, J: Int32;
begin
  Body := N.Subs[0];
  SetLength(Terms, N.Min + 1);
  T := 0;
  for K := 1 to N.Min do begin
    Terms[T] := Arena.Clone(Body);
    Inc(T);
  end;
  if N.Max > N.Min then begin
    Optional := nil;
    for K := N.Min to N.Max - 1 do begin
      Inner := Arena.Clone(Body);
      if Optional <> nil then
        Inner := Arena.WithSubs(nkCat, [Inner, Optional]);
      Optional := Arena.RepeatNode(Inner, 0, 1, N.Lazy);
    end;
    Terms[T] := Optional;
    Inc(T);
  end;
  if T = 1 then
    Exit(Terms[0]);
  Flat := nil;
  F := 0;
  for K := 0 to T - 1 do
    if Terms[K].Kind = nkCat then begin
      SetLength(Flat, F + Length(Terms[K].Subs));
      for J := 0 to High(Terms[K].Subs) do
        Flat[F + J] := Terms[K].Subs[J];
      Inc(F, Length(Terms[K].Subs));
    end else begin
      SetLength(Flat, F + 1);
      Flat[F] := Terms[K];
      Inc(F);
    end;
  Result := Arena.Node(nkCat);
  Result.Subs := Flat;
end;

(* Simplify is the tree with two rewrites, both of which V8 makes. Neither changes what the pattern matches or what
  any group holds. Without them a pattern can take time exponential in its counts for no reason that ECMA-262 gives.

  A backreference to a group it is inside of is the empty string. The group is not set until it closes, and the
  repetition around a group clears it at the start of each iteration, so inside the group it is never set.

  A repetition whose body cannot consume a character, such as (?:\b|(?=a)|){4,5}, is the body once when its minimum
  is one or more, and nothing when its minimum is zero. Every iteration of such a body is empty. ECMA-262 refuses an
  empty iteration after the minimum, so the iterations are exactly the minimum. Each of them starts with the groups
  of the body cleared and at the same position, so what the last one can do does not depend on the ones before it,
  and the ways through the last one come in the same order whatever the others chose. Run as written, the matcher
  would try every combination of the ways through every iteration. *)
function Simplify(N: TNode; var Open: TInts; var OpenCount: Int32; Arena: TNodeArena): TNode;
var
  K, J, F, G: Int32;
  Opened, All, AnyCat: Boolean;
  Flat: TNodes;
begin
  if N.Kind = nkBackref then begin
    All := True;
    for K := 0 to High(N.Groups) do begin
      G := 0;
      for J := 0 to OpenCount - 1 do
        if Open[J] = N.Groups[K] then
          G := 1;
      if G = 0 then
        All := False;
    end;
    if All then
      Exit(Arena.Node(nkEmpty));
    Exit(N);
  end;
  if Length(N.Subs) = 0 then
    Exit(N);
  Opened := (N.Kind = nkGroup) and (N.Group > 0);
  if Opened then begin
    if OpenCount = Length(Open) then
      SetLength(Open, 2 * OpenCount + 8);
    Open[OpenCount] := N.Group;
    Inc(OpenCount);
  end;
  for K := 0 to High(N.Subs) do
    N.Subs[K] := Simplify(N.Subs[K], Open, OpenCount, Arena);
  if Opened then
    Dec(OpenCount);
  if N.Kind = nkCat then begin
    AnyCat := False;
    for K := 0 to High(N.Subs) do
      if N.Subs[K].Kind = nkCat then
        AnyCat := True;
    if AnyCat then begin
      // A sequence inside a sequence (a written-out repetition) is the same sequence: flat, so that what reads the
      // terms (the searches, the first characters) sees them all.
      Flat := nil;
      F := 0;
      for K := 0 to High(N.Subs) do
        if N.Subs[K].Kind = nkCat then begin
          SetLength(Flat, F + Length(N.Subs[K].Subs));
          for J := 0 to High(N.Subs[K].Subs) do
            Flat[F + J] := N.Subs[K].Subs[J];
          Inc(F, Length(N.Subs[K].Subs));
        end else begin
          SetLength(Flat, F + 1);
          Flat[F] := N.Subs[K];
          Inc(F);
        end;
      N.Subs := Flat;
    end;
  end;
  if (N.Kind = nkRepeat) and (N.Max <> 0) and not Consumes(N.Subs[0]) then begin
    if N.Min = 0 then
      Exit(Arena.Node(nkEmpty));
    Exit(N.Subs[0]);
  end;
  if Unrolling and (N.Kind = nkRepeat) and (N.Min = N.Max) and (N.Max >= 2) and (N.Max <= 32) and
    ((N.Subs[0].Kind = nkSet) or (N.Subs[0].Kind = nkChar)) then
    // An exact count of one character or class is that many of it in a row: a straight run of tests without a
    // loop's counting, which pays where a search tries the run at every occurrence of a literal after it
    // ([a-q][^u-z]{13}x). (The .NET reference engine's Simplify.)
    Exit(Unroll(N, Arena));
  if Unrolling and (N.Kind = nkRepeat) and (N.Max >= 1) and (N.Max <= 4) and (N.Min >= 1) and
    not Nullable(N.Subs[0]) and not HasCapture(N.Subs[0]) and (TreeSize(N.Subs[0], 33) <= 32) and
    (N.Subs[0].Kind in [nkGroup, nkAlt, nkCat]) then
    // A small counted repetition of a body that holds no group and cannot be empty is the body written out, with
    // the copies beyond the least count optional one inside the other: the same matches in the same order, without
    // a loop's counting. A body of one character stays a counted loop, which the matcher runs without choices.
    Exit(Unroll(N, Arena));
  Result := N;
end;

{ StartsAtBol reports whether every way through N begins with ^. }
function StartsAtBol(N: TNode): Boolean;
var
  K: Int32;
begin
  case N.Kind of
    nkBol: Exit(True);
    nkCat, nkGroup: Exit(StartsAtBol(N.Subs[0]));
    nkAlt: begin
      for K := 0 to High(N.Subs) do
        if not StartsAtBol(N.Subs[K]) then
          Exit(False);
      Exit(True);
    end;
    nkRepeat: Exit((N.Min >= 1) and StartsAtBol(N.Subs[0]));
  end;
  Result := False;
end;

procedure AppendRanges(var Pairs: TRunes; var N: Int32; const S: TCharSet);
var
  K: Int32;
begin
  if N + Length(S.Ranges) > Length(Pairs) then
    SetLength(Pairs, 2 * (N + Length(S.Ranges)) + 16);
  for K := 0 to High(S.Ranges) do
    Pairs[N + K] := S.Ranges[K];
  Inc(N, Length(S.Ranges));
end;

{ FirstChars appends, as inclusive pairs, the code points a match of N can start with. It returns whether N can match
  the empty string, and reports in Known whether the set is known at all. Assertions are treated as matching the
  empty string, which can only make the set larger than it need be. }
function FirstChars(var Pairs: TRunes; var Np: Int32; N: TNode; out Known: Boolean): Boolean;
var
  K: Int32;
  E, Ok, AnyEmpty: Boolean;
begin
  Known := True;
  case N.Kind of
    nkChar: begin
      if Np + 2 > Length(Pairs) then
        SetLength(Pairs, 2 * Np + 16);
      Pairs[Np] := N.R;
      Pairs[Np + 1] := N.R;
      Inc(Np, 2);
      Exit(False);
    end;
    nkSet: begin
      AppendRanges(Pairs, Np, N.CharSet);
      Exit(False);
    end;
    nkCat: begin
      for K := 0 to High(N.Subs) do begin
        E := FirstChars(Pairs, Np, N.Subs[K], Ok);
        if not Ok then begin
          Known := False;
          Exit(False);
        end;
        if not E then
          Exit(False);
      end;
      Exit(True);
    end;
    nkAlt: begin
      AnyEmpty := False;
      for K := 0 to High(N.Subs) do begin
        E := FirstChars(Pairs, Np, N.Subs[K], Ok);
        if not Ok then begin
          Known := False;
          Exit(False);
        end;
        AnyEmpty := AnyEmpty or E;
      end;
      Exit(AnyEmpty);
    end;
    nkGroup: Exit(FirstChars(Pairs, Np, N.Subs[0], Known));
    nkRepeat: begin
      if N.Max = 0 then
        Exit(True);
      E := FirstChars(Pairs, Np, N.Subs[0], Ok);
      if not Ok then begin
        Known := False;
        Exit(False);
      end;
      Exit(E or (N.Min = 0));
    end;
    nkBackref: begin
      Known := False;
      Exit(False);
    end;
  end;
  Result := True;
end;

{ TimesNeed is Count times Need, capped at NoMatch. }
function TimesNeed(Count, Need: Int32): Int32;
begin
  if (Count = 0) or (Need = 0) then
    Exit(0);
  if (Need >= NoMatch) or (Count >= NoMatch div Need) then
    Exit(NoMatch);
  Result := Count * Need;
end;

{ MinLength is the least number of units a match of N consumes, capped at NoMatch: bytes of UTF-8 with Utf8Set, and
  UTF-16 code units without it. Like the needs, it counts a character as its units when the matcher compares units
  for it and as one unit otherwise, so it can only be too small. }
function MinLength(N: TNode; Utf8Set: Boolean): Int32;
var
  K, Total, Least, L: Int32;
begin
  case N.Kind of
    nkChar: begin
      if not LiteralRune(N.R) then
        Exit(1);
      if Utf8Set then
        Exit(RuneLen(N.R));
      if N.R > $FFFF then
        Exit(2);
      Exit(1);
    end;
    nkSet: begin
      if N.CharSet.Empty then
        Exit(NoMatch);
      Exit(1);
    end;
    nkCat: begin
      Total := 0;
      for K := 0 to High(N.Subs) do begin
        Inc(Total, MinLength(N.Subs[K], Utf8Set));
        if Total >= NoMatch then
          Exit(NoMatch);
      end;
      Exit(Total);
    end;
    nkAlt: begin
      Least := NoMatch;
      for K := 0 to High(N.Subs) do begin
        L := MinLength(N.Subs[K], Utf8Set);
        if L < Least then
          Least := L;
      end;
      Exit(Least);
    end;
    nkGroup: Exit(MinLength(N.Subs[0], Utf8Set));
    nkRepeat: Exit(TimesNeed(N.Min, MinLength(N.Subs[0], Utf8Set)));
  end;
  Result := 0;
end;

function Min2(A, B: Int64): Int64; inline;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

{ NeedsIn works out the needs in one unit (see SetNeeds), writes them into the counted loops, and returns the need of
  the program. }
function NeedsIn(var Insts: TInsts; Utf8Set: Boolean): Int32;
var
  Need: TInts;
  Changed: Boolean;
  Pc, After: Int32;
  N, V: Int64;
  I: PInst;
  Head: PInst;
begin
  SetLength(Need, Length(Insts));
  for Pc := 0 to High(Need) do
    Need[Pc] := NoMatch;
  Changed := True;
  // The needs only fall, and nearly every way goes forward, so going through the instructions from the last to the
  // first settles all but the loops in one pass.
  while Changed do begin
    Changed := False;
    for Pc := High(Insts) downto 0 do begin
      I := @Insts[Pc];
      N := NoMatch;
      After := Pc + 1;
      case I^.Op of
        opMatch, opLookOk, opLookFail: N := 0;
        opFail: ;
        opChar, opSet: N := Min2(N, Int64(Need[After]) + 1);
        opLit:
          if Utf8Set then
            N := Min2(N, Int64(Need[After]) + Length(I^.Lit8))
          else
            N := Min2(N, Int64(Need[After]) + Length(I^.Lit16));
        opRep, opRepLazy: N := Min2(N, Int64(Need[After]) + I^.Min);
        opJmp: begin
          // The one way that goes back is the jump at the end of the body of a loop, to the instruction at its head,
          // which this pass has not reached. The need of that instruction is the need of what follows the loop,
          // since its other way, through the body, comes back to it and cannot need less. So the jump takes what
          // follows the loop, which this pass has settled. Taking the need of the head would settle one loop of a
          // nest for each pass: a thousand passes for loops a thousand deep.
          Head := @Insts[I^.X];
          if (I^.X < Pc) and (Head^.Op = opLoop) then
            N := Min2(N, Need[Head^.X])
          else if (I^.X < Pc) and (Head^.Op = opSplit) then
            N := Min2(N, Min2(Need[Head^.X], Need[Head^.Y]))
          else
            N := Min2(N, Need[I^.X]);
        end;
        opLook: N := Min2(N, Need[I^.X]);
        opSplit: N := Min2(N, Min2(Need[I^.X], Need[I^.Y]));
        opLoop: N := Min2(N, Min2(Need[After], Need[I^.X]));
        opLoopInit: begin
          Head := @Insts[Pc + 1];
          if Utf8Set then
            N := Min2(N, Int64(Need[After]) + TimesNeed(Head^.Min, Head^.Iter8))
          else
            N := Min2(N, Int64(Need[After]) + TimesNeed(Head^.Min, Head^.Iter16));
        end;
      else
        N := Min2(N, Need[After]);
      end;
      V := Min2(N, NoMatch);
      if V < Need[Pc] then begin
        Need[Pc] := Int32(V);
        Changed := True;
      end;
    end;
  end;
  for Pc := 0 to High(Insts) do
    if Insts[Pc].Op = opLoop then begin
      if Utf8Set then
        Insts[Pc].Need8 := Need[Pc]
      else
        Insts[Pc].Need16 := Need[Pc];
    end;
  Result := Need[0];
end;

{ SetNeeds works out, for every instruction, the least number of bytes of text that any way from it to a match
  consumes going forward, and writes it into the counted loops. It returns the need of the whole program. The matcher
  gives up at a counted loop when fewer bytes than that are left, as V8 does at every choice. A loop whose iterations
  can be empty would otherwise try every combination of its ways at a position from which the rest of the pattern
  cannot match at all.

  A counted loop that is entered needs its least count of iterations, each of them the least its body consumes
  (Iter8), and then what follows it. The loop instruction itself is also reached after each iteration, so its own
  need counts only what follows, and the matcher adds the iterations it has still to make.

  A character is counted as one byte, a literal run as its bytes and a single character loop as its minimum, so the
  figure can only be too small. The body of a lookaround ends at its own last instruction and the instruction that
  opens one goes straight to what follows it, so a body is counted by itself. An instruction that matches right to
  left, which is the body of a lookbehind, counts nothing.

  The needs are worked out twice, in bytes of UTF-8 and in UTF-16 code units. }
procedure SetNeeds(var Insts: TInsts; out Need8, Need16: Int32);
begin
  Need16 := NeedsIn(Insts, False);
  Need8 := NeedsIn(Insts, True);
end;

{ SetQuick works out the quick of every instruction. Every figure is a set that can only be too large: an assertion
  is taken to hold, a backreference and an instruction that matches right to left (the body of a lookbehind) to allow
  anything. A positive lookahead needs both its body and what follows it to go on from the same position, so it
  allows what both allow. }
function SetQuick(const Insts: TInsts): TQuicks;
var
  Q: TQuicks;
  Changed: Boolean;
  Pc: Int32;
  I, Head: PInst;
  N, B: TQuick;
begin
  SetLength(Q, Length(Insts));
  for Pc := 0 to High(Q) do
    Q[Pc] := QuickNone;
  Changed := True;
  // The sets only grow, and nearly every way goes forward, so going through the instructions from the last to the
  // first settles all but the loops in one pass.
  while Changed do begin
    Changed := False;
    for Pc := High(Insts) downto 0 do begin
      I := @Insts[Pc];
      N := QuickNone;
      case I^.Op of
        opMatch, opLookOk, opLookFail: N := QuickAll;
        opFail: ;
        opChar: N := AddRune(N, I^.R);
        opSet: N := AddSet(N, I^.CharSet);
        opLit: N := AddRune(N, I^.Lit8[0]);
        opRep, opRepLazy: begin
          if I^.HasSet then
            N := AddSet(N, I^.CharSet)
          else
            N := AddRune(N, I^.R);
          if I^.Min = 0 then
            N := QuickUnion(N, Q[Pc + 1]);
        end;
        opJmp: begin
          // The jump at the end of the body of a loop goes back to the head of the loop, which this pass has not
          // reached. The head allows what follows the loop, which this pass has settled, and what the body starts
          // with. So the jump takes what follows the loop too, and the first pass settles the head of every loop,
          // the second every instruction, and the third finds nothing to change, however deep the loops nest.
          N := Q[I^.X];
          Head := @Insts[I^.X];
          if (I^.X < Pc) and (Head^.Op = opLoop) then
            N := QuickUnion(N, Q[Head^.X])
          else if (I^.X < Pc) and (Head^.Op = opSplit) then
            N := QuickUnion(QuickUnion(N, Q[Head^.X]), Q[Head^.Y]);
        end;
        opSplit: N := QuickUnion(Q[I^.X], Q[I^.Y]);
        opLoop: N := QuickUnion(Q[Pc + 1], Q[I^.X]);
        opEol: begin
          N := QuickNone;
          N.AtEnd := Q[Pc + 1].AtEnd;
        end;
        opLook: begin
          N := Q[I^.X];
          if not I^.Flag then begin
            B := Q[Pc + 1];
            N.Ascii0 := N.Ascii0 and B.Ascii0;
            N.Ascii1 := N.Ascii1 and B.Ascii1;
            N.Other := N.Other and B.Other;
            N.Mid := N.Mid and B.Mid;
            N.AtEnd := N.AtEnd and B.AtEnd;
          end;
        end;
        opCharBack, opSetBack, opBackref, opBackrefBack, opBackrefFold, opBackrefFoldBack, opBackrefUnits,
        opBackrefUnitsBack: N := QuickAll;
      else
        N := Q[Pc + 1];
      end;
      if not SameQuick(N, Q[Pc]) then begin
        Q[Pc] := N;
        Changed := True;
      end;
    end;
  end;
  Result := Q;
end;

{ SetBack gives each greedy single-character loop the ASCII bytes what follows it can start with, when there are one
  to three and nothing else can follow: the vectorised give-back of the .NET reference engine. }
procedure SetBack(var Insts: TInsts; const Q: TQuicks);
var
  Pc, N: Int32;
  C: UInt32;
  Next: TQuick;
  Bytes: array[0..3] of Byte;
  Word_: UInt64;
begin
  for Pc := 0 to High(Insts) do begin
    if (Insts[Pc].Op <> opRep) or (Pc + 1 >= Length(Q)) then
      Continue;
    Next := Q[Pc + 1];
    if Next.Other or Next.Mid then
      Continue;
    FillChar(Bytes, SizeOf(Bytes), 0);
    N := 0;
    for C := 0 to $7F do begin
      if C < 64 then
        Word_ := Next.Ascii0
      else
        Word_ := Next.Ascii1;
      if ((Word_ shr (C and 63)) and 1) <> 0 then begin
        if N < 4 then
          Bytes[N] := C;
        Inc(N);
      end;
    end;
    if (N >= 1) and (N <= 3) then begin
      SetLength(Insts[Pc].Back, N);
      for C := 0 to N - 1 do
        Insts[Pc].Back[C] := Bytes[C];
    end;
  end;
end;

const
  { What FForward holds for a program with no forward automaton. }
  NoForward = Pointer(1);

{ TProgram }

destructor TProgram.Destroy;
begin
  if (FForward <> nil) and (FForward <> NoForward) then
    TAnchoredDfa(FForward).Free;
  Search.Free;
  AnchoredDfa.Free;
  Skip.Free;
  Arena.Free;
  inherited;
end;

function TProgram.Forward: TAnchoredDfa;
var
  Built: Pointer;
begin
  if ForwardRoot = nil then
    Exit(nil);
  Built := FForward;
  if Built = nil then begin
    Built := BuildForwardDfa(ForwardRoot);
    if Built = nil then
      Built := NoForward;
    // Two threads that race both build the automaton, and the one that loses frees its copy.
    if InterlockedCompareExchangePointer(FForward, Built, nil) <> nil then begin
      if Built <> NoForward then
        TAnchoredDfa(Built).Free;
      Built := FForward;
    end;
  end;
  if Built = NoForward then
    Result := nil
  else
    Result := TAnchoredDfa(Built);
end;

{ ShallowerThan reports whether a tree nests fewer than Limit levels. }
function ShallowerThan(N: TNode; Limit: Int32): Boolean;
var
  K: Int32;
begin
  if Limit <= 0 then
    Exit(False);
  for K := 0 to High(N.Subs) do
    if not ShallowerThan(N.Subs[K], Limit - 1) then
      Exit(False);
  Result := True;
end;

{ TCompiler }

function TCompiler.Add(const I: TInst): Int32;
begin
  if Count = Length(Insts) then
    SetLength(Insts, 2 * Count + 16);
  Insts[Count] := I;
  Result := Count;
  Inc(Count);
end;

function TCompiler.Pc: Int32;
begin
  Result := Count;
end;

{ Point is the number of a new memo point for an instruction written here, or 0 when a choice here cannot be
  remembered. }
function TCompiler.Point: Int32;
var
  K: Int32;
  Pt: TMemoPoint;
begin
  if not Memo or (OpenCount > MaxMemoLoops) then
    Exit(0);
  for K := 0 to MaxMemoLoops - 1 do begin
    Pt.Loops[K] := -1;
    Pt.Mins[K] := 0;
  end;
  for K := 0 to OpenCount - 1 do begin
    if not Open[K].Simple then
      Exit(0);
    Pt.Loops[K] := Open[K].Loop;
    Pt.Mins[K] := Open[K].Min;
  end;
  if PointCount = Length(Points) then
    SetLength(Points, 2 * PointCount + 8);
  Points[PointCount] := Pt;
  Inc(PointCount);
  Result := PointCount;
end;

{ GroupRange finds the first and last slot of the tracked groups inside N, and whether it has any. }
procedure TCompiler.GroupRange(N: TNode; var Lo, Hi: Int32; var Found: Boolean);
var
  K, T: Int32;
begin
  if (N.Kind = nkGroup) and (N.Group > 0) and (N.Group < Length(Tracked)) then begin
    T := Tracked[N.Group];
    if T >= 0 then begin
      if not Found then begin
        Lo := T;
        Hi := T;
        Found := True;
      end else begin
        if T < Lo then
          Lo := T;
        if T > Hi then
          Hi := T;
      end;
    end;
  end;
  for K := 0 to High(N.Subs) do
    GroupRange(N.Subs[K], Lo, Hi, Found);
end;

{ Utf8Of is the UTF-8 of code points that LiteralRune allows, and Utf16Of their UTF-16. }
function Utf8Of(const Lit: TRunes; Count: Int32): TBytes;
var
  K, N, R: Int32;
begin
  SetLength(Result, 4 * Count);
  N := 0;
  for K := 0 to Count - 1 do begin
    R := Lit[K];
    if R < $80 then begin
      Result[N] := R;
      Inc(N);
    end else if R < $800 then begin
      Result[N] := $C0 or (R shr 6);
      Result[N + 1] := $80 or (R and $3F);
      Inc(N, 2);
    end else if R < $10000 then begin
      Result[N] := $E0 or (R shr 12);
      Result[N + 1] := $80 or ((R shr 6) and $3F);
      Result[N + 2] := $80 or (R and $3F);
      Inc(N, 3);
    end else begin
      Result[N] := $F0 or (R shr 18);
      Result[N + 1] := $80 or ((R shr 12) and $3F);
      Result[N + 2] := $80 or ((R shr 6) and $3F);
      Result[N + 3] := $80 or (R and $3F);
      Inc(N, 4);
    end;
  end;
  SetLength(Result, N);
end;

function Utf16Of(const Lit: TRunes; Count: Int32): TWords;
var
  K, N, R: Int32;
begin
  SetLength(Result, 2 * Count);
  N := 0;
  for K := 0 to Count - 1 do begin
    R := Lit[K];
    if R > $FFFF then begin
      Result[N] := HighSurrogate(R);
      Result[N + 1] := LowSurrogate(R);
      Inc(N, 2);
    end else begin
      Result[N] := R;
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

{ Emit writes the instructions for N. With Back set the instructions match right to left, as the body of a
  lookbehind must. }
procedure TCompiler.Emit(N: TNode; Back: Boolean);
var
  I: TInst;
  K, J, M, Sp, Look, T, G: Int32;
  Lit: TRunes;
  Jumps: TInts;
  Outer: TLoopContexts;
  OuterCount: Int32;
  Op: TOp;
begin
  case N.Kind of
    nkEmpty: ;
    nkChar: begin
      if Back then
        I := NewInst(opCharBack)
      else
        I := NewInst(opChar);
      I.R := N.R;
      Add(I);
    end;
    nkSet: begin
      if N.CharSet.Empty then
        Add(NewInst(opFail))
      else begin
        if Back then
          I := NewInst(opSetBack)
        else
          I := NewInst(opSet);
        I.CharSet := N.CharSet;
        I.HasSet := True;
        Add(I);
      end;
    end;
    nkCat: begin
      if Back then begin
        for K := High(N.Subs) downto 0 do
          Emit(N.Subs[K], True);
        Exit;
      end;
      K := 0;
      SetLength(Lit, Length(N.Subs));
      while K < Length(N.Subs) do begin
        // A run of literal characters becomes one comparison of units.
        J := K;
        while (J < Length(N.Subs)) and (N.Subs[J].Kind = nkChar) and LiteralRune(N.Subs[J].R) do begin
          Lit[J - K] := N.Subs[J].R;
          Inc(J);
        end;
        if J - K >= 2 then begin
          I := NewInst(opLit);
          I.Lit8 := Utf8Of(Lit, J - K);
          I.Lit16 := Utf16Of(Lit, J - K);
          Add(I);
          K := J;
          Continue;
        end;
        Emit(N.Subs[K], False);
        Inc(K);
      end;
    end;
    nkAlt: begin
      SetLength(Jumps, Length(N.Subs));
      for K := 0 to High(N.Subs) do begin
        if K = High(N.Subs) then begin
          Emit(N.Subs[K], Back);
          Break;
        end;
        M := Point;
        I := NewInst(opSplit);
        I.M := M;
        Sp := Add(I);
        Insts[Sp].X := Pc;
        Emit(N.Subs[K], Back);
        Jumps[K] := Add(NewInst(opJmp));
        Insts[Sp].Y := Pc;
      end;
      for K := 0 to High(N.Subs) - 1 do
        Insts[Jumps[K]].X := Pc;
    end;
    nkGroup: begin
      T := -1;
      if (N.Group <> 0) and (N.Group < Length(Tracked)) then
        T := Tracked[N.Group];
      if T < 0 then begin
        Emit(N.Subs[0], Back);
        Exit;
      end;
      I := NewInst(opSaveTmp);
      I.A := T;
      Add(I);
      Emit(N.Subs[0], Back);
      I := NewInst(opCapture);
      I.A := T;
      I.Flag := Back;
      Add(I);
    end;
    nkBol: Add(NewInst(opBol));
    nkEol: Add(NewInst(opEol));
    nkLineStart: Add(NewInst(opLineStart));
    nkLineEnd: Add(NewInst(opLineEnd));
    nkWordBoundary:
      if N.Fold then
        Add(NewInst(opWordBoundaryFold))
      else
        Add(NewInst(opWordBoundary));
    nkNotWordBoundary:
      if N.Fold then
        Add(NewInst(opNotWordBoundaryFold))
      else
        Add(NewInst(opNotWordBoundary));
    nkBackref: begin
      if N.Fold and Back then
        Op := opBackrefFoldBack
      else if N.Fold then
        Op := opBackrefFold
      else if Back and not Unicode then
        Op := opBackrefUnitsBack
      else if Back then
        Op := opBackrefBack
      else if not Unicode then
        Op := opBackrefUnits
      else
        Op := opBackref;
      // When several groups share the name, at most one has taken part, and the others match the empty string. So
      // matching each in turn matches the one that took part.
      for K := 0 to High(N.Groups) do begin
        G := N.Groups[K];
        I := NewInst(Op);
        I.A := Tracked[G];
        I.Flag := Unicode;
        Add(I);
      end;
    end;
    nkLook: begin
      I := NewInst(opLook);
      I.Flag := N.Negative;
      Look := Add(I);
      // Whether the body matches depends on nothing outside it.
      Outer := Open;
      OuterCount := OpenCount;
      Open := nil;
      OpenCount := 0;
      Emit(N.Subs[0], N.Behind);
      Open := Outer;
      OpenCount := OuterCount;
      if N.Negative then
        Add(NewInst(opLookFail))
      else
        Add(NewInst(opLookOk));
      Insts[Look].X := Pc;
    end;
    nkRepeat: EmitRepeat(N, Back);
  end;
end;

procedure TCompiler.EmitBody(Body: TNode; Back: Boolean; Lo, Hi: Int32; Clear: Boolean);
var
  I: TInst;
begin
  if Clear then begin
    I := NewInst(opClear);
    I.A := Lo;
    I.B := Hi;
    Add(I);
  end;
  Emit(Body, Back);
end;

{ Split is a choice between entering the body and leaving the loop, to be completed by SetSplit. }
function TCompiler.Split: Int32;
var
  I: TInst;
begin
  I := NewInst(opSplit);
  I.M := Point;
  Result := Add(I);
end;

{ SetSplit completes a split in the order the quantifier prefers. }
procedure TCompiler.SetSplit(Lazy: Boolean; At, Enter, Leave: Int32);
begin
  if Lazy then begin
    Insts[At].X := Leave;
    Insts[At].Y := Enter;
  end else begin
    Insts[At].X := Enter;
    Insts[At].Y := Leave;
  end;
end;

procedure TCompiler.EmitRepeat(N: TNode; Back: Boolean);
var
  Body: TNode;
  I: TInst;
  Lo, Hi, At, Enter, K, Loop, PointNo: Int32;
  Clear, Simple: Boolean;
begin
  Body := N.Subs[0];
  if N.Max = 0 then
    Exit;
  if not Back and ((Body.Kind = nkChar) or ((Body.Kind = nkSet) and not Body.CharSet.Empty)) then begin
    if N.Lazy then
      I := NewInst(opRepLazy)
    else
      I := NewInst(opRep);
    I.R := Body.R;
    if Body.Kind = nkSet then begin
      I.CharSet := Body.CharSet;
      I.HasSet := True;
    end;
    I.Min := N.Min;
    I.Max := N.Max;
    I.M := Point;
    Add(I);
    Exit;
  end;
  Lo := 0;
  Hi := 0;
  Clear := False;
  GroupRange(Body, Lo, Hi, Clear);
  // A body that always consumes something needs no check for empty iterations, so the unbounded forms and the
  // optional form are plain choices.
  if not Nullable(Body) then begin
    if (N.Min = 0) and (N.Max = Unbounded) then begin
      At := Split;
      Enter := Pc;
      EmitBody(Body, Back, Lo, Hi, Clear);
      I := NewInst(opJmp);
      I.X := At;
      Add(I);
      SetSplit(N.Lazy, At, Enter, Pc);
      Exit;
    end else if (N.Min = 1) and (N.Max = Unbounded) then begin
      Enter := Pc;
      EmitBody(Body, Back, Lo, Hi, Clear);
      At := Split;
      SetSplit(N.Lazy, At, Enter, Pc);
      Exit;
    end else if (N.Min = 0) and (N.Max = 1) then begin
      At := Split;
      Enter := Pc;
      EmitBody(Body, Back, Lo, Hi, Clear);
      SetSplit(N.Lazy, At, Enter, Pc);
      Exit;
    end;
  end;
  K := Loops;
  Inc(Loops);
  I := NewInst(opLoopInit);
  I.A := K;
  Add(I);
  I := NewInst(opLoop);
  I.A := K;
  I.Min := N.Min;
  I.Max := N.Max;
  I.Flag := N.Lazy;
  if not Back then begin
    I.Iter8 := MinLength(Body, True);
    I.Iter16 := MinLength(Body, False);
  end;
  Simple := (N.Max = Unbounded) and (N.Min <= 1);
  // The loop is left or entered from here, and what follows either depends on the loops around this one.
  PointNo := 0;
  if Simple then
    PointNo := Point;
  I.M := PointNo;
  Loop := Add(I);
  I := NewInst(opLoopIter);
  I.A := K;
  Add(I);
  if OpenCount = Length(Open) then
    SetLength(Open, 2 * OpenCount + 4);
  Open[OpenCount].Loop := K;
  Open[OpenCount].Min := N.Min;
  Open[OpenCount].Simple := Simple;
  Inc(OpenCount);
  EmitBody(Body, Back, Lo, Hi, Clear);
  Dec(OpenCount);
  I := NewInst(opJmp);
  I.X := Loop;
  Add(I);
  Insts[Loop].X := Pc;
end;

function CompileProgram(Root: TNode; Unicode: Boolean; Groups: Int32; Arena: TNodeArena): TProgram;
var
  C: TCompiler;
  Open: TInts;
  OpenCount, NRefs, K, J, Slot, MaxGroup, Np: Int32;
  Referenced: TInts;
  Pairs: TRunes;
  NullableFirst, Known: Boolean;
  Used: array of Boolean;
begin
  Open := nil;
  OpenCount := 0;
  Root := Simplify(Root, Open, OpenCount, Arena);
  Result := TProgram.Create;
  C := TCompiler.Create;
  try
    C.Unicode := Unicode;
    C.Arena := Arena;
    Referenced := nil;
    NRefs := 0;
    CollectBackrefs(Referenced, NRefs, Root);
    // A choice can be remembered to have failed only where what a group holds cannot change what follows.
    C.Memo := NRefs = 0;
    MaxGroup := Groups;
    for K := 0 to NRefs - 1 do
      if Referenced[K] > MaxGroup then
        MaxGroup := Referenced[K];
    SetLength(C.Tracked, MaxGroup + 1);
    for K := 0 to MaxGroup do
      C.Tracked[K] := -1;
    if Groups >= 0 then begin
      for K := 1 to Groups do
        C.Tracked[K] := K - 1;
      C.TrackedCount := Groups;
    end else begin
      // Slots follow group order, so the groups inside any one subtree take a contiguous range of slots.
      SetLength(Used, MaxGroup + 1);
      for K := 0 to NRefs - 1 do
        Used[Referenced[K]] := True;
      Slot := 0;
      for J := 1 to MaxGroup do
        if Used[J] then begin
          C.Tracked[J] := Slot;
          Inc(Slot);
        end;
      C.TrackedCount := Slot;
    end;
    C.Emit(Root, False);
    C.Add(NewInst(opMatch));
    SetLength(C.Insts, C.Count);
    Result.Insts := C.Insts;
    SetNeeds(Result.Insts, Result.Need8, Result.Need16);
    Result.Quick := SetQuick(Result.Insts);
    SetBack(Result.Insts, Result.Quick);
    Result.Anchored := StartsAtBol(Root);
    Result.Groups := C.TrackedCount;
    Result.Loops := C.Loops;
    Result.Units := not Unicode;
    SetLength(C.Points, C.PointCount);
    Result.Points := C.Points;
    Result.HasFirst := False;
    if (Result.Groups = 0) and (NRefs = 0) then
      Result.AnchoredDfa := BuildAdfa(Root);
    if not Result.Anchored then begin
      Pairs := nil;
      Np := 0;
      NullableFirst := FirstChars(Pairs, Np, Root, Known);
      if Known and not NullableFirst then begin
        SetLength(Pairs, Np);
        Result.First := NewCharSet(Pairs);
        Result.HasFirst := True;
      end;
      Result.Search := PlanSearch(Root, NRefs > 0, Result.HasFirst, Result.First, not Unicode, Arena);
      if (Result.Search.Plan = pkWindows) and (Result.Search.Hi = 0) and (Result.AnchoredDfa <> nil) and
        Result.Search.Literals.HasSingle8 then
        if Result.AnchoredDfa.After(Result.Search.Literals.Single8, Result.AfterLiteral) then begin
          Result.HasAfter := True;
          Result.AfterLength := Length(Result.Search.Literals.Single8);
        end;
      if not NoSearch and (NRefs = 0) and ShallowerThan(Root, 64) and (Result.Search.Plan = pkScan) and
        (Result.Search.Shape = shNone) then begin
        Result.ForwardRoot := Root;
        Result.Arena := Arena;
        Result.Skip := SkipWindow(Root);
      end;
    end else
      Result.Search := TSearchPlan.Create;
  finally
    C.Free;
  end;
end;

end.
