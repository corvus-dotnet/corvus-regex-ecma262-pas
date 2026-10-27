unit Corvus.Ecma262.RegularExpressions.Swar;
{$I ecma262.inc}

{ The searches the Rust crate takes from memchr, and the Teddy search it takes from aho-corasick. Over x86_64 each
  reads sixteen bytes at a time with SSE2 (Teddy with SSSE3) and finishes with SWAR; over any other processor one byte
  is the run-time library's IndexByte and the rest are SWAR: eight bytes of a UInt64 read at a time and tested
  together. A lane test is exact (no lane is flagged that does not pass), so the first flagged lane is the first unit
  that passes.

  Every function takes the text as a pointer and the end of what it may read, N, which the caller has checked lies
  within the text (the matcher checks it once against the length of the text). Each reads only below N: a word of
  eight bytes is read at a position at most N - 8. }

interface

uses
  SysUtils;

{$IFDEF ENDIAN_BIG}
  {$ERROR The searches read words of the text in little-endian order.}
{$ENDIF}

const
  Ones = UInt64($0101010101010101);
  Low7 = UInt64($7F7F7F7F7F7F7F7F);
  Highs = UInt64($8080808080808080);

{ Word8 is the eight bytes at P[At], the first in the low byte. }
function Word8(P: PByte; At: NativeInt): UInt64; inline;
{ Broadcast8 is a byte in every lane. }
function Broadcast8(B: Byte): UInt64; inline;
{ Zeros8 is the high bit of each lane of X that is zero. }
function Zeros8(X: UInt64): UInt64; inline;
{ Eq8 is the high bit of each lane of X that equals the broadcast byte V. }
function Eq8(X, V: UInt64): UInt64; inline;
{ Lane is the lane of the lowest flagged high bit. }
function Lane(Flags: UInt64): NativeInt; inline;
{ HasZero is the cheap test of whether some lane of X is zero: it flags every zero lane but may also flag a lane of 1
  above a zero lane. The loops use it to know that a block holds a byte they look for, and Zeros8 to find which; a
  finder that tests candidates can take its flags as they are. }
function HasZero(X: UInt64): UInt64; inline;

{ IndexByte1 is the first position at or after From and before N whose byte is B, or -1. }
function IndexByte1(P: PByte; From, N: NativeInt; B: Byte): NativeInt; inline;
{ IndexByte2 is the first position at or after From and before N whose byte is A or B, or -1. }
function IndexByte2(P: PByte; From, N: NativeInt; A, B: Byte): NativeInt;
{ IndexByte4 is the first position at or after From and before N whose byte is one of four (which may repeat), or
  -1. }
function IndexByte4(P: PByte; From, N: NativeInt; A, B, C, D: Byte): NativeInt;
{ IndexBetween is the first position at or after From and before N whose byte is from Lo to Hi (both below $80), or
  -1. }
function IndexBetween(P: PByte; From, N: NativeInt; Lo, Hi: Byte): NativeInt;
{ StartsWith reports whether the Len bytes from Lit are at P[At], before End_. }
function StartsWith(P: PByte; At, End_: NativeInt; Lit: PByte; Len: NativeInt): Boolean; inline;

{ PairBlock finds the first block of sixteen starts, from the start At by steps of sixteen up to (not past) Last,
  at which a start S has (P[S + I] or MI) = VI and (P[S + J] or MJ) = VJ for some lane (each a byte broadcast to a
  word): it returns that block's first start and the lanes in Lanes (bit k for the start + k), or -1. The caller
  checks that every byte read, up to Last + Max(I, J) + 15, lies within the text. Over x86_64 it reads sixteen bytes
  at a time with SSE2, and over any other processor eight at a time as words. }
function PairBlock(P: PByte; At, Last, I, J: NativeInt; MI, VI, MJ, VJ: UInt64; out Lanes: UInt32): NativeInt;

{ PairBlockN is PairBlock with NI tests of position I and NJ of position J (each from one to four), a start passing
  when one test of each passes. Consts holds sixteen bytes of each mask and then of its value, the tests of I first:
  32 * (NI + NJ) bytes (see VecConsts). }
function PairBlockN(P: PByte; At, Last, I, J: NativeInt; Consts: PByte; NI, NJ: Int32; out Lanes: UInt32): NativeInt;

{ IndexRanges is the first position at or after From and before N whose byte is in one of NR ranges (from one to
  four), or -1. Consts holds sixteen bytes of each range's least byte and then of its width (greatest less least):
  32 * NR bytes (see VecConsts). }
