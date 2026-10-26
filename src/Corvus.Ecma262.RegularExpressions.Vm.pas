unit Corvus.Ecma262.RegularExpressions.Vm;
{$I ecma262.inc}

{ The backtracking matcher (vm.rs of the Rust crate): its working memory, its limits and the memory of failed places.
  The matcher itself is in Corvus.Ecma262.RegularExpressions.Matcher.inc, compiled once for each encoding.

  The working memory of a match belongs to the thread: it is one thread variable, shared by every program the thread
  runs, and it grows to the largest size any of them has needed. A match never runs inside another on one thread, so
  one is enough. That keeps a match free of allocation in the steady state with no lock and no atomic operation, and
  it keeps a compiled pattern a value that any number of threads can read. The cost is that neither Free Pascal nor
  Delphi frees a thread variable of a managed type when its thread ends, so a thread that has matched and is about to
  end should call ReleaseEcmaRegexThreadState. A thread that does not leaks the memory its matches grew, which is
  kept below a few hundred kilobytes (see MaxRetainedStack and MaxRetainedMemo). }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.Prog,
  Corvus.Ecma262.RegularExpressions.Errors;

const
  { The number of steps the matcher takes between two looks at the clock and at the depth of its stack. A step is one
    instruction, and eight characters of a single character loop or of a backreference. A step takes a few
    nanoseconds, so the clock is read every ten to twenty microseconds, a match that ends before its first check
    never reads it, and a match goes past its limit by that much at most. }
  CheckEvery = 1 shl 12;

  (* The number of entries the backtracking stack of a match with a limit may hold. A match that needs more is
    abandoned. A pattern that keeps a choice for every character of its text needs one entry or a few for each, so
    this is room for a text of some hundred thousand characters, and a pattern that pushes without consuming, such as
    (?:a?){2147483647}, reaches it in a few milliseconds. It is looked at with the clock, so the stack can go past it
    by CheckEvery entries. *)
  MaxStack = 1 shl 20;

  { Why a match was abandoned. }
  StopNone = 0;
  StopTime = 1;
  StopMemory = 2;

  { The kinds of entry on the backtracking stack. A choice entry says where to resume. An undo entry restores a value
    that was overwritten after the entries below it were pushed. }

  { Resumes at Pc with the position Pos. }
  EChoice = 0;
  { Belongs to a greedy single character loop that stopped at Pos. Resuming gives back one character, down to the
    position A. }
  ERep = 1;
  { Belongs to a lazy single character loop that has taken A characters and stands at Pos. Resuming takes one
    more. }
  ERepLazy = 2;
  { ELook marks the start of a positive lookaround and ELookNeg of a negative one. Both hold the position to restore,
    and ELookNeg the instruction to continue at when its body has failed. }
  ELook = 3;
  ELookNeg = 4;
  { Lies under the choices of a memo point. When it is reached, every way from the point has failed, and the bit Pos
    of the memory is set (see Memo in TState). }
  EMark = 5;
  { Restores the entry position of group Pc to Pos. }
  ETmp = 6;
  { Restores the start and end of group Pc to Pos and A. }
  ECap = 7;
  { Restores the count and the iteration start of loop Pc to Pos and A. }
  ECounter = 8;

  { The value of a group that has not taken part, and of the start of an iteration that has not started. }
  None = -1;

  { The largest memory of failed places, in words of 64 bits: 8 MB. A match that would need more goes without it. }
  MaxMemoWords = 1 shl 20;
  { The number of steps for each position of the text that a match makes before it takes the memory into use. }
  MemoStepsPerPosition = 64;
  { The largest memory kept between matches. }
  MaxRetainedMemo = 1 shl 16;
  { The depth of the backtracking stack beyond which a memo point is not marked. A mark is an entry of the stack, and
    a pattern that keeps no choice for a character still marks a place for each, so on a long text the marks alone
    would reach MaxStack. A place that is not marked is not remembered, which loses time and nothing else, and the
    places below this depth are remembered when the stack unwinds, so a later start has the room to mark the next
    ones. }
  MaxMarkDepth = MaxStack div 2;
  { The largest stack kept between matches. }
  MaxRetainedStack = 1 shl 16;

