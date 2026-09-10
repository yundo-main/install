# 설계상 고정한 통제 · 잔여 위험 색인

> **역할: 주제 문서.** 단계에 걸쳐 반복되는 통제 원칙과, 각 단계 문서에 흩어진
> 잔여 위험의 색인이다. 단계별 상세는 해당 `NN-*.md` 를 본다.

---

## 고정한 통제

수행자의 판단에 맡기지 않고 스크립트·문서에 고정한 항목.

| 통제 | 내용 | 근거 문서 |
|---|---|---|
| **지문 대조 후 신뢰** | 호스트 키·GPG 키는 기대 지문과 대조한 뒤에만 신뢰 경로에 넣는다. 불일치 시 중단 | [00-ssh-server.md](00-ssh-server.md) · [01-ssh-client.md](01-ssh-client.md) · [02-docker-ce.md](02-docker-ce.md) |
| **무검증 TOFU 금지** | `--yes` 는 `--expect-fpr` 없이는 동작하지 않는다 | [01-ssh-client.md](01-ssh-client.md) |
| **`signed-by=` 범위 한정** | APT 키의 서명 권한을 해당 저장소로만 한정. `apt-key add` 미사용 | [02-docker-ce.md](02-docker-ce.md) |
| **순서 강제** | 키 인증 검증이 성공하지 않으면 비밀번호 인증을 차단하지 않는다 | [00-ssh-server.md](00-ssh-server.md) · [01-ssh-client.md](01-ssh-client.md) |
| **zero-trust 기본값** | 인자 없이 실행 시 publickey 전용 + `ufw deny incoming`. 완화는 명시적 플래그로만 | [00-ssh-server.md](00-ssh-server.md) |
| **최소 권한 기본값** | docker 그룹 부여, 비밀번호 인증 확대는 명시적 opt-in | [00-ssh-server.md](00-ssh-server.md) · [02-docker-ce.md](02-docker-ce.md) |
| **범위 한정** | 비밀번호 인증·22/tcp 는 기본적으로 LAN 격리 대역(`10.10.10.0/24`)으로 한정 | [00-ssh-server.md](00-ssh-server.md) |
| **상태 기반 검증** | 설정 파일이 아니라 `sshd -T`·`ufw status`·`docker info`·`/proc/self/status` 의 실제 상태로 확인 | 전 단계 |
| **비파괴 기본값** | 기존 `daemon.json` 은 `--force-daemon-config` 없이 덮어쓰지 않는다. `daemon.json` 수정은 백업 후 `dockerd --validate` 통과 시에만 재시작 | [02-docker-ce.md](02-docker-ce.md) · [04-swarm-cluster.md](04-swarm-cluster.md) |
| **자기완결 스크립트** | 대상 호스트로 전송되는 스크립트는 외부 파일을 참조하지 않는다 | [README.md](README.md) |
| **토큰 비출력** | Swarm 가입 토큰은 터미널에 표시하지 않고 `0600` 파일로만 다룬다. 가입 후 회전 | [04-swarm-cluster.md](04-swarm-cluster.md) |

---

## 대조 상수

| 상수 | 값 | 용도 |
|---|---|---|
| 서버 호스트 키 지문 (ed25519) | `SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A` | `known_hosts` 등록 전 대조 |
| Docker GPG 키 지문 | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` | keyring 배치 전 대조 |
| 격리 대역 | `10.10.10.0/24` (vmnet3) | 방화벽·`Match Address` 범위 |

---

## 잔여 위험 색인

| 위험 | 상세 |
|---|---|
| 비밀번호 인증 무차별 대입 표면 (OpenSSH 9.6, `PerSourcePenalties` 없음) | [00-ssh-server.md](00-ssh-server.md) |
| macOS 앱 단위 로컬 네트워크 권한 — 앱마다 차단/timeout | [01-ssh-client.md](01-ssh-client.md) · [../network-troubleshooting.md](../network-troubleshooting.md) |
| `~/.ssh/id_rsa` 파일명과 실제 키 타입 불일치 | [01-ssh-client.md](01-ssh-client.md) |
| `icc=false` 가 compose·overlay 네트워크에 미적용 | [02-docker-ce.md](02-docker-ce.md) · [compose-authoring.md](compose-authoring.md) · [04-swarm-cluster.md](04-swarm-cluster.md) |
| Docker `-p` 게시 포트가 ufw 를 우회 | [02-docker-ce.md](02-docker-ce.md) · [compose-authoring.md](compose-authoring.md) |
| `no-new-privileges` 로 setuid 의존 이미지 실패 | [02-docker-ce.md](02-docker-ce.md) |
| 데몬 소켓 `/var/run/docker.sock` = root 등가 | [02-docker-ce.md](02-docker-ce.md) · [compose-authoring.md](compose-authoring.md) |
| 패키지 버전 미고정 | [02-docker-ce.md](02-docker-ce.md) |
| file-based secret 호스트 평문 | [compose-authoring.md](compose-authoring.md) |
| 매니저 1대 단일 장애점 (정족수 1) | [04-swarm-cluster.md](04-swarm-cluster.md) |
| Raft 로그 시크릿 디스크 평문 (autolock 미적용) | [04-swarm-cluster.md](04-swarm-cluster.md) |
| 가입 토큰 argv (`/proc/<pid>/cmdline`) 노출 | [04-swarm-cluster.md](04-swarm-cluster.md) |
| overlay 기본 비암호화 | [04-swarm-cluster.md](04-swarm-cluster.md) |
| 복제 VM 호스트 키·machine-id 승계 | [04-swarm-cluster.md](04-swarm-cluster.md) |