function IndexRanges(P: PByte; From, N: NativeInt; Consts: PByte; NR: Int32): NativeInt;

{ TeddyBlock finds the first block of sixteen starts, from the start At by steps of sixteen up to (not past) Last, at
  which some start S passes the nibble tables of Teddy (the searcher of the Rust crate aho-corasick, which the crate
  takes for several literals): for each of the positions 0, 1 and 2, the table of the low nibble of P[S + m] and the
  table of its high nibble give a byte of buckets each, and S passes where some bucket is in all six. Tab holds
  sixteen bytes of each table, low then high, for positions 0 to 2, then sixteen bytes of $0F: 112 bytes. It returns
  that block's first start and the lanes in Lanes (bit k for the start + k), or -1. The caller checks that every byte
  read, up to Last + 17, lies within the text. It takes SSSE3 (HasSsse3); over any other processor it tests a start
  at a time. }
function TeddyBlock(P: PByte; At, Last: NativeInt; Tab: PByte; out Lanes: UInt32): NativeInt;

{ HasSsse3 reports whether the processor has SSSE3, whose byte shuffle TeddyBlock reads its tables with. }
function HasSsse3: Boolean;

{ VecConsts writes the pairs of bytes Pairs (a mask and a value, or a least byte and a width), each pair as sixteen
  copies of the one and then sixteen of the other, for PairBlockN and IndexRanges. }
procedure VecConsts(const Pairs: array of Byte; var Consts: TBytes);

{ IndexUnit is the first position at or after From and before N whose UTF-16 unit is V, or -1. }
function IndexUnit(P: PUInt16; From, N: NativeInt; V: UInt16): NativeInt;
{ HasUnits16 reports whether the Len units from Lit are at P[At] of a text of N units. }
function HasUnits16(P: PUInt16; At, N: NativeInt; Lit: PUInt16; Len: NativeInt): Boolean; inline;

implementation

function Word8(P: PByte; At: NativeInt): UInt64;
begin
  Result := PUInt64(@P[At])^;
end;

function Broadcast8(B: Byte): UInt64;
begin
  Result := UInt64(B) * Ones;
end;

function Zeros8(X: UInt64): UInt64;
begin
  Result := not (((X and Low7) + Low7) or X or Low7);
end;

function Eq8(X, V: UInt64): UInt64;
begin
  Result := Zeros8(X xor V);
end;

function Lane(Flags: UInt64): NativeInt;
begin
  Result := BsfQWord(Flags) shr 3;
end;

function HasZero(X: UInt64): UInt64;
begin
  // The subtraction wraps on purpose.
  Result := (X - Ones) and not X and Highs;
end;

{$IFDEF CPUX86_64}
{$ASMMODE INTEL}

(* The SSE2 kernels. Each reads Blocks blocks of sixteen bytes from Base and returns the offset of the first byte that
  passes, or -1 when none of the blocks holds one. The arguments are copied into locals first, which the asm block
  reads, so that nothing depends on the registers the calling convention of the system puts them in; the blocks use
  only registers both conventions let a routine overwrite (rax, rcx, rdx, r8 to r11, xmm0 to xmm5). A constant is a
  byte broadcast to a word (Broadcast8), which the block broadcasts to the sixteen lanes. *)

{ VecEq1 passes a byte equal to A, two blocks of sixteen a step: Pairs is the number of steps of thirty-two bytes. }
function VecEq1(Base: PByte; Pairs: NativeInt; A: UInt64): NativeInt;
var
  LBase: PByte;
  LPairs, R: NativeInt;
  LA: UInt64;
begin
  LBase := Base;
  LPairs := Pairs;
  LA := A;
  R := -1;
  if LPairs > 0 then
    asm
      mov rdx, LBase
      mov rcx, LPairs
      mov rax, LA
      movq xmm1, rax
      punpcklqdq xmm1, xmm1
      xor r8, r8
    @loop:
      movdqu xmm0, [rdx + r8]
      movdqu xmm3, [rdx + r8 + 16]
      pcmpeqb xmm0, xmm1
      pcmpeqb xmm3, xmm1
      movdqa xmm2, xmm0
      por xmm2, xmm3
      pmovmskb eax, xmm2
      test eax, eax
      jnz @found
      add r8, 32
      dec rcx
      jnz @loop
      jmp @done
    @found:
      pmovmskb eax, xmm0
      pmovmskb r9d, xmm3
      shl r9, 16
      or rax, r9
      bsf rax, rax
      add rax, r8
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'r9', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  Result := R;
end;

