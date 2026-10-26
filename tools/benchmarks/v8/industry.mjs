// The Industry workloads under V8: every pattern with the flags the Corvus rows carry (its own plus g and u), the
// matches counted by the ECMA-262 global loop, over the same texts as the .NET benchmark. Prints JSON of
// {workload id: {median, min, max}} in nanoseconds per Count, the figures of several timed passes after a warm-up.
//
//   node industry.mjs <workloads.json> [seconds per workload] [passes]
//   node industry.mjs --one <workloads.json> <index> <seconds> <passes>
//
// With --one it times the one workload and prints one line of JSON ({median, min, max, count, reps, engine}): the
// figure of one turn of an interleaved run (this repository's Driver.cs, the Rust harness's industry.rs), which
// starts it in a process of its own.
// Run it as the pinned procedure runs the .NET benchmark: on the performance cores, after a settle, nothing else on
// the host. Node 24 (V8 13.6) is the oracle of the test data, so the same build is used here.
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { join } from "node:path";
import { homedir } from "node:os";

const one = process.argv[2] === "--one";
const args = one ? process.argv.slice(3) : process.argv.slice(2);
const workloads = JSON.parse(readFileSync(args[0], "utf8"));
const index = one ? Number(args[1]) : -1;
const seconds = Number((one ? args[2] : args[1]) ?? 1.5);
const passes = Number((one ? args[3] : args[2]) ?? 5);
const dir = process.env.CORVUS_REGEX_TEXTS ?? join(homedir(), ".local", "share", "corvus-regex-benchmarks");
const texts = new Map();
function text(file) {
  if (!texts.has(file) && process.env.CORVUS_REGEX_PLAIN) {
    try {
      texts.set(file, readFileSync(join(process.env.CORVUS_REGEX_PLAIN, file.replace(/\.gz$/, "")), "utf8"));
    } catch { /* unzipped below */ }
  }
  if (!texts.has(file)) {
    let bytes = gunzipSync(readFileSync(join(dir, file)));
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) bytes = bytes.subarray(3);
    texts.set(file, bytes.toString("utf8"));
  }
  return texts.get(file);
}

// The count of a global search by RegExp.prototype.test, which sets lastIndex as exec does without building the
// match array, so V8 pays for the search alone. An empty match leaves lastIndex where it was, and is moved on by one
// code point as RegExp.prototype[Symbol.matchAll] moves it.
function count(re, s) {
  re.lastIndex = 0;
  let n = 0;
  for (;;) {
    const from = re.lastIndex;
    if (!re.test(s)) return n;
    n++;
    if (re.lastIndex === from) {
      if (from >= s.length) return n;
      const c = s.charCodeAt(from);
      re.lastIndex = from + (c >= 0xd800 && c <= 0xdbff && from + 1 < s.length ? 2 : 1);
    }
  }
}

const engine = "V8 " + process.versions.v8 + " (Node " + process.versions.node + ")";
const results = {};
for (const w of one ? [workloads[index]] : workloads) {
  const s = text(w.file);
  const flags = [...new Set((w.flags + "gu").split(""))].join("");
  const re = new RegExp(w.pattern, flags);
  const expected = count(re, s);
  // Warm up until the JIT has settled, then time passes of as many counts as fit the budget.
  const warmEnd = process.hrtime.bigint() + BigInt(Math.round(seconds * 0.4e9));
  let reps = 0;
  while (process.hrtime.bigint() < warmEnd) { if (count(re, s) !== expected) throw new Error("count changed: " + w.id); reps++; }
  const perPass = Math.max(1, Math.round(reps * 0.6 / passes));
  const times = [];
  for (let p = 0; p < passes; p++) {
    const t0 = process.hrtime.bigint();
    for (let k = 0; k < perPass; k++) count(re, s);
    times.push(Number(process.hrtime.bigint() - t0) / perPass);
  }
  times.sort((a, b) => a - b);
  results[w.id] = { median: times[passes >> 1], min: times[0], max: times[passes - 1], count: expected, reps: perPass * passes };
  if (one) {
    process.stdout.write(JSON.stringify({ ...results[w.id], engine }) + "\n");
    process.exit(0);
  }
  process.stderr.write(`${w.id.padEnd(60)} ${(times[passes >> 1] / 1000).toFixed(1).padStart(10)} us  (${expected} matches)\n`);
}
process.stdout.write(JSON.stringify({ engine, results }, null, 1));
