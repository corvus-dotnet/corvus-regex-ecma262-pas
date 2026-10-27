#!/usr/bin/env python3
"""Writes the data file of an Industry benchmark run, in the shape of the results page
(tools/benchmarks/results-page/generate_site.py documents it: meta, vocab, measures, impls, schemas, results). The
central benchmark site (https://corvus-oss.org/corvus-regex-ecma262-benchmarks/) runs this repository's harness image
each night and builds the one page of figures from its data file; this repository publishes no results of its own.

Usage: industry-results.py [--workloads <workloads.json>] --run <harness results json> --out <data file>
                           --compliance-corvus <compliance file>
                           [--compliance-v8 <tools/benchmarks/v8/dataset.mjs's compliance file>] [--run-url <url>]

The run is the output of the harness (tools/benchmarks/industry.pas, which run.sh runs), whose facts are the run's
own record of itself: the processor, the cores it was given, the system, the load when it started, the runner when it
is a GitHub-hosted one, the Free Pascal that built it, the engines' versions, the commit, the seconds and passes of each
figure, and the time it ended. V8 is timed by tools/benchmarks/v8/industry.mjs, which names its engine. Nothing is typed in: what is
not in a record is not said.

Each engine that claims ECMA-262 carries its compliance over the ECMA-262 test data, the compliance file its data-set
runner writes (--compliance: the counts, the runner and the calls it makes, and what it leaves out): this library's by
tools/dataset/run.pas and V8's by tools/benchmarks/v8/dataset.mjs under Node. TRegExpr, in either build, does not claim
it, and carries "not ECMA-262".
"""
import argparse, json, os, re, sys


def failure(r):
    """A figure the harness gave no time for, as the data file carries it: stopped at the harness's limit
    ({"limit": s}), a count of matches that differs from V8's ({"wrongCount": {"counted": n, "v8": m}}), or another
    failure with what the harness said ({"error": "..."})."""
    if "limit" in r:
        return {"limit": r["limit"]}
    m = re.match(r"counted (\d+) where V8 counts (\d+)", str(r.get("error", "")))
    if m:
        return {"wrongCount": {"counted": int(m.group(1)), "v8": int(m.group(2))}}
    # A count other than V8's from an engine of another dialect ("<engine> n, V8 m"): a wrong answer all the same.
    m = re.search(r"(\d+), V8 (\d+)$", str(r.get("differs", "")))
    if m:
        return {"wrongCount": {"counted": int(m.group(1)), "v8": int(m.group(2))}}
    return {"error": r["error"]} if "error" in r else None

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--v8", help="the V8 harness's own results, for a run whose harness did not run V8 itself")
ap.add_argument("--out", required=True)
ap.add_argument("--compliance-corvus", required=True)
ap.add_argument("--compliance-v8", help="V8's data-set run; absent for a run without V8 (V8=0)")
ap.add_argument("--run-url", default="")
ap.add_argument("--workloads", help="the workloads.json of the run (tools/benchmarks/workloads.json when not given)")
args = ap.parse_args()

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
run = json.load(open(args.run, encoding="utf-8"))
facts = run["facts"]
# V8 runs inside the interleaved run (results["v8"], its engine in the facts); a separate V8 run is still read. A run
# without V8 (V8=0, whose counts were checked against the workloads' v8Count) has no V8 row.
if "v8" in run["results"]:
    v8 = {"engine": facts.get("v8", "V8"), "results": run["results"]["v8"]}
elif args.v8:
    v8 = json.load(open(args.v8, encoding="utf-8"))
else:
    v8 = None
workloads = json.load(open(args.workloads or os.path.join(root, "tools", "benchmarks", "workloads.json"), encoding="utf-8"))
ids = [w["id"] for w in workloads]


def compliance(path):
    """The compliance object a data-set runner wrote (its --compliance file), which the page reads as it is: the counts
    (every answer the engine never gave, a limit, a crash, a hang or a worker that gave up, in `limited`, as the judging
    rule of the test data counts it), `judge` and `excludes`, and for counts checked in beside the harness the commit
    of the test data they were made at (`dataCommit`), which the page judges them against. None, with a warning on
    stderr, when the file cannot be read or lacks one of them: the engine is then written without a compliance, and
    the run keeps its figures."""
    try:
        with open(path, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError) as e:
        print(f"warning: {path} could not be read ({e}), so its engine is written without a compliance", file=sys.stderr)
        return None
    missing = [k for k in ("right", "wrong", "refused", "acceptedInvalid", "limited", "judge", "excludes")
               if not isinstance(c, dict) or k not in c]
    if missing:
        print(f"warning: {path} has no {', '.join(missing)}, so its engine is written without a compliance", file=sys.stderr)
        return None
    return c


