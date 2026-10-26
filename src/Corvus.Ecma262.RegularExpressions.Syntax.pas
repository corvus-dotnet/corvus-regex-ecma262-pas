unit Corvus.Ecma262.RegularExpressions.Syntax;
{$I ecma262.inc}

{ The parser: a pattern to its syntax tree, in either grammar, with the limits of size (parse.rs of the Rust crate).

  The nodes of a tree belong to a TNodeArena, which frees them all at once. A tree is read once and compiled, and
  the compiler adds the nodes it makes to the same arena. }

interface

uses
  SysUtils,
  Corvus.Ecma262.RegularExpressions.Ucd,
  Corvus.Ecma262.RegularExpressions.CharSet,
  Corvus.Ecma262.RegularExpressions.Errors;

const
  { The max of a quantifier with no upper bound. }
  Unbounded = -1;
  { What a byte that is not UTF-8 decodes to. }
  RuneError = $FFFD;
  { Caps the bounds of a counted quantifier. No text that fits in memory reaches a larger count. }
  MaxCount = High(Int32);

  { The limits on the size of one pattern. A pattern may come from outside, so reading and compiling one must take
    bounded time and memory whatever it holds. A pattern over a limit is refused with an EEcmaRegexTooLarge, which is
    not the error of a pattern that is not valid. }

  { MaxPatternLength is the longest pattern that is read, in bytes of UTF-8. }
  MaxPatternLength = 1 shl 20;
  { MaxNesting is the deepest groups nest, which bounds the recursion of the parser and of the compilers. }
  MaxNesting = 1000;
  { MaxSize is the largest size a pattern may have, in the bytes the parser counts for it: NodeSize for each node of
    its syntax tree, and RangeSize for each range of a class as its members are read, for each range a case
    insensitive group or a negated property adds, for each alternative that encloses a named group and for each
    group that shares its name. The tree, the program compiled from it and the time to make both are proportional to
    that size, so it bounds them all: a pattern at the limit takes a few milliseconds and a few megabytes. }
  MaxSize = 1 shl 20;
  NodeSize = 32;
  RangeSize = 8;

type
  TNodeKind = (nkEmpty, nkChar, nkSet, nkCat, nkAlt, nkGroup, nkRepeat, nkBol, nkEol,
    { ^ and $ inside a group with the m modifier. }
    nkLineStart, nkLineEnd, nkWordBoundary, nkNotWordBoundary, nkLook, nkBackref);

  TNode = class;
  TNodes = array of TNode;
  TInts = array of Int32;

  { A TNode is one element of the syntax tree of a pattern. }
  TNode = class
  public
    Kind: TNodeKind;
    { The code point of an nkChar. }
    R: Int32;
    { The class of an nkSet. }
    CharSet: TCharSet;
    { The children of nkCat and nkAlt, and the one child of nkGroup, nkRepeat and nkLook. }
    Subs: TNodes;
    { Min, Max and Lazy describe an nkRepeat. }
    Min: Int32;
    Max: Int32;
    Lazy: Boolean;
    { The number of the capturing group of an nkGroup, counted from 1; 0 for a group that does not capture. }
    Group: Int32;
    { The groups an nkBackref names. A name can belong to several groups in separate alternatives, of which at most
      one has taken part at any time. }
    Groups: TInts;
    { The group name of a named backreference until it is resolved. }
    Name: TRunes;
    { Marks an nkBackref, nkWordBoundary or nkNotWordBoundary inside a case-insensitive group. }
    Fold: Boolean;
    { Behind and Negative describe an nkLook. }
    Behind: Boolean;
    Negative: Boolean;
  end;

  { A TNodeArena owns the nodes of trees, and frees them when it is freed. }
  TNodeArena = class
  private
    FNodes: TNodes;
    FCount: NativeInt;
  public
    destructor Destroy; override;
    { Node makes a node of the kind. }
    function Node(Kind: TNodeKind): TNode;
    function WithSubs(Kind: TNodeKind; const Subs: array of TNode): TNode;
    function CharNode(R: Int32): TNode;
    function SetNode(const CharSet: TCharSet): TNode;
    function RepeatNode(Atom: TNode; Min, Max: Int32; Lazy: Boolean): TNode;
    { Clone is a deep copy of a tree. A class is immutable, so the copy shares it. }
    function Clone(N: TNode): TNode;
  end;

  { A TGroupName is a group name with the groups that have it. }
  TGroupName = record
    Name: TRunes;
    Groups: TInts;
  end;
  TGroupNames = array of TGroupName;

  { A TSyntax is the grammar a pattern is read with and the flags that change what its atoms mean. Unicode is the
    grammar of the u flag (without it, the Annex B grammar of a pattern with no u or v flag); Sets is the grammar of
    the v flag inside a class, and the properties of strings, and comes with Unicode; ICase, Multiline and DotAll are
    the i, m and s flags: the modifiers in force at the start of the pattern. }
  TSyntax = record
    Unicode: Boolean;
    Sets: Boolean;
    ICase: Boolean;
    Multiline: Boolean;
    DotAll: Boolean;
  end;

  { A TParsed is what reading a pattern gives: its tree, the number of its capturing groups, their names, and whether
    it has a construct only the backtracking matcher can run. }
  TParsed = record
    Root: TNode;
    GroupCount: Int32;
    Names: TGroupNames;
    NeedsBacktracking: Boolean;
  end;

{ ParseWith reads the pattern, whose nodes go to the arena. It raises an ESyntax for a pattern that is not valid under
  the chosen grammar, and an EEcmaRegexTooLarge for a pattern over a limit of size, which it stops reading at the
  limit. The pattern must be UTF-8. }
function ParseWith(const Pattern: UTF8String; const Sx: TSyntax; Arena: TNodeArena): TParsed;

{ DecodeUtf8 reads UTF-8 into code points. It reports false for bytes that are not UTF-8. }
function DecodeUtf8(const S: UTF8String; out Runes: TRunes): Boolean;

{ LiteralRune reports whether a code point can be matched by comparing its UTF-8 bytes. A surrogate has no encoding,
  and U+FFFD is also what a malformed byte of the text decodes to. }
function LiteralRune(R: Int32): Boolean;

{ RuneLen is the number of bytes of UTF-8 a code point takes. }
function RuneLen(R: Int32): Int32;

{ Nullable reports whether N can match without consuming anything. It errs towards true. }
function Nullable(N: TNode): Boolean;

{ HighSurrogate and LowSurrogate are the two UTF-16 code units of a code point beyond the Basic Multilingual Plane. }
function HighSurrogate(C: Int32): Int32; inline;
function LowSurrogate(C: Int32): Int32; inline;

implementation

