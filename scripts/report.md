# Report: Week 8 — EC2 + ALB Benchmark on AWS

## 1. 개요

본 보고서는 AWS Academy Learner Lab 환경에서 Terraform으로 배포한 EC2 2대 + Application Load Balancer(ALB) 아키텍처에 대해 ApacheBench(ab)를 사용하여 수행한 벤치마크 테스트 결과를 분석한다. 실험의 목적은 시스템의 baseline 성능을 측정하고, 동시성(concurrency) 증가에 따른 처리량과 레이턴시 변화를 해석하며, ALB 경유 경로와 EC2 직접 경로를 비교하는 것이다.

---

## 2. 배포 아키텍처

```
인터넷 클라이언트 (ab)
        │
        ▼
Application Load Balancer (ALB)
  - HTTP:80, 2개 AZ 걸침
  - 헬스체크: 30초 간격, / 경로, HTTP 200 기준
        │
  ┌─────┴──────┐
  ▼            ▼
EC2 #1        EC2 #2
(t2.micro)    (t2.micro)
us-east-1a    us-east-1b
```

- Terraform으로 모든 리소스를 코드로 정의 및 배포
- 두 EC2 인스턴스는 각각 다른 AZ에 배치 (ALB 요구사항: 최소 2개 AZ)
- 보안 그룹: ALB와 EC2 모두 HTTP:80 인바운드 허용 (Scenario 3 direct 접근을 위해)

---

## 3. 벤치마크 방법론

### 도구
- **Primary:** ApacheBench (ab) — HTTP/1.1, 백분위 레이턴시 지원
- **Wrapper:** `scripts/benchmark-ec2-alb.sh` — CSV 결과 자동 기록
- **Fallback:** curl 루프 (ab 미설치 시 자동 전환, p95는 n/a로 기록)

### 실험 설계 원칙
- 각 시나리오마다 하나의 변수만 변경 (단일 변수 변화 원칙)
- 벤치마크 전 5회 워밍업 요청 실행
- 각 시나리오 시작 전 `aws elbv2 describe-target-health`로 타겟 헬스 확인
- Scenario 1에서만 `RESET_SUMMARY=true` 사용 (CSV 초기화)

---

## 4. 실험 결과 (summary.csv)

| Scenario | Target | Tool | Requests | Concurrency | Success | Failed | Fail Rate | Avg Time (sec) | P95 Time (sec) | Requests/sec |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline-alb | alb | ab | 100 | 10 | 100 | 0 | 0.00% | 0.023400 | 0.041000 | 42.30 |
| higher-concurrency-alb | alb | ab | 400 | 40 | 398 | 2 | 0.50% | 0.038000 | 0.089000 | 47.10 |
| direct-compare | direct | ab | 100 | 10 | 100 | 0 | 0.00% | 0.020000 | 0.038000 | 48.20 |

---

## 5. 결과 분석

### 5.1 처리량 (Throughput) 분석

동시성이 10→40(4배)으로 증가했을 때 처리량은 42.30→47.10 req/s로 약 **11% 증가**에 그쳤다. 동시성 증가에 비례한 선형 증가(이론상 4배, 약 169 req/s)는 관찰되지 않았다. 이는 t2.micro 인스턴스의 단일 vCPU 한계와 ALB-to-EC2 간 연결 처리 오버헤드로 설명된다. 처리량이 정체(plateau)되기 시작한 것은 시스템이 포화 임계점에 접근하고 있음을 나타낸다.

### 5.2 레이턴시 (Latency) 분석

| 지표 | Scenario 1 (C=10) | Scenario 2 (C=40) | 변화율 |
|---|---|---|---|
| Avg latency | 23 ms | 38 ms | **+65%** |
| P95 latency | 41 ms | 89 ms | **+117%** |

평균 레이턴시보다 p95 레이턴시의 증가폭이 훨씬 크다는 점이 핵심이다. 이는 **tail latency 악화** 현상으로, 동시성이 높아질수록 일부 요청이 큐에서 오래 대기하게 되어 전체 평균은 적당해 보여도 실제 일부 사용자는 훨씬 긴 응답 시간을 경험하고 있음을 의미한다.

> **함의:** 평균 레이턴시만 보고 "괜찮다"고 판단하는 것은 위험하다. p95/p99 tail latency를 항상 함께 보아야 한다.

### 5.3 실패 요청 (Failed Requests) 분석

- Scenario 1 (C=10): 실패 0건 → 시스템 정상 기준선 확인
- Scenario 2 (C=40): 실패 2건 (0.50%) → **동시성 40에서 최초 에러 신호 발생**

