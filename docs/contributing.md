# Contributing

This guide is for someone who wants to build the library, run its tests and gates, and open a pull request. It covers
the tools, the build step by step, the gates every change must pass, and how a pull request is released. The
[design document](design.md) describes what is underneath.

## 1. Tools

| Tool | Needed for | Version |
|---|---|---|
| Free Pascal | Everything | 3.2.2 |
| PowerShell 7 | The build script, the getting-started runner, the table and API generators, the release scripts | 7.4 or later |
| Git | The repository and the test data | Any recent version |
| Node.js | The test data for other versions of Unicode and for ECMAScript 2020, and the V8 rows of the harness | 24 (the V8 it carries is the oracle) |

- **Windows:** the Free Pascal 3.2.2 installer from [freepascal.org](https://www.freepascal.org/download.html);
  `winget install Microsoft.PowerShell Git.Git OpenJS.NodeJS.LTS`.
- **Linux:** `fpc` 3.2.2 from the distribution (`apt install fpc` on Ubuntu) or freepascal.org's tarball; PowerShell
  from Microsoft's feed; Git and Node.js 24 from the distribution or nodejs.org.
- **macOS:** the Free Pascal 3.2.2 package from freepascal.org; `brew install powershell git node@24`.

`fpc -iV` must print 3.2.2.

## 2. Getting the sources

```
git clone https://github.com/corvus-dotnet/corvus-regex-ecma262-pas.git
git clone https://github.com/corvus-dotnet/ecma262-regex-test-data.git   # beside it: the test data
git clone https://github.com/corvus-dotnet/corvus-regex-ecma262-rs.git   # beside it: for the table check
cd corvus-regex-ecma262-pas
```

The test data is the oracle for the engine (design, section 6). It is not vendored; the commands below assume it at
`../ecma262-regex-test-data`.

## 3. Building and testing, step by step

Every command runs from the repository root.

1. **Build.** `pwsh tools/build.ps1 -Options "-O3"` builds every unit with the compiler's warnings shown, the tests,
   the stack probe and the test-data runner into `bin/`.
2. **The tests.** `bin/TestEngine`, `bin/TestSearch` and `bin/TestAllocations`; again (the first two) with
   `CORVUS_REGEX_MEMO_FROM_THE_START=1`, which takes the memo of failed places into use from the first step.
3. **The getting-started programs.** `pwsh tools/docs/run-getting-started.ps1 -Options "-O3"` compiles and runs each
   program of the page.
4. **The API reference.** After a change to the unit's interface or its comments, run `pwsh tools/docs/gen-api.ps1`;
   `pwsh tools/docs/gen-api.ps1 -Check` must pass.
5. **The stack probe.** `bin/stackprobe` asks the deep, wide and long patterns; none may overflow.
6. **The test data.** `bin/run ../ecma262-regex-test-data/data wrong-cases.tsv --threads 4` must report 0 wrong, 0
   refused and 0 at a limit, and again with `CORVUS_REGEX_MEMO_FROM_THE_START=1`. For the other versions of Unicode and
   for ECMAScript 2020, write the data with its own scripts and run it with the engine set to match:

   ```
   node ../ecma262-regex-test-data/unicode.js apply 13.0 /tmp/u13 ../ecma262-regex-test-data/data
   bin/run /tmp/u13 wrong-u13.tsv --unicode 13
   node ../ecma262-regex-test-data/edition.js apply /tmp/es2020 "" ../ecma262-regex-test-data/data
   bin/run /tmp/es2020 wrong-es2020.tsv --edition es2020
   ```

## 4. The Unicode tables

The tables of each version of Unicode (the units `Ucd<major>`, with `Strings<major>.inc`) and the property names of
ECMAScript 2020 (`Es2020`) are written from the Rust crate's, so that every engine carries the same tables. After the
crate's tables change:

```
$src = '../corvus-regex-ecma262-rs/corvus-regex-ecma262/src'
foreach ($major in 13, 17, 18) {
  ./tools/unicode/gen-ucd-tables.ps1 -CrateTables "$src/tables$major.rs"
  ./tools/unicode/gen-strings.ps1 -CrateStrings "$src/strings$major.rs"
}
./tools/unicode/gen-es2020-properties.ps1 -CrateEs2020 "$src/es2020.rs"
```

With `-Check`, each script fails when what is checked in differs, as CI runs them.

## 5. Benchmarks

`tools/benchmarks/run.sh <workloads.json> <texts directory> <out.json>` runs this library, TRegExpr and V8 over the
Industry workloads; the script lists what it needs and its settings. The published figures are on
[the benchmark page](https://corvus-oss.org/corvus-regex-ecma262-benchmarks/), which runs this repository's harness
image each night beside every other engine; a run on another machine is comparable with itself, never with the page.

## 6. What a pull request needs

- **The gates of section 3** passing on the change as pushed.
- **The case in the test data first** for a change to the engine's semantics: add the pattern to the data repository's
  family it belongs to, regenerate with its `generate.js`, check with `verify.js`, and pin the new data commit in
  `ci.yml`. V8 is the oracle; a fault V8 has is marked in the data, never copied into the engine.
- **A failing test first** for a bug: the test that reproduces it, then the fix.
- **A measured run** for a change made for speed, with the rows it moved.
- **The design document kept current**, describing the library as it is.
- **Comments** on every declaration of the unit's interface, since the API reference is generated from them.
- **The getting-started page** kept true: its programs are compiled and run in CI.

### Conventions

- Free Pascal in Delphi mode, written to compile with Delphi, using only the RTL.
- Nothing on the match path asks for memory once warm, and the allocation test holds that line.
- Every assembler kernel has a fallback, and the tests pass with each fallback forced.

## 7. Releases

Every pull request merged into main releases the library with the next patch version, unless it is labelled
`no_release`: `auto-release.yml` runs `tools/release` on the merge, which tags `v<version>` on a commit with the version
written into `EcmaRegexVersion` (main keeps 0.0.0), and `pascal-publish.yml` adds the source archives to the release. A
change to the benchmark harness alone is a harness release, which publishes the harness image. A pull request that needs
a minor or major version sets `nextVersion` in `.github/release.json`. The documentation site takes the published
documents (the getting-started page, the API reference, the design document and this guide) from `main`, and they
describe the latest release: a change to them alone is merged with `no_release`, and a change to the API carries its
documents, which its release brings into step.

`main` is protected by a ruleset: changes arrive by pull request, and the `CI gate` and `Harness image` checks must be
green on the branch as it will merge.
