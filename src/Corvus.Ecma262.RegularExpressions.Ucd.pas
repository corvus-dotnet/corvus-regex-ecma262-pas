unit Corvus.Ecma262.RegularExpressions.Ucd;
{$I ecma262.inc}

{ Unit Ucd holds the Unicode Character Database properties the engine reads, for each version of Unicode the engine
  carries (ucd.rs of the Rust crate): a TUcd for each, UcdV13, UcdV17 and UcdV18.

  Nothing in the engine takes Unicode properties from the run-time library of the compiler, because that library
  follows the compiler (and, for some of its functions, the operating system). With its own tables the engine gives
  the same answers whichever compiler builds it and wherever it runs, and the answers change only when the tables
  are generated again. A pattern is read with the tables of the version it was compiled for.

  The tables of a version are in the unit Corvus.Ecma262.RegularExpressions.Ucd<major>, which
  tools/unicode/gen-ucd-tables.ps1 writes from tables<major>.rs of the Rust crate, so every engine holds the same
  data. Each is a sorted list of inclusive ranges, the code points up to U+FFFF as 16-bit bounds and the rest as
  32-bit bounds. A value that follows from other values (a General_Category group such as L, the Assigned property,
  the Unknown script) has no table of its own and is built from them.

  Two things differ from the crate. The crate builds a value that follows from others when it is first asked for.
  Here every table of a version is made when the version is made, which takes well under a millisecond, so that
  reading a table needs no lock: the default version (UcdV17) when the unit is initialised, and the others on first
  use. And the crate finds a table by name with a match over strings, which Delphi does not have, so each lookup is
  a list of names in ordinal order, which the unit searches.

  The functions Ucd<name> read the default version, for the callers that need no other. }

interface

const
  { UcdMaxRune is the last Unicode code point. }
  UcdMaxRune = $10FFFF;

