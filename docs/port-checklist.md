# Port checklist: the search layer

Every optimisation of sections 4.3 and 4.4 of the design of the .NET reference engine
([Corvus.Regex.Ecma262](https://github.com/corvus-dotnet/Corvus.Regex.Ecma262), `docs/design/design.md`), and the
working-memory parts of section 4.2 they rest on, then every item the Rust crate added beyond them
([corvus-regex-ecma262-rs](https://github.com/corvus-dotnet/corvus-regex-ecma262-rs), `docs/port-checklist.md`), each
marked **done**, **not applicable** (and why) or **to do**. This engine is a port of the Rust crate at 0.2.x, by way of
the Go and Julia engines, so the numbers are the crate's. Section 5 (the source generator) is not applicable to this
port as a whole: Free Pascal cannot compile at run time, and the plan keeps a build-time generator out.

The Rust crate takes its searches from `memchr` and `aho-corasick`, whose kernels are vector code. Free Pascal has
neither and no vector intrinsics, so the `Swar` unit writes the kernels as inline assembler for x86_64, where the
harness measured rows that needed them: SSE2 for the searches of one to four bytes, a range or up to four ranges of
bytes, a pair of positions and a UTF-16 unit; SSSE3 for Teddy (item 19); and AVX2, found when the program starts (with
the system's saving of its registers), for one byte, a literal's two rarest bytes and the skip window. Every kernel has
a fallback of SWAR (eight bytes of a `UInt64` read at a time and tested together) or a unit at a time, which another
processor takes, and the tests pass with each fallback forced. Where this does a thing another way, or less well than
the crate, the entry says so. The rows the harness still measures slower than V8 are listed at the end.

| Count | |
|---|---|
| Done | 50 |
| Not applicable | 5 |
| To do | 0 |

## Section 4.2: the program and the working memory

| # | Optimisation | State | In this port |
|---|---|---|---|
| 1 | Flat program, per-thread working memory grown to what a match needs and kept up to a cap | done | `TState`, a thread variable (the `Vm` unit), with no pool and no lock; its stack, groups, loop counters and memo kept up to caps, freed by `ReleaseEcmaRegexThreadState`. A warm match asks for no memory (`tests/TestAllocations.pas`, over every search, with and without a timeout, counted by a memory manager of its own). |
| 2 | The memo of failed places, so a pattern without backreferences is linear | done | `TState.Memo`, taken into use once a match has made sixty-four steps a position. |
| 3 | The clock read every 4,096 steps, and a match that ends before the first check never reads it | done | `CheckEvery`, with the monotonic `GetTickCount64`. |
| 4 | The quick check of the next character at every choice, as V8 makes it | done | `SetQuick`. |
| 5 | A counted loop gives up where the rest cannot fit | done | `SetNeeds`, in bytes of UTF-8 and in UTF-16 code units. |
| 6 | A repetition whose body cannot consume runs once or not at all | done | `Simplify`. |
| 7 | Small counted repetitions written out | done | `Simplify` and `Unroll`, as the crate writes them. |

## Section 4.3: finding where to start

| # | Optimisation | State | In this port |
|---|---|---|---|
| 8 | An anchored pattern starts only at 0 | done | `TProgram.Anchored`. |
| 9 | A literal every match starts with, found by an anchored search | done | Over UTF-8 by its rarest byte (`TRareFinder`, item 53) or its two rarest bytes (item 10), in place of `memmem`; over UTF-16 by its rarest unit where that is rare, or the packed search of item 45. |
| 10 | The needle by the literal's rarest positions, compared over a vector of starts, the literal in full only where they agree | done | With AVX2, `TRareFinder` tests a literal's two bytes at sixty-four starts a step (`Eq2Block`), the literal in full only at a candidate: where its rarest byte is as common as a capital T and the literal is longer than three bytes (a second byte turns away the Ts that begin no Twain, but not those of The), and where it has no ASCII byte rare enough alone, by the two rarest by `memchr`'s table, unless the last byte of a capital of another alphabet (the Ш of Шерлок) can be searched for alone. Without AVX2, the pair search of item 52. |
| 11 | The lazy third anchor | not applicable | As in the crate: the pair search compares two positions and then the literal. |
| 12 | A unit rare enough alone searched for by the one-value span search | done | `TOneFinder` and `TRareFinder` (`IndexByte1`: 64 bytes a step with AVX2, else 32 with SSE2); over UTF-16 `IndexUnit` (eight units a step with SSE2). |
| 13 | Over UTF-16, the span search, or the fingerprint search where both ends are common letters | done | Another way: the search for one literal's rarest unit, and for several the packed search of item 45. |
| 14 | A literal at a fixed distance from the start, the start found by walking back over the characters | done | The windows of item 20, with one distance. |
| 15 | A literal at a bounded range of distances | done | The windows of item 20. |
| 16 | A literal after a run of disjoint unbounded loops, with a leading `\b`, the runs walked back to the earliest start | done | `pkAfterLoops` (`SearchAfterLoops`), with the crate's 0.2.1 floor. |
| 17 | Several literals at once, by a cost model of one or two positions | done | Another way, as the Java engine: literals whose bytes at one position are up to four rare values, or a range of them, by the search for those bytes (`TFirstsFinder`); literals two of whose positions take four masked tests or fewer by the pair search where they are one word's cases (its candidates need no compare, or each position is one test); any others by Teddy (item 19), and without SSSE3 by the pair search or `TTableFinder`, a table of the bytes at their rarest position read a byte at a time. |
| 18 | The pairs of first characters of a sequence of classes as a multi-needle | done | Another way, as the crate: a class of up to four characters is one character of an anchor with several forms. |
| 19 | Fingerprints (Teddy): buckets, nibble tables, up to three positions | done | `TeddyBlock` with SSSE3's byte shuffle: eight buckets, the literals' first three bytes (the ASCII letters folded, so a word's cases share a bucket), sixteen starts a step. Each candidate is tested against the bytes of the literals' first sixteen positions and then the literals of its first byte, from a flat list read through a pointer (`TTableFinder.LiteralAt`). Without SSSE3, `TTableFinder` reads its table a byte at a time. |
| 20 | The literal every alternative holds, at a fixed or bounded distance, the occurrences opening windows of starts tried in order and never twice | done | `pkWindows` (`SearchWindows`), through nested alternations. |
| 21 | The case-insensitive search: a letter's forms in one search, masks joining the forms that differ in a bit | done | The forms are written out into literals, and the pair search compares the two cases of a letter (or of a Cyrillic lead byte) with one masked test, as the reference joins them. |
| 22 | The long s and the Kelvin sign, whose UTF-8 is longer than s and k, looked for apart | done | Another way, as the crate: they are forms like any other. Over UTF-16 the packed search takes their low bytes in the one search. |
| 23 | The fingerprint search's positions chosen by rarity | done | Another way: the pair search and the table choose their positions by `memchr`'s table of byte frequencies. |
| 24 | The first set found by a vectorised search for its units | done | Over UTF-8 `TFirstBytes`: one to four bytes, a range, or up to four ranges (the ASCII runs and one run of lead bytes, each candidate then tested against the set) by SSE2 or AVX2; a set of more than four bytes (a class) tested by its table for four bytes before the vector search starts, since the next word starts a byte or two on. |
| 25 | The same over UTF-16 | done | Another way: the first set's units as up to eight ranges merged as the crate merges them (`FirstUnitsOf`); one unit by `IndexUnit`, any other set a unit at a time through a table of bits, its blocks of bits each kept once. |
| 26 | A failed start skips the rest of its leading loop's run | done | `TSearchPlan.SkipRun`. |
| 27 | A start inside a word skipped where the pattern starts with `\b` and every first character is a word character | done | `TSearchPlan.LeadingWordBoundary`. |
| 28 | A minimum length rules out short rests | done | `TProgram.Need8` and `Need16`. |
| 29 | Simple shapes answered without the matcher: a literal alone | done | `shLiterals`. |
| 30 | Simple shapes: one class alone, a sequence of classes, one unbounded loop, an alternation of literals, a case-insensitive ASCII literal | done | `shSet`, `shLoop` (its run's end by `RunEndOf`), `shLiterals` and `shForms`, answered before a working memory is taken (`ShapeSearch`). A sequence of classes is left to the anchored automaton, as in the crate. |
| 31 | What an enumeration carries: the range known to hold no rare line terminator, so a run of `.` is one search for LF and CR | done | Another way, as the crate: a run of `.` is one SWAR search for LF, CR and the lead byte of U+2028 and U+2029 (`reLine`); over UTF-16 a search for the four units. |
| 32 | What an enumeration carries: the range known to hold no form the search leaves out | not applicable | No form is left out of the search (item 22). |
| 33 | The give-back of a single-character loop by a scan for the units what follows can start with | done | `SetBack`: where what follows a greedy loop can start with one to three ASCII bytes alone, the give-back goes back to the last of them (`LastOfBack`). |
| 34 | The search's kernels as static methods with constants as arguments, no call inside | not applicable | A .NET JIT concern. The matcher and the readers of the automata are written once in include files and compiled for each encoding's unit; a finder is a class with a virtual `Find`, one indirect call a search. |

## Section 4.4: the automaton

| # | Optimisation | State | In this port |
|---|---|---|---|
| 35 | An automaton over ASCII for a pattern that needs no backtracking, built on first use, its steps bounded | done | The `Dfa` unit, for a test from the start of the text (`IsMatch`). |
| 36 | The automaton takes `\b` and `\B` | done | The `Dfa` and `Adfa` units. Not a boundary of a case-insensitive pattern with the u flag, which folds. |
| 37 | One table read per unit for both encodings | done | The automata read UTF-8 bytes and UTF-16 units alike. |
| 38 | An automaton over full Unicode | not applicable | Neither the reference nor the crate has one. |

## Beyond the reference: level with the `regex` crate

| # | Optimisation | State | In this port |
|---|---|---|---|
| 39 | Simple shapes and the dot's run by `memchr` | done | Items 30 and 31, by `memchr` and SWAR. |
| 40 | An anchored, leftmost-first automaton over ASCII for where a match from a start ends | done | `BuildAdfa`, read by `FindDfa` (the matcher): the states premultiplied by the stride, a match ending the lower threads; it gives up at the first unit beyond ASCII. Used for a pattern with no group and no backreference, at every start the search tries (`Run`). |
| 41 | The terms before a window's anchors read backwards from each occurrence, so that only the starts they allow are tried | done | `BuildReverseDfa`, run by `SearchReverse`, the starts it allows held as a mask of 128 bits in two words. The window and the look for a nearer occurrence count units, which are characters over ASCII alone, so a window whose reach holds a unit beyond ASCII goes to the plain search (a leftmost start the crate's reach of `hi` units can miss there, found by `tests/TestSearch.pas`). |
| 42 | Case-insensitive anchors cut to one length by `regex`'s literal rule | done | `LiteralCounts` and `Utf8Cuts`. |
| 43 | Two literals by the automaton only when they start with the same rare byte | done | Another way: literals with rare bytes at one position by `TFirstsFinder`; any other pair by the pair search. |
| 44 | A failed start of a leading loop's run passes over the occurrences in the rest of the run | done | `SearchAfterLoops` with one loop. |
| 45 | Over UTF-16, literals found by searches of the code units themselves | done | Another way: one literal by the search for its rarest unit (`IndexUnit`) where that is rare; up to four with one rare first unit by the search for it and a compare of each; several by `FindPacked`, which packs a chunk of units to their low bytes, searches them with the UTF-8 search of the literals' low bytes, and compares each candidate with the literals. A text can change between calls, so no packed chunk is kept from one search to the next: each search packs from where it starts, a chunk of 256 units and each after it twice the one before up to 4,096, into a buffer the thread keeps. |
| 46 | The anchor and what follows it checked at each occurrence before any start is walked back to | done | `TRestCheck`, dropped for good when fewer than one in eight of its first sixty-four checks ruled an occurrence out. |
| 47 | The reverse automaton's table premultiplied, and the look for a nearer occurrence made without a search call on a few bytes | done | `TReverseDfa` and `FindWithin8`. |
| 48 | Up to four literals with one rare first byte found by a search for it and a compare of each | done | `TFirstsFinder`, which also takes a rare byte at a later position. |
| 49 | Literals with forms written out in full answered by the search alone | done | `shLiterals`; an alternation of literals with forms cut short is compared at each occurrence by the anchored automaton where the text is ASCII (`shForms`). |
| 50 | A pattern with no literal read once by a forward automaton, not tried at every start its first set allows | done | `BuildForwardDfa`, built on the first search that wants it (`TProgram.Forward`), read by `ScanDfa` from the scan. |

## Beyond the reference: the C library level with the crate

| # | Optimisation | State | In this port |
|---|---|---|---|
| 51 | The matches of a global search a batch at a time | not applicable | A fix for the cost of a call across the C library's boundary; this port has no C library, and a global search through `Exec` calls the matcher directly. |

## Beyond the reference: what PCRE2 and V8 do

| # | Optimisation | State | In this port |
|---|---|---|---|
| 52 | A few literals found by two of their byte positions, each holding a few values, compared over a vector of starts (PCRE2's `fast_forward_char_pair_simd`) | done | `TPairFinder`: the rarest pair of positions whose values are apart, each a few masked tests (two values that differ in one bit are one test), sixteen starts a step with SSE2 (`PairBlock`, `PairBlockN`); a word's cases written out are known a literal once the bytes pass the sets of each position. It takes up to four tests a position, and one literal too. |
| 53 | One literal with a byte rare in text found by a search for that byte | done | `TRareFinder`, for a literal holding a capital, a digit, rare punctuation or one of `jqxzk`: of those, the byte with the least share of text (`UnitShare`, as the Java, Go and Julia engines choose), not the rarest by `memchr`'s table, which ranks Sherlock's k rarest. |
| 54 | A window of positions read one unit at a time before the first set is searched for (V8's Boyer-Moore lookahead) | done | `SkipWindow` and `SkipAhead`, for a pattern the forward automaton reads. Over UTF-8, where the window's bytes are up to four ranges, a vector search for a run of them as long as the window (`IndexRun`, AVX2 or SSE2): a start has one of the window's bytes at each of its places, so a run that short rules out every start in it. |
| 55 | Where every match starts with one literal, the automaton goes on after an occurrence rather than reading the literal again | done | `TAnchoredDfa.After` and `FindAfterDfa`, over UTF-8. |

## The rows still slower than V8

Over UTF-8, in a measured run of the harness (cores 0 to 11, the interleaved protocol), 7 of the 57 Industry
workloads are slower than V8, each counting what V8 counts:

| Workload | This port (µs) | V8 (µs) | Ratio | Where the time goes |
|---|--:|--:|--:|---|
| `(?:(?:25[0-5]\|2[0-4][0-9]\|[01]?[0-9][0-9])\.){3}...` | 777 | 723 | 1.08 | The run search of item 54 over the digits and dots of the text. |
| `Шерлок Холмс` | 45.6 | 39.7 | 1.15 | The search for the Ш's last byte over 1.5 MB of Russian text, 967 places for 724 matches. |
| `\w+` | 3,407 | 2,828 | 1.20 | 109,222 matches: each match's call from the search through the shape to the end of its run. |
| `Sherlock\|Holmes\|Watson\|Irene\|Adler\|John\|Baker` | 280 | 231 | 1.21 | The search for the range of the capitals, each found then compared with the literals of its byte. |
| `The` | 25.3 | 17.5 | 1.44 | The search for the T, nearly every one of which begins The. |
| `Holmes` | 22.4 | 14.3 | 1.56 | The search for the H, whose 1,278 places in the text each end a search for 461 matches. |
| `zqj` | 8.5 | 5.3 | 1.61 | The search for the z over 595 KB of text. |

The last three are each a few microseconds; the Go engine is slower than V8 on `zqj` too.

## The stack

The matcher keeps its choices on a stack of its own, so the depth of a match is bounded by memory. The parser, the
compiler and the builders of the automata walk the syntax tree, on the stack of the thread that compiles the pattern,
to the depth of `MaxNesting` groups at most.

`tools/stackprobe` asks the engine about the patterns the crate's stack probe asks about (deep, wide and long, in every
grammar, through every call over UTF-8 and UTF-16), each on a thread of its own with a stack of 4 MB and of 2 MB. On each
stack it answers the 964 probes as the crate's does on each of its threads: 374 answered, 590 refused, no fault (748 and
1,180 over the two), with Free Pascal 3.2.2 on Linux. The deep probes (the groups, lookarounds, quantified groups and
classes nested to the limit, one past it and far past it) are answered the same on stacks of 1 MB, the default of a
thread on Windows, and of 512 KB. A stack that overflows ends the process, which the probe counts as a fault.