{ VecEq2 passes a byte equal to A or B. }
function VecEq2(Base: PByte; Blocks: NativeInt; A, B: UInt64): NativeInt;
var
  LBase: PByte;
  LBlocks, R: NativeInt;
  LA, LB: UInt64;
begin
  LBase := Base;
  LBlocks := Blocks;
  LA := A;
  LB := B;
  R := -1;
  if LBlocks > 0 then
    asm
      mov rdx, LBase
      mov rcx, LBlocks
      mov rax, LA
      movq xmm1, rax
      punpcklqdq xmm1, xmm1
      mov rax, LB
      movq xmm2, rax
      punpcklqdq xmm2, xmm2
      xor r8, r8
    @loop:
      movdqu xmm0, [rdx + r8]
      movdqa xmm3, xmm0
      pcmpeqb xmm0, xmm1
      pcmpeqb xmm3, xmm2
      por xmm0, xmm3
      pmovmskb eax, xmm0
      test eax, eax
      jnz @found
      add r8, 16
      dec rcx
      jnz @loop
      jmp @done
    @found:
      bsf eax, eax
      add rax, r8
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  Result := R;
end;

{ VecEq4 passes a byte equal to one of A, B, C and D. }
function VecEq4(Base: PByte; Blocks: NativeInt; A, B, C, D: UInt64): NativeInt;
var
  LBase: PByte;
  LBlocks, R: NativeInt;
  LA, LB, LC, LD: UInt64;
begin
  LBase := Base;
  LBlocks := Blocks;
  LA := A;
  LB := B;
  LC := C;
  LD := D;
  R := -1;
  if LBlocks > 0 then
    asm
      mov rdx, LBase
      mov rcx, LBlocks
      mov rax, LA
      movq xmm1, rax
      punpcklqdq xmm1, xmm1
      mov rax, LB
      movq xmm2, rax
      punpcklqdq xmm2, xmm2
      mov rax, LC
      movq xmm4, rax
      punpcklqdq xmm4, xmm4
      mov rax, LD
      movq xmm5, rax
      punpcklqdq xmm5, xmm5
      xor r8, r8
    @loop:
      movdqu xmm0, [rdx + r8]
      pcmpeqb xmm0, xmm1
      movdqu xmm3, [rdx + r8]
      pcmpeqb xmm3, xmm2
      por xmm0, xmm3
      movdqu xmm3, [rdx + r8]
      pcmpeqb xmm3, xmm4
      por xmm0, xmm3
      movdqu xmm3, [rdx + r8]
      pcmpeqb xmm3, xmm5
      por xmm0, xmm3
      pmovmskb eax, xmm0
      test eax, eax
      jnz @found
      add r8, 16
      dec rcx
      jnz @loop
      jmp @done
    @found:
      bsf eax, eax
      add rax, r8
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'xmm0', 'xmm1', 'xmm2', 'xmm3', 'xmm4', 'xmm5'];
  Result := R;
end;

{ VecRange passes a byte from Lo to Lo + Width: the byte less Lo, which wraps below it, is at most Width. }
function VecRange(Base: PByte; Blocks: NativeInt; Lo, Width: UInt64): NativeInt;
var
  LBase: PByte;
  LBlocks, R: NativeInt;
  LLo, LWidth: UInt64;
begin
  LBase := Base;
  LBlocks := Blocks;
  LLo := Lo;
  LWidth := Width;
  R := -1;
  if LBlocks > 0 then
    asm
      mov rdx, LBase
      mov rcx, LBlocks
      mov rax, LLo
      movq xmm1, rax
      punpcklqdq xmm1, xmm1
      mov rax, LWidth
      movq xmm2, rax
      punpcklqdq xmm2, xmm2
      xor r8, r8
    @loop:
      movdqu xmm0, [rdx + r8]
      psubb xmm0, xmm1
      movdqa xmm3, xmm0
      pminub xmm3, xmm2
      pcmpeqb xmm0, xmm3
      pmovmskb eax, xmm0
      test eax, eax
      jnz @found
      add r8, 16
      dec rcx
      jnz @loop
      jmp @done
    @found:
      bsf eax, eax
      add rax, r8
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  Result := R;
end;

