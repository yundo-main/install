# 01 · SSH 키 등록

**요약.** 대상 노드에서 로컬로 실행해 사전에 준비한 공개키를 `authorized_keys`
에 추가한다. 키 생성은 하지 않는다. `--restrict-cidr` 로 authorized_keys 의
`from=` 제한을 걸 수 있다. sshd 정책은 [00-ssh-server.md](00-ssh-server.md) 소관.

> **역할: 단계 문서.** 이 단계의 근거·실행·옵션·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`01-ssh-keys.sh`](01-ssh-keys.sh). sshd·방화벽·인증 정책은
> [00-ssh-server.md](00-ssh-server.md). 클라이언트 측 검증은
> [02-ssh-client.md](02-ssh-client.md).

`00-ssh-server.sh` 가 "누가·어떻게 인증할 수 있는가"(정책)를 정하고, 이 단계는
"이 공개키를 신뢰한다"(신원)를 등록한다. 둘을 분리한 이유: 정책은 노드마다 한 번
고정되지만 키는 회전·추가·폐기가 그보다 잦다 — 방화벽·소켓 설정을 건드리지 않고
키만 갱신할 수 있어야 한다.

---

## 0. 키페어 준비 (이 스크립트 밖)

기존 키를 재사용하거나, 이 노드 묶음 전용으로 새로 만든다.

```bash
# 전용 키 — 무암호(자동화용). 비밀번호 없는 개인키이므로 취급에 준하는 통제가 필요하다.
ssh-keygen -t ed25519 -f ~/.ssh/lab_groom -C "lab-groom-$(date +%Y%m)" -N ''
```

**실습·랩 환경에서 개인키를 git 에 두어야 한다면:**
- 가능하면 **공개키만** 커밋한다(`keys/*.pub`). `.gitignore` 로 개인키 확장자/이름을 차단한다.
  ```
  # 개인키 커밋 금지
  keys/*
  !keys/*.pub
  ```
- 개인키까지 커밋해야 하면: private 리포 + 이 노드 전용 폐기 가능한 키 +
  `--restrict-cidr` (아래) 필수.
- gitleaks/git-secrets 를 pre-commit 훅으로 걸어 실수 커밋을 물리적으로 막는다.

## 실행

```bash
bash 01-ssh-keys.sh --authorized-key-file ~/lab_groom.pub

# LAN 격리 대역 밖에서는 이 키를 무효화 (권장 — 특히 개인키를 git 에 둔 경우)
bash 01-ssh-keys.sh --authorized-key-file ~/lab_groom.pub --restrict-cidr 10.10.10.0/24
```

`.pub` 파일 전달 방법은 [00-ssh-server.md](00-ssh-server.md) 「스크립트 전달」과
동일하다 (`git clone`, `wget`, 공유 폴더, 콘솔 붙여넣기).

### 옵션

| 옵션 | 설명 |
|---|---|
| `--authorized-key-file <path>` | 추가할 공개키 파일 (여러 줄 가능). 필수 |
| `--restrict-cidr <cidr>` | 추가하는 각 키에 `from="<cidr>"` 제한을 붙인다 |
| `--verify-only` | 변경 없이 `authorized_keys` 현재 상태만 표시 |

---

## 스크립트가 하는 일

1. `~/.ssh` 700, `authorized_keys` 600 을 보장한다.
2. 유효한 키 타입(`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, FIDO2 계열)으로
   시작하는 줄만 취한다. 주석·빈 줄·이미 옵션이 붙은 줄은 무시한다.
3. **동일 키 판별은 "타입 + base64 본문"만 본다** — `from=` 옵션·코멘트 유무와
   무관하다. 이미 있으면:
   - 최종 줄이 완전히 같으면 건너뛴다.
   - 옵션만 다르면(예: 무제한 → `--restrict-cidr` 추가) **자동으로 바꿔 쓰지
     않고 경고한다.** 접속 수단을 스크립트가 실수로 좁히는 사고를 막기 위함이다 —
     기존 무제한 줄이 남아 있으면 새 제한이 무의미해지므로, 경고가 뜨면
     `authorized_keys` 를 열어 직접 정리한다.
4. 검증: 파일 권한, 등록된 키 개수와 (마스킹된) 목록을 출력한다.

`--restrict-cidr` 는 authorized_keys 줄 앞에 `from="<cidr>"` 을 붙인다 — sshd 가
그 CIDR 밖에서 온 연결에는 이 키를 아예 시도하지 않는다.

---

## 검증

```bash
bash 01-ssh-keys.sh --verify-only
```
```
검증 — /Users/.../.ssh 권한
  700 /home/groom/.ssh
검증 — authorized_keys
  권한: 600 (600 이어야 한다)
  등록된 키 1개:
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

클라이언트에서 최종 확인:
```bash
ssh -o BatchMode=yes <user>@<VM IP> true && echo OK
```

---

## 잔여 위험 / 전제

- 키를 생성하지 않는다. 개인키의 생성·보관·전달은 운영자 책임이다.
- `--restrict-cidr` 는 authorized_keys 의 `from=` 만 건다. 개인키 자체의 비밀성은
  보장하지 않는다 — 유출 시 회전(이 노드의 `authorized_keys` 에서 제거)이 유일한 대응이다.
- 옵션이 다른 동일 키가 이미 있으면 자동으로 병합·교체하지 않는다. 무제한 키가
  남아 있으면 `--restrict-cidr` 로 추가한 제한이 무의미해진다 — 스크립트가 이 경우
  경고만 하고 멈추지 않으므로, 출력의 "옵션 충돌" 건수를 반드시 확인한다.
- `authorized_keys` 를 이 스크립트가 배타적으로 관리하지 않는다.
  [02-ssh-client.md](02-ssh-client.md) 의 `ssh-copy-id` 경로가 같은 파일에 쓸 수
  있다 — 위 옵션 충돌 검사로 걸러지지만, 두 경로를 섞어 쓰면 관리가 번거롭다.
  콘솔 접근이 되면 이 스크립트로 통일한다.
- 실습 키를 public 리포에 올리는 경우, `--restrict-cidr` 를 걸어도 리포 자체의
  노출(다른 실습·프로젝트로 키 재사용 등)까지 막지는 못한다. 키는 이 노드 묶음
  전용으로 두고 실습 종료 시 폐기한다.
