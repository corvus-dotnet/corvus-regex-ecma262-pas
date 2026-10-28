program TestEngine;
{$I ../src/ecma262.inc}

(* The tests of the API: flags, the errors of compiling, matches and their groups, the global search, replace, split,
  the refusal of text that is not UTF-8, UTF-16 text, half characters, the match timeout and the linear time of a
  pattern without backreferences. The ECMA-262 test data (tools/dataset/run.pas) is what holds the answers to V8;
  these hold the API to its documentation. The program prints each failure and a final count, and exits with a
  status other than zero when anything failed. *)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils,
  Corvus.Ecma262.RegularExpressions;

var
  Failures: Int32 = 0;
  Checks: Int32 = 0;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Checks);
  if not Ok then begin
    Inc(Failures);
    WriteLn('FAIL: ', What);
  end;
end;

{ Raised checks an exception that a call raised against the class it should have, or a call that raised nothing
  (X nil). }
procedure Raised(X: Exception; E: ExceptClass; const What: string);
begin
  Check((X <> nil) and (X is E), What);
end;

procedure TestFlags;
begin
  Check(EcmaRegexFlagsText(ParseEcmaRegexFlags('ysvmigd')) = 'dgimsvy', 'flags are written in the order dgimsuvy');
  try
    ParseEcmaRegexFlags('x');
    Raised(nil, EEcmaRegexFlags, 'an unknown flag');
  except
    on X: Exception do
      Raised(X, EEcmaRegexFlags, 'an unknown flag');
  end;
  try
    ParseEcmaRegexFlags('gg');
    Raised(nil, EEcmaRegexFlags, 'a flag given twice');
  except
    on X: Exception do
      Raised(X, EEcmaRegexFlags, 'a flag given twice');
  end;
  try
    ParseEcmaRegexFlags('uv');
    Raised(nil, EEcmaRegexFlags, 'u with v');
  except
    on X: Exception do
      Raised(X, EEcmaRegexFlags, 'u with v');
  end;
end;

procedure TestCompileErrors;
var
  Deep: UTF8String;
  K: Int32;
