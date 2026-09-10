# install/docker

Ubuntu 24.04 VM 에 SSH 접속을 구성하고(00–01), Docker CE 를 설치하고(02–03),
3노드 Swarm 클러스터로 확장하는(04) 절차와 그 실행 도구.
manager `10.10.10.150` + worker `10.10.10.151`/`.152`, 클라이언트는 macOS.

절차를 문서로만 남기지 않고 스크립트로 고정해, 지문 대조·검증 순서·최소 권한
기본값이 수행자의 판단에 의존하지 않도록 하는 것이 목적이다.

## 디렉터리 구조

```
install/docker/
├── README.md              ← 현재 문서 — 인덱스·실행 순서·명명 규칙
│
├── 00-ssh-server.md / .sh    노드 로컬: sshd·방화벽(ufw)·인증 정책
├── 01-ssh-client.md / .sh    macOS: 호스트 키 지문 대조·known_hosts·~/.ssh/config·접속 검증
├── 02-docker-ce.md / .sh     대상 호스트: 저장소 신뢰·Docker CE·데몬 설정
├── 03-compose.md   / .sh     대상 호스트: Compose V2 플러그인
├── 04-swarm-cluster.md       Swarm 클러스터 — 근거+수동 절차+검증 (스크립트 없음)
│
├── compose-authoring.md    compose 파일 저작 표준 (설치 아님)
└── controls.md             고정한 통제·대조 상수·잔여 위험 색인
```

## 파일 역할

| 파일 | 역할 | 실행 위치 |
|---|---|---|
| [`00-ssh-server.md`](00-ssh-server.md) / [`.sh`](00-ssh-server.sh) | SSH 서버·ufw·인증 정책 | 대상 노드 (로컬) |
| [`01-ssh-client.md`](01-ssh-client.md) / [`.sh`](01-ssh-client.sh) | 지문 대조·known_hosts·config·접속 검증 | macOS 클라이언트 |
| [`02-docker-ce.md`](02-docker-ce.md) / [`.sh`](02-docker-ce.sh) | Docker CE + 데몬 설정 | 전 노드 |
| [`03-compose.md`](03-compose.md) / [`.sh`](03-compose.sh) | Compose 플러그인 | 필요한 노드 |
| [`04-swarm-cluster.md`](04-swarm-cluster.md) | Swarm — 근거·수동 절차·기대 출력·잔여 위험 | (수동) |
| [`compose-authoring.md`](compose-authoring.md) | compose 파일 작성 기준·금지 항목·검증 | (저작 시점) |
| [`controls.md`](controls.md) | 통제 원칙·대조 상수·잔여 위험 색인 | (참조) |

## 명명 규칙

- **실행 순서가 있는 단계는 `NN-<concept>` 로 번호를 붙인다.** 스크립트와 문서에
  같은 번호·이름을 쓴다 (`02-docker-ce.sh` ↔ `02-docker-ce.md`). 디렉터리 목록만
  보고 실행 순서를 알 수 있어야 한다.
- 번호는 실행 순서일 뿐 의존성 선언이 아니다. 전제 조건은 각 스크립트가 직접
  검증한다 (예: `03-compose.sh` 는 서명된 저장소 설정 존재를 확인하고 없으면 중단).
- **단계 문서 `NN-<concept>.md` 는 자기완결이다.** 그 단계의 근거·실행·옵션·기대
  출력·검증·잔여 위험을 한 파일에 둔다. 스크립트는 절차 설명을 복제하지 않고 이
  문서를 가리킨다. 코드가 문서와 어긋나면 문서가 기준이다.
- 실행 순서가 없는 주제(저작 표준, 통제 색인)는 번호 없이 `<concept>.md`.
- 순서가 바뀌면 번호를 다시 매기고 참조를 함께 갱신한다.

## 실행 순서

| # | 실행 위치 | 문서 |
|---|---|---|
| 00 | 대상 노드 (콘솔/로컬) | [00-ssh-server.md](00-ssh-server.md) |
| 01 | macOS 클라이언트 | [01-ssh-client.md](01-ssh-client.md) |
| 02 | 전 노드 | [02-docker-ce.md](02-docker-ce.md) |
| 03 | 필요한 노드 | [03-compose.md](03-compose.md) |
| 04 | manager + worker | [04-swarm-cluster.md](04-swarm-cluster.md) |

재확인은 각 스크립트의 `--verify-only` (`sudo` 불필요, 비대화형).

## 단일 노드와 Swarm 의 경계

`00`–`03` 은 단일 노드 Docker 호스트를 만든다. `04-swarm-cluster.md` 가 이를
클러스터로 확장한다.

확장 시 **`live-restore` 를 제거해야 한다.** 두 설정은 공존할 수 없고 데몬이 swarm
초기화를 거부한다. 나머지 데몬 설정(`no-new-privileges`, 로그 제한, `icc`)은
유지한다. `icc: false` 는 기본 bridge 전용이라 overlay 네트워크에 적용되지 않으므로,
서비스 간 격리는 overlay 네트워크 분리로 설계한다.

Compose(`03`)는 단일 노드용이다. 클러스터에서는 `docker service` 를 쓴다.

**Swarm 을 스크립트화하지 않은 이유**: 각 단계가 `sudo` 비밀번호와 호스트 키 지문
육안 대조를 요구해 비대화형 실행이 성립하지 않는다. 자동화하려면 그 통제를 다른
계층(골든 이미지, SSH CA, 범위 한정 NOPASSWD)으로 옮겨야 하는데, 3노드 규모에서는
이득이 비용을 넘지 않는다. Swarm 은 Docker CE 설치의 연장이므로 디렉터리는 나누지
않았다.

## 스크립트 분리 기준

**실행 주체의 신뢰 경계가 다르면 파일을 나눈다.** 클라이언트에서 실행하는 절차
(`01`)와 대상 호스트에서 실행하는 절차(`00`, `02`, `03`)를 한 파일에 두지 않는다.
서버로 단독 `scp` 되는 스크립트(`02`–`03`)는 클라이언트 로직을 포함하지 않고,
외부 파일을 참조하지 않는 자기완결 스크립트여야 한다.

**여기에 넣지 않는 것**: 절차와 무관한 운영 스크립트, Kubernetes 관련 절차
(`../k8s/` 소관).