ENGINES = [
    ("corvus-utf8", "corvus-regex-ecma262 UTF-8", "Object Pascal", facts.get("corvus-regex-ecma262", ""), compliance(args.compliance_corvus)),
    ("corvus-utf16", "corvus-regex-ecma262 UTF-16", "Object Pascal", facts.get("corvus-regex-ecma262", ""), compliance(args.compliance_corvus)),
    ("tregexpr", "TRegExpr", "Object Pascal", facts.get("tregexpr", ""), "not ECMA-262"),
    ("tregexpr-unicode", "TRegExpr Unicode", "Object Pascal", facts.get("tregexpr", ""), "not ECMA-262"),
]
results = {}
for key, name, _, _, _ in ENGINES:
    rows = run["results"].get(key, {})
    results[name] = {}
    for w in ids:
        r = rows.get(w)
        if r is None:
            continue
        results[name][w] = failure(r) if "error" in r or "differs" in r else {"time": {"median": r["median"], "min": r["min"], "max": r["max"]}}
if v8:
    v8_name = "V8"
    ENGINES.append(("v8", v8_name, "V8", v8["engine"], compliance(args.compliance_v8)))
    results[v8_name] = {}
    for w in ids:
        r = v8["results"].get(w)
        results[v8_name][w] = {"time": {"median": r["median"], "min": r["min"], "max": r["max"]}} if r and "error" not in r else (failure(r) if r else None)

TEXTS = {"sherlock": "Sherlock Holmes (0.6 M chars)", "leipzig": "Leipzig corpus (16 M chars)", "mariomka": "mariomka (0.05 M chars)",
         "rebar-ru": "OpenSubtitles ru (1.2 M chars)", "rebar-zh": "OpenSubtitles zh (0.3 M chars)"}
runner = " ".join(x for x in (facts.get("runner", ""), facts.get("runner_os", ""), facts.get("image", "")) if x)
host = f"{facts.get('cpu', '')}, {facts.get('os', '')}, {facts.get('cores', '')} cores (affinity {facts.get('affinity', '')}), load {facts.get('load', '')} at the start"
if facts.get("protocol") == "interleaved":
    job = (f"interleaved: every workload in turn, each in {facts.get('rounds')} rounds of the engines in turn (their order "
           f"turned each round), each figure a process of its own warmed and timed for {facts.get('seconds')} s "
           f"({facts.get('passes')} passes); a workload's figure is the median of its rounds, the spread its fastest "
           f"and slowest round")
    over = facts.get("spread_over", "")
    spread = (f"over {float(facts.get('spread_limit', 0)) * 100:.0f}% (slowest - fastest) / median: {over}" if over
              else f"every figure within {float(facts.get('spread_limit', 0)) * 100:.0f}% (slowest - fastest) / median")
else:
    job = f"each figure the median of {facts.get('passes')} passes after a warm-up, {facts.get('seconds')} s for each workload of each engine, each in a process of its own"
    spread = ""

data = {
    "meta": {
        "title": "corvus-regex-ecma262 for Object Pascal: the Industry benchmarks",
        "lede": "This library over UTF-8 and UTF-16 beside Free Pascal's TRegExpr and V8 over the Industry workloads of dotnet/performance.",
        "repo": "corvus-dotnet/corvus-regex-ecma262-pas",
        "commit": facts.get("commit", "")[:7],
        "date": run.get("end") or facts.get("date", ""),
        "start": facts.get("date", ""),
        "runner": runner,
        "host": host,
        "runtime": facts.get("fpc", ""),
        "job": job,
        "runUrl": args.run_url,
        "runs": int(facts.get("passes") or 0),
        "versions": {name: version for _, name, _, version, _ in ENGINES},
        "facts": [["Host", host]] + ([["Runner", runner]] if runner else []) + [["Runtime", facts.get("fpc", "") + ("; " + v8["engine"] if v8 else "")], ["Harness", job]]
                 + ([["Spread", spread]] if spread else []),
        "method": "<p>Each figure is one count of every match a global search finds over the whole text, after an empty match going on one character later. "
                  "This library runs with the workload's flags and u, over UTF-8 checked once before the timing (a TUtf8Text) and over UTF-16 (a UnicodeString), counted by Count; "
                  "TRegExpr, which Free Pascal ships, in its two builds, the RegExpr unit over the bytes of the UTF-8 text and the uRegExpr unit over its UTF-16, each with the pattern as it is and the flags i, m and s, counted by Exec and ExecNext; "
                  "V8 with gu added, counted by a JavaScript loop. "
                  "Each figure is a process of its own: this library and TRegExpr in a program Free Pascal built, V8 in Node.</p>",
    },
    "vocab": {
        "impl": "engine", "impls": "engines", "Impls": "Engines",
        "schema": "workload", "schemas": "workloads", "Schema": "Workload", "Schemas": "Workloads",
        "failed": "did not run", "centre": "Median", "spread": "fastest to slowest pass",
        "barLegend": "median of the passes", "whiskerLegend": "whisker: the fastest and the slowest pass",
    },
    "measures": {"time": {"label": "Time", "long": "time per count", "parts": ["time"]}},
    "impls": [{"id": name, "name": name, "group": group, "version": version, **({"compliance": c} if c is not None else {})}
              for _, name, group, version, c in ENGINES],
    "schemas": [{"name": w, "note": "",
                 "meta": [["text", TEXTS.get(w.split(":")[0], w.split(":")[0])]]} for w in ids],
    "results": results,
}
os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
with open(args.out, "w", encoding="utf-8") as fo:
    json.dump(data, fo, indent=1, ensure_ascii=False)
print(f"wrote {args.out}: {len(ids)} workloads, {len(ENGINES)} engines")
