program stackprobe;
{$I ../../src/ecma262.inc}

(* Asks the engine about patterns built to overflow the stack: deep (groups, lookarounds, modifier groups, quantified
  groups and the classes of the v flag, each nested to the limit, one past it and far past it), wide (many groups,
  classes, alternatives, backreferences, set operations and string alternatives side by side) and long (the longest
  pattern allowed, and one past it), in every grammar, through every call over UTF-8 and UTF-16, as the Rust crate's
  stack-probe does.

    stackprobe [--stacks 4M,2M] [--filter text]

  Each probe runs on a thread of its own with each of the stacks. A probe is answered (compiled and matched), refused
  (not valid, or too large, which a caller can catch), or a fault: any other error. A stack overflow ends the process,
  which is a fault too: the exit status is not 0 either way. *)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils,
  Corvus.Ecma262.RegularExpressions;

type
  TProbe = record
    Name: string;
    Flags: string;
    Pattern: UTF8String;
    Text: UTF8String;
  end;

  TProbeThread = class(TThread)
  public
    Probe: ^TProbe;
    Answer: string;
    procedure Execute; override;
  end;

var
  Probes: array of TProbe = nil;

function Rep(const S: UTF8String; N: NativeInt): UTF8String;
var
  K: NativeInt;
begin
  SetLength(Result, Length(S) * N);
  for K := 0 to N - 1 do
    Move(S[1], Result[K * Length(S) + 1], Length(S));
end;

function Nest(const Open, Body, Close: UTF8String; Depth: NativeInt): UTF8String;
begin
  Result := Rep(Open, Depth) + Body + Rep(Close, Depth);
end;

function TextOf(N: NativeInt): UTF8String;
begin
  if N < 64 then
    N := 64;
  if N > 1 shl 20 then
    N := 1 shl 20;
  Result := Rep('a', N) + 'b';
end;

procedure Add(const Name, Flags: string; const Pattern, Text: UTF8String);
begin
  SetLength(Probes, Length(Probes) + 1);
  Probes[High(Probes)].Name := Name;
  Probes[High(Probes)].Flags := Flags;
  Probes[High(Probes)].Pattern := Pattern;
  Probes[High(Probes)].Text := Text;
end;

function Named(Depth: NativeInt): UTF8String;
var
  K: NativeInt;
  B: TStringBuilder;
begin
  B := TStringBuilder.Create;
  try
    for K := 0 to Depth - 1 do
      B.Append('(?<g').Append(K).Append('>');
    Result := UTF8String(B.ToString) + 'a' + Rep(')', Depth);
  finally
    B.Free;
  end;
end;

function NamedSide(Width: NativeInt): UTF8String;
var
  K: NativeInt;
  B: TStringBuilder;
begin
  B := TStringBuilder.Create;
  try
    for K := 0 to Width - 1 do
      B.Append('(?<g').Append(K).Append('>a)');
    Result := UTF8String(B.ToString);
  finally
    B.Free;
  end;
end;

procedure BuildProbes;
const
  Depths: array[0..6] of NativeInt = (32, 33, 200, 1000, 1001, 5000, 200000);
  Grammars: array[0..4] of string = ('', 'u', 'v', 'i', 'iv');
  Groups: array[0..11, 0..2] of UTF8String = (('group', '(', ')'), ('non-capturing', '(?:', ')'),
    ('lookahead', '(?=', ')'), ('negative lookahead', '(?!', ')'), ('lookbehind', '(?<=', ')'),
    ('negative lookbehind', '(?<!', ')'), ('modifier i', '(?i:', ')'), ('modifier -i', '(?-i:', ')'),
    ('star', '(?:', ')*'), ('counted', '(?:', '){2}'), ('lazy plus', '(?:', ')+?'), ('alternative', '(?:b|', ')'));
  Classes_: array[0..5, 0..3] of UTF8String = (('class', '[', 'a', ']'), ('negated class', '[^', 'a', ']'),
    ('difference', '[a--', '[b]', ']'), ('intersection', '[a&&', '[a]', ']'),
    ('string alternatives', '[\q{ab|c}', 'a', ']'), ('class in a group', '(?:[', 'a', '])'));
  Widths: array[0..2] of NativeInt = (1000, 100000, 300000);
