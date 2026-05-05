#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/results}"
SUMMARY_FILE="${SUMMARY_FILE:-${RESULT_DIR}/summary.csv}"

TARGET_URL="${TARGET_URL:-}"
TARGET_LABEL="${TARGET_LABEL:-target}"
SCENARIO_NAME="${SCENARIO_NAME:-sample-${TARGET_LABEL}}"
REQUESTS="${REQUESTS:-100}"
CONCURRENCY="${CONCURRENCY:-10}"
RESET_SUMMARY="${RESET_SUMMARY:-false}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-3}"
AB_KEEPALIVE="${AB_KEEPALIVE:-false}"

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] ${name} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

require_no_comma() {
  local name="$1"
  local value="$2"

  if [[ "${value}" == *","* ]]; then
    echo "[ERROR] ${name} cannot contain a comma because summary.csv is intentionally simple: ${value}" >&2
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "${value}"
}

normalize_url() {
  local url
  url="$(trim "$1")"

  if [[ -z "${url}" ]]; then
    echo "[ERROR] TARGET_URL is required." >&2
    exit 1
  fi

  if [[ ! "${url}" =~ ^https?:// ]]; then
    url="http://${url}"
  fi

  if [[ "${url}" != */ ]]; then
    url="${url}/"
  fi

  printf "%s" "${url}"
}

safe_name() {
  printf "%s" "$1" | tr -c '[:alnum:]_.-' '_'
}

to_seconds() {
  local milliseconds="$1"
  awk -v ms="${milliseconds}" 'BEGIN { printf "%.6f", ms / 1000.0 }'
}

write_header_if_needed() {
  mkdir -p "${RESULT_DIR}"

  if [[ "${RESET_SUMMARY}" == "true" || ! -f "${SUMMARY_FILE}" ]]; then
    echo "scenario,target,tool,requests,concurrency,success,failed,avg_time_sec,p95_time_sec,requests_per_sec" > "${SUMMARY_FILE}"
  fi
}

run_warmup() {
  local url="$1"

  if ! command -v curl >/dev/null 2>&1; then
    return
  fi

  for _ in $(seq 1 "${WARMUP_REQUESTS}"); do
    curl -s -o /dev/null "${url}" || true
  done
}

run_ab() {
  local url="$1"
  local raw_file="${RESULT_DIR}/$(safe_name "${SCENARIO_NAME}").$(safe_name "${TARGET_LABEL}").ab.txt"
  local ab_args=(-n "${REQUESTS}" -c "${CONCURRENCY}" -q)

  if [[ "${AB_KEEPALIVE}" == "true" ]]; then
    ab_args+=(-k)
  fi

  echo "[RUN] ab ${ab_args[*]} ${url}"
  if ! ab "${ab_args[@]}" "${url}" > "${raw_file}" 2>&1; then
    echo "[ERROR] ab failed. Raw output: ${raw_file}" >&2
    sed -n '1,120p' "${raw_file}" >&2
    exit 1
  fi

  local complete failed non_2xx failed_total success rps avg_ms p95_ms avg_sec p95_sec
  complete="$(awk -F': *' '/^Complete requests:/ { print $2; exit }' "${raw_file}" | awk '{ print $1 }')"
  failed="$(awk -F': *' '/^Failed requests:/ { print $2; exit }' "${raw_file}" | awk '{ print $1 }')"
  non_2xx="$(awk -F': *' '/^Non-2xx responses:/ { print $2; exit }' "${raw_file}" | awk '{ print $1 }')"
  rps="$(awk -F': *' '/^Requests per second:/ { print $2; exit }' "${raw_file}" | awk '{ print $1 }')"
  avg_ms="$(awk '/^Total:/ { print $3; exit }' "${raw_file}")"
  p95_ms="$(awk '$1 == "95%" { print $2; exit }' "${raw_file}")"

  failed="${failed:-0}"
  non_2xx="${non_2xx:-0}"

  if [[ -z "${complete}" || -z "${rps}" || -z "${avg_ms}" || -z "${p95_ms}" ]]; then
    echo "[ERROR] Could not parse ab output. Raw output: ${raw_file}" >&2
    sed -n '1,120p' "${raw_file}" >&2
    exit 1
  fi

  failed_total=$((failed + non_2xx))
  success=$((complete - failed_total))
  if (( success < 0 )); then
    success=0
  fi

  avg_sec="$(to_seconds "${avg_ms}")"
  p95_sec="$(to_seconds "${p95_ms}")"

  echo "${SCENARIO_NAME},${TARGET_LABEL},ab,${REQUESTS},${CONCURRENCY},${success},${failed_total},${avg_sec},${p95_sec},${rps}" >> "${SUMMARY_FILE}"
  echo "[DONE] scenario=${SCENARIO_NAME}, target=${TARGET_LABEL}, success=${success}, failed=${failed_total}, avg=${avg_sec}s, p95=${p95_sec}s, rps=${rps}"
  echo "[RAW] ${raw_file}"
}

require_positive_integer "REQUESTS" "${REQUESTS}"
require_positive_integer "CONCURRENCY" "${CONCURRENCY}"
require_positive_integer "WARMUP_REQUESTS" "${WARMUP_REQUESTS}"
require_no_comma "SCENARIO_NAME" "${SCENARIO_NAME}"
require_no_comma "TARGET_LABEL" "${TARGET_LABEL}"

if ! command -v ab >/dev/null 2>&1; then
  echo "[ERROR] ApacheBench is required. Install httpd-tools or apache2-utils first." >&2
  exit 1
fi

NORMALIZED_TARGET_URL="$(normalize_url "${TARGET_URL}")"

write_header_if_needed

echo "[INFO] Scenario=${SCENARIO_NAME}"
echo "[INFO] Target=${TARGET_LABEL} -> ${NORMALIZED_TARGET_URL}"
echo "[INFO] Requests=${REQUESTS}, Concurrency=${CONCURRENCY}, KeepAlive=${AB_KEEPALIVE}"
echo "[INFO] Summary=${SUMMARY_FILE}"

run_warmup "${NORMALIZED_TARGET_URL}"
run_ab "${NORMALIZED_TARGET_URL}"
