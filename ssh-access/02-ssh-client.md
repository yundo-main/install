# 02 · SSH 클라이언트 — 지문 대조 · 접속

**요약.** macOS 클라이언트에서 실행해 서버 호스트 키 지문을 대조·`known_hosts`
등록하고, `~/.ssh/config` 별칭을 만들고, 무암호 접속을 검증한다. `authorized_keys`
등록은 [01-ssh-keys.md](01-ssh-keys.md), 비밀번호 정책은
[00-ssh-server.md](00-ssh-server.md) 소관.

> **역할: 단계 문서.** 이 단계의 근거·실행·옵션·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`02-ssh-client.sh`](02-ssh-client.sh). 서버 측(sshd·방화벽)은
> [00-ssh-server.md](00-ssh-server.md), 키 등록은 [01-ssh-keys.md](01-ssh-keys.md).
> 연결 실패 판별은 [../network-troubleshooting.md](../network-troubleshooting.md).

macOS 클라이언트(`10.10.10.1`)에서 실행한다. 호스트 키 지문을 대조해 `known_hosts`
에 등록하고, `~/.ssh/config` 별칭을 두고, 무암호 접속을 검증한다.

`authorized_keys` 배치는 [01-ssh-keys.md](01-ssh-keys.md), 비밀번호 인증 정책은
[00-ssh-server.md](00-ssh-server.md) 가 노드에서 담당한다. 이 문서는 **클라이언트가
그 서버에 올바르게 접속되는지**까지다.

**실행 위치: 기본은 Mac.** 예외 한 곳(호스트 키 지문 확인, 「실행」 절 첫 블록)만
노드 콘솔에서 한다 — 그 지점에 별도로 표시한다.

---

## 0. 사전 요건 — macOS 로컬 네트워크 권한

macOS 는 로컬 네트워크 접근을 **앱 단위**로 통제한다 (Sequoia 이후 강제).
`10.10.10.0/24` 는 로컬 네트워크로 분류되므로 SSH 를 실행하는 앱마다 허가가
필요하다. 미허가 앱은 커널이 송신을 차단한다.

**시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크** 에서 해당 앱
(Terminal.app / iTerm / Termius / VS Code 등)을 허용하고 **완전 종료 후 재실행**.

**Mac(그 앱)에서:**
```bash
ping -c 2 10.10.10.150
```
| 출력 | 원인 |
|---|---|
| `ping: sendto: No route to host` | 앱 로컬 네트워크 권한 차단 (커널이 송신 거부) |
| `Request timeout` | 패킷은 나감 — 경로 또는 수신측. Electron 앱(Termius)은 차단 시 즉시 오류 대신 timeout 으로 나타나기도 한다 |
| `64 bytes from ...` | 정상 |

토글이 켜져 있는데도 안 되면 **Mac 에서:**
```bash
tccutil reset LocalNetworkAuthorization <bundle-id>   # 예: com.googlecode.iterm2 / com.termius-dmg.mac
```
후 재실행. 상세 판별은 [../network-troubleshooting.md](../network-troubleshooting.md).

---

## 실행

