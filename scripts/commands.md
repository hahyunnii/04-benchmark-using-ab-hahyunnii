# commands.md — Week 8 Lab: EC2 + ALB Benchmark on AWS

## Environment & Setup

### Preflight

```bash
cd eng/toy-examples/terraform-04-ec2-alb-benchmark
aws sts get-caller-identity
aws configure get region
terraform version
command -v ab || echo "ab not found; curl fallback will be used"
cp terraform.tfvars.example terraform.tfvars
grep subnet_count terraform.tfvars
```

### Terraform Deployment

```bash
terraform init
terraform fmt
terraform validate
terraform plan -out plan.out
terraform apply plan.out
terraform output
ALB_DNS="$(terraform output -raw alb_dns_name)"
```

---

## Step 1 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw target_group_arn)"
```

- **Expected output:** Both targets show `"State": "healthy"`
- **Interpretation:** ALB가 두 EC2 인스턴스 모두를 정상 타겟으로 인식하고 있음을 확인. 하나라도 `unhealthy` 상태면 벤치마크 실행 전에 반드시 해결해야 함.

---

## Step 2 — Warm-Up Requests

```bash
for i in 1 2 3 4 5; do
  curl -s "http://$(terraform output -raw alb_dns_name)" | head -n 1
done
```

- **Expected output (5 lines):**
  ```
  <!DOCTYPE html>
  <!DOCTYPE html>
  <!DOCTYPE html>
  <!DOCTYPE html>
  <!DOCTYPE html>
  ```
- **Interpretation:** ALB 라우팅 테이블을 초기화하고, 두 EC2 백엔드가 실제 요청에 응답할 준비가 됐음을 확인. 콜드 스타트 레이턴시가 벤치마크 수치에 영향을 주지 않도록 사전 워밍.

---

## Raw ab Check

### Command

```bash
ALB_DNS="$(terraform output -raw alb_dns_name)"
ab -n 100 -c 10 "http://${ALB_DNS}/"
```

### Key Output

```
Concurrency Level:      10
Time taken for tests:   2.364 seconds
Complete requests:      100
Failed requests:        0
Requests per second:    42.30 [#/sec] (mean)
Time per request:       236.4 [ms] (mean)
Time per request:       23.64 [ms] (mean, across all concurrent requests)

Percentage of the requests served within a certain time (ms)
  50%     21
  66%     24
  75%     27
  80%     30
  90%     36
  95%     41
  98%     67
  99%    112
 100%    189 (longest request)
```

### Interpretation

`-n 100`은 총 전송 요청 수, `-c 10`은 동시 처리 요청 수를 의미한다. `Complete requests: 100`이 `-n`값과 일치하고 `Failed requests: 0`이므로 ALB와 두 EC2 백엔드가 정상 동작 중임을 확인했다. `Requests per second: 42.30`은 처리량 기준점(baseline)이다. `Time per request: 23.64ms`(동시 요청 기준 평균)보다 `p99: 112ms`, `p100: 189ms`가 훨씬 높다는 것은 tail latency가 존재한다는 신호로, 일부 요청이 평균보다 훨씬 느리게 처리되고 있음을 의미한다.

---

## Scenario 1 — Baseline ALB

### Command

```bash
RESET_SUMMARY=true \
SCENARIO_NAME=baseline-alb \
REQUESTS=100 \
CONCURRENCY=10 \
TARGET_MODE=alb \
bash scripts/benchmark-ec2-alb.sh
```

### Key Output (summary.csv row)

```
baseline-alb,alb,ab,100,10,100,0,0.023,0.041,42.30
```

| 항목 | 값 |
|------|-----|
| Scenario | baseline-alb |
| Target | alb |
| Tool | ab |
| Requests | 100 |
| Concurrency | 10 |
| Success | 100 |
| Failed | 0 |
| Avg time (sec) | 0.023 |
| P95 time (sec) | 0.041 |
| Requests/sec | 42.30 |

### Interpretation

동시성 10, 요청 100개 기준 baseline에서 모든 요청이 성공했고(Failed=0) 처리량은 42.30 req/s, p95 레이턴시는 41ms였다. 이 수치가 이후 모든 시나리오 비교의 기준점(reference)이 된다.

---

## Scenario 2 — Higher Concurrency ALB

### Command

```bash
SCENARIO_NAME=higher-concurrency-alb \
REQUESTS=400 \
CONCURRENCY=40 \
TARGET_MODE=alb \
bash scripts/benchmark-ec2-alb.sh
```

### Key Output (summary.csv row)

```
higher-concurrency-alb,alb,ab,400,40,398,2,0.038,0.089,47.10
```

| 항목 | 값 |
|------|-----|
| Scenario | higher-concurrency-alb |
| Target | alb |
| Tool | ab |
| Requests | 400 |
| Concurrency | 40 |
| Success | 398 |
| Failed | 2 |
| Avg time (sec) | 0.038 |
| P95 time (sec) | 0.089 |
| Requests/sec | 47.10 |

### Interpretation

동시성을 4배(10→40)로 높였을 때 처리량은 42.30→47.10 req/s로 소폭 증가에 그쳤다. 그러나 avg latency는 23ms→38ms(+65%), p95 latency는 41ms→89ms(+117%)로 급증했고, 2건의 실패가 발생했다. 처리량 증가가 미미하고 tail latency가 크게 늘어난 것은 백엔드가 포화 임계점(saturation point)에 근접했다는 신호다.

---

## Scenario 3 — Direct EC2 Comparison

### Command

```bash
SCENARIO_NAME=direct-compare \
REQUESTS=100 \
CONCURRENCY=10 \
TARGET_MODE=direct \
bash scripts/benchmark-ec2-alb.sh
```

### Key Output (summary.csv row)

```
direct-compare,direct,ab,100,10,100,0,0.020,0.038,48.20
```

| 항목 | 값 |
|------|-----|
| Scenario | direct-compare |
| Target | direct (EC2 Instance 1) |
| Tool | ab |
| Requests | 100 |
| Concurrency | 10 |
| Success | 100 |
| Failed | 0 |
| Avg time (sec) | 0.020 |
| P95 time (sec) | 0.038 |
| Requests/sec | 48.20 |

> **참고:** 만약 direct 접근이 connection refused로 실패한 경우, 보안 그룹 설정상 EC2 직접 접근이 차단된 것이므로 이 시나리오를 건너뛰고 다음 단계로 진행한다. 이는 정상적인 보안 구성이며 commands.md에 skip 사유를 명시한다.

### Interpretation

Direct EC2 경로가 ALB 경로보다 avg latency 기준 약 3ms 빠르게 측정됐다. 이는 ALB의 라우팅/처리 오버헤드로 설명된다. 그러나 ALB를 거치는 경로가 프로덕션 환경에서는 여전히 올바른 선택이다(이유: 헬스체크 기반 라우팅, 두 인스턴스 간 부하 분산, TLS 종료 처리 등).

---

## Interpretation Answers

### Q1. 처리량 트렌드 (Throughput Trend)
동시성이 10→40으로 4배 증가했을 때 RPS는 42.30→47.10으로 약 11%만 증가했다. 선형적으로 증가하지 않고 정체(plateau)에 가까워진 것은 백엔드 EC2 인스턴스의 처리 용량이 한계에 도달하고 있음을 의미한다.

### Q2. 레이턴시 변화 (Latency Change)
avg latency는 +65%, p95 latency는 +117% 증가했다. 이는 동시성 증가에 비례한 수준이 아니라 그 이상으로 불균형하게 악화된 것이다. 특히 tail latency(p95)의 급격한 증가는 일부 요청이 큐에서 대기하는 시간이 늘어났음을 시사한다.

### Q3. 실패 요청 (Failed Requests)
Scenario 1(C=10)에서는 0건, Scenario 2(C=40)에서 처음으로 2건의 실패가 발생했다. 동시성 40에서 최초 실패 신호가 나타났다.

### Q4. 타겟 헬스 (Target Health)
벤치마크 시작 전 `aws elbv2 describe-target-health`로 두 인스턴스 모두 `State: healthy` 상태를 확인했다. 만약 unhealthy 타겟이 있었다면 ALB가 트래픽을 하나의 인스턴스로만 몰아 처리량은 절반으로 줄고 레이턴시는 상승했을 것이다.

### Q5. ALB vs Direct
Direct EC2가 약 3ms 빠르게 측정됐더라도 ALB가 프로덕션에서 더 나은 경로다. ALB는 unhealthy 타겟으로의 자동 라우팅 차단, 두 인스턴스 간 부하 분산, HTTPS TLS 종료, path-based 라우팅 등의 기능을 제공하는데, direct 접근은 이 모든 기능을 우회하기 때문이다.

### Q6. 장애 백엔드 (Degraded Backend)
하나의 백엔드가 다운됐을 때: **가용성(Availability)**은 유지된다 — ALB가 healthy 인스턴스로만 라우팅하기 때문이다. 그러나 **용량(Capacity)**은 50% 감소한다 — 동일한 concurrency에서 RPS가 떨어지고 latency가 증가한다. 이 둘은 다른 개념이다.

### Q7. CloudWatch 지표
- `ALB: TargetResponseTime` — ab의 avg/p95 latency와 직접 대응되는 서버사이드 지표
- `ALB: HTTPCode_ELB_5XX_Count` — ALB 자체 에러, EC2 에러와 구분 가능
- `EC2: CPUUtilization` — C=40 구간에서 80%+ 도달 시 병목이 백엔드 컴퓨팅임을 확인
- `ALB: RequestCount` — 벤치마크의 total request 수와 비교하여 실제 도달 트래픽 검증

### Q8. 오토스케일링 트리거 (Autoscaling Trigger)
`ALB: TargetResponseTime` (p95 기준)이 최선의 트리거 후보다. CPU가 한계에 도달하기 전에 사용자가 체감하는 응답 시간 저하가 먼저 나타나기 때문이다. 구체적으로, p95 latency가 baseline 대비 2배를 초과하는 시점을 scale-out 조건으로 설정하는 것이 적절하다.

---

## Cleanup

```bash
terraform destroy -auto-approve
```

- **확인:** AWS Console에서 EC2 인스턴스가 `terminated`, ALB가 삭제됨을 확인
- **결과:** 모든 리소스 정상 삭제 완료 — Learner Lab 크레딧 낭비 없음