type
  { A list of code points. }
  TUcdRunes = array of Int32;
  { A list of names, and a list of those. }
  TUcdNames = array of UTF8String;
  TUcdNameLists = array of TUcdNames;

  { A TUcdTable is an immutable set of code points. }
  TUcdTable = record
    { R16 holds the ranges that end at or below U+FFFF and R32 the ranges that start above it, each as inclusive
      pairs in ascending order. No two ranges of one list overlap or touch. }
    R16: array of UInt16;
    R32: array of UInt32;
    { Contains reports whether the table holds the code point. }
    function Contains(R: Int32): Boolean;
    { AppendRanges appends the ranges of the table to Dst as inclusive pairs in ascending order. The pairs neither
      overlap nor touch. }
    procedure AppendRanges(var Dst: TUcdRunes);
  end;
  PUcdTable = ^TUcdTable;

  { A TUcdCaseRange maps some of the code points First, First+1, ... First+Length-1 to themselves plus Delta. The
    ones it maps are those whose offset from First has none of the bits of Mask, so a mask of 1 takes every other
    code point. }
  TUcdCaseRange = record
    First: Int32;
    Delta: Int32;
    Length: UInt16;
    Mask: UInt16;
  end;
  TUcdCaseRanges = array of TUcdCaseRange;

  { A TUcdLookup finds a table by name: the names in ordinal order, and the number of the table of each. }
  TUcdLookup = record
    Names: TUcdNames;
    Tables: array of Int32;
  end;

  { A TUcdData is the generated data of one version of Unicode, which the unit of the version fills (FillUcd<major>)
    and a TUcd is made from. }
  TUcdData = record
    Version: UTF8String;
    Tables: array of TUcdTable;
    Category, Binary, Script, ScriptExtensions: TUcdLookup;
    ScriptNameLists: TUcdNameLists;
    BinaryNames: TUcdNames;
    CaseFolds, UpperCases: TUcdCaseRanges;
    { The properties of strings but RGI_Emoji: the name of each, its single code points as hexadecimal ranges, and
      its sequences as hexadecimal code points, a space between the code points of a sequence and a semicolon
      between sequences. }
    StringNames, StringPoints, StringSequences: TUcdNames;
  end;
  PUcdData = ^TUcdData;

  { A TUcd is the Unicode of one version: its tables, made when it is made and never changed after, and the slots of
    what the engine builds from them on first use. }
  TUcd = class
  private
    FData: TUcdData;
    FMajor: Int32;
    FGenerated: Int32;
    function Derived(K: Int32): PUcdTable;
    function FindTable(const Lookup: TUcdLookup; const Name: UTF8String): PUcdTable;
  public
    { Slots for what the CharSet and Syntax units build from the tables on first use, each nil until a thread has
      built it: the classes of Canonicalize under the u flag's grammar and under the grammar of no flag, and the
      properties of strings. A slot is published with InterlockedCompareExchangePointer. }
    UnicodeFoldSlot, LegacyFoldSlot, StringPropertiesSlot: Pointer;
    constructor Create(const Data: TUcdData);
    { Version is the version of Unicode the tables hold, such as '17.0.0', and Major its major number. }
    function Version: UTF8String;
    property Major: Int32 read FMajor;
    { The General_Category groups L, LC, M, N, P, S, Z and C, the Assigned property and the Unknown script. }
    function Letter: PUcdTable;
    function CasedLetter: PUcdTable;
    function Mark: PUcdTable;
    function Number: PUcdTable;
    function Punctuation: PUcdTable;
    function Symbol: PUcdTable;
    function Separator: PUcdTable;
    function Other: PUcdTable;
    function Assigned: PUcdTable;
    function UnknownScript: PUcdTable;
    { Category, Binary, Script and ScriptExtensions are UcdCategory, UcdBinary, UcdScript and UcdScriptExtensions
      for this version. }
    function Category(const Name: UTF8String): PUcdTable;
    function Binary(const Name: UTF8String): PUcdTable;
    function Script(const Name: UTF8String): PUcdTable;
    function ScriptExtensions(const Name: UTF8String): PUcdTable;
    function ScriptNames: TUcdNameLists;
    function BinaryNames: TUcdNames;
    function Fold(R: Int32): Int32;
    function ToUpper(R: Int32): Int32;
    procedure AppendFolding(var Dst: TUcdRunes);
    function FoldByTable(R: Int32): Int32;
    function ToUpperByTable(R: Int32): Int32;
    { The properties of strings of the version (see TUcdData). }
    property StringNames: TUcdNames read FData.StringNames;
    property StringPoints: TUcdNames read FData.StringPoints;
    property StringSequences: TUcdNames read FData.StringSequences;
  end;

{ UcdV13, UcdV17 and UcdV18 are the versions of Unicode the engine carries. UcdV17 is the default, the version of
  the V8 the answers are held to. }
function UcdV13: TUcd;
function UcdV17: TUcd;
function UcdV18: TUcd;

{ UcdByMajor returns a version by its major number, 13, 17 or 18; any other number gives the default. A
  backreference carries the number of the version it folds case with, which is never another. }
function UcdByMajor(Major: Int32): TUcd;

{ UcdMade returns a version by its major number when it has been made, and nil when it has not, without making it. }
function UcdMade(Major: Int32): TUcd;

{ UcdCopyNames, UcdCopyLookup and UcdCopyCases copy generated constants into a TUcdData (FillUcd<major>). }
procedure UcdCopyNames(const Source: array of UTF8String; out Dest: TUcdNames);
procedure UcdCopyLookup(const Names: array of UTF8String; const Tables: array of Int32; out Dest: TUcdLookup);
procedure UcdCopyCases(const Source: array of TUcdCaseRange; out Dest: TUcdCaseRanges);

{ UcdVersion returns the version of Unicode the default tables hold. }
function UcdVersion: UTF8String;

{ UcdUnion builds the table of the code points that any of the tables holds. A caller that tests one code point
  against several properties builds their union once and searches one table. }
function UcdUnion(const Tables: array of PUcdTable): TUcdTable;

{ The functions below read the default version, UcdV17. }