**노드 콘솔에서** 호스트 키 지문을 먼저 확인한다 ([00-ssh-server.md](00-ssh-server.md)
검증 절 출력과 같은 값이어야 한다):

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```
```
256 SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A 10.10.10.150 (ED25519)
```

**Mac 에서** 그 값을 넘겨 실행한다 (여기서부터 이 문서가 끝날 때까지 전부 Mac):

```bash
./02-ssh-client.sh --expect-fpr SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
```

`--expect-fpr` 를 생략하면 수집한 지문을 출력하고 대화형 확인을 요구한다.
`--yes` 는 `--expect-fpr` 없이는 동작하지 않는다 — 무검증 TOFU 를 허용하지 않는다.

### 옵션

| 옵션 | 설명 |
|---|---|
| `--host <ip>` / `--user <name>` / `--key <path>` | 대상·계정·공개키 (기본 `10.10.10.150` / `groom` / `~/.ssh/id_rsa.pub`) |
| `--expect-fpr <SHA256:...>` | 호스트 키 지문 고정. 불일치 시 중단 (MITM 방어) |
| `--yes` | 대화형 확인 생략 (`--expect-fpr` 필수) |
| `--disable-password` | 키 인증 검증 성공 후 원격 `sudo` 로 비밀번호 인증 차단. **SSH-only 폴백** — 콘솔 접근이 가능하면 [00-ssh-server.md](00-ssh-server.md) 의 `--password-auth` 를 쓴다. 두 경로를 함께 쓰지 않는다 |

---

## 스크립트가 하는 일

1. **도달성** — 공개키 존재, ICMP, `22/tcp` 개방 확인.
2. **1-1 호스트 키 지문 대조** — `ssh-keyscan -t ed25519` 로 수집, `--expect-fpr`
   또는 대화형 확인, 일치 시 `known_hosts` 등록. `~/.ssh` 700, `known_hosts` 600.
3. **1-2 공개키 배포** — 키 인증이 이미 되면 건너뛴다. 아니면 `ssh-copy-id`
   (SSH·비밀번호가 이미 되는 경우의 대안 경로). 노드에서
   [01-ssh-keys.md](01-ssh-keys.md) 로 이미 배치했다면 이 단계는 자동으로 건너뛴다.
4. **검증** — `ssh -o PasswordAuthentication=no -o BatchMode=yes ... 'id'` 성공,
   출력에 `(sudo)` 포함 확인 (없으면 서버 측 Docker 스크립트가 실패한다).
5. **비밀번호 인증 상태** — 데몬이 광고하는 인증 수단을 출력. `--disable-password`
   지정 시 원격으로 차단하고 재검증.

---

## `~/.ssh/config` 별칭

```
Host ub24 10.10.10.150 10.10.10.151 10.10.10.152
    User           groom
    IdentityFile   ~/.ssh/id_rsa
    IdentitiesOnly yes
```

`IdentitiesOnly yes` 는 지정 키만 제시한다. 없으면 에이전트의 모든 키를 시도하다
서버 `MaxAuthTries 3` 을 초과해 거부되거나 비밀번호 프롬프트에 도달하지 못한다.
키 제시 1회 = 인증 시도 1회로 카운트된다.

---

## 접속 방법

```bash
ssh ub24                                    # 기본 접속
ssh groom@10.10.10.150 'docker ps'          # 원격 명령
ssh -t groom@10.10.10.150 'sudo systemctl status docker'   # sudo 는 -t 필수
scp ./파일 groom@10.10.10.150:~/            # 파일 전송
rsync -av ./dir/ groom@10.10.10.150:~/dir/
ssh -L 8080:localhost:8080 groom@10.10.10.150   # 포트 포워딩 — 컨테이너 접근
```

컨테이너는 `-p 127.0.0.1:8080:8080` 으로 띄우고 위 포워딩으로 접근한다. 게스트
포트를 네트워크에 노출하지 않는다.

### 연결 진단

```bash
ping -c 2 10.10.10.150
ssh -o BatchMode=yes ub24 true && echo OK
ssh -v ub24 true 2>&1 | grep "Authentications that can continue"
```
```
64 bytes from 10.10.10.150: icmp_seq=0 ttl=64 time=0.5 ms
OK
debug1: Authentications that can continue: publickey
```

실패 시 송신측/수신측, TCP 계층, SSH 인증 계층을 순서대로 좁힌다 —
[../network-troubleshooting.md](../network-troubleshooting.md).

---

## 다음 단계

```bash
scp ../docker/00-docker-ce.sh ../docker/01-compose.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/00-docker-ce.sh'
ssh -t groom@10.10.10.150 'bash ~/01-compose.sh'   # Compose 가 필요한 경우
```

---

## 잔여 위험 / 전제

- `~/.ssh/id_rsa` 는 파일명과 달리 ED25519 키일 수 있다 (실측: comment `jarrod@macbok2`).
  RSA 를 전제한 도구·문서가 오작동할 수 있으므로 `ssh-keygen -lf` 로 실제 타입을
  확인한다.
- `--disable-password`(이 스크립트) 와 `00-ssh-server.sh --password-auth`(00) 는
  같은 드롭인 영역을 다룬다. 한 경로만 쓴다. 콘솔 접근이 되면 00 을 기준으로 한다.
- 복제 VM 은 호스트 키 지문이 동일해 `known_hosts` 로 노드를 구별하지 못한다.
  [../docker/02-swarm-cluster.md](../docker/02-swarm-cluster.md) 1-4·3-1 절에서
  신원을 분리한 뒤 재대조한다.
- 지문을 대조하지 않은 TOFU 등록은 MITM 을 탐지하지 못한다. `--expect-fpr` 를
  생략한 대화형 확인은 운영자의 육안 대조에 의존한다.
