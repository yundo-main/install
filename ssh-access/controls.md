# 설계상 고정한 통제 · 잔여 위험 색인 (SSH)

> **역할: 주제 문서.** `ssh-access/` 단계에 걸쳐 반복되는 통제 원칙과 잔여 위험의
> 색인이다. 단계별 상세는 해당 `NN-*.md` 를 본다.

---

## 고정한 통제

| 통제 | 내용 | 근거 문서 |
|---|---|---|
| **지문 대조 후 신뢰** | 호스트 키는 기대 지문과 대조한 뒤에만 `known_hosts` 에 넣는다. 불일치 시 중단 | [00-ssh-server.md](00-ssh-server.md) (5절) |
| **순서 강제** | 키 인증이 되는지 확인하기 전에는 비밀번호 인증을 끄지 않는다 | [00-ssh-server.md](00-ssh-server.md) |
| **범위 한정** | 비밀번호 인증·22/tcp 는 기본적으로 LAN 격리 대역(`10.10.10.0/24`)으로 한정 | [00-ssh-server.md](00-ssh-server.md) |
| **개인키는 생성한 Mac 을 벗어나지 않는다** | 노드로 전송되는 것은 `.pub`(공개키) 뿐이다 | [01-key-setup.md](01-key-setup.md) |
| **비파괴 키 생성** | 대상 파일이 이미 있으면 덮어쓰지 않고 중단한다 | [01-key-setup.md](01-key-setup.md) |
| **키 배치와 정책의 분리** | authorized_keys(신원)와 sshd 정책(방화벽·인증 규칙)을 다른 문서/스크립트가 관리한다 — 회전·추가 시 방화벽을 건드리지 않는다 | [02-ssh-keys.md](02-ssh-keys.md) |
| **비파괴 키 등록** | 옵션이 다른 동일 키가 있으면 자동으로 바꿔 쓰지 않고 경고한다 | [02-ssh-keys.md](02-ssh-keys.md) |
| **상태 기반 검증** | 설정 파일이 아니라 `sshd -T`·`ufw status`·`ssh -v` 의 실제 상태로 확인 | 전 단계 |

## 대조 상수

| 상수 | 값 | 용도 |
|---|---|---|
| 서버 호스트 키 지문 (ed25519) | `SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A` | `known_hosts` 등록 전 대조 |
| 격리 대역 | `10.10.10.0/24` (vmnet3) | 방화벽·`Match Address`·`from=` 범위 |

## 잔여 위험 색인

| 위험 | 상세 |
|---|---|
| **`00`이 스크립트 없이 전 과정 수동이다** — 재현성·오탈자 방지를 스크립트만큼 보장 못 함. 실습 목적으로 의도적 선택 | [00-ssh-server.md](00-ssh-server.md) |
| 비밀번호 인증 무차별 대입 표면 (OpenSSH 9.6, `PerSourcePenalties` 없음) | [00-ssh-server.md](00-ssh-server.md) |
| macOS 앱 단위 로컬 네트워크 권한 — 앱마다 차단/timeout | [00-ssh-server.md](00-ssh-server.md) (5-0절) · [../network-troubleshooting.md](../network-troubleshooting.md) |
| 개인키를 git 에 두는 경우의 노출 범위 | [01-key-setup.md](01-key-setup.md) |
| 무암호 개인키 — Mac 계정 침해 시 파일 권한(600)이 유일한 방어선 | [01-key-setup.md](01-key-setup.md) |
| `01-key-setup.sh`(전송 단계)는 지문 육안 대조 없이 `scp` 성공만으로 신뢰한다 — 비밀번호 인증이 부트스트랩 자격증명, 실습 지름길 | [01-key-setup.md](01-key-setup.md) |
| `authorized_keys` 옵션 충돌(무제한 키 잔존) 미자동 정리 | [02-ssh-keys.md](02-ssh-keys.md) |
