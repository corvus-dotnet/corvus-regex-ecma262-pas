// The ECMA-262 test data's test answers judged against the V8 of this Node, as tools/src/bin/dataset.rs judges an
// engine: each record under each grammar V8 found it valid in when the data was written (u, none, and v in the file
// that has it), every text as a JavaScript string (UTF-16), records and tests marked v8_deviation left out.
// captures.jsonl is judged on exec, the global search, the sticky flag, replace, replaceAll, split and split3, each
// one answer, as the Rust runner judges an engine over UTF-16. exec/test262.jsonl, the exec calls of test262, is
// judged last: each call one exec with the record's flags from its lastIndex, one answer. With the Node the data was
// written with (24.22.1),
// every answer is V8's own, so this is the check that the data and the V8 on the page agree; with another, a
// difference is a place where its V8 differs.
//
// Each file is judged in a process of its own, as the data's verify.js checks it: V8 answers two hand-written
// patterns with a word boundary in a case-insensitive modifier group, (?i:\Bs) and (?i:\bk\b), otherwise once a
// process has compiled a great many patterns, and in one process for every file it gets them wrong.
//
//   node dataset.mjs <data directory> [--compliance <file>]
//
// The last line has the counts in the shape of the Rust runner's: records, right, wrong, refused-valid,
// accepted-invalid, limit, errors. With --compliance, the engine's compliance object is written to the file, as the
// benchmark page reads it (docs/implementing-a-source.md in corvus-regex-ecma262-benchmarks): the counts, the runner
// and the calls it makes, and what it leaves out (UTF-8, since a JavaScript string is UTF-16).
import { spawnSync } from "node:child_process";
import { Worker } from "node:worker_threads";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = process.argv[2];
// node dataset.mjs <data directory> --file <name>: one file, its counts written as JSON (see the top).
const only = process.argv[3] === "--file" ? process.argv[4] : null;
const compliancePath = process.argv[3] === "--compliance" ? process.argv[4] : null;
// What the compliance says of how the engine was judged: this file (each repository's copy is this one) and the calls.
const JUDGE = {
  runner: "https://github.com/corvus-dotnet/Corvus.Regex.Ecma262/blob/main/tools/benchmarks/v8/dataset.mjs",
  calls: { utf16: ["RegExp.prototype.test", "RegExp.prototype.exec", "String.prototype.matchAll", "String.prototype.replace", "String.prototype.split"] },
};
const REPLACEMENT = "<$&|$1|$2|$10|$<a>|$$|$`|$'>";
const EXEC = "exec/test262.jsonl";

function captures(m) {
  if (m === null) return null;
  const out = [[m.index, m.index + m[0].length]];
  if (m.indices) {
    for (let g = 1; g < m.length; g++) out.push(m.indices[g] === undefined ? null : [m.indices[g][0], m.indices[g][1]]);
  }
  return out;
}