{ The General_Category values that are groups of other values, the Assigned property and the Unknown script. }

{ UcdLetter is the General_Category group L. }
function UcdLetter: PUcdTable;
{ UcdCasedLetter is the General_Category group LC. }
function UcdCasedLetter: PUcdTable;
{ UcdMark is the General_Category group M. }
function UcdMark: PUcdTable;
{ UcdNumber is the General_Category group N. }
function UcdNumber: PUcdTable;
{ UcdPunctuation is the General_Category group P. }
function UcdPunctuation: PUcdTable;
{ UcdSymbol is the General_Category group S. }
function UcdSymbol: PUcdTable;
{ UcdSeparator is the General_Category group Z. }
function UcdSeparator: PUcdTable;
{ UcdOther is the General_Category group C. }
function UcdOther: PUcdTable;
{ UcdAssigned is the code points that have a General_Category other than Cn. }
function UcdAssigned: PUcdTable;
{ UcdUnknownScript is the code points that belong to no script. They are the unassigned, private use and surrogate
  code points. }
function UcdUnknownScript: PUcdTable;

{ UcdCategory returns the table of a General_Category value by its short name, such as 'Lu' or 'L'. It returns nil
  for any other name. }
function UcdCategory(const Name: UTF8String): PUcdTable;

{ UcdBinary returns the table of a binary property by its canonical name, such as 'Alphabetic' or 'White_Space'. It
  returns nil for any other name. ASCII and Any, which ECMA-262 adds to the properties of Unicode, are not here. }
function UcdBinary(const Name: UTF8String): PUcdTable;

{ UcdScript returns the table of a Script value by its long name or an alias, such as 'Greek' or 'Grek'. It returns
  nil for any other name. }
function UcdScript(const Name: UTF8String): PUcdTable;

{ UcdScriptExtensions returns the table of a Script_Extensions value by the long name of the script or an alias. It
  returns nil for any other name. }
function UcdScriptExtensions(const Name: UTF8String): PUcdTable;

{ UcdScriptNames returns the names of every script. Each element is the long name of one script followed by its
  aliases. The caller must not change it. }
function UcdScriptNames: TUcdNameLists;

{ UcdBinaryNames returns the canonical name of every binary property that has a table, which is every name
  UcdBinary knows but Assigned. The caller must not change it. }
function UcdBinaryNames: TUcdNames;

{ UcdFold returns the simple case folding of a code point (the C and S rows of CaseFolding.txt), which is the code
  point itself when it has none. Two code points are equal ignoring case when UcdFold gives the same result for
  both. }
function UcdFold(R: Int32): Int32;

{ UcdToUpper returns the simple uppercase mapping of a code point, which is the code point itself when it has
  none. }
function UcdToUpper(R: Int32): Int32;

{ UcdAppendFolding appends every code point that UcdFold changes, in ascending order. }
procedure UcdAppendFolding(var Dst: TUcdRunes);

{ UcdFoldByTable and UcdToUpperByTable are UcdFold and UcdToUpper without their path for ASCII. The tests compare
  the two paths. }
function UcdFoldByTable(R: Int32): Int32;
function UcdToUpperByTable(R: Int32): Int32;

implementation

uses
  SyncObjs,
  Corvus.Ecma262.RegularExpressions.Ucd13,
  Corvus.Ecma262.RegularExpressions.Ucd17,
  Corvus.Ecma262.RegularExpressions.Ucd18;

type
  TInt64Array = array of Int64;

const
  { The tables that are built from others follow the generated ones in the tables of a version. }
  DerivedLetter = 0;
  DerivedCasedLetter = 1;
  DerivedMark = 2;
  DerivedNumber = 3;
  DerivedPunctuation = 4;
  DerivedSymbol = 5;
  DerivedSeparator = 6;
  DerivedOther = 7;
  DerivedAssigned = 8;
  DerivedUnknownScript = 9;
  { The Script value Katakana_Or_Hiragana (Hrkt). PropertyValueAliases.txt lists the value, and no code point has it,
    in Script or in Script_Extensions. Scripts.txt has no line for it, so the generated tables do not have it. }
  DerivedKatakanaOrHiragana = 10;
  DerivedCount = 11;