type
  { A TBranch names one alternative of one disjunction. }
  TBranch = record
    Disjunction: Int32;
    Alternative: Int32;
  end;
  TBranches = array of TBranch;

  { A TNamedGroup is a capturing group with a name, and the alternatives that enclose it. }
  TNamedGroup = record
    Group: Int32;
    Path: TBranches;
  end;

  { A TNameEntry is a group name with every group that has it. }
  TNameEntry = record
    Name: TRunes;
    Hash: UInt32;
    Groups: array of TNamedGroup;
  end;

  { A TClassSetValue is the value of a class of the v flag's grammar: its code points, its strings (each of a length
    other than one, the empty string among them), and whether its syntax may hold a string. }
  TClassSetValue = record
    CharSet: TCharSet;
    Strings: TRuneLists;
    MayContainStrings: Boolean;
  end;

  { A TParser reads a pattern by recursive descent. With Unicode set it applies the grammar of the u flag. Without it,
    it applies the Annex B grammar of patterns with no flag. }
  TParser = class
  public
    { The pattern as code points with the u flag, and as UTF-16 code units without it (see CodeUnits). }
    P: TRunes;
    { The 0-based position in P. }
    I: Int32;
    Unicode: Boolean;
    { The grammar of the v flag. }
    Sets: Boolean;
    { The sequences of the property of strings the last class escape named (the v flag), when HasEscapeStrings. }
    EscapeStrings: TRuneLists;
    HasEscapeStrings: Boolean;
    Depth: Int32;
    { GroupCount and HasNames come from a scan of the whole pattern before parsing, because the meaning of \1 and \k
      depends on groups that may follow them. }
    GroupCount: Int32;
    HasNames: Boolean;
    Groups: Int32;
    { The groups of each name, in the order the names were first read, and a table of their positions by hash. }
    Names: array of TNameEntry;
    NameCount: Int32;
    NameSlots: TInts;
    NamedRefs: Boolean;
    { The alternatives that enclose the current position, innermost last. }
    Path: TBranches;
    PathLen: Int32;
    Disjunctions: Int32;
    { The modifiers in force, which only a group such as (?i:...) changes. }
    ICase: Boolean;
    Multiline: Boolean;
    DotAll: Boolean;
    { Records that the pattern has a construct only the backtracking matcher can run. }
    NeedsBacktracking: Boolean;
    { The size of what has been read so far (see MaxSize). }
    Size: Int32;
    Arena: TNodeArena;

    procedure Fail(const Msg: string);
    procedure Charge(Bytes: Int64);
    function At(K: Int32): Int32; inline;
    function More: Boolean; inline;
    function Peek: Int32; inline;
    function Eat(C: AnsiChar): Boolean;
    procedure ScanGroups;
    procedure Resolve(N: TNode);
    function FindName(const Name: TRunes): Int32;
    function AddName(const Name: TRunes): Int32;
    function GroupNames: TGroupNames;
    procedure PushPath(Disjunction: Int32);
    function Disjunction: TNode;
    function Alternative: TNode;
    function CharNodeOf(C: Int32): TNode;
    function SetNodeOf(const CharSet: TCharSet): TNode;
    function FoldSet(const CharSet: TCharSet): TCharSet;
    function FoldIf(const CharSet: TCharSet): TCharSet;
    function Term: TNode;
    function LooksLikeQuantifier: Boolean;
    function Number: Int32;
    function Quantifier(out Lo, Hi: Int32; out Lazy: Boolean): Boolean;
    function Group(out Quantifiable: Boolean): TNode;
    function ModifierGroup: TNode;
    function Capture(const Name: TRunes; HasName: Boolean): TNode;
    procedure Close;
    function GroupName: TRunes;
    function AtomEscape(out Quantifiable: Boolean): TNode;
    function LegacyOctal: Int32;
    function ClassEscape(C: Int32; out CharSet: TCharSet): Boolean;
    function Hex(N: Int32): Int32;
    function CharacterEscape(InClass: Boolean): Int32;
    function UnicodeEscape(UnicodeMode: Boolean): Int32;
    function ClassNode: TNode;
    function ClassAtom(out CharSet: TCharSet; out IsSet: Boolean): Int32;
    function ClassSetExpression: TNode;
    function ClassSetContents: TClassSetValue;
    function SetOperator: Int32;
    function ClassSetElement(out IsRange: Boolean): TClassSetValue;
    function ClassSetCharacter: Int32;
    function ClassStringDisjunction: TClassSetValue;
    function StringsValue(const CharSet: TCharSet; const Strs: TRuneLists): TClassSetValue;
    function CanonicalString(const CodePoints: TRunes): TRunes;
    function ClassNodeOf(const Value: TClassSetValue; Negated: Boolean): TNode;
  end;

var
  IdStart, IdContinue: PUcdTable;

{ TNodeArena }

destructor TNodeArena.Destroy;
var
  K: NativeInt;
begin
  for K := 0 to FCount - 1 do
    FNodes[K].Free;
  inherited;
end;

function TNodeArena.Node(Kind: TNodeKind): TNode;
begin
  if FCount = Length(FNodes) then
    SetLength(FNodes, 2 * FCount + 64);
  Result := TNode.Create;
  Result.Kind := Kind;
  FNodes[FCount] := Result;
  Inc(FCount);
end;

function TNodeArena.WithSubs(Kind: TNodeKind; const Subs: array of TNode): TNode;
var
  K: Int32;
begin
  Result := Node(Kind);
  SetLength(Result.Subs, Length(Subs));
  for K := 0 to High(Subs) do
    Result.Subs[K] := Subs[K];
end;

function TNodeArena.CharNode(R: Int32): TNode;
begin
  Result := Node(nkChar);
  Result.R := R;
end;

function TNodeArena.SetNode(const CharSet: TCharSet): TNode;
begin
  Result := Node(nkSet);
  Result.CharSet := CharSet;
end;

function TNodeArena.RepeatNode(Atom: TNode; Min, Max: Int32; Lazy: Boolean): TNode;
begin
  Result := WithSubs(nkRepeat, [Atom]);
  Result.Min := Min;
  Result.Max := Max;
  Result.Lazy := Lazy;
end;

function TNodeArena.Clone(N: TNode): TNode;
var
  K: Int32;
begin
  Result := Node(N.Kind);
  Result.R := N.R;
  Result.CharSet := N.CharSet;
  SetLength(Result.Subs, Length(N.Subs));
  for K := 0 to High(N.Subs) do
    Result.Subs[K] := Clone(N.Subs[K]);
  Result.Min := N.Min;
  Result.Max := N.Max;
  Result.Lazy := N.Lazy;
  Result.Group := N.Group;
  Result.Groups := Copy(N.Groups);
  Result.Name := Copy(N.Name);
  Result.Fold := N.Fold;
  Result.Behind := N.Behind;
  Result.Negative := N.Negative;
end;

{ Text }

function LiteralRune(R: Int32): Boolean;
begin
  Result := (R >= 0) and (R <= $10FFFF) and not ((R >= $D800) and (R <= $DFFF)) and (R <> RuneError);
end;

function RuneLen(R: Int32): Int32;
begin
  if R <= $7F then
    Result := 1
  else if R <= $7FF then
    Result := 2
  else if R <= $FFFF then
    Result := 3
  else
    Result := 4;
end;

function Nullable(N: TNode): Boolean;
var
  K: Int32;
begin
  case N.Kind of
    nkChar, nkSet: Exit(False);
    nkCat: begin
      for K := 0 to High(N.Subs) do
        if not Nullable(N.Subs[K]) then
          Exit(False);
      Exit(True);
    end;
    nkAlt: begin
      for K := 0 to High(N.Subs) do
        if Nullable(N.Subs[K]) then
          Exit(True);
      Exit(False);
    end;
    nkGroup: Exit(Nullable(N.Subs[0]));
    nkRepeat: Exit((N.Min = 0) or Nullable(N.Subs[0]));
  end;
  Result := True;
end;

function HighSurrogate(C: Int32): Int32;
begin
  Result := $D800 + ((C - $10000) shr 10);
end;

function LowSurrogate(C: Int32): Int32;
begin
  Result := $DC00 + ((C - $10000) and $3FF);
end;

function DecodeUtf8(const S: UTF8String; out Runes: TRunes): Boolean;
var
  I, N, Len, C, Need, Lo, Hi: Int32;
  B: Byte;
begin
  Len := Length(S);
  SetLength(Runes, Len);
  N := 0;
  I := 1;
  while I <= Len do begin
    B := Byte(S[I]);
    if B < $80 then begin
      Runes[N] := B;
      Inc(N);
      Inc(I);
      Continue;
    end;
    Lo := $80;
    Hi := $BF;
    case B of
      $C2..$DF: begin Need := 1; C := B and $1F; end;
      $E0: begin Need := 2; C := B and $0F; Lo := $A0; end;
      $E1..$EC, $EE..$EF: begin Need := 2; C := B and $0F; end;
      $ED: begin Need := 2; C := B and $0F; Hi := $9F; end;
      $F0: begin Need := 3; C := B and $07; Lo := $90; end;
      $F1..$F3: begin Need := 3; C := B and $07; end;
      $F4: begin Need := 3; C := B and $07; Hi := $8F; end;
    else
      Exit(False);
    end;
    if I + Need > Len then
      Exit(False);
    B := Byte(S[I + 1]);
    if (B < Lo) or (B > Hi) then
      Exit(False);
    C := (C shl 6) or (B and $3F);
    if Need >= 2 then begin
      B := Byte(S[I + 2]);
      if (B and $C0) <> $80 then
        Exit(False);
      C := (C shl 6) or (B and $3F);
    end;
    if Need = 3 then begin
      B := Byte(S[I + 3]);
      if (B and $C0) <> $80 then
        Exit(False);
      C := (C shl 6) or (B and $3F);
    end;
    Runes[N] := C;
    Inc(N);
    Inc(I, Need + 1);
  end;
  SetLength(Runes, N);
  Result := True;
end;

{ CodeUnits returns the UTF-16 code units of a pattern. Without the u flag ECMA-262 reads a pattern, and matches a
  text, a code unit at a time. A character beyond the Basic Multilingual Plane is then two atoms, a quantifier after
  it repeats the second, and in a class it is two members, so a range between two such characters runs from a low
  surrogate to a high one and is an error. }
