unit Corvus.Ecma262.RegularExpressions.Errors;
{$I ecma262.inc}

{ The exceptions of the engine. The unit Corvus.Ecma262.RegularExpressions names each of them again, so a program
  needs only that one in its uses clause. }

interface

uses
  SysUtils;

type
  { EEcmaRegex is the class of every exception the engine raises for a pattern, its flags, a text or a match. }
  EEcmaRegex = class(Exception);

  { EEcmaRegexSyntax is a pattern that is not valid under the grammar its flags choose. Reason is why, and Offset is
    the 0-based offset in the pattern's characters (UTF-16 code units without the u or v flag) where it was found. }
  EEcmaRegexSyntax = class(EEcmaRegex)
  private
    FPattern: UTF8String;
    FReason: string;
    FOffset: Int32;
  public
    constructor Create(const APattern: UTF8String; const AReason: string; AOffset: Int32);
    property Pattern: UTF8String read FPattern;
    property Reason: string read FReason;
    property Offset: Int32 read FOffset;
  end;

  { EEcmaRegexFlags is flags that are not valid: a flag that is not one of dgimsuvy, a flag given twice, or u with
    v. }
  EEcmaRegexFlags = class(EEcmaRegex);

  { TEcmaRegexLimit names a limit of the size of a pattern: its length in bytes of UTF-8, the depth its groups nest,
    and the size it has when it is read. }
  TEcmaRegexLimit = (elLength, elNesting, elSize);

  { EEcmaRegexTooLarge is a pattern over one of the limits of size. The pattern was not read to its end, so the error
    says nothing of whether it is valid. }
  EEcmaRegexTooLarge = class(EEcmaRegex)
  private
    FLimit: TEcmaRegexLimit;
    FValue: Int32;
  public
    constructor Create(ALimit: TEcmaRegexLimit; AValue: Int32);
    property Limit: TEcmaRegexLimit read FLimit;
    property Value: Int32 read FValue;
  end;

  { EEcmaRegexEncoding is a pattern or a text that is not UTF-8 (or a pattern that is not well-formed UTF-16), which
    is refused, never read as U+FFFD. }
  EEcmaRegexEncoding = class(EEcmaRegex);

  { EEcmaRegexTimeout is a match that ran for longer than its pattern's match timeout. It is not an answer. }
  EEcmaRegexTimeout = class(EEcmaRegex)
  private
    FTimeout: Double;
  public
    constructor Create(ATimeout: Double);
    { Timeout is the limit, in seconds. }
    property Timeout: Double read FTimeout;
  end;

  { EEcmaRegexMemory is a match with a timeout that needed more backtracking memory than its limit. It is not an
    answer. }
  EEcmaRegexMemory = class(EEcmaRegex);

  { ESyntax is what the parser raises. The public calls raise EEcmaRegexSyntax in its place, with the pattern. }
  ESyntax = class(Exception)
  public
    Offset: Int32;
    constructor Create(const AReason: string; AOffset: Int32);
  end;

implementation

constructor EEcmaRegexSyntax.Create(const APattern: UTF8String; const AReason: string; AOffset: Int32);
begin
  inherited CreateFmt('%s at offset %d in /%s/', [AReason, AOffset, string(APattern)]);
  FPattern := APattern;
  FReason := AReason;
  FOffset := AOffset;
end;

constructor EEcmaRegexTooLarge.Create(ALimit: TEcmaRegexLimit; AValue: Int32);
begin
  case ALimit of
    elLength: inherited CreateFmt('the pattern is longer than %d bytes', [AValue]);
    elNesting: inherited CreateFmt('the groups of the pattern nest more than %d deep', [AValue]);
  else
    inherited CreateFmt('the pattern has a size of more than %d bytes when it is read', [AValue]);
  end;
  FLimit := ALimit;
  FValue := AValue;
end;

constructor EEcmaRegexTimeout.Create(ATimeout: Double);
begin
  inherited CreateFmt('the match ran for longer than its limit of %g s', [ATimeout]);
  FTimeout := ATimeout;
end;

constructor ESyntax.Create(const AReason: string; AOffset: Int32);
begin
  inherited Create(AReason);
  Offset := AOffset;
end;

end.
