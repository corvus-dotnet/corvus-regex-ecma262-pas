#!/usr/bin/env bash
# The image's entry point: tools/benchmarks/run.sh over the mounted workloads, texts and (when mounted) test data.
set -euo pipefail
data=()
if [ -d /data ]; then data=(/data); fi
mkdir -p /out
exec /harness/tools/benchmarks/run.sh /workloads.json /texts /out/industry.json "${data[@]}"
