program industry;
{$I ../../src/ecma262.inc}

(* The Industry benchmark: each workload counted by each engine, as the V8 harness of the .NET reference engine
  (tools/benchmarks/v8/industry.mjs) counts it, in nanoseconds per count. A port of the Rust crate's
  tools/src/bin/industry.rs (by way of the Go and Julia engines' harnesses), with the same protocol.

    industry <workloads.json> [--engines corvus-utf8,corvus-utf16,tregexpr,tregexpr-unicode,v8] [--v8 <industry.mjs>]
             [--rounds 3] [--seconds 0.7] [--passes 7] [--spread 0.05] [--filter <substring of the id>]
             [--ids <file>] [--out <results.json>]

  The protocol is interleaved, so that what changes on the host over a run (its clock, its heat, its other work) falls
  on every engine alike: the workloads are the outer loop, each workload's rounds next and the engines innermost, their
  order turned by one each round. Each figure is a child process of its own (this program, or Node for V8), so that
  one engine's caches and heap do not reach another's figures; it warms for two fifths of its seconds, then times
  passes passes of as many counts as fit the rest and reports their median. A workload's figure for an engine is the
  median of its rounds, with the fastest and the slowest round as its spread. Where the spread, (slowest - fastest) /
  median, is over --spread, the figure is listed in the run's facts and on stderr. A figure that does not finish in
  30 s is stopped and recorded as giving no result within 30 s, and is not run in the workload's later rounds. A count
  is the global search of ECMA-262: after an empty match the search goes on one character later.

  The engines: this library over UTF-8 (a TUtf8Text, checked once before the timing) and over UTF-16 (a
  UnicodeString), with the workload's flags and u, counted by Count (corvus-utf8, corvus-utf16); TRegExpr, the engine
  Free Pascal ships, in its two builds: the RegExpr unit over the bytes of the UTF-8 text (tregexpr) and the uRegExpr
  unit over its UTF-16 (tregexpr-unicode), each given the pattern as it is and the flags i, m and s, counted by Exec
  and ExecNext, whose figure is an error where the pattern does not compile; and V8 (--v8, the harness run by node),
  with gu added.

  An engine may name another checkout of this repository as engine@<directory> (corvus-utf8@/tmp/base), which runs
  that engine's figures with that checkout's built harness (<directory>/bin/industry), so that two versions of the
  library are timed side by side in one interleaved run.

  The texts are those of the reference run, in CORVUS_REGEX_TEXTS (or ~/.local/share/corvus-regex-benchmarks) and
  fetched from dotnet/performance when missing. The run unzips each once into a directory of its own
  (CORVUS_REGEX_PLAIN), which the children read. *)

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Unix, {$ENDIF}
  {$IFDEF LINUX}Linux,{$ENDIF}
  Classes, SysUtils, DateUtils, Process, Math,
  RegExpr,
  uRegExpr,
  Corvus.Ecma262.RegularExpressions;

const
  Source = 'https://raw.githubusercontent.com/dotnet/performance/main/src/benchmarks/micro/libraries/' +
    'System.Text.RegularExpressions/TestData/';
  DefaultEngines = 'corvus-utf8,corvus-utf16,tregexpr,tregexpr-unicode';
  { A figure stopped at the limit, which the page shows as giving no result within 30 s. }
  Stopped = '{"error":"did not produce a result within 30 s","limit":30}';

type
  TWorkload = record
    Name, Pattern, Flags, FileName, Id: UTF8String;
    HasV8Count: Boolean;
    V8Count: Int64;
  end;
  TWorkloads = array of TWorkload;

  { A TFigures is one figure's times, in nanoseconds per count, its count and the counts timed. }
  TFigures = record
    Median, Min, Max: Double;
    Count: Int64;
    Reps: Int64;
  end;

  { A TCounter counts the matches of one workload over its text. }
  TCounter = function: Int64 of object;

  TEngineRun = class
  public
    Re: IEcmaRegex;
    Text8: TUtf8Text;
    Text16: UnicodeString;
    TR: RegExpr.TRegExpr;
    TRText: AnsiString;
    UR: uRegExpr.TRegExpr;
    URText: UnicodeString;
    function Count8: Int64;
    function Count16: Int64;
    function CountTR: Int64;
    function CountUR: Int64;
  end;

var
  { What the counts are summed into, so that no count is taken away as dead code. }
  Sink: Int64 = 0;
  Invariant: TFormatSettings;

procedure Fail(const Msg: string);
begin
  WriteLn(StdErr, 'industry: ', Msg);
  Halt(2);
end;

{ The clock, in nanoseconds. }
function NowNs: UInt64;
{$IFDEF LINUX}
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := UInt64(T.tv_sec) * 1000000000 + UInt64(T.tv_nsec);
end;
{$ELSE}
begin
  Result := GetTickCount64 * 1000000;
end;
{$ENDIF}

{ A small JSON reader, for the workloads and the children's lines. }

type
  TJKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);
  TJ = class
  public
    Kind: TJKind;
    B: Boolean;
    N: Double;
    S: UTF8String;
    Items: array of TJ;
    Keys: array of UTF8String;
    destructor Destroy; override;
    function Get(const Name: UTF8String): TJ;
  end;

destructor TJ.Destroy;
var
  K: Integer;
begin
  for K := 0 to High(Items) do
    Items[K].Free;
  inherited;
end;

function TJ.Get(const Name: UTF8String): TJ;
var
  K: Integer;
begin
  if (Self = nil) or (Kind <> jkObject) then
    Exit(nil);
  for K := 0 to High(Keys) do
    if Keys[K] = Name then
      Exit(Items[K]);
  Result := nil;
end;

procedure JSpace(const S: RawByteString; var I: Integer);
begin
  while (I <= Length(S)) and (S[I] in [' ', #9, #10, #13]) do
    Inc(I);
end;

function CodePointUtf8(C: UInt32): RawByteString;
begin
  if C < $80 then
    Result := AnsiChar(C)
  else if C < $800 then
    Result := AnsiChar($C0 or (C shr 6)) + AnsiChar($80 or (C and $3F))
  else if C < $10000 then
    Result := AnsiChar($E0 or (C shr 12)) + AnsiChar($80 or ((C shr 6) and $3F)) + AnsiChar($80 or (C and $3F))
  else
    Result := AnsiChar($F0 or (C shr 18)) + AnsiChar($80 or ((C shr 12) and $3F)) +
      AnsiChar($80 or ((C shr 6) and $3F)) + AnsiChar($80 or (C and $3F));
end;

function JString(const S: RawByteString; var I: Integer): UTF8String;
var
  R: RawByteString;
  E: AnsiChar;
  U, Low: UInt32;
begin
  Inc(I);
  R := '';
  while S[I] <> '"' do begin
    if S[I] = '\' then begin
      E := S[I + 1];
      Inc(I, 2);
      case E of
        'n': R := R + #10;
        't': R := R + #9;
        'r': R := R + #13;
        'b': R := R + #8;
        'f': R := R + #12;
        'u': begin
          U := StrToInt('$' + string(Copy(S, I, 4)));
          Inc(I, 4);
          if (U >= $D800) and (U <= $DBFF) and (S[I] = '\') and (S[I + 1] = 'u') then begin
            Low := StrToInt('$' + string(Copy(S, I + 2, 4)));
            if (Low >= $DC00) and (Low <= $DFFF) then begin
              Inc(I, 6);
              U := $10000 + ((U - $D800) shl 10) + (Low - $DC00);
            end;
          end;
          if (U >= $D800) and (U <= $DFFF) then
            U := $FFFD;
          R := R + CodePointUtf8(U);
        end;
      else
        R := R + E;
      end;
    end else begin
      R := R + S[I];
      Inc(I);
    end;
  end;
  Inc(I);
  Result := R;
end;

function JValue(const S: RawByteString; var I: Integer): TJ;
var
  Start, K: Integer;
begin
  JSpace(S, I);
  Result := TJ.Create;
  case S[I] of
    '{': begin
      Result.Kind := jkObject;
      Inc(I);
      JSpace(S, I);
      if S[I] = '}' then begin
        Inc(I);
        Exit;
      end;
      while True do begin
        JSpace(S, I);
        K := Length(Result.Keys);
        SetLength(Result.Keys, K + 1);
        SetLength(Result.Items, K + 1);
        Result.Keys[K] := JString(S, I);
        JSpace(S, I);
        Inc(I);
        Result.Items[K] := JValue(S, I);
        JSpace(S, I);
        if S[I] = ',' then begin
          Inc(I);
          Continue;
        end;
        Inc(I);
        Exit;
      end;
    end;
    '[': begin
      Result.Kind := jkArray;
      Inc(I);
      JSpace(S, I);
      if S[I] = ']' then begin
        Inc(I);
        Exit;
      end;
      while True do begin
        K := Length(Result.Items);
        SetLength(Result.Items, K + 1);
        Result.Items[K] := JValue(S, I);
        JSpace(S, I);
        if S[I] = ',' then begin
          Inc(I);
          Continue;
        end;
        Inc(I);
        Exit;
      end;
    end;
    '"': begin
      Result.Kind := jkString;
      Result.S := JString(S, I);
    end;
    't': begin
      Result.Kind := jkBool;
      Result.B := True;
      Inc(I, 4);
    end;
    'f': begin
      Result.Kind := jkBool;
      Inc(I, 5);
    end;
    'n': begin
      Result.Kind := jkNull;
      Inc(I, 4);
    end;
  else
    Start := I;
    while (I <= Length(S)) and (S[I] in ['+', '-', '0'..'9', '.', 'e', 'E']) do
      Inc(I);
    Result.Kind := jkNumber;
    Result.N := StrToFloat(string(Copy(S, Start, I - Start)), Invariant);
  end;
end;

function ParseJson(const S: RawByteString): TJ;
var
  I: Integer;
begin
  I := 1;
  Result := JValue(S, I);
end;

function JsonString(const S: UTF8String): UTF8String;
var
  K: Integer;
  C: AnsiChar;
begin
  Result := '"';
  for K := 1 to Length(S) do begin
    C := S[K];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
    else
      if Ord(C) < $20 then
        Result := Result + UTF8String(Format('\u%.4x', [Ord(C)]))
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

function ReadFileText(const Path: string): RawByteString;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure WriteFileText(const Path: string; const S: RawByteString);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(S) > 0 then
      F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
end;

function LoadWorkloads(const Path: string): TWorkloads;
var
  J, W: TJ;
  K: Integer;
begin
  J := ParseJson(ReadFileText(Path));
  try
    SetLength(Result, Length(J.Items));
    for K := 0 to High(J.Items) do begin
      W := J.Items[K];
      Result[K].Name := W.Get('name').S;
      Result[K].Pattern := W.Get('pattern').S;
      Result[K].Flags := W.Get('flags').S;
      Result[K].FileName := W.Get('file').S;
      Result[K].Id := W.Get('id').S;
      Result[K].HasV8Count := (W.Get('v8Count') <> nil) and (W.Get('v8Count').Kind = jkNumber);
      if Result[K].HasV8Count then
        Result[K].V8Count := Round(W.Get('v8Count').N);
    end;
  finally
    J.Free;
  end;
end;

function TextDir: string;
begin
  Result := GetEnvironmentVariable('CORVUS_REGEX_TEXTS');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetUserDir) + '.local/share/corvus-regex-benchmarks';
end;

function RunTool(const Exe: string; const Args: array of string): Boolean;
var
  P: TProcess;
  K: Integer;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for K := 0 to High(Args) do
      P.Parameters.Add(Args[K]);
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
  end;
end;

function Plain(const FileName: UTF8String): string;
begin
  Result := string(FileName);
  if ExtractFileExt(Result) = '.gz' then
    Result := ChangeFileExt(Result, '');
end;

{ TextOf is the bytes of a text: gunzipped, without a byte order mark (as unzipped in CORVUS_REGEX_PLAIN). }
function TextOf(const FileName: UTF8String): RawByteString;
var
  Dir, P, Path, Tmp: string;
begin
  Dir := GetEnvironmentVariable('CORVUS_REGEX_PLAIN');
  if Dir <> '' then begin
    P := IncludeTrailingPathDelimiter(Dir) + Plain(FileName);
    if FileExists(P) then
      Exit(ReadFileText(P));
  end;
  Path := IncludeTrailingPathDelimiter(TextDir) + string(FileName);
  if not FileExists(Path) then begin
    ForceDirectories(TextDir);
    if not RunTool('curl', ['-sSfL', '-o', Path, Source + string(FileName)]) then
      Fail('could not fetch ' + string(FileName));
  end;
  Tmp := GetTempFileName;
  if not RunTool('sh', ['-c', 'gzip -dc "' + Path + '" > "' + Tmp + '"']) then
    Fail('could not unzip ' + Path);
  Result := ReadFileText(Tmp);
  DeleteFile(Tmp);
  if (Length(Result) >= 3) and (Result[1] = #$EF) and (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

{ FlagsU is the workload's flags with u added, unless it has u or v. }
function FlagsU(const Flags: UTF8String): string;
begin
  if (Pos('u', Flags) > 0) or (Pos('v', Flags) > 0) then
    Result := string(Flags)
  else
    Result := string(Flags) + 'u';
end;

{ TEngineRun }

function TEngineRun.Count8: Int64;
begin
  Result := Re.Count(Text8);
end;

function TEngineRun.Count16: Int64;
begin
  Result := Re.Count(Text16);
end;

function TEngineRun.CountTR: Int64;
begin
  Result := 0;
  if TR.Exec(TRText) then
    repeat
      Inc(Result);
    until not TR.ExecNext;
end;

function TEngineRun.CountUR: Int64;
begin
  Result := 0;
  if UR.Exec(URText) then
    repeat
      Inc(Result);
    until not UR.ExecNext;
end;

{ Measure times a count: it warms, then times the passes. }
function Measure(Seconds: Double; Passes: Integer; Count: TCounter): TFigures;
var
  Expected, Reps, PerPass, S, R: Int64;
  WarmEnd, T0: UInt64;
  Times: array of Double;
  P, A, B: Integer;
  X: Double;
begin
  Expected := Count();
  WarmEnd := NowNs + UInt64(Round(Seconds * 0.4E9));
  Reps := 0;
  while NowNs < WarmEnd do begin
    if Count() <> Expected then
      raise Exception.Create('the count changed');
    Inc(Reps);
  end;
  PerPass := Max(1, Round(Reps * 0.6 / Passes));
  SetLength(Times, Passes);
  for P := 0 to Passes - 1 do begin
    T0 := NowNs;
    S := 0;
    for R := 1 to PerPass do
      Inc(S, Count());
    Times[P] := (NowNs - T0) / PerPass;
    Inc(Sink, S);
  end;
  for A := 1 to Passes - 1 do begin
    X := Times[A];
    B := A;
    while (B > 0) and (Times[B - 1] > X) do begin
      Times[B] := Times[B - 1];
      Dec(B);
    end;
    Times[B] := X;
  end;
  Result.Median := Times[Passes div 2];
  Result.Min := Times[0];
  Result.Max := Times[Passes - 1];
  Result.Count := Expected;
  Result.Reps := PerPass * Passes;
end;

{ One runs one workload on one engine in this process and prints its figures as one line of JSON. }
procedure One(const Path: string; Index: Integer; const Engine: string; Seconds: Double; Passes: Integer);
var
  Ws: TWorkloads;
  W: TWorkload;
  B: RawByteString;
  E: TEngineRun;
  F: TFigures;
  Msg: string;
begin
  Ws := LoadWorkloads(Path);
  W := Ws[Index];
  B := TextOf(W.FileName);
  E := TEngineRun.Create;
  try
    try
      if Engine = 'corvus-utf8' then begin
        E.Text8 := TUtf8Text.Create(B);
        E.Re := CompileEcmaRegex(W.Pattern, FlagsU(W.Flags));
        F := Measure(Seconds, Passes, E.Count8);
      end else if Engine = 'corvus-utf16' then begin
        E.Text16 := UTF8Decode(B);
        E.Re := CompileEcmaRegex(W.Pattern, FlagsU(W.Flags));
        F := Measure(Seconds, Passes, E.Count16);
      end else if Engine = 'tregexpr' then begin
        E.TRText := B;
        E.TR := RegExpr.TRegExpr.Create;
        E.TR.ModifierI := Pos('i', W.Flags) > 0;
        E.TR.ModifierM := Pos('m', W.Flags) > 0;
        E.TR.ModifierS := Pos('s', W.Flags) > 0;
        E.TR.Expression := RegExpr.RegExprString(W.Pattern);
        E.TR.Compile;
        F := Measure(Seconds, Passes, E.CountTR);
      end else if Engine = 'tregexpr-unicode' then begin
        E.URText := UTF8Decode(B);
        E.UR := uRegExpr.TRegExpr.Create;
        E.UR.ModifierI := Pos('i', W.Flags) > 0;
        E.UR.ModifierM := Pos('m', W.Flags) > 0;
        E.UR.ModifierS := Pos('s', W.Flags) > 0;
        E.UR.Expression := UTF8Decode(W.Pattern);
        E.UR.Compile;
        F := Measure(Seconds, Passes, E.CountUR);
      end else
        raise Exception.Create('unknown engine ' + Engine);
    except
      on X: Exception do begin
        Msg := X.Message;
        if Pos(#10, Msg) > 0 then
          Msg := Copy(Msg, 1, Pos(#10, Msg) - 1);
        WriteLn('{"error":', JsonString(UTF8String(Msg)), '}');
        Exit;
      end;
    end;
  finally
    E.TR.Free;
    E.UR.Free;
    E.Free;
  end;
  WriteLn(Format('{"median":%.1f,"min":%.1f,"max":%.1f,"count":%d,"reps":%d}', [F.Median, F.Min, F.Max, F.Count,
    F.Reps], Invariant));
end;

{ Figure runs Engine over workload Index in a child process, and returns its line of JSON, or one with the error. }
function Figure(const V8, Path: string; Index: Integer; const Engine: string; const Seconds, Passes: string): string;
var
  P: TProcess;
  Name, Checkout: string;
  Out_: TStringStream;
  Buf: array[0..4095] of Byte;
  N: LongInt;
  Started: QWord;
  WasStopped: Boolean;
  Line: string;
  At: Integer;

  procedure Drain;
  begin
    while P.Output.NumBytesAvailable > 0 do begin
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        Out_.WriteBuffer(Buf, N);
    end;
    while P.Stderr.NumBytesAvailable > 0 do begin
      N := P.Stderr.Read(Buf, SizeOf(Buf));
      if N > 0 then
        FileWrite(StdErrorHandle, Buf, N);
    end;
  end;

begin
  P := TProcess.Create(nil);
  Out_ := TStringStream.Create('');
  try
    if Engine = 'v8' then begin
      P.Executable := 'node';
      P.Parameters.Add(V8);
      P.Parameters.Add('--one');
      P.Parameters.Add(Path);
      P.Parameters.Add(IntToStr(Index));
    end else begin
      At := Pos('@', Engine);
      if At > 0 then begin
        // Another checkout of this repository, whose built harness runs the figure.
        Name := Copy(Engine, 1, At - 1);
        Checkout := Copy(Engine, At + 1, MaxInt);
        P.Executable := IncludeTrailingPathDelimiter(Checkout) + 'bin' + PathDelim + 'industry';
      end else begin
        Name := Engine;
        P.Executable := ParamStr(0);
      end;
      P.Parameters.Add('--one');
      P.Parameters.Add(Path);
      P.Parameters.Add(IntToStr(Index));
      P.Parameters.Add(Name);
    end;
    P.Parameters.Add(Seconds);
    P.Parameters.Add(Passes);
    P.Options := [poUsePipes];
    P.Execute;
    P.CloseInput;
    // The watchdog stays until the child has ended: a child that gave its line ends by itself, and one that runs
    // past the limit is killed outright.
    Started := GetTickCount64;
    WasStopped := False;
    while P.Running do begin
      Drain;
      if GetTickCount64 - Started > 30000 then begin
        WasStopped := True;
        P.Terminate(9);
        Break;
      end;
      Sleep(5);
    end;
    P.WaitOnExit;
    Drain;
    if WasStopped then
      Exit(Stopped);
    Line := Out_.DataString;
    if Pos(#10, Line) > 0 then
      Line := Copy(Line, 1, Pos(#10, Line) - 1);
    Line := Trim(Line);
    if Line = '' then
      Exit('{"error":"the process ended without figures"}');
    Result := Line;
  finally
    Out_.Free;
    P.Free;
  end;
end;

function FirstLine(const Exe: string; const Args: array of string): string;
var
  Output: string;
begin
  if RunCommand(Exe, Args, Output, [poStderrToOutPut]) then begin
    if Pos(#10, Output) > 0 then
      Output := Copy(Output, 1, Pos(#10, Output) - 1);
    Result := Trim(Output);
  end else
    Result := '';
end;

function Field(const FileName, Prefix: string): string;
var
  L: TStringList;
  K: Integer;
begin
  Result := '';
  if not FileExists(FileName) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    for K := 0 to L.Count - 1 do
      if Copy(L[K], 1, Length(Prefix)) = Prefix then
        Exit(Trim(Copy(L[K], Pos(':', L[K]) + 1, MaxInt)));
  finally
    L.Free;
  end;
end;

function Iso8601Now: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', LocalTimeToUniversal(Now));
end;

{ Facts is what the run is: the host, the runtime, the affinity, the load and the commit, read from the run. }
function Facts(const Seconds, Passes: string; const Extra: array of string): UTF8String;
var
  Load, Commit: string;
  F: TStringList;
  K: Integer;
begin
  // A file of /proc says it is empty, so it is read a line at a time.
  Load := '';
  if FileExists('/proc/loadavg') then begin
    F := TStringList.Create;
    try
      F.LoadFromFile('/proc/loadavg');
      if F.Count > 0 then
        Load := Trim(F[0]);
    finally
      F.Free;
    end;
    if Pos(' ', Load) > 0 then
      Load := Copy(Load, 1, Pos(' ', Load) - 1);
  end;
  Commit := GetEnvironmentVariable('CORVUS_COMMIT');
  if Commit = '' then
    Commit := FirstLine('git', ['rev-parse', 'HEAD']);
  F := TStringList.Create;
  try
    F.Add('cpu=' + Field('/proc/cpuinfo', 'model name'));
    F.Add('cores=' + FirstLine('nproc', ['--all']));
    F.Add('affinity=' + Field('/proc/self/status', 'Cpus_allowed_list'));
    F.Add('os=' + FirstLine('uname', ['-sr']));
    F.Add('load=' + Load);
    F.Add('fpc=Free Pascal ' + {$I %FPCVERSION%} + ' ' + {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
    F.Add('commit=' + Commit);
    F.Add('date=' + Iso8601Now);
    F.Add('seconds=' + Seconds);
    F.Add('passes=' + Passes);
    // On a GitHub-hosted runner, what the runner says it is.
    F.Add('runner=' + GetEnvironmentVariable('RUNNER_NAME'));
    F.Add('runner_os=' + GetEnvironmentVariable('RUNNER_OS'));
    F.Add('image=' + Trim(GetEnvironmentVariable('ImageOS') + ' ' + GetEnvironmentVariable('ImageVersion')));
    F.Add('corvus-regex-ecma262=' + EcmaRegexVersion);
    F.Add(Format('tregexpr=TRegExpr %d.%d (Free Pascal %s)', [RegExpr.TRegExpr.VersionMajor,
      RegExpr.TRegExpr.VersionMinor, {$I %FPCVERSION%}]));
    for K := 0 to High(Extra) do
      F.Add(Extra[K]);
    Result := '{';
    for K := 0 to F.Count - 1 do begin
      if K > 0 then
        Result := Result + ',';
      Result := Result + JsonString(UTF8String(F.Names[K])) + ':' + JsonString(UTF8String(F.ValueFromIndex[K]));
    end;
    Result := Result + '}';
  finally
    F.Free;
  end;
end;

function CountOf(const Line: string; out Count: Int64): Boolean;
var
  J, C: TJ;
begin
  Result := False;
  Count := 0;
  try
    J := ParseJson(RawByteString(Line));
  except
    Exit;
  end;
  try
    C := J.Get('count');
    if (C <> nil) and (C.Kind = jkNumber) then begin
      Count := Round(C.N);
      Result := True;
    end;
  finally
    J.Free;
  end;
end;

function MedianOf(const Sorted: array of Double): Double;
var
  N: Integer;
begin
  N := Length(Sorted);
  if Odd(N) then
    Result := Sorted[N div 2]
  else
    Result := (Sorted[N div 2 - 1] + Sorted[N div 2]) / 2;
end;

procedure Main;
var
  Path, V8, EnginesText, SecondsText, PassesText, Filter, IdsFile, OutFile, Dir, P, Line, Entry: string;
  Opt: TStringList;
  Engines, Ids, Over, Differ, Results, Rows: TStringList;
  Rounds, K, E, R, Turn, Done, NE, I: Integer;
  Limit: Double;
  Ws: TWorkloads;
  Chosen: array of Integer;
  Times: array of array of array of Double;
  Lines: array of array of string;
  Names: TStringList;
  J, M: TJ;
  Sorted: array of Double;
  Med, Lo, Hi, Spread: Double;
  Count, Oracle: Int64;
  HasOracle: Boolean;
  V8E: Integer;
  Each, OutText: UTF8String;
begin
  if (ParamCount > 0) and (ParamStr(1) = '--one') then begin
    One(ParamStr(2), StrToInt(ParamStr(3)), ParamStr(4), StrToFloat(ParamStr(5), Invariant), StrToInt(ParamStr(6)));
    Exit;
  end;
  if ParamCount = 0 then
    Fail('usage: industry <workloads.json> [--engines ...] [--v8 <industry.mjs>] [--out <file>]');
  Path := ParamStr(1);
  Opt := TStringList.Create;
  K := 2;
  while K < ParamCount do begin
    Opt.Values[ParamStr(K)] := ParamStr(K + 1);
    Inc(K, 2);
  end;
  V8 := Opt.Values['--v8'];
  EnginesText := Opt.Values['--engines'];
  if EnginesText = '' then begin
    EnginesText := DefaultEngines;
    if V8 <> '' then
      EnginesText := EnginesText + ',v8';
  end;
  Engines := TStringList.Create;
  Engines.StrictDelimiter := True;
  Engines.CommaText := EnginesText;
  if (Engines.IndexOf('v8') >= 0) and (V8 = '') then
    Fail('V8 is run by the V8 harness: give --v8 <industry.mjs>');
  Rounds := StrToIntDef(Opt.Values['--rounds'], 3);
  SecondsText := Opt.Values['--seconds'];
  if SecondsText = '' then
    SecondsText := '0.7';
  PassesText := Opt.Values['--passes'];
  if PassesText = '' then
    PassesText := '7';
  if Opt.Values['--spread'] = '' then
    Limit := 0.05
  else
    Limit := StrToFloat(Opt.Values['--spread'], Invariant);
  Filter := Opt.Values['--filter'];
  IdsFile := Opt.Values['--ids'];
  OutFile := Opt.Values['--out'];
  // One id a line: the ids hold spaces.
  Ids := nil;
  if IdsFile <> '' then begin
    Ids := TStringList.Create;
    Ids.LoadFromFile(IdsFile);
    for K := Ids.Count - 1 downto 0 do
      if Trim(Ids[K]) = '' then
        Ids.Delete(K)
      else
        Ids[K] := Trim(Ids[K]);
  end;
  Ws := LoadWorkloads(Path);
  Chosen := nil;
  for K := 0 to High(Ws) do
    if ((Filter = '') or (Pos(Filter, string(Ws[K].Id)) > 0)) and
      ((Ids = nil) or (Ids.IndexOf(string(Ws[K].Id)) >= 0)) then begin
      SetLength(Chosen, Length(Chosen) + 1);
      Chosen[High(Chosen)] := K;
    end;
  Dir := GetEnvironmentVariable('CORVUS_REGEX_PLAIN');
  if Dir = '' then
    Fail('run.sh sets CORVUS_REGEX_PLAIN, the directory of the unzipped texts');
  // The texts unzipped once, for every child.
  ForceDirectories(Dir);
  for K := 0 to High(Ws) do begin
    P := IncludeTrailingPathDelimiter(Dir) + Plain(Ws[K].FileName);
    if not FileExists(P) then
      WriteFileText(P, TextOf(Ws[K].FileName));
  end;
  NE := Engines.Count;
  SetLength(Times, NE, Length(Ws));
  SetLength(Lines, NE, Length(Ws));
  Names := TStringList.Create;
  Done := 0;
  for I := 0 to High(Chosen) do begin
    K := Chosen[I];
    for R := 0 to Rounds - 1 do
      for Turn := 0 to NE - 1 do begin
        E := (Turn + R) mod NE;
        // A figure stopped at the limit in an earlier round is not run again.
        if Lines[E][K] = Stopped then
          Continue;
        Line := Figure(V8, Path, K, Engines[E], SecondsText, PassesText);
        J := nil;
        try
          try
            J := ParseJson(RawByteString(Line));
          except
            J := nil;
          end;
          M := nil;
          if J <> nil then
            M := J.Get('median');
          if (M <> nil) and (M.Kind = jkNumber) then begin
            SetLength(Times[E][K], Length(Times[E][K]) + 1);
            Times[E][K][High(Times[E][K])] := M.N;
          end else
            WriteLn(StdErr, Format('%-13s %-62s %s', [Engines[E], string(Ws[K].Id), Line]));
          if (J <> nil) and (J.Get('engine') <> nil) and (J.Get('engine').Kind = jkString) then
            Names.Values[Engines[E]] := string(J.Get('engine').S);
        finally
          J.Free;
        end;
        Lines[E][K] := Line;
      end;
    Inc(Done);
    WriteLn(StdErr, Format('workload %d of %d done', [Done, Length(Chosen)]));
  end;
  Over := TStringList.Create;
  Differ := TStringList.Create;
  // V8 is the oracle of the counts: an engine that counts otherwise has given a wrong answer, whatever its dialect.
  V8E := Engines.IndexOf('v8');
  Results := TStringList.Create;
  for E := 0 to NE - 1 do begin
    Rows := TStringList.Create;
    try
      for I := 0 to High(Chosen) do begin
        K := Chosen[I];
        Line := Lines[E][K];
        if Length(Times[E][K]) < Rounds then begin
          // A round with no figure (an error, a limit) makes the figure an error.
          if Pos('"error"', Line) > 0 then
            Entry := Line
          else
            Entry := '{"error":"a round gave no figure"}';
        end else begin
          Sorted := Copy(Times[E][K]);
          for R := 1 to High(Sorted) do begin
            Med := Sorted[R];
            Turn := R;
            while (Turn > 0) and (Sorted[Turn - 1] > Med) do begin
              Sorted[Turn] := Sorted[Turn - 1];
              Dec(Turn);
            end;
            Sorted[Turn] := Med;
          end;
          Med := MedianOf(Sorted);
          Lo := Sorted[0];
          Hi := Sorted[High(Sorted)];
          if Med > 0 then
            Spread := (Hi - Lo) / Med
          else
            Spread := 0;
          if Spread > Limit then begin
            Over.Add(Format('%s %s %.1f%%', [Engines[E], string(Ws[K].Id), Spread * 100], Invariant));
            WriteLn(StdErr, Format('SPREAD %-13s %-62s %.1f%% over %.1f%%', [Engines[E], string(Ws[K].Id),
              Spread * 100, Limit * 100], Invariant));
          end;
          if not CountOf(Line, Count) then
            Count := 0;
          HasOracle := False;
          if V8E >= 0 then
            HasOracle := CountOf(Lines[V8E][K], Oracle)
          else if Ws[K].HasV8Count then begin
            HasOracle := True;
            Oracle := Ws[K].V8Count;
          end;
          if HasOracle and (Oracle <> Count) and (Engines[E] <> 'v8') then begin
            Differ.Add(Format('%s %s %d vs V8 %d', [Engines[E], string(Ws[K].Id), Count, Oracle]));
            WriteLn(StdErr, Format('COUNT  %-13s %-62s %d against V8''s %d', [Engines[E], string(Ws[K].Id), Count,
              Oracle]));
            Entry := '{"error":' + string(JsonString(UTF8String(Format('counted %d where V8 counts %d',
              [Count, Oracle])))) + '}';
          end else begin
            Each := '';
            for R := 0 to High(Times[E][K]) do begin
              if R > 0 then
                Each := Each + ',';
              Each := Each + UTF8String(Format('%.1f', [Times[E][K][R]], Invariant));
            end;
            Entry := Format('{"median":%.1f,"min":%.1f,"max":%.1f,"count":%d,"rounds":%d,"spread":%.4f,"each":[%s]}',
              [Med, Lo, Hi, Count, Length(Times[E][K]), Spread, string(Each)], Invariant);
          end;
        end;
        Rows.Add(string(JsonString(Ws[K].Id)) + ':' + Entry);
      end;
      Rows.Delimiter := ',';
      Rows.StrictDelimiter := True;
      Rows.QuoteChar := #0;
      Results.Add(string(JsonString(UTF8String(Engines[E]))) + ':{' + Rows.DelimitedText + '}');
    finally
      Rows.Free;
    end;
  end;
  Over.Delimiter := ';';
  Differ.Delimiter := ';';
  Results.Delimiter := ',';
  Results.StrictDelimiter := True;
  Results.QuoteChar := #0;
  OutText := '{"facts":' + Facts(SecondsText, PassesText, ['rounds=' + IntToStr(Rounds), 'protocol=interleaved',
    'spread_limit=' + FloatToStr(Limit, Invariant), 'spread_over=' + StringReplace(Over.Text, LineEnding, '; ',
    [rfReplaceAll]), 'counts_differ=' + StringReplace(Differ.Text, LineEnding, '; ', [rfReplaceAll]),
    'v8=' + Names.Values['v8']]) + ',"end":' + JsonString(UTF8String(Iso8601Now)) + ',"results":{' +
    UTF8String(Results.DelimitedText) + '}}' + LineEnding;
  if OutFile <> '' then
    WriteFileText(OutFile, OutText)
  else
    Write(OutText);
end;

begin
  Invariant := DefaultFormatSettings;
  Invariant.DecimalSeparator := '.';
  Invariant.ThousandSeparator := #0;
  Main;
end.
