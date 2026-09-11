# 02 · Docker Swarm 클러스터 구성

**요약.** manager 1 + worker 2 를 Swarm 으로 묶는 수동 절차. 복제 노드 신원 분리
→ `live-restore` 제거 → `docker swarm init` → 워커 토큰 scp 전달·가입 → 토큰 회전.
스크립트 없음, 전제는 SSH 접속 + Docker CE·데몬 설정 완료.

> **역할: 단계 문서 (02).** 근거·수동 절차·기대 출력·잔여 위험을 한곳에 둔다.
> SSH 접속은 [../ssh-access/](../ssh-access/), Docker CE·데몬 설정은
> [00-docker-ce.md](00-docker-ce.md), Compose 는 [01-compose.md](01-compose.md).
> 이 절차는 스크립트화하지 않았다 — 이유는 [README.md](README.md) 참조.

manager 1 + worker 2 구성. `10.10.10.150` / `.151` / `.152`.

전제: 전 노드에 SSH 접속([../ssh-access/](../ssh-access/)) + Docker CE·데몬 설정
([00-docker-ce.md](00-docker-ce.md)) 완료.

| 절 | 내용 |
|---|---|
| 1 | 선행 조건과 설계 결정 — `live-restore` 제거, 매니저 1대 위험, 복제본 신원 |
| 2 | 네트워크 요건 — 2377 / 7946 / 4789 |
| 3 | 실행 절차 — 신원 분리 → 매니저 초기화 → 토큰 전달 → 가입 → 회전 |
| 4 | 토큰과 시크릿 관리 — 토큰 두 종류, autolock |
| 5 | 서비스 배포 — 격리 설계 |
| 6 | 수행자가 지켜야 할 규칙 |
| 7 | 배제한 대안 |
| 8 | 잔여 위험 |

---

## 1. 선행 조건과 설계 결정

### 1-1. `live-restore` 제거

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

### 1-2. `icc: false` 의 적용 범위

overlay 네트워크는 사용자 정의 네트워크다. `icc` 는 기본 bridge(`docker0`)에만
적용되므로 **swarm 서비스 간 통신에는 아무 영향이 없다.**
서비스 격리는 overlay 네트워크 분리로 설계해야 한다(5절).

### 1-3. 매니저 수 — 1대의 잔여 위험

이 구성은 manager 1 + worker 2 다. Raft 정족수(quorum)는 `floor(N/2)+1` 이므로
매니저 1대는 정족수 1이다.

**매니저가 죽으면 클러스터 관리가 불가능해진다.** 실행 중인 태스크는 계속 돌지만
서비스 생성·갱신·재배치·노드 가입이 전부 막히고, 매니저 복구 없이는 되돌릴 수 없다.

프로덕션은 매니저 3대(정족수 2, 1대 장애 허용)가 최소 구성이다.
이 계획은 학습·검증 목적으로 1대를 수용한다. 그 대가를 명시적으로 기록한다.

---

### 1-4. 복제 노드의 신원 분리

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

## 2. 네트워크 요건

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

## 3. 실행 절차

전 단계가 `sudo` 비밀번호 또는 지문 육안 대조를 요구한다. 순서를 지킨다 —
신원 분리(3-1)를 먼저 하지 않으면 이후 단계에서 어느 노드를 조작하는지 확정할 수 없다.

### 3-1. 워커 노드 신원 분리 (`.151`, `.152`)

워커가 매니저 VM 의 복제본이면 SSH 호스트 키·`machine-id` 를 승계한다. 세 노드의
호스트 키 지문이 같으면 `known_hosts` 가 노드를 구별하지 못한다. 근거는 1-4 절.

각 워커에서 실행한다. `sudo` 프롬프트 때문에 `-t` 가 필요하다.