begin
  try
    CompileEcmaRegex(UTF8String('a{2,1}'));
    Raised(nil, EEcmaRegexSyntax, 'counts out of order');
  except
    on X: Exception do
      Raised(X, EEcmaRegexSyntax, 'counts out of order');
  end;
  try
    CompileEcmaRegex(UTF8String('\p{Lu}'), 'q');
    Raised(nil, EEcmaRegexFlags, 'bad flags');
  except
    on X: Exception do
      Raised(X, EEcmaRegexFlags, 'bad flags');
  end;
  try
    CompileEcmaRegex(UTF8String('a'#$FF'b'));
    Raised(nil, EEcmaRegexEncoding, 'a pattern that is not UTF-8');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'a pattern that is not UTF-8');
  end;
  try
    CompileEcmaRegex(UnicodeString('a'#$D800));
    Raised(nil, EEcmaRegexEncoding, 'a pattern with a lone surrogate');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'a pattern with a lone surrogate');
  end;
  Check(IsValidEcmaRegex('\p{Lu}', 'u'), 'a property with u');
  Check(not IsValidEcmaRegex('\p{Lu', 'u'), 'an unterminated property with u');
  Check(IsValidEcmaRegex('\p{Lu', ''), 'Annex B reads \p as p');
  Deep := '';
  for K := 1 to 1001 do
    Deep := '(' + Deep + ')';
  try
    CompileEcmaRegex(Deep);
    Raised(nil, EEcmaRegexTooLarge, 'groups nested too deep');
  except
    on X: Exception do
      Raised(X, EEcmaRegexTooLarge, 'groups nested too deep');
  end;
  try
    CompileEcmaRegex(UTF8String('ab)'));
    Check(False, 'an unmatched )');
  except
    on E: EEcmaRegexSyntax do
      Check((E.Offset = 2) and (E.Reason = 'unmatched '')''') and (E.Pattern = 'ab)'), 'the syntax error''s parts');
  end;
end;

procedure TestMatch;
var
  Re: IEcmaRegex;
  M: TEcmaMatch;
  W: TEcmaMatchW;
begin
  Re := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'u');
  Check(Re.IsMatch(UTF8String('on 2026-10-25')), 'IsMatch over UTF-8');
  Check(Re.IsMatch(UnicodeString('on 2026-10-25')), 'IsMatch over UTF-16');
  Check(not Re.IsMatch(UTF8String('on 26-10')), 'no match');
  M := Re.Match(UTF8String('on 2026-10-25'));
  Check(M.Success and (M.Value = '2026-10') and (M.Index = 4) and (M.Length = 7), 'the match');
  Check((M.Groups[1].Value = '2026') and (M.Groups[2].Value = '10') and (M.Groups[2].Index = 9), 'the groups');
  Check((M.Group('month').Value = '10') and (M.Group('year').Value = '2026'), 'the groups by name');
  Check((Re.GroupName(1) = 'year') and (Re.GroupName(2) = 'month') and (Re.GroupCount = 2), 'the group names');
  Check((Length(Re.GroupNumbers('month')) = 1) and (Re.GroupNumbers('month')[0] = 2), 'the group of a name');
  Check(not Re.Match(UTF8String('on 2026-10-25'), 5).Success, 'a search from an index');
  W := CompileEcmaRegex('\d', 'u').Match(UnicodeString('a1b2'), 3);
  Check(W.Success and (W.Index = 4), 'a search from an index over UTF-16');
  Check(Re.FlagsText = 'u', 'the flags');
  Check(Re.Pattern = '(?<year>\d{4})-(?<month>\d{2})', 'the pattern');
end;

procedure TestManyNames;
var
  Pattern: UTF8String;
  K: Int32;
  Re: IEcmaRegex;
begin
  // The table of names grows several times on the way.
  Pattern := '';
  for K := 1 to 200 do
    Pattern := Pattern + '(?<n' + UTF8String(IntToStr(K)) + '>a)';
  Re := CompileEcmaRegex(Pattern);
  Check((Re.GroupCount = 200) and (Re.GroupName(150) = 'n150') and (Re.GroupNumbers('n77')[0] = 77),
    'two hundred group names');
end;

procedure TestGroupNotTakingPart;
var
  M: TEcmaMatch;
begin
  M := CompileEcmaRegex('(a)|(b)').Match(UTF8String('b'));
  Check(not M.Groups[1].Success and M.Groups[2].Success and (M.Groups[2].Value = 'b'),
    'a group that did not take part');
end;

procedure TestGlobalSearch;
var
  Re: IEcmaRegex;
  All: TEcmaMatchArray;
begin
  Re := CompileEcmaRegex('a*', 'u');
  All := Re.Matches(UTF8String('baa'#$F0#$9F#$98#$80)).ToArray;
  Check((Length(All) = 4) and (All[0].Index = 1) and (All[0].Length = 0) and (All[1].Index = 2) and
    (All[1].Length = 2) and (All[2].Index = 4) and (All[3].Index = 8), 'a global search moves on past an empty match');
  Check(CompileEcmaRegex('\w+').Count(UTF8String('hello big world')) = 3, 'Count');
  // Without the u flag a code unit at a time: between the halves of the pair, and after it.
  Check(CompileEcmaRegex('').Count(UnicodeString(#$D83D#$DE00)) = 3, 'empty matches by code unit');
  Check(CompileEcmaRegex('', 'u').Count(UnicodeString(#$D83D#$DE00)) = 2, 'empty matches by code point');
end;

procedure TestReplace;
var
  Re: IEcmaRegex;
begin
  Re := CompileEcmaRegex('(?<year>\d{4})-(?<month>\d{2})', 'u');
  Check(Re.Replace(UTF8String('2026-10 and 2027-11'), UTF8String('$<month>/$<year>')) = '10/2026 and 2027-11',
    'Replace without g replaces the first');
  Check(Re.ReplaceAll(UTF8String('2026-10 and 2027-11'), UTF8String('[$&|$1|$$|$`|$'']')) =
    '[2026-10|2026|$|| and 2027-11] and [2027-11|2027|$|2026-10 and |]', 'the $ forms');
  Check(CompileEcmaRegex('o', 'g').Replace(UTF8String('foo'), UTF8String('0')) = 'f00', 'Replace with g');
  // Without a named group $< is itself.
  Check(CompileEcmaRegex('o').Replace(UTF8String('o'), UTF8String('$<x>')) = '$<x>', '$< without a named group');
  Check(CompileEcmaRegex('x').Replace(UTF8String('abc'), UTF8String('y')) = 'abc', 'no match');
  Check(CompileEcmaRegex('b').Replace(UnicodeString('abc'), UnicodeString('[$&]')) = 'a[b]c', 'over UTF-16');
end;

procedure TestSplit;
var
  P: TEcmaGroups;
  W: TEcmaGroupsW;
begin
  P := CompileEcmaRegex('\d+').Split(UTF8String('a1b22c'));
  Check((Length(P) = 3) and (P[0].Value = 'a') and (P[1].Value = 'b') and (P[2].Value = 'c'), 'split');
  P := CompileEcmaRegex('(-)|(\+)').Split(UTF8String('a-b+c'));
  Check((Length(P) = 7) and (P[1].Value = '-') and not P[2].Success and not P[4].Success and (P[5].Value = '+') and
    (P[6].Value = 'c'), 'split with groups');
  Check(Length(CompileEcmaRegex('(-)|(\+)').Split(UTF8String('a-b+c'), 3)) = 3, 'split with a limit');
  Check(Length(CompileEcmaRegex('x*').Split(UTF8String(''))) = 0, 'split of nothing by a match of nothing');
  P := CompileEcmaRegex('x').Split(UTF8String(''));
  Check((Length(P) = 1) and P[0].Success and (P[0].Value = ''), 'split of nothing');
  W := CompileEcmaRegex(UnicodeString(#$D83D#$DE00), 'u').Split(UnicodeString('x'#$D83D#$DE00'y'));
  Check((Length(W) = 2) and (W[0].Value = 'x') and (W[1].Value = 'y'), 'split over UTF-16');
end;

procedure TestRefusal;
var
  Re: IEcmaRegex;
begin
  Re := CompileEcmaRegex('a', 'u');
  try
    Re.IsMatch(UTF8String('a'#$FF));
    Raised(nil, EEcmaRegexEncoding, 'IsMatch refuses');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'IsMatch refuses');
  end;
  try
    Re.Match(UTF8String('a'#$FF));
    Raised(nil, EEcmaRegexEncoding, 'Match refuses');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'Match refuses');
  end;
  try
    Re.IsMatch(UTF8String(#$C0#$80));
    Raised(nil, EEcmaRegexEncoding, 'an overlong form');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'an overlong form');
  end;
  try
    TUtf8Text.Create(#$ED#$A0#$80);
    Raised(nil, EEcmaRegexEncoding, 'a surrogate in UTF-8');
  except
    on X: Exception do
      Raised(X, EEcmaRegexEncoding, 'a surrogate in UTF-8');
  end;
  Check(Re.IsMatch(TUtf8Text.Create('xa')), 'a checked text');
end;

procedure TestUtf16;
var
  U: UnicodeString;
begin
  U := 'x'#$D83D#$DE00'y';
  // A lone low surrogate is a character without the u flag.
  Check(CompileEcmaRegex('^.y').IsMatch(Copy(U, 3, MaxInt)), 'a lone surrogate is a character');
  Check(CompileEcmaRegex('x.y', 'u').IsMatch(U), 'the dot takes a pair with the u flag');
  Check(not CompileEcmaRegex('x.y').IsMatch(U), 'and one unit without it');
  Check(CompileEcmaRegex('.', 'u').Match(UnicodeString(#$D83D#$DE00)).Length = 2, 'a pair is one character');
  Check(CompileEcmaRegex('.').Match(UnicodeString(#$D83D#$DE00)).Length = 1, 'a unit is one character');
end;

procedure TestHalfCharacter;
begin
  // Without the u flag \ude00 is a code unit, the second half of U+1F600 (F0 9F 98 80 is D83D DE00).
  Check(CompileEcmaRegex('\ude00').Replace(UTF8String('a'#$F0#$9F#$98#$80'b'), UTF8String('-')) =
    'a'#$EF#$BF#$BD'-b', 'a half character is written as U+FFFD');
  Check(CompileEcmaRegex('\ude00').Match(UTF8String('a'#$F0#$9F#$98#$80'b')).Value = #$EF#$BF#$BD,
    'a half character in a match');
end;

procedure TestTimeout;
var
  Re: IEcmaRegex;
  Text: UTF8String;
begin
  Re := CompileEcmaRegex('(?:a?){1000}a{1000}', '', 0.001);
  Check(Abs(Re.MatchTimeout - 0.001) < 1E-9, 'the timeout');
  Text := StringOfChar('a', 999);
  try
    Re.IsMatch(Text);
  except
    on E: Exception do
      Check((E is EEcmaRegexTimeout) or (E is EEcmaRegexMemory), 'a limit raises');
  end;
  Check(CompileEcmaRegex('a').MatchTimeout = 0, 'no timeout');
  SetDefaultEcmaRegexMatchTimeout(5);
  Check(CompileEcmaRegex('a').MatchTimeout = 5, 'the default timeout');
  SetDefaultEcmaRegexMatchTimeout(0);
  Check(CompileEcmaRegex('a').MatchTimeout = 0, 'no default timeout');
end;

type
  { A TFirstUse thread compiles and matches patterns of Unicode 13 and 18, which are made on their first use. }
  TFirstUse = class(TThread)
  protected
    procedure Execute; override;
  public
    Wrong: Int32;
  end;

procedure TFirstUse.Execute;
const
  Yezidi = #$F0#$90#$BA#$80;
  Jurchen = #$F0#$98#$B8#$80;
var
  Options: TEcmaRegexOptions;
  K: Int32;
begin
  Wrong := 0;
  Options := TEcmaRegexOptions.Default;
  for K := 1 to 20 do
    try
      Options.UnicodeVersion := eru13;
      if not CompileEcmaRegex('^\p{Script=Yezidi}\p{Lu}$', 'u', Options).IsMatch(Yezidi + 'A') then
        Inc(Wrong);
      Options.UnicodeVersion := eru18;
      if not CompileEcmaRegex('^\p{scx=Jurc}$', 'iu', Options).IsMatch(Jurchen) then
        Inc(Wrong);
    except
      Inc(Wrong);
    end;
end;

{ TestFirstUse makes Unicode 13 and 18 from eight threads at once, before any other test makes them: two threads must
  not fill one version together. }
procedure TestFirstUse;
var
  Threads: array[0..7] of TFirstUse;
  K, Wrong: Int32;
begin
  for K := 0 to High(Threads) do
    Threads[K] := TFirstUse.Create(True);
  for K := 0 to High(Threads) do
    Threads[K].Start;
  Wrong := 0;
  for K := 0 to High(Threads) do begin
    Threads[K].WaitFor;
    Inc(Wrong, Threads[K].Wrong);
    Threads[K].Free;
  end;
  Check(Wrong = 0, 'Unicode 13 and 18 made from eight threads at once give their answers (' + IntToStr(Wrong) +
    ' wrong)');
end;

{ The edition of the grammar and the version of Unicode (tests/editions.rs of the Rust crate): ECMAScript 2020
  refuses what later editions added and nothing else, and each version of Unicode has its own scripts and case
  folding, in the matcher as in the parser. U+10570 and U+10597 are a capital and a small letter of Vithkuqi, a
  script of Unicode 14; U+A7C0 and U+A7C1 are the capital and the small Old Polish O, also of Unicode 14. }
procedure TestEditions;
const
  VithkuqiCapital = #$F0#$90#$95#$B0;
  VithkuqiSmall = #$F0#$90#$96#$97;
  OldPolishCapital = #$EA#$9F#$80;
  OldPolishSmall = #$EA#$9F#$81;
  Versions: array[0..4] of TEcmaRegexUnicodeVersion = (eruDefault, eru13, eru17, eru18, eruLatest);
  Resolved: array[0..4] of Int32 = (17, 13, 17, 18, 18);
  Refused2020: array[0..7, 0..1] of UTF8String = (('(?i:a)', ''), ('(?-i:a)', 'i'), ('(?s:.)', 'u'),
    ('(?<a>x)|(?<a>y)', ''), ('(?<a>x)|(?<a>y)', 'u'), ('\p{Script=Yezidi}', 'u'), ('\p{sc=Vith}', 'u'),
    ('\p{Script_Extensions=Toto}', 'u'));
  Accepted2020: array[0..6, 0..1] of UTF8String = (('\p{Script=Greek}', 'u'), ('\p{L}\p{gc=Lu}\p{Lowercase}', 'u'),
    ('\P{scx=Latn}', 'iu'), ('\p{Script=Yezidi}', ''), ('(?<a>x)(?<b>y)\k<a>', 'u'), ('(?<=a)(?<!b)', 's'),
    ('(?:i)', ''));
  Backrefs: array[0..2] of UTF8String = ('(.)\1', '(?<=\1(.))', '(?:x|(.))+\1$');
var
  Re: IEcmaRegex;
  Err: TEcmaRegexError;
  K, P: Int32;
  Text, First, Twice: UTF8String;
  Flags: string;

  function Opts(Edition: TEcmaRegexEdition; Version: TEcmaRegexUnicodeVersion): TEcmaRegexOptions;
  begin
    Result := TEcmaRegexOptions.Default;
    Result.Edition := Edition;
    Result.UnicodeVersion := Version;
  end;

  function Under(const Pattern: UTF8String; const F: string; Version: TEcmaRegexUnicodeVersion): IEcmaRegex;
  begin
    Result := CompileEcmaRegex(Pattern, F, Opts(ereCurrent, Version));
  end;

begin
  Err := Default(TEcmaRegexError);
  Re := CompileEcmaRegex('a');
  Check((Re.Edition = ereCurrent) and (Re.UnicodeVersion = 17), 'the defaults are today''s grammar and V8''s Unicode');
  for K := 0 to High(Versions) do
    Check(Under('a', '', Versions[K]).UnicodeVersion = Resolved[K], 'a version is resolved when compiled');

  Check(not IsValidEcmaRegex('\p{Script=Vithkuqi}', 'u', Opts(ereCurrent, eru13)), 'no Vithkuqi in Unicode 13');
  Check(IsValidEcmaRegex('\p{Script=Vithkuqi}', 'u', Opts(ereCurrent, eruDefault)), 'Vithkuqi in Unicode 17');
  Check(IsValidEcmaRegex('\p{Script=Yezidi}', 'u', Opts(ereCurrent, eru13)), 'Yezidi in Unicode 13');
  Check(not IsValidEcmaRegex('\p{Script=Jurchen}', 'u', Opts(ereCurrent, eruDefault)), 'no Jurchen in Unicode 17');
  Check(IsValidEcmaRegex('\p{scx=Jurc}', 'u', Opts(ereCurrent, eru18)), 'Jurchen in Unicode 18');
  Check(IsValidEcmaRegex('\p{Script=Jurchen}', 'u', Opts(ereCurrent, eruLatest)), 'Jurchen in the latest');

  // The same expression under two versions, in both orders: the property sets are each version's.
  for K := 1 to 2 do begin
    Check(Under('^\p{Ll}$', 'u', eru17).IsMatch(VithkuqiSmall), '\p{Ll} under 17');
    Check(not Under('^\p{Ll}$', 'u', eru13).IsMatch(VithkuqiSmall), '\p{Ll} under 13');
  end;

  Check(Under('\u{10570}', 'iu', eru17).IsMatch(VithkuqiSmall), 'a literal folds as 17 folds');
  Check(not Under('\u{10570}', 'iu', eru13).IsMatch(VithkuqiSmall), 'a literal folds as 13 folds');
  Check(Under(OldPolishCapital, 'i', eru17).IsMatch(OldPolishSmall), 'Old Polish O folds in 17 without u');
  Check(not Under(OldPolishCapital, 'i', eru13).IsMatch(OldPolishSmall), 'Old Polish O does not fold in 13');

  for K := 0 to 1 do begin
    if K = 0 then begin
      Flags := 'iu';
      Text := VithkuqiCapital + VithkuqiSmall;
      First := VithkuqiCapital;
    end else begin
      Flags := 'i';
      Text := OldPolishCapital + OldPolishSmall;
      First := OldPolishCapital;
    end;
    Twice := First + First;
    for P := 0 to High(Backrefs) do begin
      Check(Under(Backrefs[P], Flags, eru17).IsMatch(Text), Backrefs[P] + ' folds under 17');
      Check(Under(Backrefs[P], Flags, eru18).IsMatch(UTF8Decode(Text)), Backrefs[P] + ' folds over UTF-16 under 18');
      Re := Under(Backrefs[P], Flags, eru13);
      Check(not Re.IsMatch(Text), Backrefs[P] + ' does not fold under 13');
      Check(not Re.IsMatch(UTF8Decode(Text)), Backrefs[P] + ' does not fold over UTF-16 under 13');
      Check(Re.IsMatch(Twice), Backrefs[P] + ' matches the same letter twice under 13');
      // The program that records every group folds as the one that finds the match.
      Check(Re.Match(Twice).Success, Backrefs[P] + ' captures under 13');
      Check(not Re.Match(Text).Success, Backrefs[P] + ' captures nothing under 13');
    end;
  end;

  for K := 0 to High(Refused2020) do begin
    Check(not TryCompileEcmaRegex(Refused2020[K, 0], string(Refused2020[K, 1]), Opts(ereEs2020, eruLatest), Re, Err) and
      (Err.Kind = eekSyntax) and (Re = nil), Refused2020[K, 0] + ' is refused in 2020');
    Check(TryCompileEcmaRegex(Refused2020[K, 0], string(Refused2020[K, 1]), Opts(ereCurrent, eruLatest), Re, Err) and
      (Err.Kind = eekNone) and (Re <> nil), Refused2020[K, 0] + ' is accepted today');
  end;
  for K := 0 to High(Accepted2020) do
    Check(TryCompileEcmaRegex(Accepted2020[K, 0], string(Accepted2020[K, 1]), Opts(ereEs2020, eru13), Re, Err),
      Accepted2020[K, 0] + ' is accepted in 2020');
  Check(not TryCompileEcmaRegex('a', 'd', Opts(ereEs2020, eruDefault), Re, Err) and (Err.Kind = eekFlags),
    'no d flag in 2020');
  Check(not TryCompileEcmaRegex('a', 'v', Opts(ereEs2020, eruDefault), Re, Err) and (Err.Kind = eekFlags),
    'no v flag in 2020');
  Check(not IsValidEcmaRegex('a', 'v', Opts(ereEs2020, eruDefault)), 'IsValidEcmaRegex: no v flag in 2020');
  Check(TryCompileEcmaRegex('a', 'v', Opts(ereCurrent, eruDefault), Re, Err), 'the v flag today');

  // TryCompileEcmaRegex takes a match timeout of its own and raises nothing for the pattern.
  Check(TryCompileEcmaRegex('a+', 'u', Opts(ereCurrent, eruDefault), Re, Err), 'a valid pattern');
  Check(Abs(Re.MatchTimeout - DefaultEcmaRegexMatchTimeout) < 1E-9, 'the default timeout without one');
  Err.Kind := eekNone;
  Check(not TryCompileEcmaRegex('(', 'u', Opts(ereCurrent, eruDefault), Re, Err) and (Err.Kind = eekSyntax) and
    (Err.Message <> ''), 'an invalid pattern gives its error');
  Check(not TryCompileEcmaRegex('a', 'x', Opts(ereCurrent, eruDefault), Re, Err) and (Err.Kind = eekFlags),
    'invalid flags give their error');
  Check(not TryCompileEcmaRegex(#$61#$FF, '', Opts(ereCurrent, eruDefault), Re, Err) and (Err.Kind = eekEncoding),
    'a pattern that is not UTF-8 gives its error');
end;

procedure TestLinear;
var
  Text: UTF8String;
begin
  Text := StringOfChar('a', 5000) + 'b';
  Check(not CompileEcmaRegex('^(a+)+$').IsMatch(Text), 'nested quantifiers in linear time');
  Check(not CompileEcmaRegex('^(?:a|aa)*$').IsMatch(Text), 'an alternation in a loop in linear time');
end;

procedure TestCaptures;
var
  Re: IEcmaRegex;
  C: TEcmaCaptures;
  Text: TUtf8Text;
  Index, Len: NativeInt;
  N: Int32;
begin
  Re := CompileEcmaRegex('(?<k>\w+)=(?<v>\d+)', 'u');
  C := Default(TEcmaCaptures);
  Text := TUtf8Text.Create('x a=1 b=22');
  Check(Re.Exec(Text, C), 'Exec');
  Check(C.Range(0, Index, Len) and (Index = 3) and (Len = 3), 'the range of the match');
  Check(C.Range(2, Index, Len) and (Index = 5) and (Len = 1), 'the range of a group');
  N := 0;
  Index := 1;
  while Re.Exec(Text, C, Index) do begin
    Inc(N);
    C.Range(0, Index, Len);
    Index := Index + Len;
  end;
  Check(N = 2, 'a loop of Exec');
  Check(not Re.Exec(Text, C, 12), 'no match from past the end');
  Check(not C.Range(0, Index, Len), 'no range after no match');
  Check(Re.Exec(PByte(PAnsiChar('k=7')), 3, C) and C.Range(2, Index, Len) and (Index = 3), 'Exec over bytes');
  Check(Re.Exec(PWideChar(UnicodeString('k=7')), 3, C) and C.Range(1, Index, Len) and (Len = 1),
    'Exec over UTF-16 code units');
end;

begin
  TestFirstUse;
  TestFlags;
  TestCompileErrors;
  TestMatch;
  TestManyNames;
  TestGroupNotTakingPart;
  TestGlobalSearch;
  TestReplace;
  TestSplit;
  TestRefusal;
  TestUtf16;
  TestHalfCharacter;
  TestTimeout;
  TestEditions;
  TestLinear;
  TestCaptures;
  WriteLn(Format('%d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
