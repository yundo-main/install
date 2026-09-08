# Ubuntu 24.04 Docker 설치

> **역할: 기준 문서(source of truth).** 절차의 근거와 기대 출력을 보유한다.
> 스크립트가 대조하는 상수(GPG 지문, 호스트 키 지문)와 검증 기준의 출처가 이 문서다.
> 실행 도구가 아니다 — 실행은 [USAGE.md](USAGE.md) 를 따른다.
> 배제된 대안(`apt-key add`)과 그 이유도 여기에만 기록한다.

Mac(SSH 클라이언트)에서 Ubuntu 24.04 VM(Docker 호스트)에 SSH 키 인증을 구성하고
Docker 공식 저장소로 Docker CE 를 설치하는 절차.

| 항목 | 값 |
|---|---|
| 서버 | `10.10.10.150` / Ubuntu 24.04.4 LTS / arm64 |
| 계정 | `groom` (sudo 그룹) |
| 클라이언트 | `10.10.10.1` (macOS, VMware Fusion vmnet3) |
| 결과 | Docker 29.7.2 / containerd v2.3.4 / runc 1.4.3 / compose v5.5.0 |

---

## 0. 사전 요건

### macOS — 로컬 네트워크 권한
**시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크** 에서 터미널을 실행하는 앱
(Terminal.app 또는 Visual Studio Code)을 허용한다. 적용 후 해당 앱 재시작.

권한이 없으면 VM 으로 나가는 패킷이 커널에서 차단된다.

```bash
ping -c 2 10.10.10.150
```
```
64 bytes from 10.10.10.150: icmp_seq=0 ttl=64 time=0.505 ms
```
응답이 없으면 [network-troubleshooting.md](network-troubleshooting.md) 참조.

### Ubuntu VM — SSH 서버
게스트 콘솔에서 실행한다.

```bash
sudo apt update
sudo apt install openssh-server -y
sudo systemctl enable --now ssh
systemctl is-active ssh
```

**검증** — Mac 에서:
```bash
nc -z -w 4 10.10.10.150 22 && echo OPEN
```
```
OPEN
```

---

## 1. SSH 키 인증 구성

### 1-1. 호스트 키 확인

게스트 콘솔에서 지문을 확인한다.
```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Mac 에서 수집한 값과 대조한 뒤 등록한다.
```bash
ssh-keyscan -t ed25519 10.10.10.150 | ssh-keygen -lf -
ssh-keyscan -t ed25519 10.10.10.150 >> ~/.ssh/known_hosts
```
```
256 SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A 10.10.10.150 (ED25519)
```

### 1-2. 공개키 배포

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub groom@10.10.10.150
```
```
Number of key(s) added:        1
```

**검증** — 비밀번호 없이 접속되는지 확인한다.
```bash
ssh -o PasswordAuthentication=no -o BatchMode=yes groom@10.10.10.150 'id'
```
```
uid=1000(groom) gid=1000(groom) groups=1000(groom),...,27(sudo),...
```

### 1-3. 비밀번호 인증 차단

위 검증이 **성공한 뒤에** 적용한다. 순서를 뒤집으면 접속 수단이 사라진다.

```bash
sudo tee /etc/ssh/sshd_config.d/60-no-password.conf > /dev/null <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF

sudo sshd -t && sudo systemctl reload ssh.service
```
```
configuration OK
```

**검증** — 서버가 광고하는 인증 수단으로 확인한다. 설정 파일이 아니라 데몬의 실제 상태다.
```bash
ssh -v -o BatchMode=yes -o PubkeyAuthentication=no groom@10.10.10.150 true 2>&1 \
  | grep "Authentications that can continue"
```
```
debug1: Authentications that can continue: publickey
```
`password` 가 목록에 남아 있으면 reload 가 반영되지 않은 것이다.

키 로그인이 여전히 되는지 최종 확인한다.
```bash
ssh -o BatchMode=yes groom@10.10.10.150 'echo OK'
```

---

## 2. 저장소 신뢰 설정

이후 명령은 모두 SSH 접속 후 서버에서 실행한다.

### 2-1. 기존 패키지 확인

```bash
dpkg -l | grep -iE "docker|containerd|runc|podman"
```
출력이 있으면 제거한다.
```bash
sudo apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc
```

### 2-2. GPG 키 — 지문 대조 후 등록

키를 먼저 받아 **지문을 확인한 뒤에** 신뢰 경로에 넣는다.

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
gpg --show-keys --with-fingerprint /tmp/docker.asc | grep -A1 "^pub"
```
```
pub   rsa4096 2017-02-22 [SCEA]
      9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88
```
위 지문과 일치할 때만 다음으로 진행한다.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo install -m 0644 -o root -g root /tmp/docker.asc /etc/apt/keyrings/docker.asc
rm /tmp/docker.asc
```

### 2-3. 저장소 등록

```bash
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
```

`signed-by=` 는 이 키의 서명 권한을 해당 저장소로만 한정한다.
`apt-key add` 방식은 키를 전역 키링에 넣어 모든 저장소를 서명할 수 있게 하므로 쓰지 않는다.

**검증**
```bash
apt-cache policy docker-ce | head -5
```
```
docker-ce:
  설치: (없음)
  후보: 5:29.7.2-1~ubuntu.24.04~noble
  버전 테이블:
     5:29.7.2-1~ubuntu.24.04~noble 500
        500 https://download.docker.com/linux/ubuntu noble/stable arm64 Packages
```
`apt-get update` 에서 GPG 오류가 없어야 한다. 오류가 나면 키 등록이 잘못된 것이다.

---

