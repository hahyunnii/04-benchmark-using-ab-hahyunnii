# commands.md — Week 8 Lab: Benchmark Using ab

## 환경 준비

### ab 설치
```bash
sudo dnf install -y httpd-tools
ab -V
```

### 레포 클론 및 권한 부여
```bash
git clone https://github.com/hahyunnii/04-benchmark-using-ab-hahyunnii.git
cd 04-benchmark-using-ab-hahyunnii
chmod +x scripts/*.sh
```

---

## 인프라 배포 (lab03 - Terraform)

```bash
cd ~/03-terraform-ec2-alb-hahyunnii/terraform-03-alb-two-ec2
terraform init
terraform apply -auto-approve
```

- ALB DNS: `ccaws-tf03-alb-959492896.us-east-1.elb.amazonaws.com`
- web-a IP: `32.197.44.252`
- web-b IP: `44.201.202.82`

---

## 타겟 헬스 확인

```bash
ALB_DNS="$(terraform output -raw alb_dns_name)"
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw target_group_arn)"
```

- **결과:** 두 인스턴스(i-0283f7034737c23f9, i-0e793ec6f067969ae) 모두 `State: healthy` 확인
- **Interpretation:** ALB가 두 EC2 인스턴스 모두를 정상 타겟으로 인식하고 있음을 확인. 벤치마크 실행 전 필수 확인 단계.

---

## 워밍업

```bash
for i in 1 2 3 4 5; do
  curl -s "http://${ALB_DNS}" | head -n 1
done
```

- **결과:** `<h1>Terraform Example 03</h1>` 5회 출력
- **Interpretation:** ALB 라우팅 테이블 초기화 및 콜드 스타트 레이턴시 제거.

---

## Raw ab Check

### Command
```bash
ab -n 60 -c 1 "http://ccaws-tf03-alb-959492896.us-east-1.elb.amazonaws.com/"
```

### Key Output
```
Server Software:        nginx/1.30.0
Concurrency Level:      1
Complete requests:      60
Failed requests:        0
Requests per second:    676.90 [#/sec] (mean)
Time per request:       1.477 [ms] (mean)

Percentage of the requests served within a certain time (ms)
  50%      1
  95%      2
  99%      3
 100%      3 (longest request)
```

### Interpretation
`-n 60`은 총 요청 수, `-c 1`은 순차 요청(동시성 없음)을 의미한다. `Complete requests: 60`이 `-n`값과 일치하고 `Failed requests: 0`이므로 ALB와 두 EC2 백엔드가 정상 동작 중임을 확인했다. C=1에서 RPS 676.90, p95 2ms가 순수 단일 요청 처리 속도의 기준점이 된다. p95(2ms)와 p100(3ms)의 격차가 매우 작아 응답 시간이 일관적임을 확인했다.

---

## Benchmark Scenarios

### Scenario 1: latency-baseline (C=1, N=60)
- Command:
  ```bash
  cd ~/04-benchmark-using-ab-hahyunnii
  TARGET_URL="http://ccaws-tf03-alb-959492896.us-east-1.elb.amazonaws.com/" \
  PRIMARY_LABEL="alb" \
  bash scripts/run-sample-scenarios.sh
  ```
- Key output (CSV row):
  `latency-baseline,alb,ab,60,1,60,0,0.001000,0.002000,676.90`
- Interpretation: 동시성 1에서 RPS 676.90, avg 1ms, p95 2ms. 순차 처리 기준점으로, 이후 동시성 증가 시나리오와 비교하는 기준이 된다.

### Scenario 2: throughput-baseline (C=10, N=100)
- Key output (CSV row):
  `throughput-baseline,alb,ab,100,10,100,0,0.002000,0.002000,5481.25`
- Interpretation: 동시성 10에서 RPS 5,481로 C=1 대비 약 8.1배 증가했다. avg와 p95 latency가 모두 2ms로 동일하게 유지되어 서버가 동시 요청을 효율적으로 처리하고 있음을 나타낸다.

### Scenario 3: concurrency-step-c20 (C=20, N=200)
- Key output (CSV row):
  `concurrency-step-c20,alb,ab,200,20,200,0,0.002000,0.004000,7284.65`
- Interpretation: 동시성 20에서 RPS 7,284로 C=10 대비 약 33% 증가했다. p95 latency가 2ms→4ms로 증가하기 시작했다. 처리량 증가 폭이 줄어들며 포화 근접 신호가 나타나기 시작했다.