function TUcdTable.Contains(R: Int32): Boolean;
var
  C: UInt32;
  Lo, Hi, Mid: Int32;
begin
  C := UInt32(R);
  if C <= $FFFF then begin
    Lo := 0;
    Hi := Length(R16) div 2;
    while Lo < Hi do begin
      Mid := (Lo + Hi) shr 1;
      if C > R16[2 * Mid + 1] then
        Lo := Mid + 1
      else if C < R16[2 * Mid] then
        Hi := Mid
      else
        Exit(True);
    end;
    Exit(False);
  end;
  Lo := 0;
  Hi := Length(R32) div 2;
  while Lo < Hi do begin
    Mid := (Lo + Hi) shr 1;
    if C > R32[2 * Mid + 1] then
      Lo := Mid + 1
    else if C < R32[2 * Mid] then
      Hi := Mid
    else
      Exit(True);
  end;
  Result := False;
end;

procedure TUcdTable.AppendRanges(var Dst: TUcdRunes);
var
  At, I, From: Int32;
  Joined: Boolean;
begin
  At := Length(Dst);
  // A range that crosses U+FFFF is stored in two parts.
  Joined := (Length(R16) > 0) and (Length(R32) > 0) and (R16[High(R16)] = $FFFF) and (R32[0] = $10000);
  if Joined then
    SetLength(Dst, At + Length(R16) + Length(R32) - 2)
  else
    SetLength(Dst, At + Length(R16) + Length(R32));
  for I := 0 to High(R16) do begin
    Dst[At] := R16[I];
    Inc(At);
  end;
  From := 0;
  if Joined then begin
    Dst[At - 1] := Int32(R32[1]);
    From := 2;
  end;
  for I := From to High(R32) do begin
    Dst[At] := Int32(R32[I]);
    Inc(At);
  end;
end;

{ NewTable builds a table from inclusive pairs in ascending order that neither overlap nor touch. }
function NewTable(const Pairs: TUcdRunes): TUcdTable;
var
  I, N16, N32, Lo, Hi: Int32;
begin
  SetLength(Result.R16, Length(Pairs) + 2);
  SetLength(Result.R32, Length(Pairs) + 2);
  N16 := 0;
  N32 := 0;
  I := 0;
  while I < Length(Pairs) do begin
    Lo := Pairs[I];
    Hi := Pairs[I + 1];
    if Hi <= $FFFF then begin
      Result.R16[N16] := UInt16(Lo);
      Result.R16[N16 + 1] := UInt16(Hi);
      Inc(N16, 2);
    end else if Lo > $FFFF then begin
      Result.R32[N32] := UInt32(Lo);
      Result.R32[N32 + 1] := UInt32(Hi);
      Inc(N32, 2);
    end else begin
      Result.R16[N16] := UInt16(Lo);
      Result.R16[N16 + 1] := $FFFF;
      Inc(N16, 2);
      Result.R32[N32] := $10000;
      Result.R32[N32 + 1] := UInt32(Hi);
      Inc(N32, 2);
    end;
    Inc(I, 2);
  end;
  SetLength(Result.R16, N16);
  SetLength(Result.R32, N32);
end;

{ SortInt64 sorts the elements Lo to Hi of an array into ascending order. }
procedure SortInt64(var A: TInt64Array; Lo, Hi: Int32);
var
  I, J: Int32;
  Pivot, Swap: Int64;
begin
  while Lo < Hi do begin
    I := Lo;
    J := Hi;
    Pivot := A[Lo + (Hi - Lo) div 2];
    repeat
      while A[I] < Pivot do
        Inc(I);
      while A[J] > Pivot do
        Dec(J);
      if I <= J then begin
        Swap := A[I];
        A[I] := A[J];
        A[J] := Swap;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    // The smaller part is sorted by a call and the larger by the loop, so the depth of the calls stays small.
    if J - Lo < Hi - I then begin
      SortInt64(A, Lo, J);
      Lo := I;
    end else begin
      SortInt64(A, I, Hi);
      Hi := J;
    end;
  end;