type
  TEntry = record
    Kind: UInt8;
    Pc: Int32;
    Pos: NativeInt;
    A: NativeInt;
  end;
  TEntries = array of TEntry;
  TPositions = array of NativeInt;
  TUInt64s = array of UInt64;

  TGroupList = array of Int32;

  { A TGroupNameUnits is the name of one or more groups, in each encoding, and the groups. }
  TGroupNameUnits = record
    Name8: RawByteString;
    Name16: UnicodeString;
    Groups: TGroupList;
  end;

  { A TSearch is what a search of a compiled pattern needs: the program that records no group but those its
    backreferences name, the program that records every group (the same one when those are all), the number of
    groups, the grammar (Unicode is the u or v flag, which decides how a search moves by characters), the sticky
    flag, the match timeout in nanoseconds (0 for none) and the names of the groups. }
  TSearch = record
    Prog: TProgram;
    Caps: TProgram;
    Groups: Int32;
    Unicode: Boolean;
    Sticky: Boolean;
    Limit: Int64;
    Names: array of TGroupNameUnits;
  end;

  { A TSpan is the bounds of a piece of a text, (-1, -1) for a group that did not take part. }
  TSpan = record
    From: NativeInt;
    To_: NativeInt;
  end;
  TSpans = array of TSpan;

  { A TState is the working memory of one match. Groups, temporaries and counters are indexed from 0: slot k of the
    program is Caps[2k] and Caps[2k+1]. }
  TState = record
    Stack: TEntries;
    Sp: NativeInt;
    { The start and end of each tracked group, or None, and the position at which each was entered. }
    Caps: TPositions;
    Tmp: TPositions;
    { For each loop, the number of iterations started and the position at which the last one started. }
    Counts: TPositions;
    { Where the match that was found ends. }
    EndPos: NativeInt;
    { The time the match may take in nanoseconds, or 0 for no limit. The clock starts at the first check, so Deadline
      is set then, in milliseconds of the monotonic clock. }
    Limit: Int64;
    Deadline: UInt64;
    { The number of steps left before the next check, and why the match was abandoned. }
    Steps: NativeInt;
    Stop: UInt8;
    { The memory of the places where a way has failed: one bit for each memo point of the program, each position of
      the text and each state of the loops around the point (see TMemoPoint). A bit is set when every way from the
      place has failed, and a way that comes to a place whose bit is set fails at once. So no place is gone through
      twice, and a pattern of repetitions inside repetitions takes time proportional to its size times the text and
      not time that doubles with each character.

      The memory costs its size to clear, and a mark on the stack for each place gone through, so a match starts
      without it. It takes it at the check by which it has made as many steps as the memory has words and
      MemoStepsPerPosition more for each position of the text, which a match that goes through its text once or a
      few times never makes. A place whose way failed before then is not remembered, which loses time and nothing
      else. MemoOn says the memory is in use, MemoOff that it never will be (the program has no memo points, or the
      memory would be larger than MaxMemoWords), and Width is the number of positions of the text. }
    Memo: TUInt64s;
    MemoOn: Boolean;
    MemoOff: Boolean;
    Width: NativeInt;
    Checks: NativeInt;
    PointCount: NativeInt;
    { The stack has grown past MaxRetainedStack in this match (seen at a check), so it is not kept. }
    Big: Boolean;
  end;
  PState = ^TState;

var
  { MemoFromTheStart makes every match take its memory of failed places before its first step, so that every
    pattern is run with the memory in use. The environment variable CORVUS_REGEX_MEMO_FROM_THE_START=1 sets it when
    the unit is initialised, which CI does for a second run of the tests and of the test data. }
  MemoFromTheStart: Boolean = False;

