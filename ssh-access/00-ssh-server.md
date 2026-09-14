# 00 · SSH 서버 · 방화벽 · 인증 정책 (+ 첫 접속)

**요약.** 대상 노드에서 로컬로, **손으로** openssh-server 를 설치하고 소켓
활성화를 끈 뒤(`ssh.service` 고정) ufw(22/tcp 만 LAN 허용)와 sshd 인증 정책을
구성한다. 마지막 절에서 Mac 에서 처음 접속해 호스트 키 지문을 대조하고
`known_hosts` 에 등록한다. **실행 도구 없음 — 전 과정 수동.** 공개키 등록은
[01-key-setup.md](01-key-setup.md) → [02-ssh-keys.md](02-ssh-keys.md) 소관.

> **역할: 단계 문서 — 스크립트 없음.** 서버 구성부터 첫 접속·지문 대조까지
> 이 한 문서에서 손으로 진행한다(왜 스크립트가 아닌지는 문서 끝 「잔여 위험」
> 참조). 디렉터리 구성은 [README.md](README.md). 키 생성·전달은
> [01-key-setup.md](01-key-setup.md). 등록은 [02-ssh-keys.md](02-ssh-keys.md).

| 항목 | 값 |
|---|---|
| **실행 위치** | 앞부분(1~4)은 **노드** 콘솔, 마지막(5~)은 **Mac** — 각 절 앞에 표시 |
| 대상 | `10.10.10.150` / Ubuntu 24.04.4 LTS |
| 계정 | `groom` (sudo 그룹) |
| 격리 대역 | `10.10.10.0/24` (VMware Fusion vmnet3, host-only + NAT) |
| 결과 | `ssh.service` 상시 기동 · ufw deny-incoming(22 만 허용) · 인증 정책 적용 · Mac 의 `known_hosts` 에 이 노드 등록 |

---

## 1. openssh-server 설치·기동 (노드에서)

```bash
dpkg -s openssh-server > /dev/null 2>&1 || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq openssh-server
}
```

**소켓 활성화 해제.** Ubuntu 22.10+ / 24.04 는 기본이 `ssh.socket` 소켓
활성화다. 이 모드에서는 `sshd_config` 의 `Port`·`ListenAddress`·`MaxStartups`
가 무시되고 연결마다 인스턴스가 뜬다. 상시 데몬이 예측 가능하므로 소켓을 끄고
서비스로 고정한다.

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl unmask ssh.service
sudo systemctl enable --now ssh.service
```

확인:
```bash
systemctl is-active ssh.service   # active
systemctl is-active ssh.socket    # inactive 여야 한다
sudo ss -tlnp | grep ':22 '       # LISTEN 확인
```

---

## 2. 방화벽 — ufw (노드에서)

```bash
command -v ufw > /dev/null || sudo apt-get install -y -qq ufw

# 허용 규칙을 enable 보다 먼저 넣는다 — 순서를 뒤집으면 원격 세션이 끊긴다
sudo ufw allow proto tcp from 10.10.10.0/24 to any port 22 comment "00-ssh-server: sshd lan"

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw logging low

sudo ufw --force enable    # 이미 active 면: sudo ufw reload
```

외부 노출이 필요 없으면 `10.10.10.0/24` 를 그대로 둔다. 대역을 넓히려면
`from` 값만 바꾼다 (예: `from any` — 무차별 대입 표면이 늘어난다).

확인:
```bash
sudo ufw status verbose
```

---

## 3. 인증 정책 — `/etc/ssh/sshd_config.d/60-auth-policy.conf` (노드에서)

이 드롭인 파일 하나로 인증 정책을 관리한다. **비밀번호 인증을 켤지**가
핵심 선택이다 — 실습 편의상 켜두면 이후 [01-key-setup.md](01-key-setup.md) 의
자동 전송(scp)을 쓸 수 있고, 끄면(zero-trust) 모든 키 전달이 콘솔 수작업이다.

**LAN 대역에서만 비밀번호 허용 (권장 — 이 문서 뒤쪽 5절과 맞물림):**
```bash
sudo tee /etc/ssh/sshd_config.d/60-auth-policy.conf > /dev/null <<'EOF'
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20

PasswordAuthentication no

Match Address 10.10.10.0/24
    PasswordAuthentication yes