end;

function UcdUnion(const Tables: array of PUcdTable): TUcdTable;
var
  All, Merged: TUcdRunes;
  Order: TInt64Array;
  I, N, M, Lo, Hi: Int32;
begin
  All := nil;
  for I := 0 to High(Tables) do
    Tables[I]^.AppendRanges(All);
  N := Length(All) div 2;
  // The ranges are sorted by their first code point. A range is one number here, its first code point above its
  // last, so that sorting the numbers sorts the ranges.
  SetLength(Order, N);
  for I := 0 to N - 1 do
    Order[I] := (Int64(All[2 * I]) shl 32) or Int64(All[2 * I + 1]);
  SortInt64(Order, 0, N - 1);
  SetLength(Merged, Length(All));
  M := 0;
  for I := 0 to N - 1 do begin
    Lo := Int32(Order[I] shr 32);
    Hi := Int32(Order[I] and $FFFFFFFF);
    if (M > 0) and (Lo <= Merged[M - 1] + 1) then begin
      if Hi > Merged[M - 1] then
        Merged[M - 1] := Hi;
      Continue;
    end;
    Merged[M] := Lo;
    Merged[M + 1] := Hi;
    Inc(M, 2);
  end;
  SetLength(Merged, M);
  Result := NewTable(Merged);
end;

{ Complement builds the table of the code points that the table does not hold. }
function Complement(const T: TUcdTable): TUcdTable;
var
  Pairs, Inverse: TUcdRunes;
  I, N, Next: Int32;
begin
  Pairs := nil;
  T.AppendRanges(Pairs);
  SetLength(Inverse, Length(Pairs) + 2);
  N := 0;
  Next := 0;
  I := 0;
  while I < Length(Pairs) do begin
    if Pairs[I] > Next then begin
      Inverse[N] := Next;
      Inverse[N + 1] := Pairs[I] - 1;
      Inc(N, 2);
    end;
    Next := Pairs[I + 1] + 1;
    Inc(I, 2);
  end;
  if Next <= UcdMaxRune then begin
    Inverse[N] := Next;
    Inverse[N + 1] := UcdMaxRune;
    Inc(N, 2);
  end;
  SetLength(Inverse, N);
  Result := NewTable(Inverse);
end;

procedure UcdCopyNames(const Source: array of UTF8String; out Dest: TUcdNames);
var
  I: Int32;
begin
  SetLength(Dest, Length(Source));
  for I := 0 to High(Source) do
    Dest[I] := Source[I];
end;

procedure UcdCopyLookup(const Names: array of UTF8String; const Tables: array of Int32; out Dest: TUcdLookup);
var
  I: Int32;
begin
  UcdCopyNames(Names, Dest.Names);
  SetLength(Dest.Tables, Length(Tables));
  for I := 0 to High(Tables) do
    Dest.Tables[I] := Tables[I];
end;

procedure UcdCopyCases(const Source: array of TUcdCaseRange; out Dest: TUcdCaseRanges);
var
  I: Int32;
begin
  SetLength(Dest, Length(Source));
  for I := 0 to High(Source) do
    Dest[I] := Source[I];
end;

{ TUcd }