{ ThreadState is the working memory of the calling thread's matches. }
function ThreadState: PState;

{ ReleaseEcmaRegexThreadState frees the working memory the calling thread's matches have used. }
procedure ReleaseEcmaRegexThreadState;

{ ResetState readies the state for a match of the program over a text of Len units, with a limit in nanoseconds or
  0. }
procedure ResetState(var St: TState; Prog: TProgram; Len: NativeInt; Limit: Int64);

{ ReleaseState gives up a stack or a memory too large to keep between matches. }
procedure ReleaseState(var St: TState);

{ CheckState is called every CheckEvery steps. It reports whether the match may go on. }
function CheckState(var St: TState): Boolean;

{ GrowStack makes room for at least one more entry. }
procedure GrowStack(var St: TState);

{ Undo applies one undo entry. }
procedure Undo(var St: TState; const E: TEntry); inline;

{ MemoIndex is the bit of the memory for the memo point M at a position, with the state of the loops around the
  point: for each, whether it would refuse an iteration that ended here as empty. }
function MemoIndex(Prog: TProgram; const St: TState; M: Int32; Pos: NativeInt): NativeInt; inline;
function MemoHas(const St: TState; Idx: NativeInt): Boolean; inline;
procedure MemoSet(var St: TState; Idx: NativeInt); inline;

{ RaiseStop raises the error of a match abandoned for the reason, if it was. }
procedure RaiseStop(Stop: UInt8; Limit: Int64);

{ RaiseRange raises the ERangeError of a read outside the text. }
procedure RaiseRange;

implementation

threadvar
  State: TState;

function ThreadState: PState;
begin
  Result := @State;
end;

procedure ReleaseEcmaRegexThreadState;
var
  St: PState;
begin
  St := @State;
  St^.Stack := nil;
  St^.Caps := nil;
  St^.Tmp := nil;
  St^.Counts := nil;
  St^.Memo := nil;
  St^.Sp := 0;
end;

procedure RaiseRange;
begin
  raise ERangeError.Create('Range check error');
end;

procedure GrowStack(var St: TState);
begin
  SetLength(St.Stack, 2 * Length(St.Stack) + 64);
end;

{ Remember takes the memory of failed places into use when the match has made enough steps to pay for it. }
procedure Remember(var St: TState);
var
  Words: Int64;
  K: NativeInt;
begin
  Words := ((Int64(St.PointCount) * St.Width shl MaxMemoLoops) + 63) shr 6;
  if Words > MaxMemoWords then begin
    St.MemoOff := True;
    Exit;
  end;
  if (Int64(St.Checks) * CheckEvery < Words + Int64(MemoStepsPerPosition) * St.Width) and not MemoFromTheStart then
    Exit;
  if Length(St.Memo) < Words then
    SetLength(St.Memo, Words);
  for K := 0 to Words - 1 do
    St.Memo[K] := 0;
  St.MemoOn := True;
end;

function CheckState(var St: TState): Boolean;
var
  Now: UInt64;
begin
  if not St.MemoOn and not St.MemoOff then begin
    Inc(St.Checks);
    Remember(St);
  end;
  if St.Sp > MaxRetainedStack then
    St.Big := True;
  if St.Limit <= 0 then
    Exit(True);
  if St.Sp > MaxStack then begin
    St.Stop := StopMemory;
    Exit(False);
  end;
  Now := GetTickCount64;
  if St.Deadline = 0 then
    St.Deadline := Now + UInt64((St.Limit + 999999) div 1000000)
  else if Now > St.Deadline then begin
    St.Stop := StopTime;
    Exit(False);
  end;
  Result := True;
end;

procedure Undo(var St: TState; const E: TEntry);
var
  K: NativeInt;
begin
  K := E.Pc;
  case E.Kind of
    ETmp: St.Tmp[K] := E.Pos;
    ECap: begin
      St.Caps[2 * K] := E.Pos;
      St.Caps[2 * K + 1] := E.A;
    end;
    ECounter: begin
      St.Counts[2 * K] := E.Pos;
      St.Counts[2 * K + 1] := E.A;
    end;
  end;
end;

procedure ResetState(var St: TState; Prog: TProgram; Len: NativeInt; Limit: Int64);
var
  K: NativeInt;
begin
  if Length(St.Caps) < 2 * Prog.Groups then
    SetLength(St.Caps, 2 * Prog.Groups);
  for K := 0 to 2 * Prog.Groups - 1 do
    St.Caps[K] := None;
  if Length(St.Tmp) < Prog.Groups then
    SetLength(St.Tmp, Prog.Groups);
  for K := 0 to Prog.Groups - 1 do
    St.Tmp[K] := 0;
  if Length(St.Counts) < 2 * Prog.Loops then
    SetLength(St.Counts, 2 * Prog.Loops);
  for K := 0 to 2 * Prog.Loops - 1 do
    St.Counts[K] := 0;
  if Limit < 0 then
    Limit := 0;
  St.Limit := Limit;
  St.Deadline := 0;
  St.Steps := CheckEvery;
  St.Stop := StopNone;
  St.Sp := 0;
  St.MemoOn := False;
  St.MemoOff := Length(Prog.Points) = 0;
  St.Checks := 0;
  St.Width := Len + 1;
  St.PointCount := Length(Prog.Points);
  St.Big := False;
  if not St.MemoOff and MemoFromTheStart then
    Remember(St);
end;

procedure ReleaseState(var St: TState);
begin
  if St.Big or (Length(St.Stack) > MaxRetainedStack) then begin
    St.Stack := nil;
    St.Big := False;
  end;
  if Length(St.Memo) > MaxRetainedMemo then
    St.Memo := nil;
  St.Sp := 0;
end;

function MemoIndex(Prog: TProgram; const St: TState; M: Int32; Pos: NativeInt): NativeInt;
var
  Pt: ^TMemoPoint;
  K, L: NativeInt;
begin
  Pt := @Prog.Points[M - 1];
  Result := ((NativeInt(M) - 1) * St.Width + Pos) shl MaxMemoLoops;
  for K := 0 to MaxMemoLoops - 1 do begin
    L := Pt^.Loops[K];
    if (L >= 0) and (St.Counts[2 * L] > Pt^.Mins[K]) and (St.Counts[2 * L + 1] = Pos) then
      Result := Result or (NativeInt(1) shl K);
  end;
end;

function MemoHas(const St: TState; Idx: NativeInt): Boolean;
begin
  Result := ((St.Memo[Idx shr 6] shr (Idx and 63)) and 1) <> 0;
end;

procedure MemoSet(var St: TState; Idx: NativeInt);
begin
  St.Memo[Idx shr 6] := St.Memo[Idx shr 6] or (UInt64(1) shl (Idx and 63));
end;

procedure RaiseStop(Stop: UInt8; Limit: Int64);
begin
  if Stop = StopTime then
    raise EEcmaRegexTimeout.Create(Limit / 1E9);
  if Stop = StopMemory then
    raise EEcmaRegexMemory.Create('the match needed more backtracking memory than its limit');
end;

initialization
  MemoFromTheStart := GetEnvironmentVariable('CORVUS_REGEX_MEMO_FROM_THE_START') = '1';
end.
