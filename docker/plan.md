# Ubuntu 24.04 Docker 설치 및 Swarm 클러스터 구성

> **역할: 기준 문서(source of truth).** 절차의 근거와 기대 출력을 보유한다.
> 스크립트가 대조하는 상수(GPG 지문, 호스트 키 지문)와 검증 기준의 출처가 이 문서다.
> 실행 도구가 아니다 — 실행은 [USAGE.md](USAGE.md) 를 따른다.
> 배제된 대안(`apt-key add`)과 그 이유도 여기에만 기록한다.

Mac(SSH 클라이언트)에서 Ubuntu 24.04 VM 에 SSH 키 인증을 구성하고 Docker 공식
저장소로 Docker CE 를 설치한 뒤(0~6단계), 3노드 Swarm 클러스터로 확장하는(7~11단계) 절차.

| 항목 | 값 |
|---|---|
| manager | `10.10.10.150` / Ubuntu 24.04.4 LTS / arm64 |
| worker-01 | `10.10.10.151` (manager 복제본) |
| worker-02 | `10.10.10.152` (manager 복제본) |
| 계정 | `groom` (sudo 그룹) |
| 클라이언트 | `10.10.10.1` (macOS, VMware Fusion vmnet3) |
| 결과 | Docker 29.7.2 / containerd v2.3.4 / runc 1.4.3 (compose v5.5.0 은 3단계 별도) |

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
응답이 없으면 [../network-troubleshooting.md](../network-troubleshooting.md) 참조.

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
sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc
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
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin
```

Compose 플러그인(`docker-compose-plugin`)은 이 절차에서 분리했다.
Docker CE 만 필요한 노드에 Compose 를 강제하지 않기 위함이며, 클러스터에서는
`docker service` 를 쓴다. 아래 검증의 `docker compose version` 은 Compose 설치
후에만 해당한다.

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

> **Swarm 으로 확장하면 `live-restore` 를 제거해야 한다.** 두 설정은 공존할 수 없다.
> 데몬이 직접 거부한다 — `--live-restore daemon configuration is incompatible with
> swarm mode`. 근거와 절차는 7-1 절에 있다.

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

## 7. Swarm 선행 조건과 설계 결정

### 7-1. `live-restore` 제거

기존 `/etc/docker/daemon.json` 의 `"live-restore": true` 는 **swarm 과 공존할 수 없다.**

두 모델은 가용성을 확보하는 방식이 다르다.

| | live-restore (단일 노드) | swarm (멀티 노드) |
|---|---|---|
| 가용성 주체 | 데몬 부재 중 컨테이너 자체 생존 | 매니저의 상태 조정(reconcile) |
| 데몬 재시작 시 | 컨테이너 유지, 감독 없음 | 태스크 재배치 |
| 충돌 | swarm init 이 거부된다 | — |

효력 없는 설정에 그치지 않는다. **데몬이 swarm 초기화 자체를 거부한다.**

```
Error response from daemon: --live-restore daemon configuration is incompatible with swarm mode
```

`daemon.json` 에서 해당 키만 제거하고, `no-new-privileges`·로그 제한·`icc` 는 유지한다.

```bash
sudo dockerd --validate --config-file /etc/docker/daemon.json
```
```
configuration OK
```

`no-new-privileges`, 로그 제한은 그대로 유지한다. swarm 과 무관하게 유효하다.

### 7-2. `icc: false` 의 적용 범위

overlay 네트워크는 사용자 정의 네트워크다. `icc` 는 기본 bridge(`docker0`)에만
적용되므로 **swarm 서비스 간 통신에는 아무 영향이 없다.**
서비스 격리는 overlay 네트워크 분리로 설계해야 한다(11절).

### 7-3. 매니저 수 — 1대의 잔여 위험

이 구성은 manager 1 + worker 2 다. Raft 정족수(quorum)는 `floor(N/2)+1` 이므로
매니저 1대는 정족수 1이다.

**매니저가 죽으면 클러스터 관리가 불가능해진다.** 실행 중인 태스크는 계속 돌지만
서비스 생성·갱신·재배치·노드 가입이 전부 막히고, 매니저 복구 없이는 되돌릴 수 없다.

프로덕션은 매니저 3대(정족수 2, 1대 장애 허용)가 최소 구성이다.
이 계획은 학습·검증 목적으로 1대를 수용한다. 그 대가를 명시적으로 기록한다.

---

### 7-4. 복제 노드의 신원 분리

워커를 매니저 VM 복제로 만들면 **SSH 호스트 키·`machine-id`·Docker `engine-id` 가
승계된다.** 실측에서 세 노드의 호스트 키 지문이 모두 동일했다.

```
10.10.10.150    SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
10.10.10.151    SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
10.10.10.152    SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
```

**호스트 키로 노드를 구별할 수 없다.** `known_hosts` 검증이 "이 서버가 맞다"를
보장하지 못한다. 실제로 ARP 캐시가 오래된 항목으로 트래픽을 다른 노드에 보냈는데도
호스트 키 검증은 통과했다. 매니저에 접속했다고 믿고 워커를 조작하는 사고를 막을
수단이 없다는 뜻이다.

클러스터 구성 전에 정리한다.

```bash
sudo ssh-keygen -A                    # 호스트 키 재생성 (rm 후)
sudo systemd-machine-id-setup         # machine-id 재생성
sudo hostnamectl set-hostname worker-01
```

재생성 후 지문이 바뀌므로 클라이언트의 `known_hosts` 를 갱신한다.
대조 없이 등록하지 않는다.

---

## 8. 네트워크 요건

매니저·워커 간 아래 포트가 열려 있어야 한다.

| 포트 | 프로토콜 | 용도 | 대상 |
|---|---|---|---|
| 2377 | tcp | 클러스터 관리 평면 | 매니저만 수신 |
| 7946 | tcp + udp | 노드 탐색(gossip) | 전 노드 |
| 4789 | udp | overlay 데이터 평면(VXLAN) | 전 노드 |

`--opt encrypted` overlay 를 쓰면 IP 프로토콜 50(ESP)도 필요하다.

**2377 은 클러스터 제어 평면이다.** 이 포트에 도달 가능한 자가 유효한 매니저 토큰을
가지면 클러스터 매니저가 된다. 신뢰 네트워크(vmnet3) 밖으로 노출하지 않는다.

**검증** — 매니저에서:
```bash
ss -lntup | grep -E '2377|7946|4789'
```
```
tcp   LISTEN 0  4096  *:2377   *:*
tcp   LISTEN 0  4096  *:7946   *:*
udp   UNCONN 0  0     *:7946   *:*
udp   UNCONN 0  0     *:4789   *:*
```

---

---

## 9. 매니저 초기화

```bash
docker swarm init --advertise-addr 10.10.10.150
```
```
Swarm initialized: current node (xxxxxxxx) is now a manager.
```

`--advertise-addr` 는 명시한다. 인터페이스가 둘 이상이면 Docker 가 주소를 고르지
못해 실패하거나, 의도하지 않은 인터페이스로 클러스터를 광고한다.

**검증**
```bash
docker info --format 'swarm   : {{.Swarm.LocalNodeState}}
manager : {{.Swarm.ControlAvailable}}
nodes   : {{.Swarm.Nodes}}'
docker node ls
```
```
swarm   : active
manager : true
nodes   : 1
```

### 9-1. 가입 토큰

토큰은 **자격 증명**이다. 두 종류가 있고 권한이 다르다.

```bash
docker swarm join-token worker    # 워커 가입용
docker swarm join-token manager   # 매니저 가입용 — 클러스터 완전 제어권
```

| 통제 | 내용 |
|---|---|
| 저장 | 파일로 저장 시 `0600`. 저장소·채팅·이슈에 남기지 않는다 |
| 전달 | SSH 등 암호화 경로로만. 평문 전달 금지 |
| 노출 | `docker swarm join --token <값>` 은 argv 에 남아 `/proc/<pid>/cmdline` 으로 노출된다. 다중 사용자 노드에서는 이 창을 위험으로 간주한다 |
| 회전 | 가입 완료 후 회전한다. 유출 시에도 즉시 회전 |

```bash
docker swarm join-token --rotate worker
```

회전은 기존 가입 노드에 영향을 주지 않는다. 신규 가입만 무효화한다.

### 9-2. Raft 로그 암호화 — autolock

매니저의 Raft 로그에는 서비스 시크릿과 TLS 키가 저장된다. 기본 상태에서는
**디스크에 평문**이다. 매니저 디스크 이미지를 획득하면 클러스터 시크릿이 노출된다.

```bash
docker swarm update --autolock=true
```

활성화하면 데몬 재시작마다 unlock 키를 입력해야 한다.

| | autolock 켬 | 끔 |
|---|---|---|
| 디스크 탈취 시 | Raft 로그 암호화됨 | 시크릿 평문 노출 |
| 데몬 재시작 | **수동 unlock 필요** — 무인 재부팅 불가 | 자동 복구 |

무인 운영과 상충한다. VM 스냅샷이 외부로 나갈 수 있는 환경이면 켠다.
이 계획에서는 **기본값(끔)** 으로 두고 위험을 수용한다 — 스냅샷 반출 경로가 없는
로컬 VM 이라는 전제다. 전제가 깨지면 재검토한다.

---

---

## 10. 워커 가입

각 워커에서 실행한다. Docker CE 설치가 선행이다.

```bash
docker swarm join --token <worker-token> 10.10.10.150:2377
```
```
This node joined a swarm as a worker.
```

**검증** — 매니저에서:
```bash
docker node ls
```
```
ID          HOSTNAME    STATUS   AVAILABILITY   MANAGER STATUS
xxxx *      ub24        Ready    Active         Leader
yyyy        worker-01   Ready    Active
zzzz        worker-02   Ready    Active
```

`MANAGER STATUS` 가 비어 있어야 워커다. 값이 있으면 매니저 토큰으로 가입한 것이며,
해당 노드가 클러스터 제어권을 가진다.

---

---

## 11. 서비스 배포 — 격리 설계

overlay 네트워크를 목적별로 분리한다. 단일 overlay 에 전 서비스를 올리면
클러스터 전체가 하나의 평면이 된다.

```bash
docker network create --driver overlay --opt encrypted backend
```

`--opt encrypted` 는 노드 간 VXLAN 트래픽을 IPsec 으로 암호화한다.
기본값은 **비암호화**다. 노드 간 네트워크를 신뢰할 수 없으면 반드시 지정한다.
성능 비용이 있으므로 트래픽 특성에 따라 판단한다.

```bash
docker service create --name web --replicas 3 \
  --network backend \
  --publish published=8080,target=80,mode=ingress \
  --no-healthcheck=false \
  nginx:1.27@sha256:<digest>