### Scenario 4: tail-latency-c30 (C=30, N=300)
- Key output (CSV row):
  `tail-latency-c30,alb,ab,300,30,300,0,0.003000,0.005000,8056.50`
- Interpretation: 동시성 30에서 RPS 8,056. avg 3ms, p95 5ms로 latency가 소폭 증가했다. 실패 0건이지만 처리량 증가폭이 점차 줄어들고 있다.

### Scenario 5: saturation-c50 (C=50, N=1000)
- Key output (CSV row):
  `saturation-c50,alb,ab,1000,50,1000,0,0.005000,0.009000,8749.75`
- Interpretation: 동시성 50에서 RPS 8,749. avg 5ms, p95 9ms. C=30 대비 RPS 증가폭(+693)이 크게 줄었고 p95 latency는 5ms→9ms로 80% 증가했다. 포화 임계점에 근접하고 있다.

### Scenario 6: saturation-c100 (C=100, N=2000)
- Key output (CSV row):
  `saturation-c100,alb,ab,2000,100,2000,0,0.011000,0.015000,8896.92`
- Interpretation: 동시성 100에서 RPS 8,896으로 C=50 대비 고작 +147(+1.7%) 증가에 그쳤다. 그러나 avg latency는 5ms→11ms(+120%), p95는 9ms→15ms(+67%)로 급등했다. RPS 정체와 latency 급등이 동시에 나타났으며 이것이 첫 번째 명확한 포화 신호다.

---

## Final summary.csv

```
scenario,target,tool,requests,concurrency,success,failed,avg_time_sec,p95_time_sec,requests_per_sec
latency-baseline,alb,ab,60,1,60,0,0.001000,0.002000,676.90
throughput-baseline,alb,ab,100,10,100,0,0.002000,0.002000,5481.25
concurrency-step-c20,alb,ab,200,20,200,0,0.002000,0.004000,7284.65
tail-latency-c30,alb,ab,300,30,300,0,0.003000,0.005000,8056.50
saturation-c50,alb,ab,1000,50,1000,0,0.005000,0.009000,8749.75
saturation-c100,alb,ab,2000,100,2000,0,0.011000,0.015000,8896.92
```

---

## Interpretation Answers

### 1. Throughput Trend (처리량 추세)
동시성이 1→100으로 증가하면서 RPS는 676→8,896으로 증가했다. 그러나 C=50 이후 증가폭이 급격히 줄어들었다(C=50: +693, C=100: +147). C=100에서 사실상 처리량이 정체(plateau)되었으며, 이는 두 EC2 인스턴스가 처리할 수 있는 최대 용량에 근접했음을 의미한다.

### 2. Latency Change (지연 시간 변화)
avg latency는 C=1(1ms)에서 C=100(11ms)으로 11배 증가했다. p95 latency는 C=1(2ms)에서 C=100(15ms)으로 7.5배 증가했다. 특히 C=50→C=100 구간에서 avg가 5ms→11ms(+120%)로 불균형하게 급등했다. 동시성 증가율(2배)보다 latency 증가율이 훨씬 커 큐잉 현상이 시작됐음을 나타낸다.

### 3. Failed Requests (실패 요청)
전체 6개 시나리오, 총 3,660건의 요청에서 실패가 단 1건도 없었다(실패율 0.00%). C=100에서도 실패는 발생하지 않았으나 latency 급등이 포화의 첫 신호로 나타났다.

### 4. Target Health (타겟 상태)
벤치마크 시작 전 두 인스턴스(i-0283f7034737c23f9, i-0e793ec6f067969ae) 모두 `State: healthy`를 확인했다. 두 인스턴스가 정상이었기 때문에 ALB가 트래픽을 균등하게 분산할 수 있었고, 단일 인스턴스였다면 포화 신호가 더 일찍 나타났을 것이다.

### 5. Where does saturation appear? (포화 신호)
포화 신호는 C=50→C=100 구간에서 처음 명확하게 나타났다. RPS 증가가 +1.7%로 사실상 정체되고 avg latency가 +120% 급등했다. 실패 발생이나 RPS 정체보다 p95 latency 증가가 먼저 나타났으며, 이는 "tail latency가 capacity signal보다 먼저 나타난다"는 원칙과 일치한다.

---

## Cleanup

```bash
cd ~/03-terraform-ec2-alb-hahyunnii/terraform-03-alb-two-ec2
terraform destroy -auto-approve
```

- EC2 인스턴스 2대 `terminated` 상태 확인
- ALB 삭제 확인
- Learner Lab 크레딧 낭비 없음