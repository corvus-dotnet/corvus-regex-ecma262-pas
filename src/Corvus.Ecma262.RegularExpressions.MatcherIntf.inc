{ The interface of the matcher of one encoding. Corvus.Ecma262.RegularExpressions.Utf8 and .Utf16 each include it
  after they declare TUnit (the code unit: a byte, or a UTF-16 code unit) and PUnit. }

type
  { A TText is the units of a text: Len of them from P. Every read of a unit compares its position with Len first,
    and raises ERangeError outside the text. }
  TText = record
    P: PUnit;
    Len: NativeInt;
  end;

  { A TUnitBuffer is units written one after another: the first Count of Data. }
  TUnitBuffer = record
    Data: array of TUnit;
    Count: NativeInt;
    procedure Add(U: TUnit); inline;
    procedure AddRun(P: PUnit; N: NativeInt);
  end;

{ MakeText is the text of N units from P. }
function MakeText(P: PUnit; N: NativeInt): TText; inline;

{ ExecProg finds the first match of a program at or after Start (at Start alone with Sticky), and reports where it
  starts and ends. With Slots given (not nil) it also writes the start and end of each group the program records,
  from Slots[2], or -1 for a group that did not take part. With a limit (in nanoseconds) the match is abandoned when
  it has run for longer than that, or when its stack has reached MaxStack, and the error says which. }
function ExecProg(Prog: TProgram; const T: TText; Start: NativeInt; Sticky: Boolean; Limit: Int64;
  Slots: PNativeInt; out From, To_: NativeInt): Boolean;

{ ExecSearch finds the first match at or after Start (at Start alone with Sticky) with the search's limit. With
  Slots given (2 * (Groups + 1) of them) it writes the start and end of the match and of each group, -1 for a group
  that did not take part. Start is moved off the middle of a character first, as RegExpBuiltinExec moves it. }
function ExecSearch(const S: TSearch; const T: TText; Start: NativeInt; Sticky: Boolean; Slots: PNativeInt;
  out From, To_: NativeInt): Boolean;

{ NextStart is the position a global search goes on from after a match From..To_. }
function NextStart(const S: TSearch; const T: TText; From, To_: NativeInt): NativeInt;

{ CountAll is the number of matches of a global search. }
function CountAll(const S: TSearch; const T: TText): NativeInt;

{ ReplaceUnits writes the text with the first match, or every match with All, replaced by the template, as
  String.prototype.replace does, with the template's $ forms ($$, $&, $`, $', $n, $nn and $<name>) replaced. At most
  Count matches are replaced (all when Count is below 0). It reports false, and writes nothing, when there is no
  match. }
function ReplaceUnits(const S: TSearch; const T, Template: TText; All: Boolean; Count: NativeInt;
  var Out_: TUnitBuffer): Boolean;

{ SplitUnits is the text split around the matches (RegExp.prototype[Symbol.split]), as spans (From, To_), (-1, -1)
  for a group that did not take part, with at most Limit items (all when Limit is below 0). The flags g and y do not
  apply: split searches with a copy of the pattern that is sticky, from each position in turn, which is what a search
  from the position finds first. }
function SplitUnits(const S: TSearch; const T: TText; Limit: NativeInt): TSpans;

{ AppendLossy appends the units From..To_ of the text. A bound between the halves of a character of four bytes of
  UTF-8 (which only a pattern without the u flag can make) cannot be written as UTF-8, and the half character is
  written as U+FFFD, as a lossy conversion of the UTF-16 text would write it; so the result is UTF-8 when the input
  is. Over UTF-16 the units are copied as they are. }
procedure AppendLossy(var Out_: TUnitBuffer; const T: TText; From, To_: NativeInt);

{ InsideFour reports whether the position is the one between the halves of a character of four bytes of UTF-8 (its
  third byte). It is false over UTF-16. }
function InsideFour(const T: TText; Pos: NativeInt): Boolean;

{ IsValidText reports whether the text is well formed in its encoding: UTF-8 for bytes. Every UTF-16 text is
  accepted, lone surrogates and all, as ECMA-262 matches them. }
function IsValidText(const T: TText): Boolean;