var
  G, D, F, W: NativeInt;
  Depth, Width: NativeInt;
  Flags, Suffix: string;
begin
  Probes := nil;
  for G := 0 to High(Groups) do
    for D := 0 to High(Depths) do
      for F := 0 to High(Grammars) do begin
        Depth := Depths[D];
        Add(Format('deep %s x%d /%s', [Groups[G][0], Depth, Grammars[F]]), Grammars[F],
          Nest(Groups[G][1], 'a', Groups[G][2], Depth), TextOf(Depth));
      end;
  for D := 0 to High(Depths) do
    for F := 0 to High(Grammars) do begin
      Depth := Depths[D];
      Add(Format('deep named x%d /%s', [Depth, Grammars[F]]), Grammars[F], Named(Depth), TextOf(Depth));
      Add(Format('deep backreference x%d /%s', [Depth, Grammars[F]]), Grammars[F], Nest('(', 'a', ')\1', Depth),
        TextOf(Depth));
    end;
  for G := 0 to High(Classes_) do
    for D := 0 to High(Depths) do
      for F := 0 to High(Grammars) do begin
        Depth := Depths[D];
        Add(Format('deep %s x%d /%s', [Classes_[G][0], Depth, Grammars[F]]), Grammars[F],
          Nest(Classes_[G][1], Classes_[G][2], Classes_[G][3], Depth), TextOf(Depth));
      end;
  for D := 0 to High(Depths) do begin
    Add(Format('deep [ unclosed x%d /v', [Depths[D]]), 'v', Rep('[', Depths[D]), TextOf(64));
    Add(Format('deep ( unclosed x%d /v', [Depths[D]]), 'v', Rep('(', Depths[D]), TextOf(64));
  end;
  for W := 0 to High(Widths) do
    for F := 0 to High(Grammars) do begin
      Width := Widths[W];
      Flags := Grammars[F];
      Suffix := Format(' x%d /%s', [Width, Flags]);
      Add('wide alternatives' + Suffix, Flags, Rep('a|', Width) + 'b', TextOf(Width));
      Add('wide empty groups' + Suffix, Flags, Rep('()', Width), TextOf(Width));
      Add('wide groups' + Suffix, Flags, Rep('(a)', Width), TextOf(Width));
      Add('wide named groups' + Suffix, Flags, NamedSide(Width), TextOf(Width));
      Add('wide classes' + Suffix, Flags, Rep('[a]', Width), TextOf(Width));
      Add('wide lookaheads' + Suffix, Flags, Rep('(?=a)', Width) + 'a', TextOf(Width));
      Add('wide backreferences' + Suffix, Flags, '(a)' + Rep('\1', Width), TextOf(Width));
      Add('wide optional' + Suffix, Flags, Rep('a?', Width), TextOf(Width));
      Add('wide optional groups' + Suffix, Flags, Rep('(?:a?)', Width), TextOf(Width));
      Add('wide ranges in a class' + Suffix, Flags, '[' + Rep('a-b', Width) + ']', TextOf(Width));
      Add('wide properties' + Suffix, Flags, Rep('\p{L}', Width), TextOf(Width));
      Add('wide stars' + Suffix, Flags, Rep('a*', Width), TextOf(Width));
      Add('wide alternatives in a star' + Suffix, Flags, '(?:' + Rep('a|', Width) + 'b)*', TextOf(Width));
      Add('wide differences' + Suffix, Flags, '[a' + Rep('--b', Width) + ']', TextOf(Width));
      Add('wide intersections' + Suffix, Flags, '[a' + Rep('&&a', Width) + ']', TextOf(Width));
      Add('wide string alternatives' + Suffix, Flags, '[\q{' + Rep('a|', Width) + 'b}]', TextOf(Width));
    end;
  for F := 0 to High(Grammars) do begin
    Add(Format('long literal x%d /%s', [1 shl 20, Grammars[F]]), Grammars[F], Rep('a', 1 shl 20), TextOf(1 shl 20));
    Add(Format('long literal x%d /%s', [(1 shl 20) + 1, Grammars[F]]), Grammars[F], Rep('a', (1 shl 20) + 1),
      TextOf((1 shl 20) + 1));
  end;
end;