Match all
EOF
```

**또는 완전 zero-trust (publickey 전용, 비밀번호 완전 차단):**
```bash
sudo tee /etc/ssh/sshd_config.d/60-auth-policy.conf > /dev/null <<'EOF'
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20

PasswordAuthentication no
EOF
```

`Match all` 종결자는 필수다(LAN 버전) — 없으면 `Include` 이후의 메인 설정
라인이 이 `Match` 블록에 흡수된다.

적용:
```bash
sudo sshd -t && sudo systemctl reload ssh
```
`sshd -t` 가 실패하면 **reload 하지 않는다** — 실행 중 설정은 그대로 유지되고,
드롭인 파일 문법만 고쳐서 다시 시도한다.

zero-trust(비밀번호 완전 차단)로 두고 아직 공개키를 하나도 등록 안 했다면,
**이 콘솔 세션이 유일한 접근 경로**다. 창을 닫기 전에
[01-key-setup.md](01-key-setup.md) → [02-ssh-keys.md](02-ssh-keys.md) 로 키를
먼저 등록한다.

---

## 4. 검증 (노드에서)

```bash
sudo sshd -T | grep -iE '^(passwordauthentication|pubkeyauthentication|permitrootlogin|maxauthtries|logingracetime) '

# LAN 버전을 썼다면 — 안/밖 분기 확인
sudo sshd -T -C addr=10.10.10.1,user=root,host=probe  | awk '/^passwordauthentication /{print $2}'  # yes
sudo sshd -T -C addr=198.51.100.1,user=root,host=probe | awk '/^passwordauthentication /{print $2}' # no

systemctl is-active ssh.service ssh.socket
sudo ufw status verbose

# 호스트 키 지문 — 이 값을 5절에서 Mac 과 대조한다
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

---

## 5. Mac에서 첫 접속 + 지문 대조 (Mac에서)

여기서부터 **Mac** 이다. 목적은 두 가지: (1) 서버가 실제로 접속 가능한지
확인, (2) 호스트 키 지문을 대조해 `known_hosts` 에 등록(TOFU 를 맹목적으로
하지 않는다 — MITM 방어).

### 5-0. macOS 로컬 네트워크 권한

macOS 는 로컬 네트워크 접근을 **앱 단위**로 통제한다. `10.10.10.0/24` 는
로컬 네트워크로 분류되므로 SSH 를 실행하는 앱(Terminal/iTerm/Termius 등)마다
허가가 필요하다.

**시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크** 에서 해당 앱을
허용하고 **완전 종료 후 재실행**한다.

```bash
ping -c 2 10.10.10.150
```
| 출력 | 원인 |
|---|---|
| `ping: sendto: No route to host` | 앱 로컬 네트워크 권한 차단 |
| `Request timeout` | 패킷은 나감 — 경로/수신측 문제, 또는 차단이 timeout 으로 나타남 |
| `64 bytes from ...` | 정상 |

권한을 껐다 켜도 안 되면:
```bash
tccutil reset LocalNetworkAuthorization <bundle-id>   # 예: com.googlecode.iterm2
```
상세 판별은 [../network-troubleshooting.md](../network-troubleshooting.md).

### 5-1. 지문 대조 후 접속

4절에서 노드 콘솔에 출력된 지문을 여기 가져와 비교한다:

```bash
# Mac 에서 — 노드가 광고하는 지문을 미리 수집(아직 known_hosts 에 넣지 않음)
ssh-keyscan -t ed25519 10.10.10.150 2>/dev/null | ssh-keygen -lf -
```

출력된 지문이 **4절에서 노드 콘솔에 적어둔 값과 문자 그대로 같은지** 확인한다.
다르면 중단 — MITM 가능성이 있으니 원인을 먼저 밝힌다.

일치하면 접속한다 (처음 접속이라 TOFU 확인 프롬프트가 뜬다 — 지문을 이미
대조했으니 `yes`):

```bash
ssh groom@10.10.10.150
```
```
The authenticity of host '10.10.10.150' can't be established.
ED25519 key fingerprint is SHA256:...
Are you sure you want to continue connecting (yes/no)? yes
```

여기서 `known_hosts` 에 자동 등록된다. 3절에서 LAN 비밀번호 허용을 선택했다면
비밀번호로 로그인된다 (zero-trust 를 선택했다면 아직 키가 없어 로그인 자체는
안 되지만, TOFU 등록은 접속 시도만으로 끝난다 — `ssh` 는 인증 전에 호스트 키
확인부터 한다).

