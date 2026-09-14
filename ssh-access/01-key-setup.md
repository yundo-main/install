# 01 · SSH 키 생성 + 전송

**요약.** Mac 에서 로컬로 실행해 노드 접속용 SSH 키페어를 만들고, 비밀번호
인증이 켜져 있으면 그 `.pub` 을 노드로 바로 전송한다(scp). 개인키는 이 Mac
을 벗어나지 않는다. **등록은 하지 않는다** — 그건 [02-ssh-keys.md](02-ssh-keys.md)
가 노드에서 한다.

> **역할: 단계 문서.** 이 단계의 근거·실행·옵션·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`01-key-setup.sh`](01-key-setup.sh). sshd·방화벽·인증 정책과
> 첫 접속·지문 대조는 [00-ssh-server.md](00-ssh-server.md)(수동 절차). 등록은
> [02-ssh-keys.md](02-ssh-keys.md)(노드 로컬).

| 항목 | 값 |
|---|---|
| **실행 위치** | macOS 클라이언트 |
| 기본 키 타입 | ed25519, 무암호(자동화용) |
| 전송 전제 | 대상 노드에 비밀번호 인증이 켜져 있음 ([00-ssh-server.md](00-ssh-server.md) 3절의 LAN 비밀번호 허용 블록을 선택한 경우) |
| 결과 | `<outdir>/<name>`(개인키, 600) / `<outdir>/<name>.pub`(공개키, 로컬+노드 사본) |

---

## 실행

```bash
./01-key-setup.sh
# 이름·대상 지정
./01-key-setup.sh --name lab_groom --host 10.10.10.150 --user groom
# 비밀번호 인증이 꺼져 있을 때 — 생성만 하고 전송은 수동으로
./01-key-setup.sh --skip-transfer
```

### 옵션

| 옵션 | 설명 |
|---|---|
| `--name <label>` | 키 파일 이름 (기본 `lab_groom`) |
| `--outdir <dir>` | 저장 위치 (기본 `~/.ssh`) |
| `--type <type>` | `ssh-keygen -t` 값 (기본 `ed25519`) |
| `--comment <text>` | 키 코멘트 (기본 `<name>-<YYYYMM>`) |
| `--host <ip>` / `--user <name>` | 전송 대상 (기본 `10.10.10.150` / `groom`) |
| `--skip-transfer` | 생성만 하고 전송하지 않는다 |
| `--verify-only` | 생성·전송 없이 기존 키 상태만 표시 |

---

## 스크립트가 하는 일

1. 대상 파일(`<outdir>/<name>`, `.pub`)이 이미 있으면 중단한다 — 비파괴.
2. `ssh-keygen -t <type> -N ''` 로 무암호 키를 생성한다. 개인키 600, 공개키 644.
3. `--skip-transfer` 가 아니면 `scp` 로 `.pub` 을 노드의 홈 디렉터리에 보낸다
   (비밀번호 대화형 입력). 실패하면 경고만 하고 수동 절차를 안내한다 — 죽지
   않는다.
4. 검증: 로컬 키 파일 존재·권한·지문을 출력한다.

**등록은 여기서 하지 않는다.** 전송까지 끝나면 노드에서 직접
[02-ssh-keys.sh](02-ssh-keys.sh) 를 실행해 `authorized_keys` 에 반영한다.

---

## 검증

```bash
./01-key-setup.sh --name lab_groom --verify-only
```
```
검증 — 키 파일
  개인키: /Users/jarrod/.ssh/lab_groom (권한 600, 600 이어야 한다)
  공개키: /Users/jarrod/.ssh/lab_groom.pub
  지문: 256 SHA256:... lab_groom-202609 (ED25519)
```

노드에 전송이 실제로 됐는지는 노드에서 직접 확인한다:
```bash
# 노드에서
ls -la ~/lab_groom.pub && ssh-keygen -lf ~/lab_groom.pub
```
위 지문이 Mac 쪽 출력과 문자 그대로 같아야 한다.

---

## 잔여 위험 / 전제

- 무암호(`-N ''`) 키다. 개인키 파일 권한(600)이 유일한 방어선이다 — 이 Mac
  계정 자체가 침해되면 이 키도 함께 침해된다.
- 이미 있는 파일은 덮어쓰지 않는다. 키를 교체하려면 `--name` 으로 새 이름을
  쓰고, 노드의 `authorized_keys` 에서 구 키를 수동으로 제거한다.
- **전송(scp)은 비밀번호 인증에 의존하는 실습 지름길이다.** 콘솔 붙여넣기와
  달리 노드에 도착한 파일의 지문을 눈으로 대조하는 단계가 없다 — `scp` 성공
  자체를 신뢰의 근거로 삼는다. 실습이 아니라 실제 운영 노드라면 이 지름길을
  쓰지 않고 [00-ssh-server.md](00-ssh-server.md) 의 콘솔 붙여넣기 절차를 쓴다.
- 비밀번호가 노출될 수 있는 네트워크(공유 Wi-Fi 등)에서 전송을 실행하지 않는다.
- 실습·랩 환경에서 개인키를 git 에 두어야 한다면:
  - 가능하면 **공개키만** 커밋한다(`keys/*.pub`). `.gitignore` 로 개인키
    확장자/이름을 차단한다.
    ```
    # 개인키 커밋 금지
    keys/*
    !keys/*.pub
    ```
  - 개인키까지 커밋해야 하면: private 리포 + 이 노드 전용 폐기 가능한 키 +
    [02-ssh-keys.md](02-ssh-keys.md) 의 `--restrict-cidr` 필수.
  - gitleaks/git-secrets 를 pre-commit 훅으로 걸어 실수 커밋을 물리적으로 막는다.
