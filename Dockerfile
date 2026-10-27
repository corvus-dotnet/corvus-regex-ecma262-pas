# The benchmark harness as an image: this library and Free Pascal's TRegExpr in a program Free Pascal 3.2.2 built, and
# Node 24 for the V8 rows, with tools/benchmarks/run.sh as the entry point. The whole invocation is
#
#   docker run --rm -v <workloads.json>:/workloads.json:ro -v <texts dir>:/texts:ro -v <out dir>:/out <image>
#
# which writes /out/industry.json, the run's data file in the results page's shape. The ECMA-262 test data is cloned
# at depth 1 inside the container unless its data/ directory is mounted at /data. JOB=short, SECONDS_EACH, PASSES,
# CORES, SETTLE, V8 and RUN_URL pass through (see tools/benchmarks/run.sh). The central benchmark site runs this image
# each night; .github/workflows/harness-image.yml builds, smoke-runs and publishes it.
FROM debian:bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*
WORKDIR /harness
COPY . .
RUN test "$(fpc -iV)" = 3.2.2 && tools/benchmarks/build.sh

FROM node:24.22.0-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 git curl ca-certificates util-linux gzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /harness
COPY --from=build /harness /harness
# The commit the image is built from, for the run's record (the image has no .git).
ARG COMMIT=""
ENV SKIP_BUILD=1 CORVUS_COMMIT=$COMMIT
ENTRYPOINT ["/harness/tools/benchmarks/container-entry.sh"]