## 3. 패키지 설치

```bash
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

**검증**
```bash
docker --version
containerd --version
runc --version | head -1
docker buildx version
docker compose version
```
```
Docker version 29.7.2, build a7dcaa6
containerd containerd v2.3.4 db8809540e1a7a9da5d518876894933ff55692ab
runc version 1.4.3
github.com/docker/buildx v0.36.1 ...
Docker Compose version v5.5.0
```

---

## 4. 서비스 기동·동작 확인

패키지 설치 시 systemd 유닛이 자동 등록·기동된다.

```bash
for u in docker.service docker.socket containerd.service; do
  printf "%-20s enabled=%-9s active=%s\n" $u \
    "$(systemctl is-enabled $u)" "$(systemctl is-active $u)"
done
```
```
docker.service       enabled=enabled   active=active
docker.socket        enabled=enabled   active=active
containerd.service   enabled=enabled   active=active
```

**검증** — 전 경로(레지스트리 pull → containerd → runc)를 확인한다.
```bash
sudo docker run --rm hello-world
```
```
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

---

## 5. 권한 모델 — `docker` 그룹

`sudo` 없이 docker 를 쓰려면 그룹에 추가한다.

```bash
sudo usermod -aG docker groom
```

새 로그인 세션부터 반영된다. SSH 는 접속마다 새 세션이므로 재접속하면 된다.

**검증**
```bash
exit
ssh groom@10.10.10.150
docker run --rm hello-world
```

> `docker` 그룹 멤버는 임의 경로를 컨테이너에 마운트해 uid 0 으로 접근할 수 있다.
> 이 그룹을 부여하면 해당 계정은 실질적으로 root 권한을 갖는다.
> `sudo docker` 만 쓰려면 이 단계를 생략한다.

---

## 6. 데몬 설정

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true,
  "icc": false
}
JSON

sudo dockerd --validate --config-file /etc/docker/daemon.json
sudo systemctl restart docker
```
```
configuration OK
```

| 설정 | 효과 |
|---|---|
| `log-opts` | 컨테이너 로그 10MB × 3개로 제한. 디스크 무한 증가 방지 |
| `live-restore` | 데몬 재시작 시 실행 중 컨테이너 유지 |
| `no-new-privileges` | 컨테이너 내 권한 상승 차단. setuid 바이너리(`ping`, `sudo`)가 동작하지 않는다 |
| `icc` | 기본 bridge 네트워크의 컨테이너 간 통신 차단. 사용자 정의 네트워크에는 적용되지 않는다 |

**검증** — 파일 내용이 아니라 데몬·컨테이너의 실제 상태로 확인한다.

```bash
docker info --format "live-restore : {{.LiveRestoreEnabled}}
security     : {{.SecurityOptions}}"

docker network inspect bridge \
  --format 'icc          : {{index .Options "com.docker.network.bridge.enable_icc"}}'

docker run -d --name logchk alpine sleep 10 > /dev/null
docker inspect logchk --format 'log          : {{.HostConfig.LogConfig.Config}}'
docker rm -f logchk > /dev/null

docker run --rm alpine grep NoNewPrivs /proc/self/status
```
```
live-restore : true
security     : [name=apparmor name=seccomp,profile=builtin name=cgroupns name=no-new-privileges]
icc          : false
log          : map[max-file:3 max-size:10m]
NoNewPrivs:	1
```

---

## 접속 방법

비밀번호 인증은 차단돼 있다. 배포한 키가 유일한 접속 수단이다.

### 기본 접속
```bash
ssh groom@10.10.10.150
```

### 별칭 등록 — `~/.ssh/config`
```
Host ub24
    HostName       10.10.10.150
    User           groom
    IdentityFile   ~/.ssh/id_rsa
    IdentitiesOnly yes
```
```bash
ssh ub24
```
`IdentitiesOnly yes` 는 지정한 키만 제시한다. 없으면 에이전트의 모든 키를 시도하다
`MaxAuthTries` 초과로 거부될 수 있다.

### 원격 명령 실행
```bash
ssh groom@10.10.10.150 'docker ps'
ssh groom@10.10.10.150 'docker run --rm hello-world'
```
`docker` 는 sudo 가 필요 없다 (5단계 그룹 부여 기준).

### sudo 가 필요한 명령 — `-t` 필수
```bash
ssh -t groom@10.10.10.150 'sudo systemctl status docker'
```
`-t` 없이 실행하면 tty 가 없어 sudo 비밀번호 프롬프트를 받지 못하고 실패한다.

### 파일 전송
```bash
scp ./파일 groom@10.10.10.150:~/
rsync -av ./디렉터리/ groom@10.10.10.150:~/디렉터리/
```

### 포트 포워딩 — 컨테이너 접근
```bash
ssh -L 8080:localhost:8080 groom@10.10.10.150
```
컨테이너를 `-p 8080:80` 으로 띄운 뒤 Mac 에서 `http://localhost:8080` 으로 접근한다.
게스트 포트를 네트워크에 노출하지 않는다.

### 연결 진단
```bash
ping -c 2 10.10.10.150
ssh -o BatchMode=yes groom@10.10.10.150 true && echo OK
ssh -v groom@10.10.10.150 true 2>&1 | grep "Authentications that can continue"
```
```
64 bytes from 10.10.10.150: icmp_seq=0 ttl=64 time=0.505 ms
OK
debug1: Authentications that can continue: publickey
```

실패 시 판별 절차는 [network-troubleshooting.md](network-troubleshooting.md) 참조.
송신측/수신측 구분, TCP 계층, SSH 인증 계층을 순서대로 좁힌다.
