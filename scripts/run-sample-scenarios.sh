#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_SCRIPT="${ROOT_DIR}/scripts/run-http-benchmark.sh"

TARGET_URL="${TARGET_URL:-}"
PRIMARY_LABEL="${PRIMARY_LABEL:-alb}"
DIRECT_URLS="${DIRECT_URLS:-}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/results}"
RESET_SUMMARY="${RESET_SUMMARY:-true}"
AB_KEEPALIVE="${AB_KEEPALIVE:-false}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"

if [[ -z "${TARGET_URL}" ]]; then
  echo "[ERROR] TARGET_URL is required." >&2
  echo "Example: TARGET_URL=\"http://example.com/\" bash scripts/run-sample-scenarios.sh" >&2
  exit 1
fi

run_one() {
  local scenario="$1"
  local label="$2"
  local url="$3"
  local requests="$4"
  local concurrency="$5"
  local reset_flag="false"

  if [[ "${FIRST_RUN}" == "true" ]]; then
    reset_flag="${RESET_SUMMARY}"
    FIRST_RUN="false"
  fi

  SCENARIO_NAME="${scenario}" \
  TARGET_LABEL="${label}" \
  TARGET_URL="${url}" \
  REQUESTS="${requests}" \
  CONCURRENCY="${concurrency}" \
  RESULT_DIR="${RESULT_DIR}" \
  RESET_SUMMARY="${reset_flag}" \
  AB_KEEPALIVE="${AB_KEEPALIVE}" \
  bash "${BENCH_SCRIPT}"

  if [[ "${SLEEP_BETWEEN}" =~ ^[0-9]+$ && "${SLEEP_BETWEEN}" -gt 0 ]]; then
    sleep "${SLEEP_BETWEEN}"
  fi
}

run_direct_comparison() {
  local index=1
  local direct_url

  IFS=',' read -r -a DIRECT_TARGETS <<< "${DIRECT_URLS}"

  run_one "path-compare-primary-direct" "${PRIMARY_LABEL}" "${TARGET_URL}" 100 10

  for direct_url in "${DIRECT_TARGETS[@]}"; do
    direct_url="${direct_url#"${direct_url%%[![:space:]]*}"}"
    direct_url="${direct_url%"${direct_url##*[![:space:]]}"}"
    if [[ -n "${direct_url}" ]]; then
      run_one "path-compare-primary-direct" "direct-${index}" "${direct_url}" 100 10
      run_one "direct-node-c20" "direct-${index}" "${direct_url}" 200 20
      index=$((index + 1))
    fi
  done
}

echo "[PLAN] Benchmark sample scenarios"
echo "[PLAN] Primary target: ${PRIMARY_LABEL} -> ${TARGET_URL}"
echo "[PLAN] Result dir: ${RESULT_DIR}"
echo "[PLAN] KeepAlive: ${AB_KEEPALIVE}"
if [[ -n "${DIRECT_URLS}" ]]; then
  echo "[PLAN] Direct targets: ${DIRECT_URLS}"
fi
echo

FIRST_RUN="true"

run_one "latency-baseline" "${PRIMARY_LABEL}" "${TARGET_URL}" 60 1
run_one "throughput-baseline" "${PRIMARY_LABEL}" "${TARGET_URL}" 100 10
run_one "concurrency-step-c20" "${PRIMARY_LABEL}" "${TARGET_URL}" 200 20
run_one "tail-latency-c30" "${PRIMARY_LABEL}" "${TARGET_URL}" 300 30
run_one "saturation-c50" "${PRIMARY_LABEL}" "${TARGET_URL}" 1000 50
run_one "saturation-c100" "${PRIMARY_LABEL}" "${TARGET_URL}" 2000 100

if [[ -n "${DIRECT_URLS}" ]]; then
  run_direct_comparison
fi

echo "[DONE] Summary: ${RESULT_DIR}/summary.csv"
echo "[NEXT] bash scripts/analyze-summary.sh"