```

**검증**
```bash
docker service ls
docker service ps web
```

---

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

실패 시 판별 절차는 [../network-troubleshooting.md](../network-troubleshooting.md) 참조.
송신측/수신측 구분, TCP 계층, SSH 인증 계층을 순서대로 좁힌다.

---

## 배제한 대안

| 대안 | 배제 이유 |
|---|---|
| `docker swarm init` without `--advertise-addr` | 다중 인터페이스에서 주소 선택 실패 또는 의도치 않은 인터페이스 광고 |
| 매니저 토큰으로 워커 가입 | 워커에 클러스터 완전 제어권 부여. 권한 분리가 무의미해진다 |
| 비암호화 overlay 를 기본으로 | 노드 간 평문 통신. 네트워크 신뢰 전제가 필요하다 |
| `live-restore` 유지 | swarm 에서 무시된다. 남겨두면 오해를 부른다 |
| Kubernetes 로 대체 | 별도 절차다. [../k8s/plan.md](../k8s/plan.md) 참조 |

---

---

## 잔여 위험

- **매니저 단일 장애점**: 매니저 1대. 장애 시 클러스터 관리 불가. 태스크는 유지된다.
- **autolock 미적용**: Raft 로그의 시크릿이 디스크에 평문이다. 스냅샷 반출이 통제
  범위 밖으로 나가면 즉시 재검토 대상이다.
- **토큰 argv 노출**: 가입 명령의 토큰이 `/proc` 에 노출된다. 가입 후 회전이 유일한 완화다.
- **방화벽 미구성**: 2377/7946/4789 를 신뢰 네트워크로 제한하는 통제가 없다.
  vmnet3 격리에 의존한다.
- **`icc: false` 무관**: overlay 트래픽에는 적용되지 않는다. 서비스 격리는 네트워크
  분리로만 확보된다.
