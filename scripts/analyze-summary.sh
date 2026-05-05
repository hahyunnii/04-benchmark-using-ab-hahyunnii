#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMMARY_FILE="${SUMMARY_FILE:-${ROOT_DIR}/results/summary.csv}"
OUTPUT_FILE="${OUTPUT_FILE:-${ROOT_DIR}/results/analysis.md}"

if [[ ! -f "${SUMMARY_FILE}" ]]; then
  echo "[ERROR] Summary file not found: ${SUMMARY_FILE}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"

{
  echo "# Benchmark Result Analysis"
  echo
  echo "Generated from: \`${SUMMARY_FILE}\`"
  echo
  echo "## Summary"
  echo
  awk -F',' '
    NR > 1 {
      rows += 1
      requests += $4
      success += $6
      failed += $7
      if ($10 + 0 > best_rps) {
        best_rps = $10 + 0
        best_rps_row = $1 " / " $2
      }
      if ($9 != "n/a" && $9 + 0 > worst_p95) {
        worst_p95 = $9 + 0
        worst_p95_row = $1 " / " $2
      }
    }
    END {
      printf "- Result rows: `%d`\n", rows
      printf "- Total requests: `%d`\n", requests
      printf "- Successful requests: `%d`\n", success
      printf "- Failed requests: `%d`\n", failed
      printf "- Best throughput: `%s` at `%.2f requests/sec`\n", best_rps_row, best_rps
      printf "- Highest p95 latency: `%s` at `%.6f sec`\n", worst_p95_row, worst_p95
    }
  ' "${SUMMARY_FILE}"

  echo
  echo "## Result Table"
  echo
  echo "| Scenario | Target | Tool | Requests | Concurrency | Success | Failed | Fail Rate | Avg Time (sec) | P95 Time (sec) | Requests/sec |"
  echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"

  awk -F',' '
    NR == 1 { next }
    {
      requests = $4 + 0
      failed = $7 + 0
      fail_rate = requests > 0 ? (failed / requests) * 100 : 0

      printf "| %s | %s | %s | %d | %d | %d | %d | %.2f%% | %.6f | %s | %.2f |\n", \
        $1, $2, $3, requests, $5, $6, failed, fail_rate, $8, $9, $10
    }
  ' "${SUMMARY_FILE}"

  echo
  echo "## Interpretation Checklist"
  echo
  echo "- Did throughput increase as concurrency increased?"
  echo "- Did average latency and p95 latency stay stable?"
  echo "- Did failed requests remain zero?"
  echo "- If direct targets were tested, how different were ALB and direct paths?"
  echo "- Where does the first saturation signal appear: throughput plateau, p95 latency, or failures?"
} > "${OUTPUT_FILE}"

cat "${OUTPUT_FILE}"