{ VecEqW passes a UTF-16 unit equal to V (a unit broadcast to a word), eight units a block; the offset is in units. }
function VecEqW(Base: PUInt16; Blocks: NativeInt; V: UInt64): NativeInt;
var
  LBase: PUInt16;
  LBlocks, R: NativeInt;
  LV: UInt64;
begin
  LBase := Base;
  LBlocks := Blocks;
  LV := V;
  R := -1;
  if LBlocks > 0 then
    asm
      mov rdx, LBase
      mov rcx, LBlocks
      mov rax, LV
      movq xmm1, rax
      punpcklqdq xmm1, xmm1
      xor r8, r8
    @loop:
      movdqu xmm0, [rdx + r8]
      pcmpeqw xmm0, xmm1
      pmovmskb eax, xmm0
      test eax, eax
      jnz @found
      add r8, 16
      dec rcx
      jnz @loop
      jmp @done
    @found:
      bsf eax, eax
      add rax, r8
      shr rax, 1
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'xmm0', 'xmm1'];
  Result := R;
end;

function PairBlock(P: PByte; At, Last, I, J: NativeInt; MI, VI, MJ, VJ: UInt64; out Lanes: UInt32): NativeInt;
var
  LPI, LPJ: PByte;
  LBlocks, R: NativeInt;
  LMI, LVI, LMJ, LVJ: UInt64;
  LMask: UInt32;
begin
  Lanes := 0;
  if At > Last then
    Exit(-1);
  LPI := @P[At + I];
  LPJ := @P[At + J];
  LBlocks := (Last - At) div 16 + 1;
  LMI := MI;
  LVI := VI;
  LMJ := MJ;
  LVJ := VJ;
  R := -1;
  LMask := 0;
  asm
    mov rdx, LPI
    mov r9, LPJ
    mov rcx, LBlocks
    mov rax, LMI
    movq xmm1, rax
    punpcklqdq xmm1, xmm1
    mov rax, LVI
    movq xmm2, rax
    punpcklqdq xmm2, xmm2
    mov rax, LMJ
    movq xmm4, rax
    punpcklqdq xmm4, xmm4
    mov rax, LVJ
    movq xmm5, rax
    punpcklqdq xmm5, xmm5
    xor r8, r8
  @loop:
    movdqu xmm0, [rdx + r8]
    por xmm0, xmm1
    pcmpeqb xmm0, xmm2
    movdqu xmm3, [r9 + r8]
    por xmm3, xmm4
    pcmpeqb xmm3, xmm5
    pand xmm0, xmm3
    pmovmskb eax, xmm0
    test eax, eax
    jnz @found
    add r8, 16
    dec rcx
    jnz @loop
    jmp @done
  @found:
    mov LMask, eax
    mov R, r8
  @done:
  end ['rax', 'rcx', 'rdx', 'r8', 'r9', 'xmm0', 'xmm1', 'xmm2', 'xmm3', 'xmm4', 'xmm5'];
  if R < 0 then
    Exit(-1);
  Lanes := LMask;
  Result := At + R;
end;

{ VecRanges passes a byte in one of NR ranges, whose least bytes and widths Consts holds as VecConsts writes them. }
function VecRanges(Base: PByte; Blocks: NativeInt; Consts: PByte; NR: Int32): NativeInt;
var
  LBase, LConsts: PByte;
  LBlocks, LNR, R: NativeInt;
