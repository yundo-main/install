# 00 · Docker CE — 저장소 신뢰 · 설치 · 데몬 설정

**요약.** 대상 호스트에서 실행해 Docker 공식 저장소를 GPG 지문 대조 후 등록하고
Docker CE(engine·cli·containerd·buildx)를 설치한 뒤 `daemon.json`(로그 제한·
`no-new-privileges`·`icc=false`·`live-restore`)을 적용한다. Compose 는
[01-compose.md](01-compose.md).

> **역할: 단계 문서.** 근거·기대 출력·대조 상수·옵션·검증·잔여 위험을 한곳에 둔다.
> 실행 도구는 [`00-docker-ce.sh`](00-docker-ce.sh). Compose 플러그인은
> [01-compose.md](01-compose.md), compose 파일 저작 표준은 [compose-authoring.md](compose-authoring.md).

대상 호스트(Ubuntu 24.04)에서 실행한다. Docker 공식 저장소로 Docker CE 를 설치하고
데몬을 설정한다.

**전제:** SSH 로 이 호스트에 `sudo` 가능한 계정으로 접속돼 있어야 한다 — 접속
구성은 [../ssh-access/](../ssh-access/) (이 디렉터리 소관 아님, 별도 절차).

| 항목 | 값 |
|---|---|
| 결과 | Docker 29.7.2 / containerd v2.3.4 / runc 1.4.3 (compose 는 [01-compose.md](01-compose.md)) |
| GPG 키 지문 (대조 상수) | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` (2017-02-22, rsa4096) |
| keyring | `/etc/apt/keyrings/docker.asc` |
| 저장소 목록 | `/etc/apt/sources.list.d/docker.list` |
| 데몬 설정 | `/etc/docker/daemon.json` |

---

## 실행

이 단계에서는 SSH 가 이미 동작하므로 `scp` 로 옮긴다.

```bash
scp 00-docker-ce.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/00-docker-ce.sh'
```

`sudo` 비밀번호 프롬프트 때문에 `-t` 가 필요하다.

### `wget` 로 노드에서 직접 받기

Mac 을 거치지 않고 노드에서 받아도 된다. `00-docker-ce.sh` 는 자기완결이라 이
파일 하나면 실행된다. **`\| bash` 로 잇지 않는다** — 대상은 root 등가 호스트다.

```bash
# main 이 아니라 커밋 SHA 로 고정한다 — 받는 내용이 확정되고 raw CDN 캐시 지연도 없다
REF=1963e4b8f440c1d42b24ff6d4c807db9fbfb8f94   # 이 값 대신 git log -1 --format=%H 의 최신 SHA 를 쓴다
BASE="https://raw.githubusercontent.com/yundo-main/install/${REF}/docker"

wget -q "${BASE}/00-docker-ce.sh" -O 00-docker-ce.sh    # TLS 검증 기본 — --no-check-certificate 금지

sha256sum 00-docker-ce.sh                                # 별도 채널(로컬 clone)의 기대값과 대조
#   기대값:  git -C <clone> show ${REF}:docker/00-docker-ce.sh | sha256sum

less 00-docker-ce.sh                                     # 무엇을 sudo 로 실행하는지 직접 본다
bash 00-docker-ce.sh
```

private 리포면 `gh api ...` 또는 `wget --header="Authorization: Bearer <token>"`.
토큰은 명령행 인자로 넘기지 않는다 (`/proc/<pid>/cmdline`·history 노출). 다중
파일이 필요하면 커밋 SHA 로 체크아웃한 `git clone` 이 낫다.

### 옵션

| 옵션 | 설명 |
|---|---|
| (기본) | docker 그룹 미부여. `sudo docker` 로 사용 (최소 권한 기본값) |
| `--docker-group` | 호출 계정을 docker 그룹에 추가. **root 등가 권한 부여** — 아래 경고 |
| `--skip-daemon-config` | `/etc/docker/daemon.json` 구성 생략 |
| `--force-daemon-config` | 기존 `daemon.json` 이 다르면 백업 후 덮어쓰기 |
| `--verify-only` | 설치 없이 검증만 수행 (`sudo` 불필요, 비대화형) |

> **경고:** docker 그룹 멤버는 임의 호스트 경로를 컨테이너에 마운트해 uid 0 으로
> 접근할 수 있다. 이 그룹 부여 = 해당 계정에 root 를 주는 것. `sudo docker` 만
> 쓰려면 `--docker-group` 을 지정하지 않는다.

---

## 절차와 근거

### 2-1. 충돌 패키지 제거

배포판 기본 패키지(`docker.io`, `containerd`, `runc`, `podman-docker` 등)가 있으면
제거한다. 공식 저장소 패키지와 공존하면 버전·소켓이 충돌한다.

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

위 지문과 일치할 때만 `/etc/apt/keyrings/docker.asc` (0644, root) 에 배치한다.
불일치 시 중단한다.

### 2-3. 저장소 등록

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

`signed-by=` 는 이 키의 서명 권한을 Docker 저장소로만 한정한다.
**`apt-key add` 는 쓰지 않는다** — 키를 전역 키링에 넣어 모든 저장소를 서명 가능하게
한다. `apt-get update` 에서 `NO_PUBKEY`/`GPG error`/`not signed` 가 나오면 키 등록이
잘못된 것이다.

```bash
apt-cache policy docker-ce | head -5    # 후보 버전이 download.docker.com 출처인지 확인
```

### 3. 패키지 설치

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
```

