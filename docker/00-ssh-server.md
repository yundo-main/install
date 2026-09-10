# 00 · SSH 서버 · 방화벽 · 인증 정책

> **역할: 단계 문서.** 이 단계의 근거·실행·옵션·기대 출력·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`00-ssh-server.sh`](00-ssh-server.sh). 디렉터리 구성은 [README.md](README.md).
> 클라이언트 측(지문 대조·`known_hosts`·`~/.ssh/config`)은 [01-ssh-client.md](01-ssh-client.md).

대상 노드에서 **로컬로** 실행한다 (게스트 콘솔 또는 로컬 세션). SSH·클라이언트가
필요 없다. macOS 의 앱 단위 로컬 네트워크 권한 때문에 클라이언트에서 sshd 설정을
원격으로 바꾸는 경로가 불안정하므로, 서버 구성은 노드에서 직접 수행한다.

| 항목 | 값 |
|---|---|
| 대상 | `10.10.10.150` (+ 워커 `.151` / `.152`) / Ubuntu 24.04.4 LTS |
| 계정 | `groom` (sudo 그룹) |
| 격리 대역 | `10.10.10.0/24` (VMware Fusion vmnet3, host-only + NAT) |
| 결과 | `ssh.service` 상시 기동 · ufw deny-incoming(22 만 허용) · publickey 전용(기본) |

---

## 실행

```bash
# 키 전용 (zero-trust 기본값) — 공개키를 노드로 먼저 옮긴 뒤
bash 00-ssh-server.sh --authorized-key-file ~/lab_groom.pub

# 키 + LAN 격리 대역 비밀번호 폴백
bash 00-ssh-server.sh --authorized-key-file ~/lab_groom.pub --password-auth lan
```

### 스크립트·공개키 전달

이 단계 이전에는 SSH·`scp` 경로가 없다. 스크립트와 `.pub` 파일을 노드에 올리는
방법:

| 방법 | 비고 |
|---|---|
| `git clone` + 커밋 SHA 체크아웃 | 무결성이 커밋 해시로 보장된다. 여러 파일을 한 번에 가져온다 — 전량이 필요하면 이 방법 |
| `wget` raw URL (아래) | 파일 하나만 필요할 때. `00-ssh-server.sh` 는 자기완결이라 이 파일만으로 실행된다 |
| VMware 공유 폴더 / 클립보드 붙여넣기 / USB | 네트워크가 없는 노드 |

**`wget` 은 `\| bash` 로 잇지 않는다.** 대상은 root 등가 권한을 얻는 호스트다.
다운로드 → 무결성 대조 → 육안 검토 → 실행으로 분리한다.

```bash
# main 이 아니라 커밋 SHA 로 고정한다 — 받는 내용이 확정되고 raw CDN 캐시 지연도 없다
REF=46e8c040acadf70a6097fcceb8272236ee0a2db7
BASE="https://raw.githubusercontent.com/yundo-main/install/${REF}/docker"

wget -q "${BASE}/00-ssh-server.sh" -O 00-ssh-server.sh     # TLS 검증 기본 — --no-check-certificate 금지

sha256sum 00-ssh-server.sh                                  # 별도 채널(로컬 clone)의 기대값과 대조
#   기대값:  git -C <clone> show ${REF}:docker/00-ssh-server.sh | sha256sum

less 00-ssh-server.sh                                       # 무엇을 sudo 로 실행하는지 직접 본다
bash 00-ssh-server.sh --authorized-key-file ~/lab_groom.pub
```

private 리포면 `gh api ...` 또는 `wget --header="Authorization: Bearer <token>"` 를
쓴다. 토큰은 명령행 인자로 넘기지 않는다 (`/proc/<pid>/cmdline`·history 노출) —
파일·환경변수로 다룬다.

### 옵션

| 옵션 | 설명 |
|---|---|
| `--password-auth <off\|lan\|on>` | 비밀번호 인증 정책. 기본 `off`(publickey 전용). `lan`: `--lan-cidr` 대역에서만 허용. `on`: 전 경로 허용 — 무차별 대입 표면 노출, 권장하지 않음 |
| `--lan-cidr <cidr>` | `--password-auth lan` 의 허용 대역 (기본 `10.10.10.0/24`) |
| `--authorized-key-file <path>` | 호출 계정 `~/.ssh/authorized_keys` 에 공개키 추가 (중복 줄 제외). 키 문자열을 인자로 받지 않는다 — 셸 history 노출 회피 |
| `--allow-users <u1,u2,...>` | `AllowUsers` 로 로그인 계정 화이트리스트 |
| `--permit-root <prohibit-password\|no\|yes>` | `PermitRootLogin` (기본 `prohibit-password`) |
| `--firewall <ufw\|none>` | 호스트 방화벽. 기본 `ufw`. `none`: 건드리지 않음 (nftables 직접 운용 등) |
| `--ssh-from <cidr\|any>` | 22/tcp 허용 출처 (기본 `--lan-cidr` 값). `any`: 전 경로 |
| `--verify-only` | 설치·변경 없이 유효 상태만 검증 |

---

## 스크립트가 하는 일

### 1. openssh-server 설치·기동

`dpkg -s openssh-server` 로 설치 여부를 보고, 없으면 `apt-get update` 후 설치한다.

**소켓 활성화 해제.** Ubuntu 22.10+ / 24.04 는 기본이 `ssh.socket` 소켓 활성화다.
이 모드에서는 `sshd_config` 의 `Port`·`ListenAddress`·`MaxStartups` 가 무시되고
연결마다 인스턴스가 뜬다. 클러스터 노드는 상시 데몬이 예측 가능하므로
`ssh.socket` 을 `disable --now` 하고 `ssh.service` 로 고정한다.

