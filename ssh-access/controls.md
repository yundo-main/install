# 설계상 고정한 통제 · 잔여 위험 색인 (SSH)

> **역할: 주제 문서.** `ssh-access/` 단계에 걸쳐 반복되는 통제 원칙과 잔여 위험의
> 색인이다. 단계별 상세는 해당 `NN-*.md` 를 본다. Docker·Swarm 통제는
> [../docker/controls.md](../docker/controls.md).

---

## 고정한 통제

| 통제 | 내용 | 근거 문서 |
|---|---|---|
| **지문 대조 후 신뢰** | 호스트 키는 기대 지문과 대조한 뒤에만 `known_hosts` 에 넣는다. 불일치 시 중단 | [00-ssh-server.md](00-ssh-server.md) · [02-ssh-client.md](02-ssh-client.md) |
| **무검증 TOFU 금지** | `--yes` 는 `--expect-fpr` 없이는 동작하지 않는다 | [02-ssh-client.md](02-ssh-client.md) |
| **순서 강제** | 키 인증 검증이 성공하지 않으면 비밀번호 인증을 차단하지 않는다 | [00-ssh-server.md](00-ssh-server.md) · [02-ssh-client.md](02-ssh-client.md) |
| **zero-trust 기본값** | 인자 없이 실행 시 publickey 전용 + `ufw deny incoming`. 완화는 명시적 플래그로만 | [00-ssh-server.md](00-ssh-server.md) |
| **범위 한정** | 비밀번호 인증·22/tcp 는 기본적으로 LAN 격리 대역(`10.10.10.0/24`)으로 한정 | [00-ssh-server.md](00-ssh-server.md) |
| **키 배치와 정책의 분리** | authorized_keys(신원)와 sshd 정책(방화벽·인증 규칙)을 다른 스크립트가 관리한다 — 회전·추가 시 방화벽을 건드리지 않는다 | [01-ssh-keys.md](01-ssh-keys.md) |
| **비파괴 키 등록** | 옵션이 다른 동일 키가 있으면 자동으로 바꿔 쓰지 않고 경고한다 | [01-ssh-keys.md](01-ssh-keys.md) |
| **상태 기반 검증** | 설정 파일이 아니라 `sshd -T`·`ufw status`·`ssh -v` 의 실제 상태로 확인 | 전 단계 |

## 대조 상수

| 상수 | 값 | 용도 |
|---|---|---|
| 서버 호스트 키 지문 (ed25519) | `SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A` | `known_hosts` 등록 전 대조 |
| 격리 대역 | `10.10.10.0/24` (vmnet3) | 방화벽·`Match Address`·`from=` 범위 |

## 잔여 위험 색인

| 위험 | 상세 |
|---|---|
| 비밀번호 인증 무차별 대입 표면 (OpenSSH 9.6, `PerSourcePenalties` 없음) | [00-ssh-server.md](00-ssh-server.md) |
| macOS 앱 단위 로컬 네트워크 권한 — 앱마다 차단/timeout | [02-ssh-client.md](02-ssh-client.md) · [../network-troubleshooting.md](../network-troubleshooting.md) |
| `~/.ssh/id_rsa` 파일명과 실제 키 타입 불일치 | [02-ssh-client.md](02-ssh-client.md) |
| `wget` 스크립트 전달 = 공급망 주입 지점 | [00-ssh-server.md](00-ssh-server.md) |
| 개인키를 git 에 두는 경우의 노출 범위 | [01-ssh-keys.md](01-ssh-keys.md) |
| `authorized_keys` 옵션 충돌(무제한 키 잔존) 미자동 정리 | [01-ssh-keys.md](01-ssh-keys.md) |
| 복제 VM 호스트 키 승계 | [../docker/02-swarm-cluster.md](../docker/02-swarm-cluster.md) |
