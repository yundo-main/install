# install/ssh-access

VM 노드에 SSH 키 기반 접속을 구성하는 절차와 실행 도구. Ubuntu 24.04 대상,
클라이언트는 macOS. Docker CE 설치([../docker/](../docker/))를 포함해 이 리포의
어떤 설치 대상이든 SSH 로 접근할 노드라면 공통으로 이 절차를 먼저 거친다 —
Docker 전용이 아니라서 `docker/` 와 별도 디렉터리로 뒀다.

절차를 문서로만 남기지 않고 스크립트로 고정해, 지문 대조·검증 순서·최소 권한
기본값이 수행자의 판단에 의존하지 않도록 하는 것이 목적이다.

## 디렉터리 구조

```
install/ssh-access/
├── README.md              ← 현재 문서 — 인덱스·실행 순서·명명 규칙
│
├── 00-ssh-server.md / .sh   노드 로컬: sshd 설치·소켓 활성화 해제·ufw·인증 정책
├── 01-ssh-keys.md   / .sh   노드 로컬: 공개키를 authorized_keys 에 등록
├── 02-ssh-client.md / .sh   macOS: 호스트 키 지문 대조·known_hosts·config·접속 검증
│
├── issue-key.sh             (번호 없음, 유틸) Mac: 00~02 를 한 번에 — 키 발급+등록+검증
│
└── controls.md              고정한 통제·대조 상수·잔여 위험 색인
```

## 파일 역할

| 파일 | 역할 | 실행 위치 |
|---|---|---|
| [`00-ssh-server.md`](00-ssh-server.md) / [`.sh`](00-ssh-server.sh) | sshd·ufw·인증 정책 (누가 어떻게 인증할 수 있는가) | 대상 노드 (로컬) |
| [`01-ssh-keys.md`](01-ssh-keys.md) / [`.sh`](01-ssh-keys.sh) | 공개키 등록 (이 키를 신뢰한다) | 대상 노드 (로컬) |
| [`02-ssh-client.md`](02-ssh-client.md) / [`.sh`](02-ssh-client.sh) | 지문 대조·known_hosts·config·접속 검증 | macOS 클라이언트 |
| [`issue-key.sh`](01-ssh-keys.md#aws-스타일-키-발급--issue-keysh) | 새 키 발급 → 원격 등록(`01-ssh-keys.sh` 재사용) → 새 키 단독 검증을 한 번에. **부트스트랩 자격증명 필요** — 최초 1회는 아니다 | macOS 클라이언트 |
| [`controls.md`](controls.md) | 통제 원칙·대조 상수·잔여 위험 색인 | (참조) |

`00`(정책)과 `01`(키)을 분리한 이유: 정책은 노드마다 한 번 고정되지만 키는
회전·추가·폐기가 그보다 잦다. 방화벽·소켓 설정을 다시 건드리지 않고 키만 갱신할
수 있어야 한다.

## 명명 규칙

전 프로젝트 공통 정책은 [../readme.md](../readme.md) 「단계 문서 정책」 참조. 이
디렉터리에서의 적용:

- `NN-<concept>.{sh,md}` 페어, 같은 번호. 디렉터리 목록만 보고 실행 순서를 알 수
  있어야 한다.
- 각 `NN-<concept>.md` 는 H1 바로 아래에 `**요약.** …` 1~3문장을 둔다.
- 각 단계 문서는 자기완결이다 — 근거·실행·옵션·기대 출력·검증·잔여 위험을 한
  파일에 모은다. 코드가 문서와 어긋나면 문서가 기준이다.

## 실행 순서

| # | 실행 위치 | 문서 |
|---|---|---|
| 00 | 대상 노드 (콘솔/로컬) | [00-ssh-server.md](00-ssh-server.md) |
| 01 | 대상 노드 (콘솔/로컬) | [01-ssh-keys.md](01-ssh-keys.md) |
| 02 | macOS 클라이언트 | [02-ssh-client.md](02-ssh-client.md) |

재확인은 각 스크립트의 `--verify-only`.

## 스크립트 분리 기준

**실행 주체의 신뢰 경계가 다르면 파일을 나눈다.** `00`·`01`(노드 로컬)과
`02`(클라이언트)를 한 파일에 두지 않는다. 노드로 전송되는 스크립트(`00`, `01`)는
클라이언트 로직을 포함하지 않고, 외부 파일을 참조하지 않는 자기완결 스크립트여야
한다.

## 이 절차를 마친 뒤

- Docker CE 설치: [../docker/](../docker/) (`00-docker-ce.sh` 부터)
- Swarm 클러스터: [../docker/02-swarm-cluster.md](../docker/02-swarm-cluster.md)
- 연결 문제: [../network-troubleshooting.md](../network-troubleshooting.md)