// The answers of captures.jsonl, in order, as generate-captures.js of the data writes them; sticky is not asked of an
// empty text.
const CAPTURES = ["exec", "all", "sticky", "replace", "replaceAll", "split", "split3"];
// One answer of captures.jsonl V8 gives, as generate-captures.js of the data writes it.
function captureAnswer(what, pattern, flags, text) {
  switch (what) {
    case "exec": return captures(new RegExp(pattern, flags + "d").exec(text));
    case "all": {
      const all = [];
      for (const m of text.matchAll(new RegExp(pattern, flags + "dg"))) {
        all.push(captures(m));
        if (all.length >= 20) break;
      }
      return all;
    }
    case "sticky": {
      const y = new RegExp(pattern, flags + "dy");
      y.lastIndex = 1;
      return captures(y.exec(text));
    }
    case "replace": return text.replace(new RegExp(pattern, flags), REPLACEMENT);
    case "replaceAll": return text.replace(new RegExp(pattern, flags + "g"), REPLACEMENT);
    case "split": return text.split(new RegExp(pattern, flags)).map((s) => (s === undefined ? null : s));
    default: return text.split(new RegExp(pattern, flags), 3).map((s) => (s === undefined ? null : s));
  }
}
// The answer of a call of exec/test262.jsonl V8 gives, as test262-exec.js of the data writes it: exec from the call's
// lastIndex on a RegExp of the record's flags with d. The named groups are built by definition, not assignment, since a
// group may be called __proto__.
function execAnswer(re, flags, text, lastIndex) {
  const carries = flags.includes("g") || flags.includes("y");
  re.lastIndex = lastIndex;
  const m = re.exec(text);
  if (m === null) return null;
  const span = (x) => (x === undefined ? null : [x[0], x[1]]);
  const a = { captures: Array.from(m.indices, span) };
  if (m.indices.groups) a.groups = Object.fromEntries(Object.keys(m.indices.groups).map((k) => [k, span(m.indices.groups[k])]));
  if (carries) a.lastIndex = re.lastIndex;
  return a;
}
// For a run with a limit of time on each answer (tools/benchmarks/tregex-compliance.py, for an engine that cannot be
// stopped in a match), DATASET_LIMIT=1: each answer is written to stderr as it is given, and a watchdog thread ends
// the process when one has run for LIMIT_MS, timed from just before the engine is called, writing "L". The lines are
// "R <file> <index>" before each record, "S" for one left out, "C <done> <right> <wrong> <refused> <accepted>
// <unanswered>" for what was counted since the last ("C 1" ends an answer), and "E" after the record. DATASET_FROM
// ("<file>\t<index>\t<answer>\t<spent>") starts at that answer of that record, the answers before it (given by the
// process before) not asked and what was counted among them not written again; with spent 1, the record has had as many
// answers at the limit as a record may, and its other answers are unanswered without being asked. The index of a record is that of its line
// among the file's lines that are not empty, and an answer's is its place among the record's answers. V8's run sets
// neither.
const LIMIT_MS = 2000;
const from = process.env.DATASET_FROM ? process.env.DATASET_FROM.split("\t") : null;
const limitMode = process.env.DATASET_LIMIT === "1";
// When the answer being given began, in milliseconds since the epoch (0 when none is being given), shared with the
// watchdog through Atomics, without which another thread may read a stale time.
const started = new BigInt64Array(new SharedArrayBuffer(8));
if (limitMode && only) {
  new Worker(`
    const { workerData } = require("node:worker_threads");
    const { writeSync } = require("node:fs");
    const started = new BigInt64Array(workerData);
    setInterval(() => {
      const s = Number(Atomics.load(started, 0));
      if (s !== 0 && Date.now() - s > ${LIMIT_MS}) {
        writeSync(2, "\\nL\\n");
        process.kill(process.pid, "SIGKILL");
      }
    }, 10);
  `, { eval: true, workerData: started.buffer }).unref();
}
// One file's counts.
function judgeFile(name) {
  let records = 0, skipped = 0, fr = 0, fw = 0, ff = 0, fa = 0, fl = 0;
  let index = -1, next = 0, first = 0, spent = false;
  let written = [0, 0, 0, 0, 0];
  const write = (done) => {
    if (!limitMode) return;
    const now = [fr, fw, ff, fa, fl];
    process.stderr.write(`C\t${done ? 1 : 0}\t${now.map((v, k) => v - written[k]).join("\t")}\n`);
    written = now;
  };
  // One answer: whether `judged` finds it right.
  const ask = (judged) => {
    if (next++ < first) {
      written = [fr, fw, ff, fa, fl];
      return;
    }
    write(false);
    if (spent) {
      fl++;
      write(true);
      return;
    }
    Atomics.store(started, 0, BigInt(Date.now()));
    const ok = judged();
    Atomics.store(started, 0, 0n);
    if (ok) fr++; else fw++;
    write(true);
  };
  for (const line of readFileSync(join(dir, name), "utf8").split("\n")) {
    if (!line) continue;
    index++;
    if (from && name === from[0] && index < Number(from[1])) continue;
    const r = JSON.parse(line);
    if (limitMode) process.stderr.write(`R\t${name}\t${index}\n`);
    if (r.v8_deviation) {
      skipped++;
      if (limitMode) process.stderr.write("S\n");
      continue;
    }
    records++;
    next = 0;
    const here = from && name === from[0] && index === Number(from[1]);
    first = here ? Number(from[2] ?? 0) : 0;
    spent = here && from[3] === "1";
    written = [fr, fw, ff, fa, fl];
    if (name === EXEC) {
      let re = null;
      try { re = new RegExp(r.pattern, r.flags.includes("d") ? r.flags : r.flags + "d"); } catch { re = null; }
      if (re === null) {
        ff++;
      } else {
        for (const t of r.tests ?? []) {
          if (t.v8_deviation) continue;
          ask(() => JSON.stringify(execAnswer(re, r.flags, t.text, t.lastIndex)) === JSON.stringify(t.answer));
        }
      }
    } else {
      const modes = [["u", "unicode", r.valid.unicode], ["", "legacy", r.valid.legacy]];
      if ("unicode_sets" in r.valid) modes.push(["v", "unicode_sets", r.valid.unicode_sets]);
      for (const [suffix, answer, valid] of modes) {
        let re = null;
        try { re = new RegExp(r.pattern, r.flags + suffix); } catch { re = null; }
        if (re === null) { if (valid) ff++; continue; }
        if (!valid) { fa++; continue; }
        for (const t of r.tests ?? []) {
          if (t.v8_deviation || !(answer in t)) continue;
          if (name === "captures.jsonl") {
            for (const what of CAPTURES) {
              if (what === "sticky" && t.text.length === 0) continue;
              ask(() => JSON.stringify(captureAnswer(what, r.pattern, r.flags + suffix, t.text)) === JSON.stringify(t[answer][what]));
            }
            continue;
          }
          ask(() => {
            re.lastIndex = 0;
            return re.test(t.text) === t[answer];
          });
        }
      }
    }
    write(false);
    if (limitMode) process.stderr.write("E\n");
  }
  return { records, skipped, right: fr, wrong: fw, refused: ff, accepted: fa, limited: fl };
}

