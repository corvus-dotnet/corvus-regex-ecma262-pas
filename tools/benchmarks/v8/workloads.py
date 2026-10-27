#!/usr/bin/env python3
"""Writes the Industry workloads as JSON from the benchmark project's own list, with the names the run records.

Usage: workloads.py <path to Solutions/Corvus.Regex.Ecma262.Benchmarks/Industry.cs> > workloads.json
"""
import json, re, sys

src = open(sys.argv[1], encoding="utf-8").read()
FILES = {"S": "sherlock.txt.gz", "L": "3200.txt.gz"}
NAMES = {"S": "sherlock", "L": "leipzig"}

def cs_string(token):
    if token.startswith('@"'):
        return token[2:-1].replace('""', '"')
    body = token[1:-1]
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(m.group(1), "\\" + m.group(1)), body)

STR = r'(@"(?:[^"]|"")*"|"(?:[^"\\]|\\.)*")'
out = []
for m in re.finditer(r'\b([SL])\(' + STR + r'(?:,\s*' + STR + r')?\)', src):
    kind, pattern, flags = m.group(1), cs_string(m.group(2)), cs_string(m.group(3)) if m.group(3) else ""
    out.append({"name": NAMES[kind], "pattern": pattern, "flags": flags, "file": FILES[kind]})
for m in re.finditer(r'new\(' + STR + r',\s*' + STR + r',\s*' + STR + r',\s*[^,]+,\s*' + STR + r'\)', src):
    out.append({"name": cs_string(m.group(1)), "pattern": cs_string(m.group(2)), "flags": cs_string(m.group(3)), "file": cs_string(m.group(4))})

# The order of Workloads.All: Mariomka, Sherlock, Leipzig, Rebar; and the display name the run records.
order = {"mariomka": 0, "sherlock": 1, "leipzig": 2, "rebar-ru": 3, "rebar-zh": 3}
out.sort(key=lambda w: order[w["name"]])
for w in out:
    p = w["pattern"]
    w["id"] = w["name"] + ": " + (p[:37] + "..." if len(p) > 40 else p) + (" /" + w["flags"] if w["flags"] else "")
json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
