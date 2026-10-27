program TestAllocations;
{$I ../src/ecma262.inc}

(* A match allocates nothing once the working memory has grown to what the pattern and the text need: not a test, not
  a count, and not a global search into a TEcmaCaptures (allocations.rs of the Rust crate, the Java engine's
  AllocationTest, the Go engine's alloc_test.go, the Julia engine's alloc.jl). Each case reaches one of the searches
  for where a match starts.

  The program installs a memory manager that counts the requests for memory (GetMem, AllocMem and ReallocMem) of the
  thread that matches, between the moment that thread starts counting and the moment it stops: the flag that says so
  is a thread variable, so no other thread is counted. *)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Corvus.Ecma262.RegularExpressions;

var
  OldManager, CountingManager: TMemoryManager;
  Requests: Int64;
  Failures: Int32 = 0;
  Checks: Int32 = 0;

threadvar
  { The calling thread is counting. }
  Counting: Boolean;

function CountedGetMem(Size: PtrUInt): Pointer;
begin
  if Counting then
    Inc(Requests);
  Result := OldManager.GetMem(Size);
end;

function CountedAllocMem(Size: PtrUInt): Pointer;
begin
  if Counting then
    Inc(Requests);
  Result := OldManager.AllocMem(Size);
end;

function CountedReallocMem(var P: Pointer; Size: PtrUInt): Pointer;
begin
  if Counting then
    Inc(Requests);
  Result := OldManager.ReallocMem(P, Size);
end;

procedure InstallCountingManager;
begin
  GetMemoryManager(OldManager);
  CountingManager := OldManager;
  CountingManager.GetMem := CountedGetMem;
  CountingManager.AllocMem := CountedAllocMem;
  CountingManager.ReallocMem := CountedReallocMem;
  SetMemoryManager(CountingManager);
end;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Checks);
  if not Ok then begin
    Inc(Failures);
    WriteLn('FAIL: ', What);
  end;
end;

{ Work tests, counts and searches with groups over each text, as a program that matches the same pattern again and
  again does. }
procedure Work(const Re: IEcmaRegex; var C: TEcmaCaptures; const Text8: TUtf8Text; const Text16: UnicodeString;
  const Text: UTF8String);
var
  Index, Len, At: NativeInt;
begin
  if not (Re.IsMatch(Text8) and Re.IsMatch(Text16) and Re.IsMatch(Text)) then
    raise Exception.Create('no match');
  if (Re.Count(Text8) = 0) or (Re.Count(Text16) = 0) then
    raise Exception.Create('no matches');
  At := 1;
  while Re.Exec(Text8, C, At) do begin
    C.Range(0, Index, Len);
    if Len = 0 then
      At := Index + 1
    else
      At := Index + Len;
  end;
  At := 1;
  while Re.Exec(Text16, C, At) do begin
    C.Range(0, Index, Len);
    if Len = 0 then
      At := Index + 1
    else
      At := Index + Len;
  end;
  if not (Re.Exec(Text, C) and Re.Exec(PWideChar(Text16), Length(Text16), C)) then
    raise Exception.Create('no match');
end;

{ LeastRequests is the fewest requests for memory of five runs of the work, after two to warm it. }
function LeastRequests(const Re: IEcmaRegex; var C: TEcmaCaptures; const Text8: TUtf8Text;
  const Text16: UnicodeString; const Text: UTF8String): Int64;
var
  K: Int32;
begin
  Work(Re, C, Text8, Text16, Text);
  Work(Re, C, Text8, Text16, Text);
  Result := High(Int64);
  for K := 1 to 5 do begin
    Requests := 0;
    Counting := True;
    Work(Re, C, Text8, Text16, Text);
    Counting := False;
    if Requests < Result then
      Result := Requests;
  end;
end;

const
  Piece: UTF8String = 'The year 2026, the month 10; Ünïcödé text, 😀 and more letters after it. ';
  Cases: array[0..37] of UTF8String = (
    '\d+', '', '(?<y>\d{4})\D+(\d+)', 'u', 'text|month', 'i', '(?<=the )\w+', 'u', '(t|e)\1', '', '\p{L}+', 'u',
    '[\p{L}--[a-z]]+', 'v', '^.*$', 'm', '\bt\w*\b', 'gi',
    // The searches for where a match starts: a literal, several (packed over UTF-16), the case forms, the windows
    // with the reverse automaton, the search after loops, the forward automaton with the skip window, and the shapes
    // answered without the matcher.
    'letters', '', 'year|month|text|letters', '', 'the', 'i', 'year.{0,25}month|month.{0,25}year', '',
    '\s[a-z]{0,12}ers\s', '', '\w+\s+month', '', '\d\d:?\d\d', '', '.*', 's', '[^\n]*', '', '\p{L}', 'u');

var
  Text: UTF8String;
  Text8: TUtf8Text;
  Text16: UnicodeString;
  K, T: Int32;
  Timeout: Double;
  Re: IEcmaRegex;
  C: TEcmaCaptures;
  Least: Int64;
begin
  Text := '';
  for K := 1 to 20 do
    Text := Text + Piece;
  Text8 := TUtf8Text.Create(Text);
  Text16 := UTF8Decode(RawByteString(Text));
  InstallCountingManager;
  // The counter counts: a match that builds the strings of its groups asks for memory.
  Re := CompileEcmaRegex('(\w+) (\w+)');
  Re.Match(Text8);
  Requests := 0;
  Counting := True;
  Re.Match(Text8);
  Counting := False;
  Check(Requests > 0, 'the counter counts the requests of a match that builds strings');
  K := 0;
  while K < Length(Cases) do begin
    for T := 0 to 1 do begin
      // With no timeout, and with one, whose clock is read as the match goes.
      Timeout := T * 60.0;
      Re := CompileEcmaRegex(Cases[K], string(Cases[K + 1]), Timeout);
      C := Default(TEcmaCaptures);
      Least := LeastRequests(Re, C, Text8, Text16, Text);
      Check(Least = 0, Format('/%s/%s with a timeout of %g s asks for memory %d times', [Cases[K], Cases[K + 1],
        Timeout, Least]));
    end;
    Inc(K, 2);
  end;
  WriteLn(Format('%d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
