# report.md — Week 8 Lab: Benchmark Using ab

## 1. 실습 개요

AWS Academy Learner Lab 환경에서 Terraform으로 배포한 EC2 2대 + ALB 아키텍처를 대상으로 ApacheBench(`ab`)를 사용하여 6개 시나리오의 HTTP 부하 테스트를 수행했다. 동시성을 C=1에서 C=100까지 단계적으로 높이며 처리량(RPS), 평균 지연 시간(avg), 꼬리 지연 시간(p95)의 변화를 측정하고 포화 지점을 탐색했다.

- **테스트 환경:** AWS CloudShell (Amazon Linux 2023)
- **대상 서버:** EC2 2대 (t3.micro, nginx/1.30.0) + ALB
  - ALB DNS: `ccaws-tf03-alb-959492896.us-east-1.elb.amazonaws.com`
  - web-a: `32.197.44.252` (us-east-1a)
  - web-b: `44.201.202.82` (us-east-1b)
- **사용 도구:** ApacheBench 2.3 (`httpd-tools`)
- **래퍼 스크립트:** `scripts/run-sample-scenarios.sh`

---

## 2. 배포 아키텍처

```
인터넷 클라이언트 (ab / CloudShell)
             │
             ▼
  Application Load Balancer (ALB)
  ccaws-tf03-alb-959492896.us-east-1.elb.amazonaws.com
  HTTP:80, 2개 AZ
             │
      ┌──────┴──────┐
      ▼             ▼
   EC2 web-a     EC2 web-b
   t3.micro      t3.micro
   us-east-1a    us-east-1b
   nginx:8080    nginx:8080
```

- Terraform으로 모든 리소스 코드 정의 및 배포
- 벤치마크 전 두 인스턴스 모두 `State: healthy` 확인

---

## 3. 벤치마크 결과

### summary.csv

```
scenario,target,tool,requests,concurrency,success,failed,avg_time_sec,p95_time_sec,requests_per_sec
latency-baseline,alb,ab,60,1,60,0,0.001000,0.002000,676.90
throughput-baseline,alb,ab,100,10,100,0,0.002000,0.002000,5481.25
concurrency-step-c20,alb,ab,200,20,200,0,0.002000,0.004000,7284.65
tail-latency-c30,alb,ab,300,30,300,0,0.003000,0.005000,8056.50
saturation-c50,alb,ab,1000,50,1000,0,0.005000,0.009000,8749.75
saturation-c100,alb,ab,2000,100,2000,0,0.011000,0.015000,8896.92
```

### 전체 결과 표

| 시나리오 | 동시성 | 요청 수 | 성공 | 실패 | RPS | avg (ms) | p95 (ms) |
|---|---|---|---|---|---|---|---|
| latency-baseline | 1 | 60 | 60 | 0 | 676.90 | 1 | 2 |
| throughput-baseline | 10 | 100 | 100 | 0 | 5,481.25 | 2 | 2 |
| concurrency-step-c20 | 20 | 200 | 200 | 0 | 7,284.65 | 2 | 4 |
| tail-latency-c30 | 30 | 300 | 300 | 0 | 8,056.50 | 3 | 5 |
| saturation-c50 | 50 | 1,000 | 1,000 | 0 | 8,749.75 | 5 | 9 |
| saturation-c100 | 100 | 2,000 | 2,000 | 0 | **8,896.92** | **11** | **15** |

---

## 4. 결과 분석

### 4.1 처리량(Throughput) 추세

| 구간 | RPS 증가량 | 증가율 |
|---|---|---|
| C=1 → C=10 | +4,804 | +710% |
| C=10 → C=20 | +1,803 | +33% |
| C=20 → C=30 | +771 | +11% |
| C=30 → C=50 | +693 | +8.6% |
| C=50 → C=100 | +147 | **+1.7%** ← 정체 |

C=50 이후 RPS 증가폭이 급격히 줄어들어 C=100에서 사실상 처리량이 정체(plateau)되었다. 동시성을 2배로 늘렸음에도 처리량이 1.7%밖에 증가하지 않은 것은 두 EC2 인스턴스가 처리 가능한 최대 용량에 근접했음을 의미한다.

### 4.2 지연 시간(Latency) 분석

| 구간 | avg 변화 | p95 변화 |
|---|---|---|
| C=1 → C=50 | 1ms → 5ms (+400%) | 2ms → 9ms (+350%) |
| C=50 → C=100 | 5ms → **11ms (+120%)** | 9ms → **15ms (+67%)** |

C=50→C=100 구간에서 avg latency가 120% 급등했다. 동시성 증가율(2배)보다 latency 증가율이 훨씬 커 요청 큐잉 현상이 시작되었음을 나타낸다. 이 구간이 시스템의 실질적인 포화 시작점이다.

### 4.3 안정성 분석

전체 6개 시나리오, 총 3,660건의 요청에서 실패가 단 1건도 없었다(실패율 0.00%). C=100, 2,000 요청의 고부하 상황에서도 완전히 안정적이었다. 실패가 아닌 latency 증가가 먼저 포화 신호로 나타났다.

### 4.4 포화 신호 분석

**포화 신호 발생 순서:**
1. **p95 latency 증가** — C=20부터 2ms→4ms로 증가 시작
2. **RPS 증가 정체** — C=50 이후 증가폭 급감
3. **avg latency 급등** — C=100에서 +120%
4. **실패 발생** — 테스트 범위 내에서 미발생

실패 발생보다 latency 증가와 RPS 정체가 먼저 나타났다. 이는 이론에서 배운 "tail latency가 capacity signal보다 먼저 나타난다"는 원칙과 일치한다.

---

## 5. 핵심 학습 사항

**처리량과 지연 시간은 함께 해석해야 한다.** C=100에서 RPS 8,896은 최고값이지만 avg latency 11ms, p95 15ms는 포화 신호다. RPS만 보면 "더 잘 된다"고 착각할 수 있다.

**p95 latency는 평균보다 중요한 신호다.** avg 11ms는 양호해 보여도 p95 15ms는 상위 5% 사용자가 더 긴 응답을 경험한다는 의미다. 운영 환경에서는 p95/p99를 모니터링해야 한다.

**포화 지점은 실패 발생 전에 먼저 감지된다.** C=100에서 실패는 없었지만 RPS 정체와 latency 급등이 먼저 나타났다. 이 신호를 조기에 감지하고 오토스케일링 트리거로 활용해야 한다.

**ALB + 2대 EC2 구성의 실질적인 처리 한계는 C=50~100 구간이다.** 이 데이터는 다음 단계 오토스케일링 정책 설계의 정량적 기준점으로 활용할 수 있다.

---

## 6. 인프라 정리

```bash
cd ~/03-terraform-ec2-alb-hahyunnii/terraform-03-alb-two-ec2
terraform destroy -auto-approve
```

- EC2 인스턴스 2대 `terminated` 상태 확인
- ALB 삭제 확인
- Learner Lab 크레딧 낭비 없음