# 설계상 고정한 통제 · 잔여 위험 색인 (Docker)

> **역할: 주제 문서.** `docker/` 단계에 걸쳐 반복되는 통제 원칙과 잔여 위험의
> 색인이다. 단계별 상세는 해당 `NN-*.md` 를 본다. SSH 접속 통제는
> [../ssh-access/controls.md](../ssh-access/controls.md).

---

## 고정한 통제

| 통제 | 내용 | 근거 문서 |
|---|---|---|
| **지문 대조 후 신뢰** | Docker GPG 키는 기대 지문과 대조한 뒤에만 keyring 에 배치한다. 불일치 시 중단 | [00-docker-ce.md](00-docker-ce.md) |
| **`signed-by=` 범위 한정** | APT 키의 서명 권한을 Docker 저장소로만 한정. `apt-key add` 미사용 | [00-docker-ce.md](00-docker-ce.md) |
| **최소 권한 기본값** | docker 그룹 부여는 명시적 opt-in (부여 시 사실상 root) | [00-docker-ce.md](00-docker-ce.md) |
| **상태 기반 검증** | 설정 파일이 아니라 `docker info`·`docker network inspect`·`/proc/self/status` 의 실제 상태로 확인 | 전 단계 |
| **비파괴 기본값** | 기존 `daemon.json` 은 `--force-daemon-config` 없이 덮어쓰지 않는다. 수정은 백업 후 `dockerd --validate` 통과 시에만 재시작 | [00-docker-ce.md](00-docker-ce.md) · [02-swarm-cluster.md](02-swarm-cluster.md) |
| **자기완결 스크립트** | 대상 호스트로 전송되는 스크립트는 외부 파일을 참조하지 않는다 | [README.md](README.md) |
| **토큰 비출력** | Swarm 가입 토큰은 터미널에 표시하지 않고 `0600` 파일로만 다룬다. 가입 후 회전 | [02-swarm-cluster.md](02-swarm-cluster.md) |

## 대조 상수

| 상수 | 값 | 용도 |
|---|---|---|
| Docker GPG 키 지문 | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` | keyring 배치 전 대조 |

SSH 관련 대조 상수(호스트 키 지문, 격리 대역)는
[../ssh-access/controls.md](../ssh-access/controls.md).

## 잔여 위험 색인

| 위험 | 상세 |
|---|---|
| `icc=false` 가 compose·overlay 네트워크에 미적용 | [00-docker-ce.md](00-docker-ce.md) · [compose-authoring.md](compose-authoring.md) · [02-swarm-cluster.md](02-swarm-cluster.md) |
| Docker `-p` 게시 포트가 ufw 를 우회 | [00-docker-ce.md](00-docker-ce.md) · [compose-authoring.md](compose-authoring.md) |
| `no-new-privileges` 로 setuid 의존 이미지 실패 | [00-docker-ce.md](00-docker-ce.md) |
| 데몬 소켓 `/var/run/docker.sock` = root 등가 | [00-docker-ce.md](00-docker-ce.md) · [compose-authoring.md](compose-authoring.md) |
| 패키지 버전 미고정 | [00-docker-ce.md](00-docker-ce.md) |
| file-based secret 호스트 평문 | [compose-authoring.md](compose-authoring.md) |
| 매니저 1대 단일 장애점 (정족수 1) | [02-swarm-cluster.md](02-swarm-cluster.md) |
| Raft 로그 시크릿 디스크 평문 (autolock 미적용) | [02-swarm-cluster.md](02-swarm-cluster.md) |
| 가입 토큰 argv (`/proc/<pid>/cmdline`) 노출 | [02-swarm-cluster.md](02-swarm-cluster.md) |
| overlay 기본 비암호화 | [02-swarm-cluster.md](02-swarm-cluster.md) |
| 복제 VM 호스트 키·machine-id 승계 | [02-swarm-cluster.md](02-swarm-cluster.md) (SSH 재대조는 [../ssh-access/02-ssh-client.md](../ssh-access/02-ssh-client.md)) |
