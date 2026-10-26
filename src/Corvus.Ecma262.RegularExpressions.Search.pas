unit Corvus.Ecma262.RegularExpressions.Search;
{$I ecma262.inc}

(* Finding where a match can start (section 4.3 of the design of the .NET reference engine), worked out once from the
  syntax tree when a pattern is compiled (search.rs of the Rust crate).

  A search on a long text spends most of its time looking for where to start, so before the matcher runs the program
  applies what it learned at compile time. What is searched for (an "anchor") is a literal, each of whose characters
  may have several forms (a letter's cases under the i flag, or the members of a small class), that every match holds
  at a known number of characters from its start: one number, or a bounded range. A pattern that is an alternation, or
  that holds one after a bounded prefix (.{0,2}(Tom|Sawyer)), has an anchor in each alternative, and all of them are
  searched for at once (the Literals unit). Each occurrence opens the window of starts from which some alternative
  could reach it; the starts are tried in order and never twice (the alternation windows). Where every alternative
  starts with its literal, the matcher runs at the occurrence alone.

  A pattern that starts with loops with no upper bound, then a literal ([a-zA-Z]+ing, \w+\s+Holmes), has the literal
  searched for and the runs of the loops' sets before it walked back to the earliest start, which is the only one
  tried for that occurrence: a later start in the same run can only reach a subset of the places the loops can end
  at. *)

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Syntax,
  Corvus.Ecma262.RegularExpressions.Literals,
  Corvus.Ecma262.RegularExpressions.Adfa;

type
  { How the search finds where a match can start, beyond the first set. pkScan tries every position the first set
    allows. pkWindows: every match holds one of the literals Lo to Hi characters after its start; Rest is the anchored
    automaton of the anchors and the terms after each, run at an occurrence first where a window has more than one
    start: where nothing from the occurrence on can match, its window is not tried. pkAfterLoops: every match is runs
    of the loops' sets, then the literal; Rest is the anchored automaton of the literal and the terms after it, run at
    each occurrence first. }
  TPlanKind = (pkScan, pkWindows, pkAfterLoops);

  { The shape of a pattern whose matches the search finds without running the matcher (the .NET reference engine's
    simple shapes). Only for a pattern with no group. shLiterals is literals and nothing else, an alternation of them
    or one, with every form of each written out: the search's own match, which is the first literal in the pattern's
    order of those that start leftmost. shForms is an alternation of literals each of whose characters has several
    forms: at each occurrence the search finds, the alternatives are compared in order. shSet is one class and
    nothing else: every member is a match. shLoop is one greedy loop of a class with no upper bound and a least count
    of zero or one: a match is the run of members from where it starts. }
  TShape = (shNone, shLiterals, shForms, shSet, shLoop);

  { How the end of a run of a loop's members is found (RunEnd of search.rs). reEach finds it a member at a time.
    reAll: the set holds every character, and the run is the rest of the text. reStops: the set holds every character
    but up to three ASCII ones, found by the searches for bytes. reLine: the set holds every character but the four
    line terminators (the dot): LF and CR are found by the search for bytes, with the lead byte of U+2028 and U+2029,
    which is looked at further where it is found. }
  TRunEndKind = (reEach, reAll, reStops, reLine);

  { A TRestCheck is the anchored automaton of what follows an occurrence (an anchor and the terms after it), run at
    the occurrence before any start is walked back to. A check that seldom rules an occurrence out costs more than it
    saves (an e-mail address's @ is nearly always followed by a domain), so the check keeps count over its first
    trials and is dropped for good when fewer than one in eight of them ruled the occurrence out. The counts change
    only how fast a search is, never what it finds. }
  TRestCheck = class
  public
    Dfa: TAnchoredDfa;
    Checks: Int32;
    Rejects: Int32;
    destructor Destroy; override;
    { Pays reports whether the check is still made. }
    function Pays: Boolean; inline;
    { Count counts a check while it is still on trial: each of the first trials once, whichever threads make them,
      and none after. }
    procedure Count(Out_: Boolean);
  end;

  { A TFirstBytes is a search for any of a few bytes: the searches for one to three bytes, and a table for up to
    sixty-four, which is the set the crate finds with the fingerprint search of one-byte literals. }
  TFirstBytes = record
    Count: Int32;
    A, B, C: Byte;
    Table: array[0..3] of UInt64;
  end;

  TFormsList = array of TRuneLists;

  { A TSearchPlan is what a pattern's search knows of it. Nothing changes it once it is built, but the counts of its
    rest check. }
  TSearchPlan = class
  public
    Plan: TPlanKind;
    Shape: TShape;
    { The literals of the windows and of the search after loops, and the distances of the windows. }
    Literals: TLiterals;
    Lo, Hi: NativeInt;
    { The reverse automaton of the windows' prefixes (see BuildReverseDfa). }
    Reverse: TReverseDfa;
    { The check of what follows an occurrence (see TRestCheck). }
    Rest: TRestCheck;
    { The loops of the search after loops, and their least counts. }
    Sets: TCharSets;
    Mins: TInts;
    { The alternatives of shForms: for each, the forms of each of its characters. }
    Forms: TFormsList;
    { The class of shSet and shLoop, the loop's least count, and how its run ends. }
    ShapeSet: TCharSet;
    ShapeMin: Int32;
    RunEnd: TRunEndKind;
    { The bytes of reStops (the last repeated to three), and the units that end a run over UTF-16, for reStops and
      reLine. }
    Stops: array[0..2] of Byte;
    NStops: Int32;
    Stops16: TUnitSet;
    { The set of a loop every match starts with, when a start that fails may move to the end of the run of its set:
      every start in the rest of the run can only reach a subset of the places the loop can end at. }
    SkipRun: TCharSet;
    HasSkipRun: Boolean;
    { The pattern starts with \b and every character a match can start with is an ASCII word character, so a start
      inside a word fails and the search passes over the rest of the word. }
    LeadingWordBoundary: Boolean;
    { The bytes a match can start with over UTF-8, searched for together when they are few: the first set's ASCII
      members and the lead bytes of its other members. }
    FirstBytes: TFirstBytes;
    HasFirstBytes: Boolean;
    { The code units a match can start with over UTF-16, or nil. }
    FirstUnits: TUnitSet;
    destructor Destroy; override;
  end;

var
  { NoSearch makes every pattern compiled while it is set try every position its first set allows, which the tests
    compare the searches with. }
  NoSearch: Boolean = False;

{ PlanSearch is the search of a tree, after simplify. Backrefs says the pattern has a backreference, which rules out
  what depends on a start reaching a subset of another's places; First is the first set of the program, when
  HasFirst. The nodes it makes go to the arena. }
function PlanSearch(Root: TNode; Backrefs, HasFirst: Boolean; const First: TCharSet; Units: Boolean;
  Arena: TNodeArena): TSearchPlan;

implementation

const
  { The most literals the forms of one anchor are expanded to. }
  MaxForms = 64;
  { The most literals of all the anchors of a pattern. }
  MaxLiterals = 512;
  { The most characters a window of starts may span. }
  MaxWindow = 64;
  { The checks a TRestCheck makes before it decides whether it pays. }
  RestTrials = 64;
  { A bound past every window, so that sums of widths saturate there. }
  Far = Int64(1) shl 40;

type
  { A TAnchor is one literal every match of an alternative holds, Lo to Hi characters after its start. }
  TAnchor = record
    { The forms of each of its characters. }
    Chars: TRuneLists;
    Lo, Hi: Int64;
    { The terms a match goes through before the anchor, and the terms from the anchor on, to the end of the
      pattern. }
    Prefix: TNodes;
    Rest: TNodes;
  end;
  TAnchors = array of TAnchor;

{ TRestCheck }

destructor TRestCheck.Destroy;
begin
  Dfa.Free;
  inherited;
end;

function TRestCheck.Pays: Boolean;
begin
  Result := (Checks < RestTrials) or (Rejects * 8 >= RestTrials);
end;

procedure TRestCheck.Count(Out_: Boolean);
begin
  if (Checks < RestTrials) and (InterLockedIncrement(Checks) <= RestTrials) and Out_ then
    InterLockedIncrement(Rejects);
end;

{ TSearchPlan }

destructor TSearchPlan.Destroy;
begin
  Literals.Free;
  Reverse.Free;
  Rest.Free;
  Stops16.Free;
  FirstUnits.Free;
  inherited;
end;

function Min64(A, B: Int64): Int64; inline;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

function Max64(A, B: Int64): Int64; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function AddFar(A, B: Int64): Int64; inline;
begin
  Result := Min64(A + B, Far);
end;

function MulFar(A, B: Int64): Int64;
begin
  if (A = 0) or (B = 0) then
    Exit(0);
  A := Min64(A, Far);
  B := Min64(B, Far);
  if A >= Far div B then
    Exit(Far);
  Result := A * B;
end;

procedure AddNode(var L: TNodes; N: TNode);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := N;
end;

function SameRunes(const A, B: TRunes): Boolean;
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

{ FirstBytesOf is the search for the bytes a set's members start with, and false when they are none or too many. }
function FirstBytesOf(const S: TCharSet; Units: Boolean; out F: TFirstBytes): Boolean;
const
  SpanLo: array[0..3] of Int32 = (0, $80, $800, $10000);
  SpanHi: array[0..3] of Int32 = ($7F, $7FF, $FFFF, $10FFFF);
  SpanShift: array[0..3] of Int32 = (0, 6, 12, 18);
  SpanLead: array[0..3] of Int32 = (0, $C0, $E0, $F0);
var
  K, Sp, X, Y, B, N: Int32;
  Lo, Hi: Int32;
  List: array[0..255] of Byte;
begin
  F := Default(TFirstBytes);
  FillChar(List, SizeOf(List), 0);
  K := 0;
  while K < Length(S.Ranges) do begin
    Lo := S.Ranges[K];
    Hi := S.Ranges[K + 1];
    // A surrogate without the u flag is half of a character of four bytes, and U+FFFD is also what a byte that is
    // not UTF-8 reads as: neither starts at a byte the set can name.
    if (Units and (Lo <= $DFFF) and (Hi >= $D800)) or ((Lo <= $FFFD) and (Hi >= $FFFD)) then
      Exit(False);
    for Sp := 0 to 3 do begin
      X := Lo;
      if SpanLo[Sp] > X then
        X := SpanLo[Sp];
      Y := Hi;
      if SpanHi[Sp] < Y then
        Y := SpanHi[Sp];
      if X <= Y then
        for B := SpanLead[Sp] or (X shr SpanShift[Sp]) to SpanLead[Sp] or (Y shr SpanShift[Sp]) do
          F.Table[B shr 6] := F.Table[B shr 6] or (UInt64(1) shl (B and 63));
    end;
    Inc(K, 2);
  end;
  N := 0;
  for B := 0 to 255 do
    if ((F.Table[B shr 6] shr (B and 63)) and 1) <> 0 then begin
      List[N] := B;
      Inc(N);
    end;
  if (N = 0) or (N > MaxForms) then
    Exit(False);
  F.Count := N;
  F.A := List[0];
  if N >= 2 then F.B := List[1] else F.B := List[N - 1];
  if N >= 3 then F.C := List[2] else F.C := List[N - 1];
  Result := True;
end;

{ FirstUnitsOf is the test for the code units a match can start with over UTF-16: the first set's units as up to
  eight ranges (a member beyond the BMP as its lead surrogate), where more are merged across the narrowest gaps, the
  ASCII and Latin ones last since those units are common in text. A candidate is then tested against the first set
  itself. }
function FirstUnitsOf(const S: TCharSet): TUnitSet;
type
  TPair = record
    Lo, Hi: Int32;
  end;
var
  Units, Merged: array of TPair;
  K, N, M, Best, J: Int32;
  Lo, Hi, A, B: Int32;
  Cost, BestCost: Int64;
  T: TPair;
  R: TRunes;

  function Lead(Cp: Int32): Int32;
  begin
    Result := $D800 + ((Cp - $10000) shr 10);
  end;

begin
  Result := nil;
  N := 0;
  SetLength(Units, Length(S.Ranges) + 2);
  K := 0;
  while K < Length(S.Ranges) do begin
    Lo := S.Ranges[K];
    Hi := S.Ranges[K + 1];
    if N + 2 > Length(Units) then
      SetLength(Units, 2 * N + 4);
    if Lo <= $FFFF then begin
      Units[N].Lo := Lo;
      if Hi > $FFFF then
        Units[N].Hi := $FFFF
      else
        Units[N].Hi := Hi;
      Inc(N);
    end;
    if Hi > $FFFF then begin
      if Lo < $10000 then
        Units[N].Lo := Lead($10000)
      else
        Units[N].Lo := Lead(Lo);
      Units[N].Hi := Lead(Hi);
      Inc(N);
    end;
    Inc(K, 2);
  end;
  // Sorted, by an insertion sort: the lists are short.
  for K := 1 to N - 1 do begin
    T := Units[K];
    J := K;
    while (J > 0) and ((Units[J - 1].Lo > T.Lo) or ((Units[J - 1].Lo = T.Lo) and (Units[J - 1].Hi > T.Hi))) do begin
      Units[J] := Units[J - 1];
      Dec(J);
    end;
    Units[J] := T;
  end;
  SetLength(Merged, N);
  M := 0;
  for K := 0 to N - 1 do
    if (M > 0) and (Units[K].Lo <= Merged[M - 1].Hi + 1) then begin
      if Units[K].Hi > Merged[M - 1].Hi then
        Merged[M - 1].Hi := Units[K].Hi;
    end else begin
      Merged[M] := Units[K];
      Inc(M);
    end;
  while M > 8 do begin
    // The gap whose units are least likely in text: its width, a thousand times over below U+0300.
    Best := 0;
    BestCost := High(Int64);
    for K := 0 to M - 2 do begin
      A := Merged[K].Hi + 1;
      B := Merged[K + 1].Lo;
      Cost := B - A;
      if A < $300 then
        Cost := Cost * 1000;
      if Cost < BestCost then begin
        BestCost := Cost;
        Best := K;
      end;
    end;
    Merged[Best].Hi := Merged[Best + 1].Hi;
    for K := Best + 1 to M - 2 do
      Merged[K] := Merged[K + 1];
    Dec(M);
  end;
  if M = 0 then
    Exit;
  SetLength(R, 2 * M);
  for K := 0 to M - 1 do begin
    R[2 * K] := Merged[K].Lo;
    R[2 * K + 1] := Merged[K].Hi;
  end;
  Result := TUnitSet.Create(R);
end;

{ FormsOf is the forms of a character the search can look for: a literal code point, or the members of a small class;
  false otherwise. }
function FormsOf(N: TNode; out F: TRunes): Boolean;
var
  K, Lo, Hi, C, Count: Int32;
begin
  F := nil;
  if N.Kind = nkChar then begin
    if not LiteralRune(N.R) then
      Exit(False);
    SetLength(F, 1);
    F[0] := N.R;
    Exit(True);
  end;
  if N.Kind <> nkSet then
    Exit(False);
  Count := 0;
  SetLength(F, 4);
  K := 0;
  while K < Length(N.CharSet.Ranges) do begin
    Lo := N.CharSet.Ranges[K];
    Hi := N.CharSet.Ranges[K + 1];
    if (Hi - Lo >= 4) or (Count + (Hi - Lo + 1) > 4) then
      Exit(False);
    for C := Lo to Hi do begin
      if not LiteralRune(C) then
        Exit(False);
      F[Count] := C;
      Inc(Count);
    end;
    Inc(K, 2);
  end;
  SetLength(F, Count);
  // An empty class has no form to look for.
  Result := Count > 0;
end;

function HasForms(N: TNode): Boolean;
var
  F: TRunes;
begin
  Result := FormsOf(N, F);
end;

{ Terms is the terms of a node in order: a sequence and a group whose body is a sequence are spliced in. }
procedure AddTerms(var Out_: TNodes; N: TNode);
var
  K: Int32;
begin
  if N.Kind = nkCat then begin
    for K := 0 to High(N.Subs) do
      AddTerms(Out_, N.Subs[K]);
  end else if N.Kind = nkGroup then begin
    if N.Subs[0].Kind <> nkAlt then
      AddTerms(Out_, N.Subs[0])
    else
      AddNode(Out_, N);
  end else if N.Kind <> nkEmpty then
    AddNode(Out_, N);
end;

function Terms(N: TNode): TNodes;
begin
  Result := nil;
  AddTerms(Result, N);
end;

{ Width finds the least and the greatest number of characters a node consumes (the greatest -1 for no bound), and
  reports false when it is not known (a backreference). }
function Width(N: TNode; out Lo, Hi: Int64): Boolean;
var
  K: Int32;
  A, B: Int64;
  First: Boolean;
begin
  Lo := 0;
  Hi := 0;
  case N.Kind of
    nkChar, nkSet: begin
      Lo := 1;
      Hi := 1;
      Exit(True);
    end;
    nkCat: begin
      for K := 0 to High(N.Subs) do begin
        if not Width(N.Subs[K], A, B) then
          Exit(False);
        Lo := AddFar(Lo, A);
        if (Hi < 0) or (B < 0) then
          Hi := -1
        else
          Hi := AddFar(Hi, B);
      end;
      Exit(True);
    end;
    nkAlt: begin
      First := True;
      for K := 0 to High(N.Subs) do begin
        if not Width(N.Subs[K], A, B) then
          Exit(False);
        if First then begin
          Lo := A;
          Hi := B;
          First := False;
        end else begin
          Lo := Min64(Lo, A);
          if (Hi < 0) or (B < 0) then
            Hi := -1
          else
            Hi := Max64(Hi, B);
        end;
      end;
      Exit(True);
    end;
    nkGroup: Exit(Width(N.Subs[0], Lo, Hi));
    nkRepeat: begin
      if not Width(N.Subs[0], A, B) then
        Exit(False);
      Lo := MulFar(A, N.Min);
      if (N.Max = Unbounded) and (B = 0) then
        Hi := 0
      else if (N.Max = Unbounded) or (B < 0) then
        Hi := -1
      else
        Hi := MulFar(B, N.Max);
      Exit(True);
    end;
    nkBackref: Exit(False);
  end;
  Result := True;
end;

function SliceNodes(const L: TNodes; From: NativeInt): TNodes;
begin
  Result := Copy(L, From, Length(L) - From);
end;

function JoinNodes(const A, B: TNodes): TNodes;
var
  K: NativeInt;
begin
  SetLength(Result, Length(A) + Length(B));
  for K := 0 to High(A) do
    Result[K] := A[K];
  for K := 0 to High(B) do
    Result[Length(A) + K] := B[K];
end;

{ AnchorsAfter finds the anchors of N, which the terms Before precede and the terms After follow, whose match starts
  Lo to Hi characters after the start of the whole match: the first run of literal characters of each of its
  alternatives. It reports false when some alternative has none at a bounded distance. }
function AnchorsAfter(N: TNode; Lo, Hi: Int64; const Before, After: TNodes; out Found: TAnchors): Boolean;
var
  Ts, Prefix, Following: TNodes;
  K, J, M: NativeInt;
  T, Alt: TNode;
  F: TRunes;
  A: TAnchor;
  More: TAnchors;
  WA, WB: Int64;
begin
  Found := nil;
  F := nil;
  Ts := Terms(N);
  Prefix := Copy(Before);
  K := 0;
  while K < Length(Ts) do begin
    T := Ts[K];
    if HasForms(T) then begin
      A.Rest := JoinNodes(SliceNodes(Ts, K), After);
      A.Chars := nil;
      while (K < Length(Ts)) and FormsOf(Ts[K], F) do begin
        SetLength(A.Chars, Length(A.Chars) + 1);
        A.Chars[High(A.Chars)] := F;
        Inc(K);
      end;
      A.Lo := Lo;
      A.Hi := Hi;
      A.Prefix := Prefix;
      SetLength(Found, 1);
      Found[0] := A;
      Exit(True);
    end;
    Alt := nil;
    if T.Kind = nkAlt then
      Alt := T
    else if (T.Kind = nkGroup) and (T.Subs[0].Kind = nkAlt) then
      Alt := T.Subs[0];
    if Alt <> nil then begin
      Following := JoinNodes(SliceNodes(Ts, K + 1), After);
      for J := 0 to High(Alt.Subs) do begin
        if not AnchorsAfter(Alt.Subs[J], Lo, Hi, Prefix, Following, More) then
          Exit(False);
        for M := 0 to High(More) do begin
          SetLength(Found, Length(Found) + 1);
          Found[High(Found)] := More[M];
        end;
      end;
      Exit(True);
    end;
    if not Width(T, WA, WB) or (WB < 0) then
      Exit(False);
    Lo := AddFar(Lo, WA);
    Hi := AddFar(Hi, WB);
    if Hi > MaxWindow then
      Exit(False);
    AddNode(Prefix, T);
    Inc(K);
  end;
  Result := False;
end;

{ Expand is the literals of an anchor: the forms of its first Count characters written out. }
function Expand(const A: TAnchor; Count: NativeInt): TRuneLists;
var
  Next: TRuneLists;
  C, P, R, N: NativeInt;
begin
  SetLength(Result, 1);
  Result[0] := nil;
  for C := 0 to Count - 1 do begin
    SetLength(Next, Length(Result) * Length(A.Chars[C]));
    N := 0;
    for P := 0 to High(Result) do
      for R := 0 to High(A.Chars[C]) do begin
        Next[N] := Copy(Result[P]);
        SetLength(Next[N], Length(Next[N]) + 1);
        Next[N][High(Next[N])] := A.Chars[C][R];
        Inc(N);
      end;
    Result := Next;
  end;
end;

{ Utf8Cuts is the most bytes of each of an anchor's literals written out over UTF-8: where the anchor was cut short,
  every literal is cut to the bytes of its shortest, so that the forms of a character longer than the others (the
  long s, two bytes beside the one of s) make no more literals than the others. The regex crate's rule. }
function Utf8Cuts(CutShort: Boolean; const Lits: TRuneLists): TIntArray;
var
  Cut, Sum: Int32;
  K, J: NativeInt;
begin
  Cut := High(Int32);
  if CutShort then
    for K := 0 to High(Lits) do begin
      Sum := 0;
      for J := 0 to High(Lits[K]) do
        Inc(Sum, RuneLen(Lits[K][J]));
      if Sum < Cut then
        Cut := Sum;
    end;
  SetLength(Result, Length(Lits));
  for K := 0 to High(Result) do
    Result[K] := Cut;
end;

{ TotalLiterals is the number of literals the anchors make with the first K characters of each written out. }
function TotalLiterals(const As_: TAnchors; K: NativeInt): Int64;
var
  A, C, Top: NativeInt;
  P: Int64;
begin
  Result := 0;
  for A := 0 to High(As_) do begin
    P := 1;
    Top := Length(As_[A].Chars);
    if K < Top then
      Top := K;
    for C := 0 to Top - 1 do
      P := MulFar(P, Length(As_[A].Chars[C]));
    Result := AddFar(Result, P);
  end;
end;

{ LiteralCounts finds how many of each anchor's characters to write out, and whether the anchors were cut short.
  Exact anchors are written out in full. Where a character has several forms (a letter under the i flag), every
  anchor is cut to one length by the rule of the regex crate's literal optimisation (Seq::optimize_by_preference): the
  full literals if they are ten or fewer, else five characters if that makes ten or fewer, else four if that makes
  sixty-four or fewer, else three if sixty-four or fewer, else two if ten or fewer, else one. }
function LiteralCounts(const As_: TAnchors; out CutShort: Boolean): TIntArray;
const
  All = High(Int32);
var
  Exact: Boolean;
  A, C, K: NativeInt;
begin
  Exact := True;
  for A := 0 to High(As_) do
    for C := 0 to High(As_[A].Chars) do
      if Length(As_[A].Chars[C]) <> 1 then
        Exact := False;
  if Exact or (TotalLiterals(As_, All) <= 10) then
    K := All
  else if TotalLiterals(As_, 5) <= 10 then
    K := 5
  else if TotalLiterals(As_, 4) <= MaxForms then
    K := 4
  else if TotalLiterals(As_, 3) <= MaxForms then
    K := 3
  else if TotalLiterals(As_, 2) <= 10 then
    K := 2
  else
    K := 1;
  SetLength(Result, Length(As_));
  for A := 0 to High(As_) do
    if Length(As_[A].Chars) < K then
      Result[A] := Length(As_[A].Chars)
    else
      Result[A] := K;
  CutShort := not Exact and (K <> All);
end;

{ AsciiWordSet reports whether a set holds ASCII word characters alone. }
function AsciiWordSet(HasSet: Boolean; const F: TCharSet): Boolean;
var
  C: UInt32;
begin
  if not HasSet or F.Empty or (F.Ranges[High(F.Ranges)] >= $80) then
    Exit(False);
  for C := 0 to $7F do
    if F.HasAscii(C) and not IsWordByte(C) then
      Exit(False);
  Result := True;
end;

{ Alternatives is the top-level alternatives of a tree: the alternatives of an alternation (in a group or not), or the
  tree. }
function Alternatives(Root: TNode): TNodes;
begin
  if Root.Kind = nkAlt then
    Exit(Root.Subs);
  if (Root.Kind = nkGroup) and (Root.Group = 0) and (Root.Subs[0].Kind = nkAlt) then
    Exit(Root.Subs[0].Subs);
  SetLength(Result, 1);
  Result[0] := Root;
end;

{ HoldsGroup reports whether a node holds a capturing group. }
function HoldsGroup(N: TNode): Boolean;
var
  K: Int32;
begin
  if (N.Kind = nkGroup) and (N.Group > 0) then
    Exit(True);
  for K := 0 to High(N.Subs) do
    if HoldsGroup(N.Subs[K]) then
      Exit(True);
  Result := False;
end;

{ ShapeOfLiterals sets the literal shapes of a tree whose anchors are found: literals and nothing else, exact or with
  forms. }
procedure ShapeOfLiterals(S: TSearchPlan; Root: TNode; const Found: TAnchors; const Counts: TIntArray;
  CutShort: Boolean);
var
  Alts, Ts: TNodes;
  All: TFormsList;
  A, K: NativeInt;
  Literal: Boolean;
begin
  if HoldsGroup(Root) then
    Exit;
  Alts := Alternatives(Root);
  SetLength(All, Length(Alts));
  for A := 0 to High(Alts) do begin
    Ts := Terms(Alts[A]);
    if Length(Ts) = 0 then
      Exit;
    SetLength(All[A], Length(Ts));
    for K := 0 to High(Ts) do
      if not FormsOf(Ts[K], All[A][K]) then
        Exit;
  end;
  // Literals written out in full, every form of each, are the search's own literals, in the pattern's order (an
  // alternative's forms together), so the search's leftmost-first match is the pattern's.
  Literal := not CutShort and (Length(Found) = Length(All));
  A := 0;
  while (A < Length(All)) and Literal do begin
    Literal := (Found[A].Lo = 0) and (Found[A].Hi = 0) and (Counts[A] = Length(All[A]));
    Inc(A);
  end;
  if Literal then
    S.Shape := shLiterals
  else begin
    S.Shape := shForms;
    S.Forms := All;
  end;
end;

{ OpenLoop finds the set of a loop of one character or class with no upper bound, and reports false for any other
  term. }
function OpenLoop(T: TNode; out S: TCharSet): Boolean;
var
  Body: TNode;
begin
  if (T.Kind <> nkRepeat) or (T.Max <> Unbounded) then
    Exit(False);
  Body := T.Subs[0];
  if Body.Kind = nkSet then begin
    S := Body.CharSet;
    Exit(True);
  end;
  if Body.Kind = nkChar then begin
    S := NewCharSet([Body.R, Body.R]);
    Exit(True);
  end;
  Result := False;
end;

{ SetRunEnd sets how the end of a run of the set's members is found. }
procedure SetRunEnd(S: TSearchPlan; const CS: TCharSet);
var
  C: TRunes;
  Stops: array of Byte;
  K, N: NativeInt;
  Lo, Hi, X: Int32;
begin
  C := ComplementSet(CS).Ranges;
  if Length(C) = 0 then begin
    S.RunEnd := reAll;
    Exit;
  end;
  if (Length(C) = 6) and (C[0] = $0A) and (C[1] = $0A) and (C[2] = $0D) and (C[3] = $0D) and (C[4] = $2028) and
    (C[5] = $2029) then begin
    S.RunEnd := reLine;
    S.Stops16 := TUnitSet.Create(Copy(C));
    Exit;
  end;
  Stops := nil;
  K := 0;
  while K < Length(C) do begin
    Lo := C[K];
    Hi := C[K + 1];
    if (Hi >= $80) or (Hi - Lo >= 3) or (Length(Stops) + (Hi - Lo + 1) > 3) then begin
      S.RunEnd := reEach;
      Exit;
    end;
    for X := Lo to Hi do begin
      SetLength(Stops, Length(Stops) + 1);
      Stops[High(Stops)] := X;
    end;
    Inc(K, 2);
  end;
  N := Length(Stops);
  while Length(Stops) < 3 do begin
    SetLength(Stops, Length(Stops) + 1);
    Stops[High(Stops)] := Stops[N - 1];
  end;
  S.RunEnd := reStops;
  S.NStops := N;
  S.Stops[0] := Stops[0];
  S.Stops[1] := Stops[1];
  S.Stops[2] := Stops[2];
  S.Stops16 := TUnitSet.Create(Copy(C));
end;

{ ShapeOfOne sets the class and loop shapes of a tree that is one term. }
procedure ShapeOfOne(S: TSearchPlan; Root: TNode);
var
  Ts: TNodes;
  T: TNode;
  CS: TCharSet;
begin
  if HoldsGroup(Root) then
    Exit;
  CS := Default(TCharSet);
  Ts := Terms(Root);
  if Length(Ts) <> 1 then
    Exit;
  T := Ts[0];
  if (T.Kind = nkSet) and not T.CharSet.Empty then begin
    S.Shape := shSet;
    S.ShapeSet := T.CharSet;
  end else if (T.Kind = nkRepeat) and not T.Lazy and (T.Min <= 1) then
    if OpenLoop(T, CS) and not CS.Empty then begin
      S.Shape := shLoop;
      S.ShapeSet := CS;
      S.ShapeMin := T.Min;
      SetRunEnd(S, CS);
    end;
end;

function PlanSearch(Root: TNode; Backrefs, HasFirst: Boolean; const First: TCharSet; Units: Boolean;
  Arena: TNodeArena): TSearchPlan;
var
  S: TSearchPlan;
  Ts, Rest: TNodes;
  Boundary, CutShort, Longer, Seen, Words, Disjoint, Small, Ok: Boolean;
  Found: TAnchors;
  Lits, Expanded: TRuneLists;
  Cuts, C, Counts: TIntArray;
  Lo, Hi: Int64;
  I, E, L, K, LiteralAt, J: NativeInt;
  Prefixes: TNodeLists;
  Alts: TNodes;
  Dfa: TAnchoredDfa;
  Sets: TCharSets;
  Mins: TInts;
  CS: TCharSet;
  Chars: TRuneLists;
  F: TRunes;
  A: TAnchor;
  One: TAnchors;
begin
  S := TSearchPlan.Create;
  Result := S;
  if NoSearch then
    Exit;
  if HasFirst then begin
    S.HasFirstBytes := FirstBytesOf(First, Units, S.FirstBytes);
    S.FirstUnits := FirstUnitsOf(First);
  end;
  Ts := Terms(Root);
  // A leading \b before characters that are all ASCII word characters.
  Boundary := (Length(Ts) > 0) and (Ts[0].Kind = nkWordBoundary) and not Ts[0].Fold;
  if Boundary and AsciiWordSet(HasFirst, First) then
    S.LeadingWordBoundary := True;
  if AnchorsAfter(Root, 0, 0, nil, nil, Found) then begin
    Lits := nil;
    Cuts := nil;
    Lo := High(Int64);
    Hi := 0;
    Counts := LiteralCounts(Found, CutShort);
    for I := 0 to High(Found) do begin
      Lo := Min64(Lo, Found[I].Lo);
      Hi := Max64(Hi, Found[I].Hi);
      Expanded := Expand(Found[I], Counts[I]);
      C := Utf8Cuts(CutShort, Expanded);
      for E := 0 to High(Expanded) do begin
        Seen := False;
        for L := 0 to High(Lits) do
          if SameRunes(Lits[L], Expanded[E]) then begin
            Seen := True;
            Break;
          end;
        if not Seen then begin
          SetLength(Lits, Length(Lits) + 1);
          Lits[High(Lits)] := Expanded[E];
          SetLength(Cuts, Length(Cuts) + 1);
          Cuts[High(Cuts)] := C[E];
        end;
      end;
    end;
    Ok := (Length(Lits) > 0) and (Length(Lits) <= MaxLiterals);
    for L := 0 to High(Lits) do
      if Length(Lits[L]) = 0 then
        Ok := False;
    if Ok then begin
      ShapeOfLiterals(S, Root, Found, Counts, CutShort);
      S.Literals := TLiterals.Create(Lits, Cuts);
      // Where a window has more than one start, the terms before the anchors are matched backwards from each
      // occurrence, so that only the starts they allow are tried (the reverse search of the regex crate).
      if Hi > 0 then begin
        SetLength(Prefixes, Length(Found));
        Longer := False;
        for I := 0 to High(Found) do begin
          Prefixes[I] := Found[I].Prefix;
          if Length(Found[I].Rest) > Length(Found[I].Chars) then
            Longer := True;
        end;
        S.Reverse := BuildReverseDfa(Prefixes);
        // Where every anchor is the end of its alternative, the occurrence is all the rest there is to check.
        if Longer then begin
          SetLength(Alts, Length(Found));
          for I := 0 to High(Found) do
            Alts[I] := Arena.WithSubs(nkCat, Found[I].Rest);
          Dfa := BuildAdfa(Arena.WithSubs(nkAlt, Alts));
          if Dfa <> nil then begin
            S.Rest := TRestCheck.Create;
            S.Rest.Dfa := Dfa;
          end;
        end;
      end;
      S.Plan := pkWindows;
      S.Lo := Lo;
      S.Hi := Hi;
      Exit;
    end;
  end;
  ShapeOfOne(S, Root);
  if Backrefs then
    Exit;
  // Loops with no upper bound, then a literal.
  if Boundary then
    K := 1
  else
    K := 0;
  Sets := nil;
  Mins := nil;
  while (K < Length(Ts)) and OpenLoop(Ts[K], CS) do begin
    SetLength(Sets, Length(Sets) + 1);
    Sets[High(Sets)] := CS;
    SetLength(Mins, Length(Mins) + 1);
    Mins[High(Mins)] := Ts[K].Min;
    Inc(K);
  end;
  if Length(Sets) = 0 then
    Exit;
  (* \b is allowed when every loop's set is of word characters (a later start of the runs can be in any loop's run,
    where \b holds after a word character before a member that is not one: \b\d*\s*a over " a"), and the sets must
    share no character, any two of them. *)
  Words := True;
  for I := 0 to High(Sets) do
    if not AsciiWordSet(True, Sets[I]) then
      Words := False;
  Disjoint := True;
  for I := 0 to High(Sets) do
    for J := I + 1 to High(Sets) do
      if not IntersectSets(Sets[I], Sets[J]).Empty then
        Disjoint := False;
  Small := True;
  for I := 0 to High(Mins) do
    if Mins[I] > 1 then
      Small := False;
  Chars := nil;
  F := nil;
  LiteralAt := K;
  while (K < Length(Ts)) and FormsOf(Ts[K], F) do begin
    SetLength(Chars, Length(Chars) + 1);
    Chars[High(Chars)] := F;
    Inc(K);
  end;
  if (not Boundary or Words) and Disjoint and Small and (Length(Chars) > 0) then begin
    A.Chars := Chars;
    A.Lo := 0;
    A.Hi := 0;
    A.Prefix := nil;
    A.Rest := nil;
    SetLength(One, 1);
    One[0] := A;
    Counts := LiteralCounts(One, CutShort);
    Lits := Expand(A, Counts[0]);
    Rest := SliceNodes(Ts, LiteralAt);
    S.Plan := pkAfterLoops;
    S.Literals := TLiterals.Create(Lits, Utf8Cuts(CutShort, Lits));
    S.Sets := Sets;
    S.Mins := Mins;
    if Length(Rest) > Length(A.Chars) then begin
      Dfa := BuildAdfa(Arena.WithSubs(nkCat, Rest));
      if Dfa <> nil then begin
        S.Rest := TRestCheck.Create;
        S.Rest.Dfa := Dfa;
      end;
    end;
  end;
  // A failed start may skip the rest of its leading loop's run (the loop is the first term).
  if not Boundary then begin
    S.SkipRun := Sets[0];
    S.HasSkipRun := True;
  end;
end;

end.