```bash
ssh -t groom@10.10.10.151
```
```bash
# 현재 신원 확인 — 매니저와 같으면 분리 대상이다
hostname; cat /etc/machine-id
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# SSH 호스트 키 재생성
sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A
sudo sshd -t && sudo systemctl restart ssh

# machine-id 재생성
sudo rm -f /etc/machine-id && sudo systemd-machine-id-setup
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

# 호스트명
sudo hostnamectl set-hostname worker-01
sudo sed -i 's/^127.0.1.1.*/127.0.1.1\tworker-01/' /etc/hosts

# 신규 지문 확인 — 이 값을 받아 적는다
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

`.152` 는 `worker-02` 로 동일하게 반복한다.
복제본이 아닌 신규 설치 노드에는 필요 없다.

지문이 바뀌었으므로 클라이언트에서 `known_hosts` 를 갱신한다.
**위에서 받아 적은 값과 대조한 뒤에** 등록한다.

```bash
ssh-keygen -R 10.10.10.151
ssh-keyscan -t ed25519 10.10.10.151 | ssh-keygen -lf -    # 게스트 출력과 대조
ssh-keyscan -t ed25519 10.10.10.151 >> ~/.ssh/known_hosts
```

### 3-2. 매니저 초기화 (`.150`)

`live-restore` 와 swarm 은 공존할 수 없다. 데몬이 초기화를 거부하므로 먼저 제거한다.

```bash
ssh -t groom@10.10.10.150
```
```bash
# 백업 후 live-restore 키만 제거. 나머지 설정은 유지한다
sudo cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
sudo tee /etc/docker/daemon.json > /dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "icc": false
}
JSON

# 검증 통과 후에만 재시작한다
sudo dockerd --validate --config-file /etc/docker/daemon.json
sudo systemctl restart docker
docker info --format 'live-restore: {{.LiveRestoreEnabled}}'   # false 여야 한다

# swarm 초기화
docker swarm init --advertise-addr 10.10.10.150
```

`--advertise-addr` 는 생략하지 않는다. 인터페이스가 둘 이상이면 주소 선택에
실패하거나 의도하지 않은 인터페이스로 클러스터를 광고한다.

**검증**
```bash
docker info --format 'swarm: {{.Swarm.LocalNodeState}}  manager: {{.Swarm.ControlAvailable}}'
ss -lntup | grep -E ':2377|:7946'
docker node ls
```

### 3-3. 토큰 전달

토큰은 자격 증명이다. 매니저에서 파일로 저장하고 암호화 경로로만 옮긴다.
**워커 토큰만 쓴다** — 매니저 토큰은 클러스터 완전 제어권이다.

매니저에서:
```bash
install -m 0700 -d ~/.swarm
umask 077
docker swarm join-token -q worker > ~/.swarm/worker.token
chmod 0600 ~/.swarm/worker.token
```

클라이언트에서:
```bash
ssh groom@10.10.10.150 'cat ~/.swarm/worker.token' > /tmp/worker.token
chmod 0600 /tmp/worker.token
scp /tmp/worker.token groom@10.10.10.151:~/
scp /tmp/worker.token groom@10.10.10.152:~/
shred -u /tmp/worker.token 2>/dev/null || rm -f /tmp/worker.token
```

### 3-4. 워커 가입 (`.151`, `.152`)

각 워커에서 실행한다.

```bash
ssh groom@10.10.10.151
```
```bash
# 매니저 관리 포트 도달성 확인 — 닫혀 있으면 가입이 무의미하게 타임아웃된다
nc -z -w 4 10.10.10.150 2377 && echo REACHABLE