function CodeUnits(const P: TRunes): TRunes;
var
  K, N, Wide: Int32;
begin
  Wide := 0;
  for K := 0 to High(P) do
    if P[K] > $FFFF then
      Inc(Wide);
  if Wide = 0 then
    Exit(P);
  SetLength(Result, Length(P) + Wide);
  N := 0;
  for K := 0 to High(P) do
    if P[K] > $FFFF then begin
      Result[N] := HighSurrogate(P[K]);
      Result[N + 1] := LowSurrogate(P[K]);
      Inc(N, 2);
    end else begin
      Result[N] := P[K];
      Inc(N);
    end;
end;

function IsDigit(C: Int32): Boolean; inline;
begin
  Result := (C >= Ord('0')) and (C <= Ord('9'));
end;

function Isc(C: Int32; Ch: AnsiChar): Boolean; inline;
begin
  Result := C = Ord(Ch);
end;

{ GreaterAsWritten reports whether the first of two runs of decimal digits is the greater number. The runs are
  compared as written, because a count has no limit of size in the grammar and Number stops at MaxCount. }
function GreaterAsWritten(const P: TRunes; AFrom, ATo, BFrom, BTo: Int32): Boolean;
var
  K: Int32;
begin
  while (AFrom < ATo) and (P[AFrom] = Ord('0')) do
    Inc(AFrom);
  while (BFrom < BTo) and (P[BFrom] = Ord('0')) do
    Inc(BFrom);
  if ATo - AFrom <> BTo - BFrom then
    Exit(ATo - AFrom > BTo - BFrom);
  for K := 0 to ATo - AFrom - 1 do
    if P[AFrom + K] <> P[BFrom + K] then
      Exit(P[AFrom + K] > P[BFrom + K]);
  Result := False;
end;

{ SeparateAlternatives reports whether two positions lie in different alternatives of some disjunction. }
function SeparateAlternatives(const A: TBranches; const B: TBranches; BLen: Int32): Boolean;
var
  K, N: Int32;
begin
  N := Length(A);
  if BLen < N then
    N := BLen;
  for K := 0 to N - 1 do begin
    if A[K].Disjunction <> B[K].Disjunction then
      Break;
    if A[K].Alternative <> B[K].Alternative then
      Exit(True);
  end;
  Result := False;
end;

function HexValue(C: Int32): Int32;
begin
  if (C >= Ord('0')) and (C <= Ord('9')) then
    Exit(C - Ord('0'));
  if (C >= Ord('a')) and (C <= Ord('f')) then
    Exit(C - Ord('a') + 10);
  if (C >= Ord('A')) and (C <= Ord('F')) then
    Exit(C - Ord('A') + 10);
  Result := -1;
end;

function IsAsciiLetter(C: Int32): Boolean;
begin
  Result := ((C >= Ord('a')) and (C <= Ord('z'))) or ((C >= Ord('A')) and (C <= Ord('Z')));
end;

{ InAscii reports whether C is one of the ASCII characters of Chars. }
function InAscii(C: Int32; const Chars: AnsiString): Boolean;
var
  K: Int32;
begin
  if (C < 0) or (C >= $80) then
    Exit(False);
  for K := 1 to Length(Chars) do
    if Ord(Chars[K]) = C then
      Exit(True);
  Result := False;
end;

{ SyntaxCharacter reports whether C is one of the characters the u flag lets an identity escape name. }
function SyntaxCharacter(C: Int32): Boolean;
begin
  Result := InAscii(C, '^$\.*+?()[]{}|/');
end;

procedure AppendPair(var Pairs: TRunes; var N: Int32; Lo, Hi: Int32); inline;
begin
  if N + 2 > Length(Pairs) then
    SetLength(Pairs, 2 * N + 16);
  Pairs[N] := Lo;
  Pairs[N + 1] := Hi;
  Inc(N, 2);
end;

procedure AppendClassAtom(var Pairs: TRunes; var N: Int32; C: Int32; const CharSet: TCharSet; IsSet: Boolean);
var
  K: Int32;
begin
  if not IsSet then begin
    AppendPair(Pairs, N, C, C);
    Exit;
  end;
  K := 0;
  while K < Length(CharSet.Ranges) do begin
    AppendPair(Pairs, N, CharSet.Ranges[K], CharSet.Ranges[K + 1]);
    Inc(K, 2);
  end;
end;

function SameRunes(const A, B: TRunes): Boolean;
var
  K: Int32;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for K := 0 to High(A) do
    if A[K] <> B[K] then
      Exit(False);
  Result := True;
end;

function HasString(const List: TRuneLists; const S: TRunes): Boolean;
var
  K: Int32;
begin
  for K := 0 to High(List) do
    if SameRunes(List[K], S) then
      Exit(True);
  Result := False;
end;

procedure AddString(var List: TRuneLists; const S: TRunes);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := S;
end;

function RunesHash(const R: TRunes): UInt32;
var
  K: Int32;
begin
  // FNV-1a, which wraps on purpose.
  Result := 2166136261;
  for K := 0 to High(R) do
    Result := UInt32((UInt64(Result xor UInt32(R[K])) * 16777619) and $FFFFFFFF);
end;

function RunesText(const R: TRunes; From, Count: Int32): UTF8String;
var
  K: Int32;
begin
  // A name ECMA-262 defines is ASCII. Any other character makes a name no table has.
  SetLength(Result, Count);
  for K := 0 to Count - 1 do
    if (R[From + K] >= 1) and (R[From + K] < $80) then
      Result[K + 1] := AnsiChar(R[From + K])
    else
      Result[K + 1] := #0;
end;

function EmptyValue: TClassSetValue;
begin
  Result.CharSet := NewCharSet([]);
  Result.Strings := nil;
  Result.MayContainStrings := False;
end;

function ValueOf(const CharSet: TCharSet): TClassSetValue;
begin
  Result.CharSet := CharSet;
  Result.Strings := nil;
  Result.MayContainStrings := False;
end;

function UnionValues(const A, B: TClassSetValue): TClassSetValue;
var
  K: Int32;
begin
  Result.Strings := Copy(A.Strings);
  for K := 0 to High(B.Strings) do
    if not HasString(Result.Strings, B.Strings[K]) then
      AddString(Result.Strings, B.Strings[K]);
  Result.CharSet := UnionSets(A.CharSet, B.CharSet);
  Result.MayContainStrings := A.MayContainStrings or B.MayContainStrings;
end;

function IntersectValues(const A, B: TClassSetValue): TClassSetValue;
var
  K: Int32;
begin
  Result.Strings := nil;
  for K := 0 to High(A.Strings) do
    if HasString(B.Strings, A.Strings[K]) then
      AddString(Result.Strings, A.Strings[K]);
  Result.CharSet := IntersectSets(A.CharSet, B.CharSet);
  Result.MayContainStrings := A.MayContainStrings and B.MayContainStrings;
end;

function SubtractValues(const A, B: TClassSetValue): TClassSetValue;
var
  K: Int32;
begin
  Result.Strings := nil;
  for K := 0 to High(A.Strings) do
    if not HasString(B.Strings, A.Strings[K]) then
      AddString(Result.Strings, A.Strings[K]);
  Result.CharSet := SubtractSets(A.CharSet, B.CharSet);
  Result.MayContainStrings := A.MayContainStrings;
end;

{ TParser }

function TParser.At(K: Int32): Int32;
begin
  Result := P[K];
end;

function TParser.More: Boolean;
begin
  Result := I < Length(P);
end;

function TParser.Peek: Int32;
begin
  if I < Length(P) then
    Result := P[I]
  else
    Result := -1;
end;

function TParser.Eat(C: AnsiChar): Boolean;
begin
  if (I < Length(P)) and (P[I] = Ord(C)) then begin
    Inc(I);
    Exit(True);
  end;
  Result := False;
end;

procedure TParser.Fail(const Msg: string);
begin
  raise ESyntax.Create(Msg, I);
end;

procedure TParser.Charge(Bytes: Int64);
begin
  if Int64(Size) + Bytes > MaxSize then
    raise EEcmaRegexTooLarge.Create(elSize, MaxSize);
  Inc(Size, Int32(Bytes));
end;

procedure TParser.PushPath(Disjunction: Int32);
begin
  if PathLen = Length(Path) then
    SetLength(Path, 2 * PathLen + 8);
  Path[PathLen].Disjunction := Disjunction;
  Path[PathLen].Alternative := 0;
  Inc(PathLen);
end;

function TParser.FindName(const Name: TRunes): Int32;
var
  H: UInt32;
  Mask, Slot: Int32;
