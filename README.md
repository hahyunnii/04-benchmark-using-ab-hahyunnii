[![Review Assignment Due Date](https://classroom.github.com/assets/deadline-readme-button-22041afd0340ce965d47ae6ef1cefeee28c7c493a6346c4f15d667ab976d596c.svg)](https://classroom.github.com/a/lpEEmyUq)
# Benchmark Sample Code

This directory contains lightweight benchmark code for a lab assignment.
It intentionally avoids Terraform, AWS CLI, and repository-specific wrappers.
Students only need a reachable HTTP URL and ApacheBench (`ab`).

## Files

- `scripts/run-http-benchmark.sh`: runs one ApacheBench scenario against one URL.
- `scripts/run-sample-scenarios.sh`: runs a small set of latency, throughput, concurrency, tail latency, and optional ALB-vs-direct scenarios.
- `scripts/analyze-summary.sh`: converts `results/summary.csv` into a Markdown analysis table.

Generated benchmark output is written to `results/` and is ignored by git.

## Install ApacheBench

macOS:

```bash
brew install httpd
```

Amazon Linux 2023:

```bash
sudo dnf install -y httpd-tools
```

Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y apache2-utils
```

Check installation:

```bash
ab -V
```

## Run One Scenario

```bash
TARGET_URL="http://example.com/" \
SCENARIO_NAME="throughput-baseline" \
TARGET_LABEL="alb" \
REQUESTS=100 \
CONCURRENCY=10 \
RESET_SUMMARY=true \
bash scripts/run-http-benchmark.sh
```

Output:

- `results/summary.csv`
- `results/throughput-baseline.alb.ab.txt`

## Run Sample Scenarios

Use this when students should run the same small scenario set.

```bash
TARGET_URL="http://example.com/" \
bash scripts/run-sample-scenarios.sh
```

Optional ALB-vs-direct comparison:

```bash
TARGET_URL="http://my-alb.example.com/" \
PRIMARY_LABEL="alb" \
DIRECT_URLS="http://10.0.1.10:8080/,http://10.0.2.20:8080/" \
bash scripts/run-sample-scenarios.sh
```

## Analyze Summary

```bash
bash scripts/analyze-summary.sh
```

The generated Markdown file is written to:

```text
results/analysis.md
```

## Important Metrics

- `requests_per_sec`: throughput.
- `avg_time_sec`: ApacheBench `Connection Times` total mean, converted from milliseconds to seconds.
- `p95_time_sec`: 95th percentile latency, converted from milliseconds to seconds.
- `concurrency`: number of parallel requests attempted by `ab`.
- `failed`: ApacheBench failed requests plus non-2xx responses.

## Lab Assignment Ideas

Students can use this sample as a starting point and then:

- compare low and high concurrency.
- explain why throughput and latency must be interpreted together.
- find a saturation point by increasing concurrency gradually.
- compare ALB and direct node paths if direct access is allowed.
- explain why p95 or p99 latency can reveal problems even when failed requests are zero.

Do not benchmark systems you do not own or do not have permission to test.