docker swarm join --token "$(< ~/worker.token)" 10.10.10.150:2377
```
```
This node joined a swarm as a worker.
```

**검증** — 워커는 제어 평면을 갖지 않아야 한다.
```bash
docker info --format 'swarm: {{.Swarm.LocalNodeState}}  manager: {{.Swarm.ControlAvailable}}'
```
```
swarm: active  manager: false
```

`manager: true` 면 매니저 토큰으로 가입한 것이다. 권한 분리가 깨졌으므로
매니저에서 `docker node demote` 로 정정하거나 재가입한다.

`.152` 도 동일하게 반복한다.

**매니저에서 최종 확인**
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

### 3-5. 토큰 회전

전 노드 가입이 끝나면 즉시 회전한다. 기존 가입 노드에는 영향이 없고 신규 가입만
무효화된다. 가입 명령의 토큰은 `/proc/<pid>/cmdline` 에 노출되므로 회전이 유일한 완화다.

```bash
ssh groom@10.10.10.150 'docker swarm join-token --rotate worker'
ssh groom@10.10.10.151 'shred -u ~/worker.token 2>/dev/null || rm -f ~/worker.token'
ssh groom@10.10.10.152 'shred -u ~/worker.token 2>/dev/null || rm -f ~/worker.token'
```

---

## 4. 토큰과 시크릿 관리

### 4-1. 가입 토큰의 두 종류

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

### 4-2. Raft 로그 암호화 — autolock

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

## 5. 서비스 배포 — 격리 설계

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
  nginx:1.27@sha256:<digest>
```

**검증**
```bash
docker service ls
docker service ps web
```

---

## 6. 수행자가 지켜야 할 규칙

- **토큰 비출력**: 토큰을 터미널에 표시하지 않고 `0600` 파일로만 다룬다.
  `docker swarm join-token -q worker > 파일` 형태를 쓴다.
- **워커 토큰만 사용**: 매니저 토큰은 클러스터 완전 제어권이다. 워커 가입에 쓰지 않는다.
- **권한 분리 확인**: 가입 후 `Swarm.ControlAvailable` 이 `false` 인지 반드시 본다.
  `true` 면 매니저 토큰으로 가입한 것이다.
- **가입 후 토큰 회전**: 가입 명령의 토큰은 `/proc/<pid>/cmdline` 에 노출된다.
- **advertise-addr 명시**: 생략하지 않는다.
- **비파괴 순서**: `daemon.json` 은 백업 후 수정하고, `dockerd --validate` 통과
  후에만 데몬을 재시작한다.
- **지문 대조 후 등록**: 호스트 키 재생성 후 게스트가 출력한 값과 대조한 뒤에만
  `known_hosts` 에 넣는다.

---

## 7. 배제한 대안

| 대안 | 배제 이유 |
|---|---|
| `docker swarm init` without `--advertise-addr` | 다중 인터페이스에서 주소 선택 실패 또는 의도치 않은 인터페이스 광고 |
| 매니저 토큰으로 워커 가입 | 워커에 클러스터 완전 제어권 부여. 권한 분리가 무의미해진다 |
| 비암호화 overlay 를 기본으로 | 노드 간 평문 통신. 네트워크 신뢰 전제가 필요하다 |
| `live-restore` 유지 | swarm 에서 무시된다. 남겨두면 오해를 부른다 |
| Kubernetes 로 대체 | 별도 절차다. [../k8s/plan.md](../k8s/plan.md) 참조 |

---

## 8. 잔여 위험

- **매니저 단일 장애점**: 매니저 1대(정족수 1). 장애 시 서비스 생성·갱신·노드 가입이
  모두 막힌다. 실행 중 태스크는 유지된다. 프로덕션 최소 구성은 매니저 3대다.
- **autolock 미적용(기본)**: Raft 로그의 시크릿·TLS 키가 디스크에 평문이다.
  VM 스냅샷이 통제 밖으로 나가는 환경이면 `--autolock` 을 켠다.
- **토큰 argv 노출**: `docker swarm join` 실행 순간 토큰이 `/proc` 에 노출된다.
  가입 후 회전이 유일한 완화다.
- **방화벽 미구성**: `2377`/`7946`/`4789` 를 신뢰 네트워크로 제한하지 않는다.
  vmnet3 격리에 의존한다. 2377 도달 + 유효 매니저 토큰 = 클러스터 제어권이다.
- **overlay 기본 비암호화**: `--opt encrypted` 를 지정하지 않은 overlay 는 노드 간
  트래픽이 평문이다.
- **`icc: false` 무관**: overlay 트래픽에 적용되지 않는다.
