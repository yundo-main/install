# install/docker

Ubuntu 24.04 VM 에 Docker CE 를 설치하고, 3노드 Swarm 클러스터로 확장하는 절차와
그 실행 도구를 담는다. manager `10.10.10.150` + worker `10.10.10.151`/`.152`,
클라이언트는 macOS 다.

절차를 문서로만 남기지 않고 스크립트로 고정해, 지문 대조·검증 순서·최소 권한
기본값이 수행자의 판단에 의존하지 않도록 하는 것이 목적이다.

## 디렉터리 구조

```
install/docker/
├── README.md            프로젝트 목적, 디렉터리 구조, 파일 역할  ← 현재 문서
├── plan.md              기준 문서 — 절차의 근거와 기대 출력 (0~11 단계)
├── USAGE.md             운영 매뉴얼 — 실행 순서, 옵션, 구성 표준, 잔여 위험
├── 01-ssh-setup.sh      클라이언트 — SSH 키 인증
├── 02-install.sh        서버 — Docker CE
├── 03-compose.sh        서버 — Compose 플러그인
├── 04-node-prepare.sh   워커 — 복제본 신원 분리
├── 05-swarm-init.sh     매니저 — Swarm 초기화
└── 06-swarm-join.sh     워커 — 클러스터 가입
```

## 파일 역할

| 파일 | 역할 | 실행 위치 | 변경 사유 |
|---|---|---|---|
| [plan.md](plan.md) | 기준 문서 — 근거·기대 출력·배제된 대안 | (실행 대상 아님) | 절차 또는 대상 환경이 바뀔 때 |
| [USAGE.md](USAGE.md) | 운영 매뉴얼 — 실행 순서·옵션 계약·구성 표준·잔여 위험 | (실행 대상 아님) | 스크립트 인터페이스 또는 구성 표준이 바뀔 때 |
| [01-ssh-setup.sh](01-ssh-setup.sh) | plan.md 0~1 (SSH 키 인증) | macOS 클라이언트 | 구현이 바뀔 때 |
| [02-install.sh](02-install.sh) | plan.md 2~6 (Docker CE) | 전 노드 | 구현이 바뀔 때 |
| [03-compose.sh](03-compose.sh) | Compose 플러그인 설치 | 필요한 노드 | 구현이 바뀔 때 |
| [04-node-prepare.sh](04-node-prepare.sh) | plan.md 7-4 (복제본 신원 분리) | 워커 `.151`/`.152` | 구현이 바뀔 때 |
| [05-swarm-init.sh](05-swarm-init.sh) | plan.md 7~9 (매니저 초기화) | 매니저 `.150` | 구현이 바뀔 때 |
| [06-swarm-join.sh](06-swarm-join.sh) | plan.md 10 (워커 가입) | 워커 `.151`/`.152` | 구현이 바뀔 때 |
| README.md | 목적·구조·역할 정의 | (실행 대상 아님) | 파일이 추가·삭제될 때 |

스크립트 번호는 **실행 순서**다. 의존성 선언이 아니므로 각 스크립트가 전제 조건을
직접 검증한다 — `03-compose.sh` 는 서명된 저장소 설정을, `05-swarm-init.sh` 는
`advertise-addr` 의 인터페이스 존재를 확인하고 없으면 중단한다.

의존 방향은 `plan.md` → 스크립트 → `USAGE.md` 단방향이다.
코드가 `plan.md` 와 어긋나면 `plan.md` 가 기준이다.

## 단일 노드와 Swarm 의 경계

0~6 단계(스크립트 01~03)는 단일 노드 Docker 호스트를 만든다.
7~11 단계(스크립트 04~06)는 이를 클러스터로 확장한다.

확장 시 **`live-restore` 를 제거해야 한다.** 두 설정은 공존할 수 없고 데몬이
swarm 초기화를 거부한다. 나머지 데몬 설정(`no-new-privileges`, 로그 제한, `icc`)은
유지한다. `icc: false` 는 기본 bridge 전용이라 overlay 네트워크에 적용되지 않으므로,
서비스 간 격리는 overlay 네트워크 분리로 설계한다.

Compose(03) 는 단일 노드용이다. 클러스터에서는 `docker service` 를 쓴다.

**스크립트를 분리한 이유**: 실행 주체의 신뢰 경계가 다르다.
서버로 단독 `scp` 되는 스크립트(02~06)는 클라이언트 로직을 포함하지 않고,
외부 파일을 참조하지 않는 자기완결 스크립트여야 한다.

**여기에 넣지 않는 것**: 절차와 무관한 운영 스크립트, Kubernetes 관련 절차
(`../k8s/` 소관).