begin
  if Length(NameSlots) = 0 then
    Exit(-1);
  H := RunesHash(Name);
  Mask := High(NameSlots);
  Slot := Int32(H and UInt32(Mask));
  while NameSlots[Slot] >= 0 do begin
    if (Names[NameSlots[Slot]].Hash = H) and SameRunes(Names[NameSlots[Slot]].Name, Name) then
      Exit(NameSlots[Slot]);
    Slot := (Slot + 1) and Mask;
  end;
  Result := -1;
end;

function TParser.AddName(const Name: TRunes): Int32;
var
  K, Slot, Mask: Int32;
begin
  if 2 * (NameCount + 1) > Length(NameSlots) then begin
    // The table is kept at most half full, and made again twice as large. Its length is a power of two, so that a
    // probe masked by it visits every slot.
    if Length(NameSlots) = 0 then
      SetLength(NameSlots, 16)
    else
      SetLength(NameSlots, 2 * Length(NameSlots));
    for K := 0 to High(NameSlots) do
      NameSlots[K] := -1;
    Mask := High(NameSlots);
    for K := 0 to NameCount - 1 do begin
      Slot := Int32(Names[K].Hash and UInt32(Mask));
      while NameSlots[Slot] >= 0 do
        Slot := (Slot + 1) and Mask;
      NameSlots[Slot] := K;
    end;
  end;
  if NameCount = Length(Names) then
    SetLength(Names, 2 * NameCount + 8);
  Names[NameCount].Name := Name;
  Names[NameCount].Hash := RunesHash(Name);
  Names[NameCount].Groups := nil;
  Mask := High(NameSlots);
  Slot := Int32(Names[NameCount].Hash and UInt32(Mask));
  while NameSlots[Slot] >= 0 do
    Slot := (Slot + 1) and Mask;
  NameSlots[Slot] := NameCount;
  Result := NameCount;
  Inc(NameCount);
end;

function TParser.GroupNames: TGroupNames;
var
  K, J: Int32;
begin
  // The names are in the order they were first read, which is the order of their first groups.
  SetLength(Result, NameCount);
  for K := 0 to NameCount - 1 do begin
    Result[K].Name := Names[K].Name;
    SetLength(Result[K].Groups, Length(Names[K].Groups));
    for J := 0 to High(Names[K].Groups) do
      Result[K].Groups[J] := Names[K].Groups[J].Group;
  end;
end;

{ Resolve gives every named backreference the groups of its name. A name no group has is an error. }
procedure TParser.Resolve(N: TNode);
var
  K, E: Int32;
begin
  if (N.Kind = nkBackref) and (Length(N.Name) > 0) then begin
    E := FindName(N.Name);
    if E < 0 then
      Fail('reference to an unknown group name');
    SetLength(N.Groups, Length(Names[E].Groups));
    for K := 0 to High(Names[E].Groups) do
      N.Groups[K] := Names[E].Groups[K].Group;
  end;
  for K := 0 to High(N.Subs) do
    Resolve(N.Subs[K]);
end;

{ ScanGroups counts the capturing groups of the pattern and notes whether any is named. }
procedure TParser.ScanGroups;
var
  InClass: Boolean;
  K, C: Int32;