```bash
systemctl is-active ssh.service   # active
systemctl is-active ssh.socket    # inactive 여야 한다
```

### 2. 공개키 배치 (`--authorized-key-file` 지정 시)

`~/.ssh` 700, `authorized_keys` 600 을 보장하고, 유효한 키 타입으로 시작하는 줄만
취해 중복 없이 추가한다.

### 3. 방화벽 — ufw (`--firewall ufw`, 기본)

```
default deny incoming / allow outgoing
allow  proto tcp from <SSH_FROM> to any port 22   # 주석 태그 00-ssh-server
logging low
```

- 허용 규칙을 `enable` **보다 먼저** 넣는다. 순서를 뒤집으면 원격 세션이 끊긴다.
- 멱등: 재실행 시 주석 태그가 붙은 자기 규칙만 골라 제거 후 재적용한다. 수동
  추가 규칙은 건드리지 않는다.

### 4. 인증 정책 드롭인 — `/etc/ssh/sshd_config.d/60-auth-policy.conf`

이 스크립트가 이 드롭인 하나만 소유·관리한다. 레거시 `60-no-password.conf` 가
있으면 제거한다.

고정 항목:
```
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
```

`--password-auth lan` 일 때:
```
PasswordAuthentication no

Match Address 10.10.10.0/24
    PasswordAuthentication yes
Match all
```

`Match all` 종결자는 필수다 — 없으면 `Include` 이후의 메인 설정 라인이 이 `Match`
블록에 흡수된다.

적용 전 `sudo sshd -t` 로 병합 결과를 검사하고, 실패하면 드롭인을 제거한다
(실행 중 설정 불변). 통과 시 `systemctl reload ssh` (무중단).

---

## 검증

스크립트가 자동 수행하며, `--verify-only` 로 재실행할 수 있다. 근거는 파일 내용이
아니라 `sshd -T` / `ufw status` 가 보고하는 유효 상태다.

```bash
# 유효 설정
sudo sshd -T | grep -iE '^(passwordauthentication|pubkeyauthentication|permitrootlogin|maxauthtries|logingracetime) '

# Match 해석 — LAN 안/밖
sudo sshd -T -C addr=10.10.10.0,user=root,host=probe | awk '/^passwordauthentication /{print $2}'   # lan 정책 → yes
sudo sshd -T -C addr=198.51.100.1,user=root,host=probe | awk '/^passwordauthentication /{print $2}' # → no

# 서비스·리슨
systemctl is-active ssh.service ssh.socket
sudo ss -tlnp | grep ':22 '

# 방화벽
sudo ufw status verbose

# 호스트 키 지문 — 이 값을 받아 적어 01-ssh-client.md 에서 대조한다
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

기대:
```
passwordauthentication no
pubkeyauthentication yes
permitrootlogin prohibit-password
maxauthtries 3
logingracetime 20
ssh.service: active / ssh.socket: inactive
Status: active   Default: deny (incoming), allow (outgoing)
22/tcp   ALLOW IN   10.10.10.0/24
```

---

## 잔여 위험 / 전제

- **`wget` 로 스크립트를 받는 경로는 공급망 주입 지점이다.** 네트워크로 실행
  아티팩트를 root 등가 호스트에 들인다. `main` 이 아니라 커밋 SHA 고정 + 별도
  채널 해시 대조 + 실행 전 육안 검토가 완화책이다. 리포가 public 이면 raw URL 은
  누구나 읽는다 — 리포에 시크릿을 두지 않는 전제가 유지돼야 한다.
- `--password-auth lan|on` 은 비밀번호 무차별 대입 표면을 연다. OpenSSH 9.6 에는
  `PerSourcePenalties`(9.8+) 가 없다. 자동 소스 차단이 필요하면 `fail2ban` 을 별도
  도입한다 — 운영 부담 발생.
- `lan` 한정은 `Match Address` / `ufw from` 기반이다. 브리지·추가 NIC 로 비 LAN
  경로가 생겨도 그 경로에는 22/tcp·비밀번호가 노출되지 않는다 (의도된 동작).
- 비밀번호 인증이 유효하려면 계정에 강한 암호가 있어야 한다. 미설정(`NP`)·약한
  암호에서는 이 정책이 순손실이다.
- **ufw 는 호스트 자신의 인바운드만 통제한다.** [02-docker-ce.md](02-docker-ce.md)
  로 Docker 를 설치하면 `-p` 게시 컨테이너 포트는 ufw 를 우회한다 (Docker 가
  `nat`/`DOCKER` 체인에 직접 규칙 삽입, ufw `FORWARD` 평가보다 먼저). 컨테이너
  포트는 `127.0.0.1` 바인딩 또는 `DOCKER-USER` 체인으로 별도 통제한다.
- ufw 규칙은 `--ssh-from` 의 IPv4 주소군만 처리한다. sshd 가 `::` 로도 리슨하면
  v6 경로는 default deny 로 차단된다. vmnet 격리에서는 의도에 부합한다.
- `--firewall none` 은 방화벽을 건드리지 않는다. nftables 직접 운용 환경에서
  쓰고, 22/tcp 범위 통제 책임은 그 계층으로 넘어간다.
- `PermitRootLogin prohibit-password` 는 root 의 암호·kbd-interactive 로그인만
  차단한다. root 키 로그인은 별도로 통제한다.
- 호스트 키는 재생성하지 않는다. 회전이 필요하면 수동으로 수행하고 전 클라이언트
  에서 지문을 재대조한다. 복제 VM 의 호스트 키 승계 문제는
  [04-swarm-cluster.md](04-swarm-cluster.md) 1-4 절.