constructor TUcd.Create(const Data: TUcdData);
begin
  inherited Create;
  FData := Data;
  FGenerated := Length(FData.Tables);
  FMajor := 0;
  while (FMajor < Length(FData.Version)) and (FData.Version[FMajor + 1] <> '.') do
    Inc(FMajor);
  Val(Copy(FData.Version, 1, FMajor), FMajor);
  SetLength(FData.Tables, FGenerated + DerivedCount);
  FData.Tables[FGenerated + DerivedLetter] :=
    UcdUnion([Category('Lu'), Category('Ll'), Category('Lt'), Category('Lm'), Category('Lo')]);
  FData.Tables[FGenerated + DerivedCasedLetter] := UcdUnion([Category('Lu'), Category('Ll'), Category('Lt')]);
  FData.Tables[FGenerated + DerivedMark] := UcdUnion([Category('Mn'), Category('Mc'), Category('Me')]);
  FData.Tables[FGenerated + DerivedNumber] := UcdUnion([Category('Nd'), Category('Nl'), Category('No')]);
  FData.Tables[FGenerated + DerivedPunctuation] := UcdUnion([Category('Pc'), Category('Pd'), Category('Ps'),
    Category('Pe'), Category('Pi'), Category('Pf'), Category('Po')]);
  FData.Tables[FGenerated + DerivedSymbol] :=
    UcdUnion([Category('Sm'), Category('Sc'), Category('Sk'), Category('So')]);
  FData.Tables[FGenerated + DerivedSeparator] := UcdUnion([Category('Zs'), Category('Zl'), Category('Zp')]);
  FData.Tables[FGenerated + DerivedOther] :=
    UcdUnion([Category('Cc'), Category('Cf'), Category('Cs'), Category('Co'), Category('Cn')]);
  FData.Tables[FGenerated + DerivedAssigned] := Complement(Category('Cn')^);
  FData.Tables[FGenerated + DerivedUnknownScript] := UcdUnion([Category('Cn'), Category('Co'), Category('Cs')]);
end;

function TUcd.Version: UTF8String;
begin
  Result := FData.Version;
end;

function TUcd.Derived(K: Int32): PUcdTable;
begin
  Result := @FData.Tables[FGenerated + K];
end;

function TUcd.Letter: PUcdTable;
begin
  Result := Derived(DerivedLetter);
end;

function TUcd.CasedLetter: PUcdTable;
begin
  Result := Derived(DerivedCasedLetter);
end;

function TUcd.Mark: PUcdTable;
begin
  Result := Derived(DerivedMark);
end;

function TUcd.Number: PUcdTable;
begin
  Result := Derived(DerivedNumber);
end;

function TUcd.Punctuation: PUcdTable;
begin
  Result := Derived(DerivedPunctuation);
end;

function TUcd.Symbol: PUcdTable;
begin
  Result := Derived(DerivedSymbol);
end;

function TUcd.Separator: PUcdTable;
begin
  Result := Derived(DerivedSeparator);
end;

function TUcd.Other: PUcdTable;
begin
  Result := Derived(DerivedOther);
end;

function TUcd.Assigned: PUcdTable;
begin
  Result := Derived(DerivedAssigned);
end;

function TUcd.UnknownScript: PUcdTable;
begin
  Result := Derived(DerivedUnknownScript);
end;

{ FindTable searches the names of a lookup in ordinal order for a name, and returns the table of the same position,
  or nil when the name is not there. This is what a match over the names is in the crate. }
function TUcd.FindTable(const Lookup: TUcdLookup; const Name: UTF8String): PUcdTable;
var
  Lo, Hi, Mid: Int32;
begin
  Lo := 0;
  Hi := Length(Lookup.Names);
  while Lo < Hi do begin
    Mid := (Lo + Hi) shr 1;
    if Lookup.Names[Mid] < Name then
      Lo := Mid + 1
    else if Lookup.Names[Mid] > Name then
      Hi := Mid
    else
      Exit(@FData.Tables[Lookup.Tables[Mid]]);
  end;
  Result := nil;
end;

function TUcd.Category(const Name: UTF8String): PUcdTable;
begin
  if Name = 'L' then
    Exit(Letter);
  if Name = 'LC' then
    Exit(CasedLetter);
  if Name = 'M' then
    Exit(Mark);
  if Name = 'N' then
    Exit(Number);
  if Name = 'P' then
    Exit(Punctuation);
  if Name = 'S' then
    Exit(Symbol);
  if Name = 'Z' then
    Exit(Separator);
  if Name = 'C' then
    Exit(Other);
  Result := FindTable(FData.Category, Name);
end;

