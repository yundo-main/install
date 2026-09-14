# 01 · SSH 키 생성

**요약.** Mac 에서 로컬로 실행해 노드 접속용 SSH 키페어를 만든다. 개인키는 이
Mac 을 벗어나지 않는다 — 노드로 가는 것은 `.pub`(공개키) 뿐이다. 이미 있는
파일은 덮어쓰지 않는다(비파괴).

> **역할: 단계 문서.** 이 단계의 근거·실행·옵션·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`01-key-generation.sh`](01-key-generation.sh). 여기서 만든
> `.pub` 을 노드로 옮기는 건 [02-key-transfer.md](02-key-transfer.md), 등록은
> [03-ssh-keys.md](03-ssh-keys.md)(노드 로컬).

| 항목 | 값 |
|---|---|
| **실행 위치** | macOS 클라이언트 |
| 기본 키 타입 | ed25519, 무암호(자동화용) |
| 결과 | `<outdir>/<name>`(개인키, 600) / `<outdir>/<name>.pub`(공개키) |

---

## 실행

```bash
./01-key-generation.sh
# 이름·타입 지정
./01-key-generation.sh --name lab_groom --type ed25519
```

### 옵션

| 옵션 | 설명 |
|---|---|
| `--name <label>` | 키 파일 이름 (기본 `lab_groom`) — `<outdir>/<name>[.pub]` 로 저장 |
| `--outdir <dir>` | 저장 위치 (기본 `~/.ssh`) |
| `--type <type>` | `ssh-keygen -t` 값 (기본 `ed25519`) |
| `--comment <text>` | 키 코멘트 (기본 `<name>-<YYYYMM>`) |
| `--verify-only` | 생성 없이 기존 키 상태만 표시 |

이미 쓸 만한 키(`~/.ssh/id_rsa` 등)가 있다면 이 스크립트를 건너뛰고 그 `.pub`
을 바로 [03-ssh-keys.md](03-ssh-keys.md) 에 넘겨도 된다 — 이 스크립트는
"이 노드 묶음 전용 키가 필요할 때"를 위한 것이다.

---

## 스크립트가 하는 일

1. 대상 파일(`<outdir>/<name>`, `.pub`)이 이미 있으면 중단한다 — 실수로
   기존 키를 덮어써 다른 곳에서 쓰던 접속 수단을 깨는 사고를 막는다.
2. `ssh-keygen -t <type> -N ''` 로 무암호 키를 생성한다. 개인키 600, 공개키
   644.
3. 검증: 파일 존재·권한·지문을 출력한다.

---

## 검증

```bash
./01-key-generation.sh --name lab_groom --verify-only
```
```
검증 — 키 파일
  개인키: /Users/jarrod/.ssh/lab_groom (권한 600, 600 이어야 한다)
  공개키: /Users/jarrod/.ssh/lab_groom.pub
  지문: 256 SHA256:... lab_groom-202609 (ED25519)
```

---

## 잔여 위험 / 전제

- 무암호(`-N ''`) 키다. 개인키 파일 권한(600)이 유일한 방어선이다 — 이 Mac
  계정 자체가 침해되면 이 키도 함께 침해된다.
- 이미 있는 파일은 덮어쓰지 않는다. 키를 교체하려면 `--name` 으로 새 이름을
  쓰고, 노드의 `authorized_keys` 에서 구 키를 수동으로 제거한다
  ([03-ssh-keys.md](03-ssh-keys.md) 참조 — 이 스크립트는 등록·폐기를 하지 않는다).
- 실습·랩 환경에서 개인키를 git 에 두어야 한다면:
  - 가능하면 **공개키만** 커밋한다(`keys/*.pub`). `.gitignore` 로 개인키
    확장자/이름을 차단한다.
    ```
    # 개인키 커밋 금지
    keys/*
    !keys/*.pub
    ```
  - 개인키까지 커밋해야 하면: private 리포 + 이 노드 전용 폐기 가능한 키 +
    [03-ssh-keys.md](03-ssh-keys.md) 의 `--restrict-cidr` 필수.
  - gitleaks/git-secrets 를 pre-commit 훅으로 걸어 실수 커밋을 물리적으로 막는다.