begin
  LBase := Base;
  LBlocks := Blocks;
  LConsts := Consts;
  LNR := NR;
  R := -1;
  if LBlocks > 0 then
    asm
      mov rdx, LBase
      mov rcx, LBlocks
      xor r8, r8
    @block:
      pxor xmm0, xmm0
      mov r10, LConsts
      mov r11, LNR
    @range:
      movdqu xmm1, [rdx + r8]
      movdqu xmm2, [r10]
      psubb xmm1, xmm2
      movdqu xmm2, [r10 + 16]
      movdqa xmm3, xmm1
      pminub xmm3, xmm2
      pcmpeqb xmm1, xmm3
      por xmm0, xmm1
      add r10, 32
      dec r11
      jnz @range
      pmovmskb eax, xmm0
      test eax, eax
      jnz @found
      add r8, 16
      dec rcx
      jnz @block
      jmp @done
    @found:
      bsf eax, eax
      add rax, r8
      mov R, rax
    @done:
    end ['rax', 'rcx', 'rdx', 'r8', 'r10', 'r11', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  Result := R;
end;

function PairBlockN(P: PByte; At, Last, I, J: NativeInt; Consts: PByte; NI, NJ: Int32; out Lanes: UInt32): NativeInt;
var
  LPI, LPJ, LCI, LCJ: PByte;
  LBlocks, LNI, LNJ, R: NativeInt;
  LMask: UInt32;
begin
  Lanes := 0;
  if At > Last then
    Exit(-1);
  LPI := @P[At + I];
  LPJ := @P[At + J];
  LBlocks := (Last - At) div 16 + 1;
  LCI := Consts;
  LCJ := @Consts[32 * NI];
  LNI := NI;
  LNJ := NJ;
  R := -1;
  LMask := 0;
  asm
    mov rdx, LPI
    mov r9, LPJ
    mov rcx, LBlocks
    xor r8, r8
  @block:
    pxor xmm0, xmm0
    mov r10, LCI
    mov r11, LNI
  @ti:
    movdqu xmm2, [rdx + r8]
    movdqu xmm3, [r10]
    por xmm2, xmm3
    movdqu xmm3, [r10 + 16]
    pcmpeqb xmm2, xmm3
    por xmm0, xmm2
    add r10, 32
    dec r11
    jnz @ti
    pxor xmm1, xmm1
    mov r10, LCJ
    mov r11, LNJ
  @tj:
    movdqu xmm2, [r9 + r8]
    movdqu xmm3, [r10]
    por xmm2, xmm3
    movdqu xmm3, [r10 + 16]
    pcmpeqb xmm2, xmm3
    por xmm1, xmm2
    add r10, 32
    dec r11
    jnz @tj
    pand xmm0, xmm1
    pmovmskb eax, xmm0
    test eax, eax
    jnz @found
    add r8, 16
    dec rcx
    jnz @block
    jmp @done
  @found:
    mov LMask, eax
    mov R, r8
  @done:
  end ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11', 'xmm0', 'xmm1', 'xmm2', 'xmm3'];
  if R < 0 then
    Exit(-1);
  Lanes := LMask;
  Result := At + R;
end;

{$ELSE}

function PairBlock(P: PByte; At, Last, I, J: NativeInt; MI, VI, MJ, VJ: UInt64; out Lanes: UInt32): NativeInt;
var
  M0, M1: UInt64;
  K: Int32;
begin
  // Eight starts a word, two words a block; a flagged lane of HasZero may not pass, and the finder compares it.
  while At <= Last do begin
    M0 := HasZero((Word8(P, At + I) or MI) xor VI) and HasZero((Word8(P, At + J) or MJ) xor VJ);
    M1 := HasZero((Word8(P, At + 8 + I) or MI) xor VI) and HasZero((Word8(P, At + 8 + J) or MJ) xor VJ);
    if (M0 or M1) <> 0 then begin
      Lanes := 0;
      for K := 0 to 7 do begin
        if ((M0 shr (8 * K + 7)) and 1) <> 0 then
          Lanes := Lanes or (UInt32(1) shl K);
        if ((M1 shr (8 * K + 7)) and 1) <> 0 then
          Lanes := Lanes or (UInt32(1) shl (8 + K));
      end;
      Exit(At);
    end;
    Inc(At, 16);
  end;
  Lanes := 0;
  Result := -1;
end;

function PairBlockN(P: PByte; At, Last, I, J: NativeInt; Consts: PByte; NI, NJ: Int32; out Lanes: UInt32): NativeInt;
var
  S, T: NativeInt;
  OkI, OkJ: Boolean;
begin
  // A start at a time, over the first byte of each sixteen of the constants.
  while At <= Last do begin
    Lanes := 0;
    for S := 0 to 15 do begin
      OkI := False;
      for T := 0 to NI - 1 do
        if (P[At + S + I] or Consts[32 * T]) = Consts[32 * T + 16] then
          OkI := True;
      OkJ := False;
      for T := NI to NI + NJ - 1 do
        if (P[At + S + J] or Consts[32 * T]) = Consts[32 * T + 16] then
          OkJ := True;
      if OkI and OkJ then
        Lanes := Lanes or (UInt32(1) shl S);
    end;
    if Lanes <> 0 then
      Exit(At);
    Inc(At, 16);
  end;
  Lanes := 0;
  Result := -1;
end;

{$ENDIF}

{$IFDEF CPUX86_64}

function DetectSsse3: Boolean;
var
  R: UInt32;
begin
  asm
    mov eax, 1
    cpuid
    mov R, ecx
  end ['rax', 'rbx', 'rcx', 'rdx'];
  Result := (R and (UInt32(1) shl 9)) <> 0;
end;

function TeddyBlock(P: PByte; At, Last: NativeInt; Tab: PByte; out Lanes: UInt32): NativeInt;
var
  LP, LTab: PByte;
  LBlocks, R: NativeInt;
  LMask: UInt32;
begin
  Lanes := 0;
  if At > Last then
    Exit(-1);
  LP := @P[At];
  LTab := Tab;
  LBlocks := (Last - At) div 16 + 1;
  R := -1;
  LMask := 0;
  asm
    mov rdx, LP
    mov r10, LTab
    mov rcx, LBlocks
    movdqu xmm5, [r10 + 96]
    xor r8, r8
  @block:
    movdqu xmm0, [rdx + r8]
    movdqa xmm1, xmm0
    psrlw xmm1, 4
    pand xmm0, xmm5
    pand xmm1, xmm5
    movdqu xmm4, [r10]
    pshufb xmm4, xmm0
    movdqu xmm2, [r10 + 16]
    pshufb xmm2, xmm1
    pand xmm4, xmm2
    movdqu xmm0, [rdx + r8 + 1]
    movdqa xmm1, xmm0
    psrlw xmm1, 4
    pand xmm0, xmm5
    pand xmm1, xmm5
    movdqu xmm2, [r10 + 32]
    pshufb xmm2, xmm0
    pand xmm4, xmm2
    movdqu xmm2, [r10 + 48]
    pshufb xmm2, xmm1
    pand xmm4, xmm2
    movdqu xmm0, [rdx + r8 + 2]
    movdqa xmm1, xmm0
    psrlw xmm1, 4
    pand xmm0, xmm5
    pand xmm1, xmm5
    movdqu xmm2, [r10 + 64]
    pshufb xmm2, xmm0
    pand xmm4, xmm2
    movdqu xmm2, [r10 + 80]
    pshufb xmm2, xmm1
    pand xmm4, xmm2
    pxor xmm3, xmm3
    pcmpeqb xmm4, xmm3
    pmovmskb eax, xmm4
    xor eax, $FFFF
    jnz @found
    add r8, 16
    dec rcx
    jnz @block
    jmp @done
  @found:
    mov LMask, eax
    mov R, r8
  @done:
  end ['rax', 'rcx', 'rdx', 'r8', 'r10', 'xmm0', 'xmm1', 'xmm2', 'xmm3', 'xmm4', 'xmm5'];
  if R < 0 then
    Exit(-1);
  Lanes := LMask;
  Result := At + R;
end;

{$ELSE}

function DetectSsse3: Boolean;
begin
  Result := False;
end;

function TeddyBlock(P: PByte; At, Last: NativeInt; Tab: PByte; out Lanes: UInt32): NativeInt;
var
  S, M: NativeInt;
  B, X: Byte;
begin
  // A start at a time, over the first byte of each table.
  while At <= Last do begin
    Lanes := 0;
    for S := 0 to 15 do begin
      B := $FF;
      for M := 0 to 2 do begin
        X := P[At + S + M];
        B := B and Tab[32 * M + (X and 15)] and Tab[32 * M + 16 + (X shr 4)];
      end;
      if B <> 0 then
        Lanes := Lanes or (UInt32(1) shl S);
    end;
    if Lanes <> 0 then
      Exit(At);
    Inc(At, 16);
  end;
  Lanes := 0;
  Result := -1;
end;

{$ENDIF}

var
  Ssse3: Boolean;

function HasSsse3: Boolean;
begin
  Result := Ssse3;
end;

function IndexByte1(P: PByte; From, N: NativeInt; B: Byte): NativeInt;
var
  K: SizeInt;
begin
  if From >= N then
    Exit(-1);
  {$IFDEF CPUX86_64}
  // The run-time library's search over the first 256 bytes, which starts sooner for a byte close by (the ends of
  // lines), then 32 bytes a step.
  if N - From >= 288 then begin
    K := IndexByte(P[From], 256, B);
    if K >= 0 then
      Exit(From + K);
    Inc(From, 256);
    K := VecEq1(@P[From], (N - From) div 32, Broadcast8(B));
    if K >= 0 then
      Exit(From + K);
    Inc(From, ((N - From) div 32) * 32);
    if From >= N then
      Exit(-1);
  end;
  {$ENDIF}
  K := IndexByte(P[From], N - From, B);
  if K < 0 then
    Exit(-1);
  Result := From + K;
end;

function IndexByte2(P: PByte; From, N: NativeInt; A, B: Byte): NativeInt;
var
  VA, VB, W0, W1, X, Z: UInt64;
  At: NativeInt;
begin
  {$IFDEF CPUX86_64}
  if N - From >= 16 then begin
    At := VecEq2(@P[From], (N - From) div 16, Broadcast8(A), Broadcast8(B));
    if At >= 0 then
      Exit(From + At);
    Inc(From, ((N - From) div 16) * 16);
  end;
  {$ENDIF}
  VA := Broadcast8(A);
  VB := Broadcast8(B);
  At := From;
  while At <= N - 16 do begin
    W0 := Word8(P, At);
    W1 := Word8(P, At + 8);
    if (HasZero(W0 xor VA) or HasZero(W0 xor VB) or HasZero(W1 xor VA) or HasZero(W1 xor VB)) <> 0 then begin
      Z := Eq8(W0, VA) or Eq8(W0, VB);
      if Z <> 0 then
        Exit(At + Lane(Z));
      Z := Eq8(W1, VA) or Eq8(W1, VB);
      if Z <> 0 then
        Exit(At + 8 + Lane(Z));
    end;
    Inc(At, 16);
  end;
  while At <= N - 8 do begin
    W0 := Word8(P, At);
    X := Eq8(W0, VA) or Eq8(W0, VB);
    if X <> 0 then
      Exit(At + Lane(X));
    Inc(At, 8);
  end;
  while At < N do begin
    if (P[At] = A) or (P[At] = B) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

function IndexByte4(P: PByte; From, N: NativeInt; A, B, C, D: Byte): NativeInt;
var
  VA, VB, VC, VD, W, Z: UInt64;
  At: NativeInt;
  X: Byte;
begin
  {$IFDEF CPUX86_64}
  if N - From >= 16 then begin
    At := VecEq4(@P[From], (N - From) div 16, Broadcast8(A), Broadcast8(B), Broadcast8(C), Broadcast8(D));
    if At >= 0 then
      Exit(From + At);
    Inc(From, ((N - From) div 16) * 16);
  end;
  {$ENDIF}
  VA := Broadcast8(A);
  VB := Broadcast8(B);
  VC := Broadcast8(C);
  VD := Broadcast8(D);
  At := From;
  while At <= N - 8 do begin
    W := Word8(P, At);
    if (HasZero(W xor VA) or HasZero(W xor VB) or HasZero(W xor VC) or HasZero(W xor VD)) <> 0 then begin
      Z := Eq8(W, VA) or Eq8(W, VB) or Eq8(W, VC) or Eq8(W, VD);
      if Z <> 0 then
        Exit(At + Lane(Z));
    end;
    Inc(At, 8);
  end;
  while At < N do begin
    X := P[At];
    if (X = A) or (X = B) or (X = C) or (X = D) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

(* Between is the high bit of each lane of X that is an ASCII byte from lo to hi (both below $80), given the
  constants Lo = Broadcast8($80 - lo) and Hi = Broadcast8($7F - hi): exact, since the seven low bits of a lane plus a
  constant below $80 cannot carry into the next lane. *)
function Between(X, Lo, Hi: UInt64): UInt64; inline;
var
  T: UInt64;
begin
  T := X and Low7;
  Result := (T + Lo) and not (T + Hi) and not X and Highs;
end;

function IndexBetween(P: PByte; From, N: NativeInt; Lo, Hi: Byte): NativeInt;
var
  VL, VH, Z0, Z1: UInt64;
  At: NativeInt;
  X: Byte;
begin
  {$IFDEF CPUX86_64}
  if N - From >= 16 then begin
    At := VecRange(@P[From], (N - From) div 16, Broadcast8(Lo), Broadcast8(Hi - Lo));
    if At >= 0 then
      Exit(From + At);
    Inc(From, ((N - From) div 16) * 16);
  end;
  {$ENDIF}
  VL := Broadcast8($80 - Lo);
  VH := Broadcast8($7F - Hi);
  At := From;
  while At <= N - 16 do begin
    Z0 := Between(Word8(P, At), VL, VH);
    Z1 := Between(Word8(P, At + 8), VL, VH);
    if (Z0 or Z1) <> 0 then begin
      if Z0 <> 0 then
        Exit(At + Lane(Z0));
      Exit(At + 8 + Lane(Z1));
    end;
    Inc(At, 16);
  end;
  while At <= N - 8 do begin
    Z0 := Between(Word8(P, At), VL, VH);
    if Z0 <> 0 then
      Exit(At + Lane(Z0));
    Inc(At, 8);
  end;
  while At < N do begin
    X := P[At];
    if (X >= Lo) and (X <= Hi) then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

procedure VecConsts(const Pairs: array of Byte; var Consts: TBytes);
var
  K: NativeInt;
begin
  SetLength(Consts, 16 * Length(Pairs));
  for K := 0 to High(Pairs) do
    FillChar(Consts[16 * K], 16, Pairs[K]);
end;

function IndexRanges(P: PByte; From, N: NativeInt; Consts: PByte; NR: Int32): NativeInt;
var
  At: NativeInt;
  T: Int32;
begin
  {$IFDEF CPUX86_64}
  if N - From >= 16 then begin
    At := VecRanges(@P[From], (N - From) div 16, Consts, NR);
    if At >= 0 then
      Exit(From + At);
    Inc(From, ((N - From) div 16) * 16);
  end;
  {$ENDIF}
  for At := From to N - 1 do
    for T := 0 to NR - 1 do
      if Byte(P[At] - Consts[32 * T]) <= Consts[32 * T + 16] then
        Exit(At);
  Result := -1;
end;

function StartsWith(P: PByte; At, End_: NativeInt; Lit: PByte; Len: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if (At < 0) or (End_ - At < Len) then
    Exit(False);
  for K := 0 to Len - 1 do
    if P[At + K] <> Lit[K] then
      Exit(False);
  Result := True;
end;

{ The same over UTF-16: four units of a UInt64. }

const
  Ones16 = UInt64($0001000100010001);
  Low15 = UInt64($7FFF7FFF7FFF7FFF);
  Highs16 = UInt64($8000800080008000);

function Word16(P: PUInt16; At: NativeInt): UInt64; inline;
begin
  Result := PUInt64(@P[At])^;
end;

function Zeros16(X: UInt64): UInt64; inline;
begin
  Result := not (((X and Low15) + Low15) or X or Low15);
end;

function HasZero16(X: UInt64): UInt64; inline;
begin
  Result := (X - Ones16) and not X and Highs16;
end;

function IndexUnit(P: PUInt16; From, N: NativeInt; V: UInt16): NativeInt;
var
  VV, W0, W1, W2, W3, Z: UInt64;
  At: NativeInt;
begin
  {$IFDEF CPUX86_64}
  if N - From >= 8 then begin
    At := VecEqW(@P[From], (N - From) div 8, UInt64(V) * Ones16);
    if At >= 0 then
      Exit(From + At);
    Inc(From, ((N - From) div 8) * 8);
  end;
  {$ENDIF}
  VV := UInt64(V) * Ones16;
  At := From;
  while At <= N - 16 do begin
    W0 := Word16(P, At) xor VV;
    W1 := Word16(P, At + 4) xor VV;
    W2 := Word16(P, At + 8) xor VV;
    W3 := Word16(P, At + 12) xor VV;
    if (HasZero16(W0) or HasZero16(W1) or HasZero16(W2) or HasZero16(W3)) <> 0 then begin
      Z := Zeros16(W0);
      if Z <> 0 then
        Exit(At + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W1);
      if Z <> 0 then
        Exit(At + 4 + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W2);
      if Z <> 0 then
        Exit(At + 8 + NativeInt(BsfQWord(Z) shr 4));
      Z := Zeros16(W3);
      if Z <> 0 then
        Exit(At + 12 + NativeInt(BsfQWord(Z) shr 4));
    end;
    Inc(At, 16);
  end;
  while At <= N - 4 do begin
    Z := Zeros16(Word16(P, At) xor VV);
    if Z <> 0 then
      Exit(At + NativeInt(BsfQWord(Z) shr 4));
    Inc(At, 4);
  end;
  while At < N do begin
    if P[At] = V then
      Exit(At);
    Inc(At);
  end;
  Result := -1;
end;

function HasUnits16(P: PUInt16; At, N: NativeInt; Lit: PUInt16; Len: NativeInt): Boolean;
var
  K: NativeInt;
begin
  if (At < 0) or (N - At < Len) then
    Exit(False);
  for K := 0 to Len - 1 do
    if P[At + K] <> Lit[K] then
      Exit(False);
  Result := True;
end;

initialization
  Ssse3 := DetectSsse3;

end.