begin
  InClass := False;
  K := 0;
  while K < Length(P) do begin
    C := P[K];
    if C = Ord('\') then
      Inc(K)
    else if C = Ord('[') then
      InClass := True
    else if C = Ord(']') then
      InClass := False
    else if (C = Ord('(')) and not InClass then begin
      if (K + 1 >= Length(P)) or (P[K + 1] <> Ord('?')) then
        Inc(GroupCount)
      else if (K + 3 < Length(P)) and (P[K + 2] = Ord('<')) and (P[K + 3] <> Ord('=')) and
        (P[K + 3] <> Ord('!')) then begin
        Inc(GroupCount);
        HasNames := True;
      end;
    end;
    Inc(K);
  end;
end;

function TParser.Disjunction: TNode;
var
  Last: Int32;
  First: TNode;
  Alts: TNodes;
  N: Int32;
begin
  Inc(Depth);
  if Depth > MaxNesting then
    raise EEcmaRegexTooLarge.Create(elNesting, MaxNesting);
  Inc(Disjunctions);
  PushPath(Disjunctions);
  Last := PathLen - 1;
  First := Alternative;
  if not Isc(Peek, '|') then begin
    PathLen := Last;
    Dec(Depth);
    Exit(First);
  end;
  SetLength(Alts, 4);
  Alts[0] := First;
  N := 1;
  while Eat('|') do begin
    Charge(NodeSize);
    Inc(Path[Last].Alternative);
    if N = Length(Alts) then
      SetLength(Alts, 2 * N);
    Alts[N] := Alternative;
    Inc(N);
  end;
  SetLength(Alts, N);
  Result := Arena.Node(nkAlt);
  Result.Subs := Alts;
  PathLen := Last;
  Dec(Depth);
end;

function TParser.Alternative: TNode;
var
  Terms: TNodes;
  N: Int32;
begin
  Terms := nil;
  N := 0;
  while More and not Isc(Peek, '|') and not Isc(Peek, ')') do begin
    if N = Length(Terms) then
      SetLength(Terms, 2 * N + 4);
    Terms[N] := Term;
    Inc(N);
  end;
  if N = 0 then
    Exit(Arena.Node(nkEmpty));
  if N = 1 then
    Exit(Terms[0]);
  SetLength(Terms, N);
  Result := Arena.Node(nkCat);
  Result.Subs := Terms;
end;

{ CharNodeOf is the node for one literal character. Inside a case-insensitive group that is the class of the
  characters equivalent to it. }
function TParser.CharNodeOf(C: Int32): TNode;
var
  CharSet: TCharSet;
  Variants: Int32;
begin
  if ICase then begin
    CharSet := FoldClosure(NewCharSet([C, C]), Unicode, Variants);
    if (Length(CharSet.Ranges) <> 2) or (CharSet.Ranges[0] <> CharSet.Ranges[1]) then
      Exit(Arena.SetNode(CharSet));
  end;
  Result := Arena.CharNode(C);
end;

{ SetNodeOf is the node for a class. Inside a case-insensitive group the class also takes every character equivalent
  to one of its members. }
function TParser.SetNodeOf(const CharSet: TCharSet): TNode;
begin
  if ICase then
    Result := Arena.SetNode(FoldSet(CharSet))
  else
    Result := Arena.SetNode(CharSet);
end;

{ FoldSet is the set with every character equivalent to one of its members. It charges the pattern for the work and
  for the set: a byte for each character with a case variant that the set holds, and its ranges. }
function TParser.FoldSet(const CharSet: TCharSet): TCharSet;
var
  Variants: Int32;
begin
  Result := FoldClosure(CharSet, Unicode, Variants);
  Charge(Int64(Variants) + Int64(RangeSize) * (Length(Result.Ranges) div 2));
end;

{ FoldIf is the set with every character equivalent to one of its members, inside a case-insensitive group, and the
  set itself outside one. }
function TParser.FoldIf(const CharSet: TCharSet): TCharSet;
begin
  if ICase then
    Result := FoldSet(CharSet)
  else
    Result := CharSet;
end;

function TParser.Term: TNode;
var
  C, Lo, Hi: Int32;
  Quantifiable, Lazy: Boolean;
  Atom: TNode;
begin
  // The atom, and the repetition or the group around it.
  Charge(2 * NodeSize);
  C := Peek;
  Quantifiable := True;
  if Isc(C, '^') then begin
    Inc(I);
    Quantifiable := False;
    if Multiline then begin
      NeedsBacktracking := True;
      Atom := Arena.Node(nkLineStart);
    end else
      Atom := Arena.Node(nkBol);
  end else if Isc(C, '$') then begin
    Inc(I);
    Quantifiable := False;
    if Multiline then begin
      NeedsBacktracking := True;
      Atom := Arena.Node(nkLineEnd);
    end else
      Atom := Arena.Node(nkEol);
  end else if Isc(C, '(') then
    Atom := Group(Quantifiable)
  else if Isc(C, '.') then begin
    Inc(I);
    if DotAll then
      Atom := Arena.SetNode(AnySet)
    else
      Atom := Arena.SetNode(DotSet);
  end else if Isc(C, '[') then
    Atom := ClassNode
  else if Isc(C, '\') then
    Atom := AtomEscape(Quantifiable)
  else if Isc(C, '*') or Isc(C, '+') or Isc(C, '?') then begin
    Fail('nothing to repeat');
    Atom := nil;
  end else if Isc(C, '{') then begin
    if Unicode or LooksLikeQuantifier then
      Fail('nothing to repeat');
    Inc(I);
    Atom := CharNodeOf(Ord('{'));
  end else if Isc(C, ']') or Isc(C, '}') then begin
    if Unicode then
      Fail('lone bracket');
    Inc(I);
    Atom := CharNodeOf(C);
  end else begin
    Inc(I);
    Atom := CharNodeOf(C);
  end;
  if not Quantifier(Lo, Hi, Lazy) then
    Exit(Atom);
  if not Quantifiable then
    Fail('nothing to repeat');
  Result := Arena.RepeatNode(Atom, Lo, Hi, Lazy);
end;

(* LooksLikeQuantifier reports whether the text at the current { reads as {n}, {n,} or {n,m}. *)
function TParser.LooksLikeQuantifier: Boolean;
var
  N, K, Start: Int32;
begin
  N := Length(P);
  K := I + 1;
  Start := K;
  while (K < N) and IsDigit(P[K]) do
    Inc(K);
  if (K = Start) or (K >= N) then
    Exit(False);
  if Isc(P[K], '}') then
    Exit(True);
  if not Isc(P[K], ',') then
    Exit(False);
  Inc(K);
  while (K < N) and IsDigit(P[K]) do
    Inc(K);
  Result := (K < N) and Isc(P[K], '}');
end;

{ Number reads a run of decimal digits, saturating at MaxCount. }
function TParser.Number: Int32;
var
  Start: Int32;
  V: Int64;
begin
  Start := I;
  V := 0;
  while (I < Length(P)) and IsDigit(P[I]) do begin
    if V < MaxCount then begin
      V := V * 10 + (P[I] - Ord('0'));
      if V > MaxCount then
        V := MaxCount;
    end;
    Inc(I);
  end;
  if Start = I then
    Fail('expected a number');
  Result := Int32(V);
end;

{ Quantifier reads a quantifier, when one is here: its bounds, and whether it is lazy. It reports false when there is
  none. }
function TParser.Quantifier(out Lo, Hi: Int32; out Lazy: Boolean): Boolean;
var
  C, First, FirstEnd, Second: Int32;
begin
  C := Peek;
  Lo := 0;
  Hi := 0;
  Lazy := False;
  if Isc(C, '*') then begin
    Inc(I);
    Lo := 0;
    Hi := Unbounded;
  end else if Isc(C, '+') then begin
    Inc(I);
    Lo := 1;
    Hi := Unbounded;
  end else if Isc(C, '?') then begin
    Inc(I);
    Lo := 0;
    Hi := 1;
  end else if Isc(C, '{') and LooksLikeQuantifier then begin
    Inc(I);
    First := I;
    Lo := Number;
    Hi := Lo;
    FirstEnd := I;
    if Eat(',') then begin
      if Isc(Peek, '}') then
        Hi := Unbounded
      else begin
        Second := I;
        Hi := Number;
        // Both counts stop at MaxCount, so the numbers are compared as they are written.
        if GreaterAsWritten(P, First, FirstEnd, Second, I) then
          Fail('numbers out of order in quantifier');
      end;
    end;
    if not Eat('}') then
      Fail('malformed quantifier');
  end else
    Exit(False);
  Lazy := Eat('?');
  Result := True;
end;

{ Group reads a group or a lookaround, and whether a quantifier may follow it. }
function TParser.Group(out Quantifiable: Boolean): TNode;
var
  C, E: Int32;
  Negative: Boolean;
  Body: TNode;
  Name: TRunes;
begin
  Inc(I);
  Quantifiable := True;
  if not Eat('?') then
    Exit(Capture(nil, False));
  if Eat(':') then begin
    Body := Disjunction;
    Close;
    Exit(Arena.WithSubs(nkGroup, [Body]));
  end;
  C := Peek;
  if Isc(C, 'i') or Isc(C, 'm') or Isc(C, 's') or Isc(C, '-') then
    Exit(ModifierGroup);
  if Eat('=') or Eat('!') then begin
    Negative := Isc(At(I - 1), '!');
    Body := Disjunction;
    Close;
    NeedsBacktracking := True;
    // Annex B lets a quantifier follow a lookahead. The u flag does not.
    Quantifiable := not Unicode;
    Result := Arena.WithSubs(nkLook, [Body]);
    Result.Negative := Negative;
    Exit;
  end;
  if Eat('<') then begin
    if Eat('=') or Eat('!') then begin
      Negative := Isc(At(I - 1), '!');
      Body := Disjunction;
      Close;
      NeedsBacktracking := True;
      Quantifiable := False;
      Result := Arena.WithSubs(nkLook, [Body]);
      Result.Negative := Negative;
      Result.Behind := True;
      Exit;
    end;
    Name := GroupName;
    // Two groups may share a name only when they are in separate alternatives of one disjunction, so that no match
    // can go through both.
    E := FindName(Name);
    if E >= 0 then
      for C := 0 to High(Names[E].Groups) do
        if not SeparateAlternatives(Names[E].Groups[C].Path, Path, PathLen) then
          Fail('duplicate group name');
    Exit(Capture(Name, True));
  end;
  Fail('invalid group');
  Result := nil;
end;

{ ModifierGroup reads a group that turns modifiers on or off for its body, such as (?i:...) or (?s-i:...). The
  position is after the (?. }
function TParser.ModifierGroup: TNode;
var
  SavedICase, SavedMultiline, SavedDotAll, Removing: Boolean;
  Seen: array[1..3] of Boolean;
  Count, C, Flag: Int32;
  Body: TNode;
begin
  SavedICase := ICase;
  SavedMultiline := Multiline;
  SavedDotAll := DotAll;
  Seen[1] := False;
  Seen[2] := False;
  Seen[3] := False;
  Removing := False;
  Count := 0;
  while not Eat(':') do begin
    C := Peek;
    Inc(I);
    if Isc(C, 'i') then begin
      Flag := 1;
      ICase := not Removing;
    end else if Isc(C, 'm') then begin
      Flag := 2;
      Multiline := not Removing;
    end else if Isc(C, 's') then begin
      Flag := 3;
      DotAll := not Removing;
    end else if Isc(C, '-') then begin
      if Removing then
        Fail('invalid group modifier');
      Removing := True;
      Continue;
    end else begin
      Fail('invalid group modifier');
      Flag := 0;
    end;
    if Seen[Flag] then
      Fail('repeated group modifier');
    Seen[Flag] := True;
    Inc(Count);
  end;
  if Count = 0 then
    Fail('invalid group modifier');
  Body := Disjunction;
  Close;
  ICase := SavedICase;
  Multiline := SavedMultiline;
  DotAll := SavedDotAll;
  Result := Arena.WithSubs(nkGroup, [Body]);
end;

function TParser.Capture(const Name: TRunes; HasName: Boolean): TNode;
var
  G, E, K: Int32;
  Body: TNode;
begin
  Inc(Groups);
  G := Groups;
  if HasName then begin
    // The path is kept, and every group of the same name is compared with it.
    E := FindName(Name);
    if E < 0 then
      E := AddName(Name);
    Charge(Int64(RangeSize) * (PathLen + Length(Names[E].Groups)));
    K := Length(Names[E].Groups);
    SetLength(Names[E].Groups, K + 1);
    Names[E].Groups[K].Group := G;
    Names[E].Groups[K].Path := Copy(Path, 0, PathLen);
  end;
  Body := Disjunction;
  Close;
  Result := Arena.WithSubs(nkGroup, [Body]);
  Result.Group := G;
end;

procedure TParser.Close;
begin
  if not Eat(')') then
    Fail('unterminated group');
end;

{ GroupName reads a group name up to and including its >. A character of the name may be written as a \u escape. }
function TParser.GroupName: TRunes;
var
  N, C: Int32;
begin
  Result := nil;
  N := 0;
  while not Eat('>') do begin
    if not More then
      Fail('invalid group name');
    C := Peek;
    Inc(I);
    if Isc(C, '\') then begin
      if not Eat('u') then
        Fail('invalid group name');
      C := UnicodeEscape(True);
      if C < 0 then
        Fail('invalid group name');
    end else if (C >= $D800) and (C <= $DBFF) and (Peek >= $DC00) and (Peek <= $DFFF) then begin
      // Without the u flag the pattern is code units, and a name still takes a surrogate pair as one character.
      C := $10000 + ((C - $D800) shl 10) + (Peek - $DC00);
      Inc(I);
    end;
    if N = 0 then begin
      if not (Isc(C, '$') or Isc(C, '_') or IdStart^.Contains(C)) then
        Fail('invalid group name');
    end else if not (Isc(C, '$') or (C = $200C) or (C = $200D) or IdContinue^.Contains(C)) then
      Fail('invalid group name');
    SetLength(Result, N + 1);
    Result[N] := C;
    Inc(N);
  end;
  if N = 0 then
    Fail('invalid group name');
end;

{ AtomEscape reads an escape outside a class, and whether a quantifier may follow it. }
function TParser.AtomEscape(out Quantifiable: Boolean): TNode;
var
  C, Start, N: Int32;
  Name: TRunes;
  CharSet: TCharSet;
begin
  Inc(I);
  Quantifiable := True;
  if not More then
    Fail('\ at end of pattern');
  C := Peek;
  if Isc(C, 'b') or Isc(C, 'B') then begin
    Inc(I);
    Quantifiable := False;
    if Isc(C, 'B') then
      Result := Arena.Node(nkNotWordBoundary)
    else
      Result := Arena.Node(nkWordBoundary);
    // With the u flag, a case-insensitive word boundary counts two more characters as word characters.
    if Unicode and ICase then begin
      Result.Fold := True;
      NeedsBacktracking := True;
    end;
    Exit;
  end;
  if Isc(C, 'k') then begin
    // Annex B reads \k as the letter k in a pattern with no named group.
    if Unicode or HasNames then begin
      Inc(I);
      if not Eat('<') then
        Fail('invalid named reference');
      Name := GroupName;
      NamedRefs := True;
      NeedsBacktracking := True;
      Result := Arena.Node(nkBackref);
      Result.Name := Name;
      Result.Fold := ICase;
      Exit;
    end;
    Inc(I);
    Exit(CharNodeOf(Ord('k')));
  end;
  if (C >= Ord('1')) and (C <= Ord('9')) then begin
    Start := I;
    N := Number;
    if N <= GroupCount then begin
      NeedsBacktracking := True;
      Result := Arena.Node(nkBackref);
      SetLength(Result.Groups, 1);
      Result.Groups[0] := N;
      Result.Fold := ICase;
      Exit;
    end;
    if Unicode then
      Fail('reference to a group that does not exist');
    // Annex B reads it as an octal escape, or as the digit itself.
    I := Start;
    Exit(CharNodeOf(LegacyOctal));
  end;
  if ClassEscape(C, CharSet) then begin
    if HasEscapeStrings then
      // A property of strings (the v flag): the class of its code points and its sequences.
      Exit(ClassNodeOf(StringsValue(FoldIf(CharSet), EscapeStrings), False));
    Exit(SetNodeOf(CharSet));
  end;
  Result := CharNodeOf(CharacterEscape(False));
end;

{ LegacyOctal reads an Annex B octal escape of up to three digits with a value below 256. A digit that cannot start
  one (8 or 9) stands for itself. }
function TParser.LegacyOctal: Int32;
var
  V, K, D: Int32;
begin
  V := 0;
  K := 0;
  while (K < 3) and More and (Peek >= Ord('0')) and (Peek <= Ord('7')) and (V * 8 + (Peek - Ord('0')) <= 255) do begin
    V := V * 8 + (Peek - Ord('0'));
    Inc(I);
    Inc(K);
  end;
  if K = 0 then begin
    D := Peek;
    Inc(I);
    Exit(D);
  end;
  Result := V;
end;

(* ClassEscape reads a class escape such as \d or \p{...} whose letter is C. It reports false, consuming nothing, when
  C does not start one. *)
function TParser.ClassEscape(C: Int32; out CharSet: TCharSet): Boolean;
var
  Start: Int32;
  Expr: UTF8String;
  Found: TCharSet;
  Prop: PStringProperty;
begin
  HasEscapeStrings := False;
  EscapeStrings := nil;
  if Isc(C, 'd') then
    CharSet := DigitSet
  else if Isc(C, 'D') then
    CharSet := NotDigitSet
  else if Isc(C, 'w') then begin
    if Unicode and ICase then
      CharSet := FoldWordSet
    else
      CharSet := WordSet;
  end else if Isc(C, 'W') then begin
    if Unicode and ICase then
      CharSet := NotFoldWordSet
    else
      CharSet := NotWordSet;
  end else if Isc(C, 's') then
    CharSet := SpaceSet
  else if Isc(C, 'S') then
    CharSet := NotSpaceSet
  else if Isc(C, 'p') or Isc(C, 'P') then begin
    // Without the u flag \p is the letter p.
    if not Unicode then
      Exit(False);
    Inc(I);
    if not Eat('{') then
      Fail('invalid property name');
    Start := I;
    while More and not Isc(Peek, '}') do
      Inc(I);
    Expr := RunesText(P, Start, I - Start);
    if not Eat('}') then
      Fail('invalid property name');
    if not PropertySet(Expr, Found) then begin
      if Sets and Isc(C, 'p') then begin
        Prop := StringPropertyOf(Expr);
        if Prop <> nil then begin
          // A property of strings, which the v flag alone names, and which has no complement.
          Charge(Int64(RangeSize) * (Length(Prop^.CharSet.Ranges) div 2 + Length(Prop^.Strings)));
          EscapeStrings := Prop^.Strings;
          HasEscapeStrings := True;
          CharSet := Prop^.CharSet;
          Exit(True);
        end;
      end;
      Fail('invalid property name');
    end;
    if Isc(C, 'P') then begin
      Charge(Int64(RangeSize) * (Length(Found.Ranges) div 2));
      // With the v flag the complement is of the case-folded set; with the u flag the fold comes after it.
      if Sets then
        Found := FoldIf(Found);
      CharSet := ComplementSet(Found);
      Exit(True);
    end;
    CharSet := Found;
    Exit(True);
  end else
    Exit(False);
  Inc(I);
  Result := True;
end;

{ Hex reads exactly N hexadecimal digits. It returns -1, consuming nothing, when they are not there. }
function TParser.Hex(N: Int32): Int32;
var
  K, D, V: Int32;
begin
  if I + N > Length(P) then
    Exit(-1);
  V := 0;
  for K := 0 to N - 1 do begin
    D := HexValue(P[I + K]);
    if D < 0 then
      Exit(-1);
    V := V * 16 + D;
  end;
  Inc(I, N);
  Result := V;
end;

{ CharacterEscape reads the escape after a backslash, in or out of a class, and returns the code point it names. }
function TParser.CharacterEscape(InClass: Boolean): Int32;
var
  C, L, H, U: Int32;
begin
  C := Peek;
  Inc(I);
  if Isc(C, 'f') then
    Exit($0C);
  if Isc(C, 'n') then
    Exit($0A);
  if Isc(C, 'r') then
    Exit($0D);
  if Isc(C, 't') then
    Exit($09);
  if Isc(C, 'v') then
    Exit($0B);
  if Isc(C, 'c') then begin
    L := Peek;
    if IsAsciiLetter(L) then begin
      Inc(I);
      Exit(L mod 32);
    end;
    if not Unicode and InClass and (IsDigit(L) or Isc(L, '_')) then begin
      Inc(I);
      Exit(L mod 32);
    end;
    if Unicode then
      Fail('invalid control escape');
    // Annex B reads a \c that is not a control escape as a backslash followed by the letter c.
    Dec(I);
    Exit(Ord('\'));
  end;
  if Isc(C, '0') then begin
    if More and IsDigit(Peek) then begin
      if Unicode then
        Fail('invalid decimal escape');
      Dec(I);
      Exit(LegacyOctal);
    end;
    Exit(0);
  end;
  if Isc(C, 'x') then begin
    H := Hex(2);
    if H < 0 then begin
      if Unicode then
        Fail('invalid \x escape');
      Exit(Ord('x'));
    end;
    Exit(H);
  end;
  if Isc(C, 'u') then begin
    U := UnicodeEscape(Unicode);
    if U < 0 then begin
      if Unicode then
        Fail('invalid \u escape');
      Exit(Ord('u'));
    end;
    Exit(U);
  end;
  if (C >= Ord('1')) and (C <= Ord('9')) and not Unicode and InClass then begin
    Dec(I);
    Exit(LegacyOctal);
  end;
  // Identity escapes. The u flag allows only the syntax characters and '/', and '-' in a class. Annex B allows any
  // character, except k in a pattern with a named group. Outside a class AtomEscape reads \k before this is reached,
  // so here the \k of such a pattern is in a class, where it is not a reference either.
  if Unicode and not SyntaxCharacter(C) and not (InClass and Isc(C, '-')) then
    Fail('invalid escape');
  if Isc(C, 'k') and HasNames then
    Fail('invalid escape');
  Result := C;
end;

(* UnicodeEscape reads what follows a \u and returns the code point, or -1, consuming nothing, when it is not a
  well-formed escape. With UnicodeMode set, as it is with the u flag and always in a group name, it accepts the
  \u{...} form and reads a surrogate pair written as two escapes as one code point. Without it each escape is one
  code unit. *)
function TParser.UnicodeEscape(UnicodeMode: Boolean): Int32;
var
  Start, Digits, U, Low, Save: Int32;
  V: Int64;
begin
  Start := I;
  if UnicodeMode and Eat('{') then begin
    Digits := I;
    V := 0;
    while More and (HexValue(Peek) >= 0) do begin
      if V <= MaxRune then
        V := V * 16 + HexValue(Peek);
      Inc(I);
    end;
    if (Digits = I) or not Eat('}') or (V > MaxRune) then begin
      I := Start;
      Exit(-1);
    end;
    Exit(Int32(V));
  end;
  U := Hex(4);
  if U < 0 then
    Exit(-1);
  if UnicodeMode and (U >= $D800) and (U <= $DBFF) and (I + 6 <= Length(P)) and Isc(P[I], '\') and
    Isc(P[I + 1], 'u') then begin
    Save := I;
    Inc(I, 2);
    Low := Hex(4);
    if (Low >= $DC00) and (Low <= $DFFF) then
      Exit($10000 + ((U - $D800) shl 10) + (Low - $DC00));
    I := Save;
  end;
  Result := U;
end;

{ ClassNode reads a character class from its [ to its ]. }
function TParser.ClassNode: TNode;
var
  Negated, FirstIsSet, SecondIsSet: Boolean;
  Pairs: TRunes;
  N, Charged, First, Second: Int32;
  FirstSet, SecondSet, CharSet: TCharSet;
begin
  if Sets then
    Exit(ClassSetExpression);
  Inc(I);
  Negated := Eat('^');
  Pairs := nil;
  N := 0;
  // The number of ranges read so far that the size of the pattern has been charged for.
  Charged := 0;
  while True do begin
    if not More then
      Fail('unterminated character class');
    if Eat(']') then
      Break;
    Charge(Int64(RangeSize) * (N div 2 - Charged));
    Charged := N div 2;
    First := ClassAtom(FirstSet, FirstIsSet);
    if Isc(Peek, '-') and (I + 1 < Length(P)) and not Isc(P[I + 1], ']') then begin
      Inc(I);
      Second := ClassAtom(SecondSet, SecondIsSet);
      if FirstIsSet or SecondIsSet then begin
        if Unicode then
          Fail('invalid character class range');
        // Annex B reads the '-' as itself when a class escape is at either end.
        AppendClassAtom(Pairs, N, First, FirstSet, FirstIsSet);
        AppendPair(Pairs, N, Ord('-'), Ord('-'));
        AppendClassAtom(Pairs, N, Second, SecondSet, SecondIsSet);
        Continue;
      end;
      if Second < First then
        Fail('range out of order in character class');
      AppendPair(Pairs, N, First, Second);
      Continue;
    end;
    AppendClassAtom(Pairs, N, First, FirstSet, FirstIsSet);
  end;
  // Inside a case-insensitive group a character matches the class when it is equivalent to a member, and a negated
  // class excludes exactly those characters.
  Charge(Int64(RangeSize) * (N div 2 - Charged));
  SetLength(Pairs, N);
  CharSet := NewCharSet(Pairs);
  if ICase then
    CharSet := FoldSet(CharSet);
  if Negated then
    CharSet := ComplementSet(CharSet);
  Result := Arena.SetNode(CharSet);
end;

{ ClassAtom reads one member of a class: a code point, or 0 and a set for a class escape. }
function TParser.ClassAtom(out CharSet: TCharSet; out IsSet: Boolean): Int32;
var
  C, E: Int32;
begin
  IsSet := False;
  C := Peek;
  Inc(I);
  if not Isc(C, '\') then
    Exit(C);
  if not More then
    Fail('\ at end of pattern');
  E := Peek;
  if Isc(E, 'b') then begin
    Inc(I);
    Exit($08);
  end;
  if ClassEscape(E, CharSet) then begin
    IsSet := True;
    Exit(0);
  end;
  Result := CharacterEscape(True);
end;

(* The v flag. Its grammar changes a class and nothing outside it. A class is read as a value of two parts, its code
  points and its strings (each of a length other than one, the empty string among them), with a flag for whether its
  syntax may hold a string, which ECMA-262's MayContainStrings decides from the syntax and not from what the strings
  turn out to be. A string of one character is a character of the class. The union, the intersection (&&) and the
  difference (--) act on both parts, strings compared whole. With the i flag each operand is case folded as it is
  read, so that the complement of a class, and of \P{...}, is of the folded set (with the u flag the fold comes after
  the complement). A class with strings is a group of an alternation: the strings longest first, each a sequence of
  characters, then the set. (This is the design of the .NET reference engine, section 3.2.) *)

{ ClassSetExpression reads a class of the v flag's grammar from its [ to its ]. }
function TParser.ClassSetExpression: TNode;
var
  Negated: Boolean;
  Start: Int32;
  Value: TClassSetValue;
begin
  Inc(I);
  Negated := Eat('^');
  Start := I;
  Value := ClassSetContents;
  if not Eat(']') then
    Fail('unterminated character class');
  if Negated and Value.MayContainStrings then begin
    I := Start;
    Fail('negated character class may contain strings');
  end;
  Result := ClassNodeOf(Value, Negated);
end;

{ ClassSetContents reads the contents of a class of the v flag's grammar, up to its ]. }
function TParser.ClassSetContents: TClassSetValue;
var
  Op: Int32;
  IsRange, OperandRange: Boolean;
  Operand: TClassSetValue;
begin
  if Isc(Peek, ']') then
    Exit(EmptyValue);
  Result := ClassSetElement(IsRange);
  Op := SetOperator;
  if Op <> 0 then begin
    // An intersection or a difference: operands only, with the one operator between every two.
    if IsRange then
      Fail('invalid set operation in character class');
    while SetOperator = Op do begin
      Inc(I, 2);
      if Isc(Peek, ']') or not More then
        Fail('invalid set operation in character class');
      Operand := ClassSetElement(OperandRange);
      if OperandRange then
        Fail('invalid set operation in character class');
      Charge(Int64(RangeSize) * ((Length(Result.CharSet.Ranges) + Length(Operand.CharSet.Ranges)) div 2));
      if Isc(Op, '&') then
        Result := IntersectValues(Result, Operand)
      else
        Result := SubtractValues(Result, Operand);
    end;
    if not Isc(Peek, ']') then
      Fail('invalid set operation in character class');
    Exit;
  end;
  // A union.
  while More and not Isc(Peek, ']') do begin
    if SetOperator <> 0 then
      Fail('invalid set operation in character class');
    Operand := ClassSetElement(OperandRange);
    Charge(Int64(RangeSize) * ((Length(Result.CharSet.Ranges) + Length(Operand.CharSet.Ranges)) div 2));
    Result := UnionValues(Result, Operand);
  end;
end;

{ SetOperator is the set operator at the position (& for &&, - for --), or 0. }
function TParser.SetOperator: Int32;
begin
  if (I + 1 < Length(P)) and (P[I] = P[I + 1]) and (Isc(P[I], '&') or Isc(P[I], '-')) then
    Exit(P[I]);
  Result := 0;
end;

{ ClassSetElement reads one element of a class of the v flag's grammar: an operand, or a range of two characters,
  which it reports in IsRange. }
function TParser.ClassSetElement(out IsRange: Boolean): TClassSetValue;
var
  C, E, Start, First, Second, Dash, Next: Int32;
  Negated, EscapeClass: Boolean;
  Inner: TClassSetValue;
  CharSet: TCharSet;
begin
  IsRange := False;
  Charge(NodeSize);
  C := Peek;
  if Isc(C, '[') then begin
    // A nested class: its strings count as strings whether or not there are any.
    Start := I;
    Inc(Depth);
    if Depth > MaxNesting then
      raise EEcmaRegexTooLarge.Create(elNesting, MaxNesting);
    Inc(I);
    Negated := Eat('^');
    Inner := ClassSetContents;
    if not Eat(']') then
      Fail('unterminated character class');
    Dec(Depth);
    if Negated then begin
      if Inner.MayContainStrings then begin
        I := Start;
        Fail('negated character class may contain strings');
      end;
      Exit(ValueOf(ComplementSet(Inner.CharSet)));
    end;
    Exit(Inner);
  end;
  if Isc(C, '\') then begin
    if I + 1 >= Length(P) then
      Fail('\ at end of pattern');
    E := P[I + 1];
    if Isc(E, 'q') then begin
      Inc(I, 2);
      Exit(ClassStringDisjunction);
    end;
    Inc(I);
    if ClassEscape(E, CharSet) then begin
      if HasEscapeStrings then
        Exit(StringsValue(FoldIf(CharSet), EscapeStrings));
      // A class escape is folded as one operand; \P is already the complement of a folded set.
      if not Isc(E, 'P') then
        CharSet := FoldIf(CharSet);
      Exit(ValueOf(CharSet));
    end;
    Dec(I);
  end;
  First := ClassSetCharacter;
  if Isc(Peek, '-') and (SetOperator = 0) then begin
    Dash := I;
    Inc(I);
    Next := Peek;
    EscapeClass := Isc(Next, '\') and (I + 1 < Length(P)) and InAscii(P[I + 1], 'qdDwWsSpP');
    if Isc(Next, ']') or Isc(Next, '[') or EscapeClass then begin
      I := Dash;
      Fail('invalid character class range');
    end;
    Second := ClassSetCharacter;
    if Second < First then begin
      I := Dash;
      Fail('range out of order in character class');
    end;
    IsRange := True;
    Exit(ValueOf(FoldIf(NewCharSet([First, Second]))));
  end;
  Result := ValueOf(FoldIf(NewCharSet([First, First])));
end;

{ ClassSetCharacter reads one character of a class of the v flag's grammar: a character that is not a syntax
  character and does not begin a reserved double punctuator, or an escape, which may be of a reserved punctuator. }
function TParser.ClassSetCharacter: Int32;
var
  C, E: Int32;
begin
  if not More then
    Fail('unterminated character class');
  C := P[I];
  if Isc(C, '\') then begin
    if I + 1 >= Length(P) then
      Fail('\ at end of pattern');
    E := P[I + 1];
    if Isc(E, 'b') then begin
      Inc(I, 2);
      Exit($08);
    end;
    if InAscii(E, '&-!#%,:;<=>@`~') then begin
      Inc(I, 2);
      Exit(E);
    end;
    Inc(I);
    Exit(CharacterEscape(True));
  end;
  if InAscii(C, '()[]{}/-\|') then
    Fail('invalid character in character class');
  if (I + 1 < Length(P)) and (P[I + 1] = C) and InAscii(C, '&!#$%*+,.:;<=>?@^`~') then
    Fail('invalid set operation in character class');
  Inc(I);
  Result := C;
end;

(* ClassStringDisjunction reads the strings of \q{...} after its \q. A string of one character is a character of the
  class. *)
function TParser.ClassStringDisjunction: TClassSetValue;
var
  Current, S: TRunes;
  N, C, Len: Int32;
begin
  if not Eat('{') then
    Fail('invalid escape');
  Current := nil;
  N := 0;
  Result := EmptyValue;
  while True do begin
    if not More then
      Fail('unterminated character class');
    C := Peek;
    if Isc(C, '|') or Isc(C, '}') then begin
      Inc(I);
      if N = 1 then
        Result.CharSet := UnionSets(Result.CharSet, FoldIf(NewCharSet([Current[0], Current[0]])))
      else begin
        Len := N;
        if Len < 1 then
          Len := 1;
        Charge(Int64(NodeSize) * Len);
        S := CanonicalString(Copy(Current, 0, N));
        if not HasString(Result.Strings, S) then
          AddString(Result.Strings, S);
        Result.MayContainStrings := True;
      end;
      N := 0;
      if Isc(C, '}') then
        Break;
      Continue;
    end;
    if N = Length(Current) then
      SetLength(Current, 2 * N + 8);
    Current[N] := ClassSetCharacter;
    Inc(N);
  end;
end;

{ StringsValue is the value of a property of strings: its code points, and its sequences (case folded in a
  case-insensitive group). }
function TParser.StringsValue(const CharSet: TCharSet; const Strs: TRuneLists): TClassSetValue;
var
  K: Int32;
begin
  Result.CharSet := CharSet;
  SetLength(Result.Strings, Length(Strs));
  for K := 0 to High(Strs) do
    Result.Strings[K] := CanonicalString(Strs[K]);
  Result.MayContainStrings := True;
end;

{ CanonicalString is a string as its code points, each canonicalized in a case-insensitive group so that strings are
  compared as ECMA-262 compares them. }
function TParser.CanonicalString(const CodePoints: TRunes): TRunes;
var
  K: Int32;
begin
  if not ICase then
    Exit(CodePoints);
  SetLength(Result, Length(CodePoints));
  for K := 0 to High(CodePoints) do
    Result[K] := Canonicalize(CodePoints[K], True);
end;

{ ClassNodeOf is the node of a class of the v flag's grammar: its set, or, where it holds strings, the alternatives of
  its strings longest first and then its set, as ECMA-262 orders them, in a group. }
function TParser.ClassNodeOf(const Value: TClassSetValue; Negated: Boolean): TNode;
var
  Order: TInts;
  Alternatives, Chars: TNodes;
  K, J, T, N: Int32;
  S: TRunes;
begin
  if Negated then
    Exit(Arena.SetNode(ComplementSet(Value.CharSet)));
  if Length(Value.Strings) = 0 then
    Exit(Arena.SetNode(Value.CharSet));
  // The strings longest first, those of one length in the order they were read: an insertion sort, which is stable.
  SetLength(Order, Length(Value.Strings));
  for K := 0 to High(Order) do begin
    J := K;
    while (J > 0) and (Length(Value.Strings[Order[J - 1]]) < Length(Value.Strings[K])) do begin
      Order[J] := Order[J - 1];
      Dec(J);
    end;
    Order[J] := K;
  end;
  SetLength(Alternatives, Length(Order) + 1);
  N := 0;
  for K := 0 to High(Order) do begin
    S := Value.Strings[Order[K]];
    Charge(Int64(NodeSize) * (Length(S) + 1));
    if Length(S) = 0 then begin
      Alternatives[N] := Arena.Node(nkEmpty);
      Inc(N);
      Continue;
    end;
    SetLength(Chars, Length(S));
    for T := 0 to High(S) do
      Chars[T] := CharNodeOf(S[T]);
    Alternatives[N] := Arena.WithSubs(nkCat, Chars);
    Inc(N);
  end;
  if not Value.CharSet.Empty then begin
    Alternatives[N] := Arena.SetNode(Value.CharSet);
    Inc(N);
  end;
  SetLength(Alternatives, N);
  Result := Arena.Node(nkAlt);
  Result.Subs := Alternatives;
  Result := Arena.WithSubs(nkGroup, [Result]);
end;

function ParseWith(const Pattern: UTF8String; const Sx: TSyntax; Arena: TNodeArena): TParsed;
var
  Ps: TParser;
  Runes: TRunes;
begin
  if Length(Pattern) > MaxPatternLength then
    raise EEcmaRegexTooLarge.Create(elLength, MaxPatternLength);
  if not DecodeUtf8(Pattern, Runes) then
    raise EEcmaRegexEncoding.Create('the pattern is not UTF-8');
  Ps := TParser.Create;
  try
    if Sx.Unicode then
      Ps.P := Runes
    else
      Ps.P := CodeUnits(Runes);
    Ps.Unicode := Sx.Unicode;
    Ps.Sets := Sx.Sets;
    Ps.ICase := Sx.ICase;
    Ps.Multiline := Sx.Multiline;
    Ps.DotAll := Sx.DotAll;
    Ps.Arena := Arena;
    Ps.ScanGroups;
    Result.Root := Ps.Disjunction;
    if Ps.I < Length(Ps.P) then begin
      if Ps.At(Ps.I) = Ord(')') then
        Ps.Fail('unmatched '')''');
      Ps.Fail('unexpected character');
    end;
    if Ps.NamedRefs then
      Ps.Resolve(Result.Root);
    Result.GroupCount := Ps.Groups;
    Result.Names := Ps.GroupNames;
    Result.NeedsBacktracking := Ps.NeedsBacktracking;
  finally
    Ps.Free;
  end;
end;

initialization
  IdStart := MustBinaryTable('ID_Start');
  IdContinue := MustBinaryTable('ID_Continue');
end.
