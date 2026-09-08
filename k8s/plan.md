# goal
ubuntu 24.04 kubernetes 설치
설치 과정 문서화

## check
- req : 요구사항
- do : LLM 실행 내용

## environment
ip address : 10.10.10.150
ssh : groom (키 인증, 비밀번호 인증 차단됨)
- SSH 접속 구성은 [../docker-install/plan.md](../docker-install/plan.md) 참조
- 연결 실패 시 [../docker-install/network-troubleshooting.md](../docker-install/network-troubleshooting.md)

## 현재 상태 (2026-09-02 실측)

```
OS               Ubuntu 24.04.4 LTS / arm64
docker           29.7.2
containerd       v2.3.4
runc             1.4.3
disabled_plugins ["cri"]          ← containerd 의 CRI 플러그인 비활성
default runtime  runc (io.containerd.runc.v2 shim)
설치된 OCI 런타임 runc 만
```

**이 상태로는 Kubernetes 노드가 될 수 없다.** Docker 가 설치한 containerd 는 CRI
플러그인이 꺼져 있다. Docker 는 자체 API 로 containerd 를 쓰므로 CRI 가 필요 없고,
켜 두면 불필요한 gRPC 표면만 늘어나기 때문이다.

---

# 배경 : CRI 와 OCI 런타임

두 계층이 다르다. 흔히 섞여 쓰이므로 먼저 구분한다.

```
kubelet ──CRI(gRPC)──> containerd / CRI-O ──OCI──> runc / crun / runsc / kata
```

- **CRI** : kubelet 이 런타임과 통신하는 규격 (고수준)
- **OCI 런타임** : 실제로 namespace·cgroup 을 만들어 컨테이너를 띄우는 실행체 (저수준)

## CRI 구현체 (고수준)

| 구현체 | 성격 |
|---|---|
| **containerd** (+ CRI 플러그인) | 사실상 표준. CNCF 졸업. Docker 도 내부적으로 사용 |
| **CRI-O** | Kubernetes 전용 설계. OpenShift 기본. 표면적이 작다 |
| **cri-dockerd** | Docker Engine 을 CRI 로 노출하는 어댑터. Mirantis 유지 |
| **Mirantis Container Runtime** | 상용. FIPS 검증 등 규제 요건 대응 |

`dockershim`(kubelet 내장 Docker 어댑터)은 **Kubernetes 1.24 에서 제거**됐다.
이후 Docker 를 노드 런타임으로 쓰려면 `cri-dockerd` 를 별도로 붙여야 한다.

## OCI 런타임 (저수준) — 격리 강도가 갈리는 지점

| 런타임 | 격리 방식 | 격리 강도 | 비용 |
|---|---|---|---|
| **runc** | namespace + cgroup + seccomp/AppArmor | 기본 | 없음 (기준선) |
| **crun** | 동일 (C 구현) | runc 와 동일 | 더 가볍고 빠름 |
| **youki** | 동일 (Rust 구현) | runc 와 동일 | 성숙도 낮음 |
| **gVisor** (`runsc`) | 유저스페이스 커널이 syscall 가로챔 | 높음 — 호스트 커널 표면 축소 | syscall 오버헤드, 미구현 syscall 존재 |
| **Kata Containers** | 컨테이너마다 경량 VM | 최상 — 하드웨어 가상화 경계 | 부팅 지연, 메모리 오버헤드, 중첩 가상화 필요 |

**runc 계열은 호스트 커널을 공유한다.** 커널 취약점 하나가 곧 테넌트 경계 붕괴다.
멀티테넌시가 실제 요구사항이면 gVisor 나 Kata 로 올려야 한다 — 특히 신뢰할 수 없는
코드(사용자 제출 학습 스크립트, 노트북 실행)를 돌리는 AI 플랫폼에서는 runc 단독으로
테넌트 격리를 주장하기 어렵다.

**GPU 워크로드에서는 선택지가 좁아진다.** gVisor 는 GPU 패스스루 지원이 제한적이고,
Kata 는 VFIO 디바이스 할당이 필요해 스케줄링이 복잡해진다. 실무에서는 "GPU 노드는
runc + 노드 단위 테넌트 분리(전용 노드풀)" 로 타협하는 경우가 많다.

---

# 결정 필요 항목

## 1. CRI 선택

| 선택 | 판단 근거 |
|---|---|
| **containerd 의 CRI 플러그인 활성화** | 표준 경로. 이미 설치돼 있어 추가 설치 없음. Docker 와 containerd 를 공유 |
| **CRI-O 별도 설치** | k8s 전용이라 표면적이 작다. Docker 와 분리되어 서로 간섭 없음 |
| **cri-dockerd** | Docker 워크플로를 그대로 유지. 계층이 하나 늘어 장애 지점 증가 |

기본 권고는 **containerd CRI 플러그인 활성화**.

> 주의 — Docker 와 containerd 를 공유하면 `docker` 명령으로 만든 컨테이너와
> k8s 파드가 같은 containerd 를 쓴다. 네임스페이스(`moby` vs `k8s.io`)로 분리되지만
> 데몬 재시작·설정 변경이 양쪽에 동시에 영향을 준다.

## 2. 배포 방식

kubeadm / k3s / minikube / kind — 미결정.
단일 VM(arm64) 환경이므로 리소스 제약과 학습 목적을 함께 고려해야 한다.

## 3. OCI 런타임

runc 유지 vs 추가 런타임(gVisor/Kata) 도입 — 미결정.
단일 노드 실습에서 멀티테넌시 격리가 실제 요구사항인지 먼저 확정할 것.

## 4. 사전 요건 (배포 방식과 무관하게 공통)

- swap 비활성화
- 커널 모듈 `overlay`, `br_netfilter`
- sysctl `net.bridge.bridge-nf-call-iptables`, `net.ipv4.ip_forward`
- cgroup 드라이버를 `systemd` 로 통일 (containerd 와 kubelet 양쪽)
- CNI 플러그인 선택 (Calico / Cilium / Flannel)

---

# step 1 : (미작성 — 위 결정 후 작성)