function TUcd.Binary(const Name: UTF8String): PUcdTable;
begin
  if Name = 'Assigned' then
    Exit(Assigned);
  Result := FindTable(FData.Binary, Name);
end;

function TUcd.Script(const Name: UTF8String): PUcdTable;
begin
  if (Name = 'Unknown') or (Name = 'Zzzz') then
    Exit(UnknownScript);
  if (Name = 'Katakana_Or_Hiragana') or (Name = 'Hrkt') then
    Exit(Derived(DerivedKatakanaOrHiragana));
  Result := FindTable(FData.Script, Name);
end;

function TUcd.ScriptExtensions(const Name: UTF8String): PUcdTable;
begin
  if (Name = 'Unknown') or (Name = 'Zzzz') then
    Exit(UnknownScript);
  if (Name = 'Katakana_Or_Hiragana') or (Name = 'Hrkt') then
    Exit(Derived(DerivedKatakanaOrHiragana));
  Result := FindTable(FData.ScriptExtensions, Name);
end;

function TUcd.ScriptNames: TUcdNameLists;
begin
  Result := FData.ScriptNameLists;
end;

function TUcd.BinaryNames: TUcdNames;
begin
  Result := FData.BinaryNames;
end;

function MapCase(const Table: array of TUcdCaseRange; R: Int32): Int32;
var
  Lo, Hi, Mid, Offset: Int32;
begin
  Lo := 0;
  Hi := Length(Table);
  while Lo < Hi do begin
    Mid := (Lo + Hi) shr 1;
    if R < Table[Mid].First then
      Hi := Mid
    else begin
      Offset := R - Table[Mid].First;
      if Offset >= Table[Mid].Length then
        Lo := Mid + 1
      else if (Offset and Table[Mid].Mask) = 0 then
        Exit(R + Table[Mid].Delta)
      else
        Exit(R);
    end;
  end;
  Result := R;
end;

function TUcd.Fold(R: Int32): Int32;
begin
  if R < $80 then begin
    if (R >= Ord('A')) and (R <= Ord('Z')) then
      Exit(R + (Ord('a') - Ord('A')));
    Exit(R);
  end;
  Result := MapCase(FData.CaseFolds, R);
end;

function TUcd.ToUpper(R: Int32): Int32;
begin
  if R < $80 then begin
    if (R >= Ord('a')) and (R <= Ord('z')) then
      Exit(R - (Ord('a') - Ord('A')));
    Exit(R);
  end;
  Result := MapCase(FData.UpperCases, R);
end;

function TUcd.FoldByTable(R: Int32): Int32;
begin
  Result := MapCase(FData.CaseFolds, R);
end;

function TUcd.ToUpperByTable(R: Int32): Int32;
begin
  Result := MapCase(FData.UpperCases, R);
end;

procedure TUcd.AppendFolding(var Dst: TUcdRunes);
var
  I, N, Offset: Int32;
begin
  N := Length(Dst);
  for I := 0 to High(FData.CaseFolds) do
    if FData.CaseFolds[I].Delta <> 0 then
      for Offset := 0 to Int32(FData.CaseFolds[I].Length) - 1 do
        if (Offset and FData.CaseFolds[I].Mask) = 0 then begin
          if N = Length(Dst) then
            SetLength(Dst, 2 * N + 64);
          Dst[N] := FData.CaseFolds[I].First + Offset;
          Inc(N);
        end;
  SetLength(Dst, N);
end;

var
  { The versions: the default made when the unit is initialised, the others nil until a thread has made them. They
    hold a TUcd. }
  V13Slot, V17Slot, V18Slot: Pointer;
  { MakeLock is held while a version is made: the unit of a version fills its data through a variable of its own, so
    two threads must not fill one version at once. }
  MakeLock: TCriticalSection;

{ Made makes the version of the major number, unless a thread has made it first, and returns the one in use. }
function Made(var Slot: Pointer; Major: Int32): TUcd;
var
  Data: TUcdData;