### 5-2. `~/.ssh/config` 별칭 (선택)

```
Host ub24 10.10.10.150
    User           groom
    IdentityFile   ~/.ssh/lab_groom
    IdentitiesOnly yes
```

`IdentitiesOnly yes` 는 지정 키만 제시한다. 없으면 에이전트의 모든 키를 시도
하다 서버 `MaxAuthTries 3` 을 초과해 거부되거나 비밀번호 프롬프트에 도달하지
못한다.

### 5-3. 접속 방법

**5-2 의 `~/.ssh/config` 별칭을 만들지 않았다면** (또는 `~/.ssh/config` 에 이
호스트용 다른 `IdentityFile` 이 이미 있다면), 매번 `-i`/`-o IdentitiesOnly=yes`
로 키를 못박아야 한다 — 안 그러면 config 의 예전 키나 에이전트의 다른 키가
먼저 시도돼 실패한다:

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/lab_groom groom@10.10.10.150                      # 기본 접속
ssh -o IdentitiesOnly=yes -i ~/.ssh/lab_groom groom@10.10.10.150 'systemctl status ssh'  # 원격 명령
ssh -t -o IdentitiesOnly=yes -i ~/.ssh/lab_groom groom@10.10.10.150 'sudo whoami'      # sudo 는 -t 필수
scp -o IdentitiesOnly=yes -i ~/.ssh/lab_groom ./파일 groom@10.10.10.150:~/            # 파일 전송
ssh -o IdentitiesOnly=yes -i ~/.ssh/lab_groom -L 8080:localhost:8080 groom@10.10.10.150  # 포트 포워딩
```

**5-2 의 별칭을 만들었다면** (그 안에 `IdentityFile ~/.ssh/lab_groom` 을 이미
지정했으므로) 매번 `-i` 를 안 붙여도 된다:

```bash
ssh ub24                                        # 기본 접속 (config 별칭)
ssh ub24 'systemctl status ssh'                 # 원격 명령
ssh -t ub24 'sudo whoami'                       # sudo 는 -t 필수
scp ./파일 ub24:~/                              # 파일 전송
ssh -L 8080:localhost:8080 ub24                 # 포트 포워딩
```

연결 진단:
```bash
ssh -v -o IdentitiesOnly=yes -i ~/.ssh/lab_groom groom@10.10.10.150 true \
  2>&1 | grep "Authentications that can continue"
```
실패 시 송신측/수신측, TCP 계층, SSH 인증 계층을 순서대로 좁힌다 —
[../network-troubleshooting.md](../network-troubleshooting.md).

---

## 잔여 위험 / 전제

- **스크립트가 없다.** 여기 있는 모든 명령은 사람이 직접 친다 — 이 노드가
  실습 전용이라 보안·재현성보다 "직접 손으로 배우는 것"을 우선했기 때문이다.
  운영 환경이라면 각 절의 명령을 스크립트로 고정하고(멱등성·검증 자동화),
  `sshd -t` 실패 시 드롭인을 자동 롤백하는 안전장치를 되살린다.
- `PasswordAuthentication yes`(LAN 이든 전체든) 는 비밀번호 무차별 대입
  표면을 연다. OpenSSH 9.6 에는 `PerSourcePenalties`(9.8+) 가 없다. 자동
  소스 차단이 필요하면 `fail2ban` 을 별도 도입한다.
- LAN 한정은 `Match Address` / `ufw from` 기반이다. 브리지·추가 NIC 로 비
  LAN 경로가 생기면 그 경로엔 22/tcp·비밀번호가 노출되지 않는다(의도된 동작).
- 비밀번호 인증이 유효하려면 계정에 강한 암호가 있어야 한다. 미설정·약한
  암호에서는 이 정책이 순손실이다.
- `PermitRootLogin prohibit-password` 는 root 의 암호·kbd-interactive
  로그인만 차단한다. root 키 로그인은 별도로 통제한다.
- 호스트 키는 재생성하지 않는다. 회전이 필요하면 수동으로 수행하고 5절을
  다시 밟아 전 클라이언트에서 지문을 재대조한다.
- 5절의 지문 대조를 생략하고 그냥 `yes` 를 누르면 TOFU 등록 자체는 되지만
  MITM 방어라는 이 단계의 실제 목적은 사라진다 — 절차상 스킵되는 게 아니라
  검증의 의미가 없어지는 것이다.