2건의 실패는 절대 수치로는 작지만, baseline에서 전무했던 에러가 등장했다는 사실 자체가 중요한 신호다. 이 시점이 향후 오토스케일링 트리거를 설정할 때 참고해야 할 경계 구간이다.

### 5.4 ALB vs Direct EC2 비교

| 지표 | ALB 경로 (Scenario 1) | Direct 경로 (Scenario 3) | 차이 |
|---|---|---|---|
| Avg latency | 23 ms | 20 ms | -3 ms (Direct가 빠름) |
| P95 latency | 41 ms | 38 ms | -3 ms (Direct가 빠름) |
| Requests/sec | 42.30 | 48.20 | +5.9 (Direct가 높음) |

Direct EC2 경로가 소폭 빠르게 측정됐다. 이는 ALB의 라우팅 처리, 헬스체크 수행, 요청 분배 등의 오버헤드(약 3ms)가 반영된 것이다. 그러나 이것이 ALB를 제거해야 한다는 의미가 아님을 강조해야 한다.

**ALB가 프로덕션에서 반드시 필요한 이유:**
- 자동 헬스체크: unhealthy 인스턴스로의 라우팅 자동 차단
- 부하 분산: 두 EC2 인스턴스에 트래픽을 나눠 전체 처리 용량 증대
- TLS 종료: HTTPS 처리를 ALB가 담당해 EC2 CPU 절감
- Path-based 라우팅: `/api/`와 `/web/` 등 경로별 다른 타겟 그룹으로 분기 가능

> 결론: Direct 경로의 3ms 이득은 위 기능들을 포기하는 비용에 비해 무의미하다.

---

## 6. 아키텍처 해석

### 가용성(Availability) vs 용량(Capacity) 구분

만약 하나의 EC2 인스턴스가 다운됐다면:

- **가용성은 유지됨:** ALB가 healthy 인스턴스 1대로만 라우팅 → 서비스 계속 제공
- **용량은 50% 감소:** 동일 동시성에서 RPS 하락, latency 상승
- **사용자 관점:** 서비스는 살아있지만 성능이 저하됨

이 구분은 인시던트 대응(Incident Response) 설계의 핵심이다. ALB의 헬스체크 기반 라우팅이 가용성을 보장하는 동안, 오토스케일링 정책이 용량을 회복시키도록 설계해야 한다.

### CloudWatch 연계

| ab 결과 지표 | 대응 CloudWatch 지표 |
|---|---|
| Requests/sec | `ALB: RequestCount` |
| avg/p95 latency | `ALB: TargetResponseTime` |
| Failed requests | `ALB: HTTPCode_Target_5XX_Count` |
| (직접 측정 불가) | `EC2: CPUUtilization` |

CloudWatch와 ab 결과를 교차 검증하면 병목이 ALB 레벨인지 EC2 백엔드 레벨인지 판별할 수 있다.

### 오토스케일링 트리거 권고

**권장 지표:** `ALB TargetResponseTime` (p95 기준)

CPU 임계치 도달보다 사용자 체감 레이턴시 저하가 먼저 나타나기 때문에, p95 latency가 baseline 대비 2배(~82ms)를 초과하는 시점을 scale-out 트리거로 설정하는 것이 적절하다.

---

## 7. 결론

| 질문 | 답변 |
|---|---|
| Baseline 성능은? | 42.30 req/s, avg 23ms, p95 41ms, 실패 0 |
| 동시성 4배 증가 시 처리량은? | 11% 소폭 증가 (선형 확장 불가) |
| Tail latency 변화는? | p95 +117% — 포화 징조 |
| ALB 오버헤드는? | 약 3ms — 제공 기능 대비 무시 가능한 수준 |
| 첫 에러 발생 구간은? | C=40 (0.50% 실패율) |

이번 벤치마크를 통해 2대의 t2.micro + ALB 구성은 동시성 10에서 쾌적한 baseline을 제공하지만, 동시성 40에서는 tail latency 급증과 소수 실패가 발생하기 시작함을 확인했다. 이 데이터는 다음 주 Auto Scaling 정책 설계의 정량적 기준점으로 활용한다.

---

## 8. 리소스 정리

```bash
terraform destroy -auto-approve
```

모든 AWS 리소스(EC2 × 2, ALB, Target Group, Listener, Security Group, VPC, Subnet, IGW)를 삭제 완료했다. Learner Lab 크레딧 낭비 없음.