begin
  MakeLock.Enter;
  try
    Result := TUcd(Slot);
    if Result <> nil then
      Exit;
    case Major of
      13: FillUcd13(Data);
      18: FillUcd18(Data);
    else
      FillUcd17(Data);
    end;
    Result := TUcd.Create(Data);
    // The version is whole before another thread can read the slot without the lock. The slot is nil here, so the
    // exchange always takes place, and it is a full barrier.
    InterlockedCompareExchangePointer(Slot, Pointer(Result), nil);
  finally
    MakeLock.Leave;
  end;
end;

function UcdV13: TUcd;
begin
  Result := TUcd(V13Slot);
  if Result = nil then
    Result := Made(V13Slot, 13);
end;

function UcdV17: TUcd;
begin
  Result := TUcd(V17Slot);
end;

function UcdV18: TUcd;
begin
  Result := TUcd(V18Slot);
  if Result = nil then
    Result := Made(V18Slot, 18);
end;

function UcdByMajor(Major: Int32): TUcd;
begin
  case Major of
    13: Result := UcdV13;
    18: Result := UcdV18;
  else
    Result := UcdV17;
  end;
end;

function UcdMade(Major: Int32): TUcd;
begin
  case Major of
    13: Result := TUcd(V13Slot);
    17: Result := TUcd(V17Slot);
    18: Result := TUcd(V18Slot);
  else
    Result := nil;
  end;
end;

function UcdVersion: UTF8String;
begin
  Result := UcdV17.Version;
end;

function UcdLetter: PUcdTable;
begin
  Result := UcdV17.Letter;
end;

function UcdCasedLetter: PUcdTable;
begin
  Result := UcdV17.CasedLetter;
end;

function UcdMark: PUcdTable;
begin
  Result := UcdV17.Mark;
end;

function UcdNumber: PUcdTable;
begin
  Result := UcdV17.Number;
end;

function UcdPunctuation: PUcdTable;
begin
  Result := UcdV17.Punctuation;
end;

function UcdSymbol: PUcdTable;
begin
  Result := UcdV17.Symbol;
end;

function UcdSeparator: PUcdTable;
begin
  Result := UcdV17.Separator;
end;

function UcdOther: PUcdTable;
begin
  Result := UcdV17.Other;
end;

function UcdAssigned: PUcdTable;
begin
  Result := UcdV17.Assigned;
end;

function UcdUnknownScript: PUcdTable;
begin
  Result := UcdV17.UnknownScript;
end;

function UcdCategory(const Name: UTF8String): PUcdTable;
begin
  Result := UcdV17.Category(Name);
end;

function UcdBinary(const Name: UTF8String): PUcdTable;
begin
  Result := UcdV17.Binary(Name);
end;

function UcdScript(const Name: UTF8String): PUcdTable;
begin
  Result := UcdV17.Script(Name);
end;

function UcdScriptExtensions(const Name: UTF8String): PUcdTable;
begin
  Result := UcdV17.ScriptExtensions(Name);
end;

function UcdScriptNames: TUcdNameLists;
begin
  Result := UcdV17.ScriptNames;
end;

function UcdBinaryNames: TUcdNames;
begin
  Result := UcdV17.BinaryNames;
end;

function UcdFold(R: Int32): Int32;
begin
  Result := UcdV17.Fold(R);
end;

function UcdToUpper(R: Int32): Int32;
begin
  Result := UcdV17.ToUpper(R);
end;

function UcdFoldByTable(R: Int32): Int32;
begin
  Result := UcdV17.FoldByTable(R);
end;

function UcdToUpperByTable(R: Int32): Int32;
begin
  Result := UcdV17.ToUpperByTable(R);
end;

procedure UcdAppendFolding(var Dst: TUcdRunes);
begin
  UcdV17.AppendFolding(Dst);
end;

initialization
  MakeLock := TCriticalSection.Create;
  Made(V17Slot, 17);

finalization
  TUcd(V13Slot).Free;
  TUcd(V17Slot).Free;
  TUcd(V18Slot).Free;
  MakeLock.Free;
end.