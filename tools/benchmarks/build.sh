#!/usr/bin/env bash
# Readies the harness: the harness program (tools/benchmarks/industry.pas) and the test data runner
# (tools/dataset/run.pas) built into bin/ with Free Pascal. run.sh calls it, and the image (Dockerfile) calls it when
# it is built. FPC names the compiler (fpc on the PATH by default).
set -euo pipefail
cd "$(dirname "$0")/../.."
fpc="${FPC:-fpc}"
mkdir -p lib bin
for program in tools/benchmarks/industry.pas tools/dataset/run.pas; do
  "$fpc" -O3 -v0 -FUlib -Fusrc -Fisrc -FEbin "$program"
done