if (only) {
  console.log(JSON.stringify(judgeFile(only)));
} else {
  let records = 0, skipped = 0, right = 0, wrong = 0, refused = 0, accepted = 0, limited = 0;
  const start = Date.now();
  const files = readdirSync(dir).filter(f => f.endsWith(".jsonl")).sort();
  if (existsSync(join(dir, EXEC))) files.push(EXEC);
  for (const name of files) {
    if (from && name !== EXEC && (from[0] === EXEC || name < from[0])) continue;
    // Progress goes to this process's stderr as it is written; the counts come back on stdout.
    const child = spawnSync(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), dir, "--file", name],
      { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], maxBuffer: 1 << 26 });
    if (child.status !== 0) throw new Error(`${name}: the process that judged it exited with ${child.status}`);
    const c = JSON.parse(child.stdout.trim().split("\n").pop());
    records += c.records; skipped += c.skipped;
    right += c.right; wrong += c.wrong; refused += c.refused; accepted += c.accepted; limited += c.limited;
    console.log(`${name.padEnd(24)} right ${String(c.right).padStart(10)}  wrong ${String(c.wrong).padStart(6)}  refused-valid ${String(c.refused).padStart(4)}  accepted-invalid ${String(c.accepted).padStart(4)}${c.limited ? `  limit ${c.limited}` : ""}`);
  }
  if (compliancePath) {
    writeFileSync(compliancePath, JSON.stringify({ right, wrong, refused, acceptedInvalid: accepted, limited, judge: JUDGE,
      excludes: [{ class: "encoding", leaves: "utf8" }] }) + "\n");
  }
  console.log("");
  console.log(`records ${records} (skipped ${skipped} deviations)  right ${right}  wrong ${wrong}  refused-valid ${refused}  accepted-invalid ${accepted}  limit ${limited}  errors 0  in ${((Date.now() - start) / 1000).toFixed(1)}s  (${process.version}, ${typeof Graal !== "undefined" ? "GraalJS " + Graal.versionGraalVM : "V8 " + process.versions.v8})`);
}