{ Ask is everything the engine is asked about one probe; the answer is a line. }
function Ask(const P: TProbe): string;
var
  Valid: Boolean;
  Re: IEcmaRegex;
  U: UnicodeString;
  Answers: string;
  C: TEcmaCaptures;

  procedure Answer(const S: string);
  begin
    Answers := Answers + ' ' + S;
  end;

begin
  Valid := IsValidEcmaRegex(P.Pattern, P.Flags);
  try
    Re := CompileEcmaRegex(P.Pattern, P.Flags, 5.0);
  except
    on E: EEcmaRegexTooLarge do begin
      if Valid then
        Exit('FAULT IsValidEcmaRegex accepted a pattern too large to compile');
      Exit('refused too large');
    end;
    on E: EEcmaRegexSyntax do begin
      if Valid then
        Exit('FAULT IsValidEcmaRegex accepted a pattern the compiler refused: ' + E.Message);
      Exit('refused not valid');
    end;
  end;
  if not Valid then
    Exit('FAULT IsValidEcmaRegex refused a pattern the compiler accepted');
  U := UTF8Decode(RawByteString(P.Text));
  Answers := '';
  C := Default(TEcmaCaptures);
  try Answer(BoolToStr(Re.IsMatch(P.Text), True)); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(BoolToStr(Re.IsMatch(U), True)); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Re.Match(P.Text).Index)); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Re.Match(U).Index)); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.Matches(P.Text).ToArray))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.Matches(U).ToArray))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Re.Count(P.Text))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(BoolToStr(Re.Exec(P.Text, C), True)); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.ReplaceAll(P.Text, UTF8String('$1x'))))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.ReplaceAll(U, UnicodeString('x'))))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.Split(P.Text)))); except on E: EEcmaRegex do Answer(E.Message); end;
  try Answer(IntToStr(Length(Re.Split(U)))); except on E: EEcmaRegex do Answer(E.Message); end;
  Result := 'answered' + Answers;
end;

procedure TProbeThread.Execute;
begin
  try
    Answer := Ask(Probe^);
  except
    on E: Exception do
      Answer := 'FAULT ' + E.ClassName + ': ' + E.Message;
  end;
  ReleaseEcmaRegexThreadState;
end;

function SizeOf_(const S: string): PtrUInt;
var
  N: PtrUInt;
begin
  N := StrToInt(Copy(S, 1, Length(S) - 1));
  case S[Length(S)] of
    'K': Result := N shl 10;
    'M': Result := N shl 20;
    'G': Result := N shl 30;
  else
    raise Exception.Create('a stack size such as 256K or 8M');
  end;
end;

var
  Stacks: TStringList;
  Filter, R: string;
  K, S, Answered, Refused: Integer;
  Faults: TStringList;
  T: TProbeThread;
  Started: QWord;
begin
  Stacks := TStringList.Create;
  Stacks.CommaText := '4M,2M';
  Filter := '';
  K := 1;
  while K < ParamCount do begin
    if ParamStr(K) = '--stacks' then
      Stacks.CommaText := ParamStr(K + 1);
    if ParamStr(K) = '--filter' then
      Filter := ParamStr(K + 1);
    Inc(K, 2);
  end;
  BuildProbes;
  Started := GetTickCount64;
  Answered := 0;
  Refused := 0;
  Faults := TStringList.Create;
  for K := 0 to High(Probes) do begin
    if (Filter <> '') and (Pos(Filter, Probes[K].Name) = 0) then
      Continue;
    for S := 0 to Stacks.Count - 1 do begin
      T := TProbeThread.Create(True, SizeOf_(Stacks[S]));
      T.Probe := @Probes[K];
      T.FreeOnTerminate := False;
      T.Start;
      T.WaitFor;
      R := T.Answer;
      T.Free;
      if Copy(R, 1, 8) = 'answered' then
        Inc(Answered)
      else if Copy(R, 1, 7) = 'refused' then
        Inc(Refused)
      else
        Faults.Add(Probes[K].Name + ' on ' + Stacks[S] + ': ' + R);
    end;
  end;
  Faults.Sort;
  for K := 0 to Faults.Count - 1 do
    WriteLn(Faults[K]);
  WriteLn(Format('%d probes on %d stacks: %d answered, %d refused, %d faults, in %d s', [Length(Probes), Stacks.Count,
    Answered, Refused, Faults.Count, (GetTickCount64 - Started) div 1000]));
  if Faults.Count > 0 then
    Halt(1);
end.