Compose 플러그인(`docker-compose-plugin`)은 이 단계에서 분리했다 →
[01-compose.md](01-compose.md).

### 6. 데몬 설정 — `/etc/docker/daemon.json`

서비스 검증 전에 적용해 재시작을 1회로 줄인다. 기존 파일이 다르면
`--force-daemon-config` 없이는 덮어쓰지 않고 diff 만 출력한다 (비파괴 기본값).

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true,
  "icc": false
}
```

| 설정 | 효과 |
|---|---|
| `log-opts` | 컨테이너 로그 10MB × 3. 디스크 무한 증가 방지 |
| `live-restore` | 데몬 재시작 시 실행 중 컨테이너 유지. **Swarm 과 공존 불가** → [02-swarm-cluster.md](02-swarm-cluster.md) 1-1 |
| `no-new-privileges` | 컨테이너 내 권한 상승 차단. setuid 바이너리(`ping`, `sudo`)가 동작하지 않는다 |
| `icc` | 기본 bridge 의 컨테이너 간 통신 차단. **사용자 정의 네트워크에는 적용되지 않는다** |

```bash
sudo dockerd --validate --config-file /etc/docker/daemon.json   # configuration OK
sudo systemctl restart docker
```

### 5. 권한 모델 — docker 그룹

`--docker-group` 지정 시에만 `sudo usermod -aG docker $USER`. 새 로그인 세션부터
반영된다. 미지정이 기본이며 `sudo docker` 로 사용한다.

---

## 검증

스크립트가 자동 수행하며 `--verify-only` 로 재실행할 수 있다. 파일이 아니라
데몬·컨테이너의 실제 상태로 확인한다.

```bash
docker --version                # Docker version 29.7.2, build a7dcaa6
containerd --version            # containerd v2.3.4 ...
runc --version | head -1        # runc version 1.4.3
docker buildx version

for u in docker.service docker.socket containerd.service; do
  printf "%-20s enabled=%-9s active=%s\n" $u "$(systemctl is-enabled $u)" "$(systemctl is-active $u)"
done

sudo docker run --rm hello-world          # "Hello from Docker!" — registry pull → containerd → runc 전 경로

docker info --format 'live-restore : {{.LiveRestoreEnabled}}
security     : {{.SecurityOptions}}'
docker network inspect bridge \
  --format 'icc          : {{index .Options "com.docker.network.bridge.enable_icc"}}'
docker run --rm alpine grep NoNewPrivs /proc/self/status
```

기대:
```
docker.service       enabled=enabled   active=active
docker.socket        enabled=enabled   active=active
containerd.service   enabled=enabled   active=active
live-restore : true
security     : [name=apparmor name=seccomp,profile=builtin name=cgroupns name=no-new-privileges]
icc          : false
NoNewPrivs:	1
```

재확인만 필요하면:
```bash
ssh groom@10.10.10.150 'bash ~/00-docker-ce.sh --verify-only'
```

---

## 설계상 고정한 통제

이 단계에 해당하는 항목. 프로젝트 공통 통제는 [controls.md](controls.md).

- **GPG 지문 고정**: `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` 대조 후에만 배치. 불일치 시 중단.
- **`signed-by=`**: 키 서명 권한을 Docker 저장소로만 한정. `apt-key add` 미사용.
- **상태 기반 검증**: 설정 파일이 아니라 `docker info`·`docker network inspect`·`/proc/self/status`.
- **최소 권한 기본값**: docker 그룹 부여는 명시적 opt-in.
- **비파괴 기본값**: 기존 `daemon.json` 은 `--force-daemon-config` 없이 덮어쓰지 않는다.

**배제한 대안** — GitHub 릴리스 바이너리를 `/usr/local/bin` 에 두는 방식
(`curl -L .../docker-compose -o ... && chmod +x`): APT 서명 검증을 우회하고 패키지
관리자가 추적하지 못해 갱신·제거·무결성 확인 경로가 사라진다. 2-2 의 지문 대조가
무효화된다.

---

## 잔여 위험 / 전제

- `icc=false` 는 기본 bridge 네트워크에만 적용된다. 사용자 정의 네트워크의 컨테이너
  간 통신은 통제되지 않는다 — compose 측 네트워크 분리로 설계한다
  ([compose-authoring.md](compose-authoring.md)).
- `no-new-privileges` 는 컨테이너 내 setuid 바이너리를 무력화한다. 이에 의존하는
  이미지는 실패한다.
- Docker 데몬 소켓(`/var/run/docker.sock`)은 root 등가다. 컨테이너에 마운트하지 않는다.
- **방화벽**: 이 스크립트는 ufw/nftables 를 구성하지 않는다. Docker 는 자체 iptables
  규칙을 삽입하므로 `-p` 포트 공개 범위를 별도로 통제한다. [00-ssh-server.md](../ssh-access/00-ssh-server.md)
  의 ufw 는 호스트 인바운드만 다룬다.
- 스크립트는 패키지 버전을 고정하지 않는다. 재현 가능한 빌드가 필요하면
  `apt-get install docker-ce=<version>` 으로 핀을 건다.
