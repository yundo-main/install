# 실행 절차

> **역할: 운영 매뉴얼.** 무엇을 어떤 순서로 실행하고 어떤 표준으로 구성하는지,
> 어떤 위험을 수용하는지 다룬다. 1~3 단계는 단일 노드 Docker, 4~8 단계는 Swarm 클러스터다.
> 절차의 근거와 기대 출력은 [plan.md](plan.md), 디렉터리 구성은 [README.md](README.md) 에 있다.

## 실행 순서

### 1. 클라이언트 — SSH 키 인증

게스트 콘솔에서 호스트 키 지문을 먼저 확인한다.

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Mac 에서 그 값을 넘겨 실행한다.

```bash
./01-ssh-setup.sh --expect-fpr SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
```

비밀번호 인증 차단은 키 인증이 **검증된 뒤** 별도 실행으로 적용한다.

```bash
./01-ssh-setup.sh --disable-password
```

`--expect-fpr` 를 생략하면 지문을 출력하고 대화형 확인을 요구한다.
`--yes` 는 `--expect-fpr` 없이는 동작하지 않는다 — 무검증 TOFU 를 허용하지 않는다.

### 2. 서버 — Docker CE

```bash
scp 02-install.sh 03-compose.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/02-install.sh'
```

`sudo` 비밀번호 프롬프트 때문에 `-t` 가 필요하다.

### 3. 서버 — Compose 플러그인 (필요한 경우)

`02-install.sh` 는 Docker CE 만 설치한다. Compose 는 별도로 실행한다.
Compose V2 는 독립 바이너리가 아니라 **Docker CLI 플러그인**이므로
`docker-compose-plugin` 패키지로 설치한다.

```bash
ssh -t groom@10.10.10.150 'bash ~/03-compose.sh'
```

설치 상태는 다음으로 확인한다.

```bash
docker compose version
dpkg -l docker-compose-plugin | tail -1
ls -l /usr/libexec/docker/cli-plugins/docker-compose
```

기대 출력

```
Docker Compose version v5.5.0
ii  docker-compose-plugin 5.5.0-1~ubuntu.24.04~noble arm64  Docker Compose (V2) plugin for the Docker CLI.
-rwxr-xr-x 1 root root 46470638  8월 17 21:04 /usr/libexec/docker/cli-plugins/docker-compose
```

`03-compose.sh` 는 서명된 저장소 설정(`signed-by=`)이 구성돼 있는지 먼저 확인하고,
설치 후 바이너리가 패키지 소유인지(`dpkg -S`)까지 검증한다.
수동으로 하려면 다음과 같다.

```bash
sudo apt-get update && sudo apt-get install -y docker-compose-plugin
```

**배제한 대안**: GitHub 릴리스 바이너리를 내려받아 `/usr/local/bin` 에 두는 방식
(`curl -L .../docker-compose -o ... && chmod +x`)은 쓰지 않는다.
APT 의 서명 검증을 우회하고, 패키지 관리자가 추적하지 못해 갱신·제거·무결성
확인 경로가 사라진다. plan.md 2-2 에서 GPG 지문을 대조한 이유가 무효화된다.

**레거시 `docker-compose`(V1)**: Python 구현의 독립 바이너리로, 2023년 지원 종료됐다.
설치돼 있으면 제거한다. 명령은 하이픈 없는 `docker compose` 를 쓴다.

구성 표준은 아래 「Compose 구성 표준」 절을 따른다.

### 4. 워커 노드 신원 분리 (`.151`, `.152`)

워커가 매니저 VM 의 복제본이면 SSH 호스트 키·`machine-id` 를 승계한다. 세 노드의
호스트 키 지문이 같으면 `known_hosts` 가 노드를 구별하지 못한다 (plan.md 7-4).

```bash
scp 04-node-prepare.sh groom@10.10.10.151:~/
ssh -t groom@10.10.10.151 'bash ~/04-node-prepare.sh --hostname worker-01'
```

실행 후 지문이 바뀐다. 출력된 신규 지문으로 대조한 뒤 `known_hosts` 를 갱신한다.

```bash
ssh-keygen -R 10.10.10.151
ssh-keyscan -t ed25519 10.10.10.151 | ssh-keygen -lf -    # 신규 지문과 대조
ssh-keyscan -t ed25519 10.10.10.151 >> ~/.ssh/known_hosts
```

`.152` 는 `--hostname worker-02` 로 동일하게 반복한다.
복제본이 아닌 신규 설치 노드에는 필요 없다.

### 5. 매니저 초기화 (`.150`)

```bash
scp 05-swarm-init.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/05-swarm-init.sh --advertise-addr 10.10.10.150'
```

`daemon.json` 에서 `live-restore` 를 제거하고 데몬을 재시작한다.
기존 파일은 타임스탬프 백업된다. `sudo` 프롬프트 때문에 `-t` 가 필요하다.

토큰은 매니저의 `~/.swarm/` 에 `0600` 으로 저장된다. **화면에 출력하지 않는다.**

### 6. 토큰 전달

암호화 경로로만 옮긴다. 워커 토큰만 쓴다 — 매니저 토큰은 클러스터 완전 제어권이다.

```bash
ssh groom@10.10.10.150 'cat ~/.swarm/worker.token' > /tmp/worker.token
chmod 0600 /tmp/worker.token
scp /tmp/worker.token groom@10.10.10.151:~/
scp /tmp/worker.token groom@10.10.10.152:~/
shred -u /tmp/worker.token 2>/dev/null || rm -f /tmp/worker.token
```

### 7. 워커 가입 (`.151`, `.152`)

```bash
scp 06-swarm-join.sh groom@10.10.10.151:~/
ssh -t groom@10.10.10.151 \
  'bash ~/06-swarm-join.sh --manager 10.10.10.150 --token-file ~/worker.token'
```

`.152` 도 동일하게 반복한다.

### 8. 토큰 회전

전 노드 가입이 끝나면 즉시 회전한다. 기존 가입 노드에는 영향이 없다.

```bash
ssh groom@10.10.10.150 'docker swarm join-token --rotate worker'
ssh groom@10.10.10.151 'shred -u ~/worker.token 2>/dev/null || rm -f ~/worker.token'
ssh groom@10.10.10.152 'shred -u ~/worker.token 2>/dev/null || rm -f ~/worker.token'
```

### 재확인

모든 스크립트에 검증 전용 모드가 있다. `sudo` 가 필요 없으므로 비대화형으로 돈다
(호출 계정이 `docker` 그룹 멤버인 경우).

```bash
ssh groom@10.10.10.150 'bash ~/02-install.sh    --verify-only'
ssh groom@10.10.10.150 'bash ~/03-compose.sh    --verify-only'
ssh groom@10.10.10.151 'bash ~/04-node-prepare.sh --verify-only'
ssh groom@10.10.10.150 'bash ~/05-swarm-init.sh --verify-only'
ssh groom@10.10.10.151 'bash ~/06-swarm-join.sh --verify-only'
ssh groom@10.10.10.150 'docker node ls'
```

`docker node ls` 의 `MANAGER STATUS` 가 워커 행에서 비어 있어야 한다.
값이 있으면 매니저 토큰으로 가입한 것이며 권한 분리가 깨진 상태다.

## 주요 옵션

`01-ssh-setup.sh`

| 옵션 | 설명 |
|---|---|
| `--host` / `--user` / `--key` | 대상·계정·배포할 공개키 (기본 `10.10.10.150` / `groom` / `~/.ssh/id_rsa.pub`) |
| `--expect-fpr <SHA256:...>` | 호스트 키 지문 고정. 불일치 시 중단 |
| `--disable-password` | 키 인증 검증 성공 후에만 비밀번호 인증 차단 |

`02-install.sh`

| 옵션 | 설명 |
|---|---|
| (기본) | docker 그룹 미부여. `sudo docker` 로 사용 |
| `--docker-group` | 호출 계정을 docker 그룹에 추가 (**root 등가 권한 부여**) |
| `--skip-daemon-config` | `/etc/docker/daemon.json` 구성 생략 |
| `--force-daemon-config` | 기존 daemon.json 이 다르면 백업 후 덮어쓰기 |
| `--verify-only` | 설치 없이 검증만 수행 |

`03-compose.sh`

| 옵션 | 설명 |
|---|---|
| (기본) | 서명된 저장소 확인 후 `docker-compose-plugin` 설치·검증 |
| `--verify-only` | 설치 없이 검증만 수행 (패키지 출처, 레거시 V1 부재 포함) |

`04-node-prepare.sh`

| 옵션 | 설명 |
|---|---|
| `--hostname <name>` | 이 노드의 호스트명 (**필수**) |
| `--skip-host-keys` | SSH 호스트 키를 재생성하지 않는다 |
| `--skip-machine-id` | `machine-id` 를 재생성하지 않는다 |
| `--reset-docker-id` | Docker `engine-id` 재생성 (데몬 재시작) |
| `--verify-only` | 변경 없이 현재 신원만 출력 |

`05-swarm-init.sh`

| 옵션 | 설명 |
|---|---|
| `--advertise-addr <IP>` | 클러스터에 광고할 주소 (**필수**). 호스트 인터페이스 존재를 검증한다 |
| `--keep-live-restore` | `live-restore` 를 제거하지 않는다. swarm 에서 무시되는 설정이 남는다 |
| `--autolock` | Raft 로그 암호화. 데몬 재시작마다 수동 unlock 이 필요해진다 |
| `--verify-only` | 초기화 없이 검증만 수행 |

`06-swarm-join.sh`

| 옵션 | 설명 |
|---|---|
| `--manager <IP>` | 매니저 주소 (**필수**) |
| `--token-file <경로>` | 토큰 파일 (**필수**). 토큰을 인자로 직접 받지 않는다 |
| `--port <포트>` | 관리 포트 (기본 `2377`) |
| `--verify-only` | 가입 없이 상태만 확인 |

## 설계상 고정한 통제

- **GPG 지문 고정**: `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` 과 대조한 뒤에만
  `/etc/apt/keyrings` 에 배치한다. 불일치 시 중단한다.
- **`signed-by=`**: 키의 서명 권한을 Docker 저장소로만 한정한다. `apt-key add` 는 쓰지 않는다.
- **순서 강제**: 키 인증 검증(`ssh -o PasswordAuthentication=no`)이 성공하지 않으면
  비밀번호 인증을 차단하지 않는다.
- **상태 기반 검증**: 설정 파일이 아니라 `docker info`, `docker network inspect`,
  컨테이너 내 `/proc/self/status` 로 확인한다.
- **최소 권한 기본값**: docker 그룹 부여는 명시적 opt-in 이다.
- **비파괴 기본값**: 기존 `daemon.json` 은 명시적 `--force-daemon-config` 없이 덮어쓰지 않는다.
- **토큰 비출력**: 매니저 스크립트는 토큰을 표준출력에 흘리지 않고 `0600` 파일로만 남긴다.
- **토큰 파일 입력**: 워커 스크립트는 토큰을 인자로 받지 않는다. argv 는
  `/proc/<pid>/cmdline` 으로 노출된다. 파일 권한도 확인한다.
- **권한 분리 검증**: 가입 후 `Swarm.ControlAvailable` 이 `true` 면 실패 처리한다.
  매니저 토큰으로 가입한 워커를 잡아낸다.
- **advertise-addr 강제**: 인터페이스 존재를 확인한 뒤에만 진행한다.
- **비파괴 기본값**: `daemon.json` 은 타임스탬프 백업 후 `live-restore` 키만 제거하고,
  `dockerd --validate` 통과 후에만 데몬을 재시작한다.
- **멱등**: 이미 swarm 에 참여 중이면 초기화·가입을 건너뛰고 검증만 수행한다.

## Compose 구성 표준

[plan.md](plan.md) 6단계 데몬 설정이 적용된 호스트에서 compose 파일을 작성할 때의
표준과 근거다. 전제: `docker-compose-plugin` 설치 완료(v5.5.0), `/etc/docker/daemon.json` 에
`no-new-privileges`, `icc=false`, `live-restore`, 로그 제한이 적용된 상태.

### 데몬 설정이 compose 에 미치는 영향

플랫폼 설정을 모르면 compose 에서 중복 통제하거나, 반대로 통제 공백이 생긴다.

| 데몬 설정 | compose 에서의 실제 효과 |
|---|---|
| `icc: false` | **적용되지 않는다.** compose 는 프로젝트마다 사용자 정의 네트워크(`<project>_default`)를 만든다. `icc` 는 기본 bridge(`docker0`)에만 적용되므로 같은 프로젝트의 컨테이너는 서로 통신한다. 격리는 compose 측 네트워크 분리로 직접 설계해야 한다. |
| `no-new-privileges: true` | 전역 적용. setuid 바이너리(`ping`, `sudo`, `passwd`)에 의존하는 이미지가 실패한다. |
| `live-restore: true` | 데몬 재시작 시 컨테이너 유지. `docker compose` 조작에는 영향 없다. Swarm 모드와는 함께 쓸 수 없다. |
| `log-opts 10m x 3` | 서비스별 `logging` 으로 덮어쓸 수 있다. 명시하지 않으면 데몬 기본값이 적용된다. |

`icc=false` 가 compose 에 적용되지 않는다는 점이 가장 흔한 오해다.
**컨테이너 간 통신 통제는 데몬이 아니라 compose 파일의 책임이다.**

### 파일 배치

```
<project>/
├── compose.yaml          기본 정의 — 커밋 대상
├── compose.override.yaml 로컬 개발용 덮어쓰기 — 커밋 제외
└── .env                  변수 — 커밋 제외, 0600
```

파일명은 `compose.yaml` 을 쓴다(`docker-compose.yml` 은 레거시 명칭).
`version:` 키는 폐기됐다. 쓰지 않는다.

프로젝트명은 디렉터리명에서 유추되므로 `-p` 또는 `name:` 으로 고정한다.
유추에 맡기면 디렉터리 이름이 바뀔 때 별도 프로젝트로 인식돼 기존 컨테이너와
네트워크가 고아가 된다.

### 서비스 정의 표준

```yaml
name: app

services:
  api:
    # 태그가 아니라 digest 로 고정한다. 태그는 가변이므로 재현되지 않는다.
    image: registry.example.com/api:1.4.2@sha256:<digest>

    # 최소 권한
    user: "10001:10001"          # 이미지의 기본 uid 0 을 신뢰하지 않는다
    read_only: true              # 루트 파일시스템 쓰기 차단
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    cap_drop: [ALL]              # 전부 제거 후 필요한 것만 되돌린다
    security_opt:
      - no-new-privileges:true   # 데몬 전역과 중복이나, 호스트 이동 시 대비해 명시
    pids_limit: 128

    # 리소스 상한 — 미설정 시 호스트 전체가 한 컨테이너의 폭주에 노출된다
    deploy:
      resources:
        limits: { cpus: "1.0", memory: 512M }

    networks: [frontend, backend]
    # LAN 노출 금지. 접근은 SSH 포트 포워딩으로 한다.
    ports: ["127.0.0.1:8080:8080"]

    environment:
      APP_ENV: production        # 비밀값을 여기에 두지 않는다 (5절)
    secrets: [db_password]

    healthcheck:
      test: ["CMD", "/usr/bin/curl", "-fsS", "http://localhost:8080/healthz"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 20s

    depends_on:
      db: { condition: service_healthy }

    restart: unless-stopped
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  db:
    image: postgres:16.4@sha256:<digest>
    user: "999:999"
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    networks: [backend]          # frontend 에 붙이지 않는다 — 외부 경로 없음
    volumes:
      - db_data:/var/lib/postgresql/data
    secrets: [db_password]
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 5

networks:
  frontend:
  backend:
    internal: true               # 게이트웨이 없음 — 컨테이너의 외부 송신 차단

volumes:
  db_data:

secrets:
  db_password:
    file: ./secrets/db_password  # 호스트에서 0600, 소유자 확인
```

#### 각 통제의 근거

| 키 | 근거 |
|---|---|
| `image` digest 고정 | 태그는 가변이다. 동일 태그가 다른 이미지를 가리키면 재현 불가하며, 공급망 변조 탐지 지점이 사라진다 |
| `user` | 이미지가 uid 0 으로 실행하도록 만들어졌다는 전제를 제거한다. 볼륨 소유권을 미리 맞춰야 한다 |
| `read_only` + `tmpfs` | 침해 후 지속성(persistence) 확보를 어렵게 한다. 쓰기 경로를 명시적으로 열어야 한다 |
| `cap_drop: [ALL]` | 기본 capability 셋은 필요 이상이다. `NET_BIND_SERVICE` 등이 필요하면 `cap_add` 로 개별 추가한다 |
| `pids_limit` | fork 폭탄으로 호스트 PID 고갈을 막는다 |
| `deploy.resources.limits` | compose v2 이상은 swarm 없이도 이 값을 적용한다 |
| `networks` 분리 | `backend` 를 `internal: true` 로 두면 DB 컨테이너의 외부 송신 경로가 없다. 데이터 반출 경로를 좁힌다 |
| `127.0.0.1` 바인딩 | 아래 4절 |
| `healthcheck` + `depends_on.condition` | 기동 순서만 맞추는 `depends_on` 은 준비 상태를 보장하지 않는다 |

### 포트 공개

**기본값은 `127.0.0.1` 바인딩이다.**

```yaml
ports: ["127.0.0.1:8080:8080"]   # 루프백만
# ports: ["8080:8080"]           # 금지 — 0.0.0.0 바인딩
```

Docker 는 자체 iptables 규칙을 `DOCKER` 체인에 삽입한다.
이 규칙은 `ufw` 의 INPUT 체인 정책보다 먼저 평가되므로,
**`ufw deny` 상태에서도 `0.0.0.0` 으로 공개한 포트는 LAN 에 노출된다.**
방화벽으로 막았다고 가정하면 안 된다.

Mac 에서의 접근은 SSH 포트 포워딩을 쓴다(plan.md 접속 방법 참조).

```bash
ssh -L 8080:localhost:8080 groom@10.10.10.150
```

### 시크릿

**`environment` 에 비밀값을 두지 않는다.** 환경변수는 `docker inspect`,
`/proc/<pid>/environ`, 컨테이너 로그, 오류 리포트로 유출된다.

`secrets:` 는 `/run/secrets/<name>` 에 tmpfs 로 마운트된다.
많은 이미지가 `*_FILE` 규약을 지원하므로 파일 경로를 넘긴다.

```yaml
environment:
  POSTGRES_PASSWORD_FILE: /run/secrets/db_password
```

호스트 측 시크릿 파일 권한을 확인한다.

```bash
chmod 0600 ./secrets/*; ls -l ./secrets/
```

compose 의 file-based secret 은 **호스트 파일이 평문**이다. 암호화 저장이 필요하면
외부 시크릿 관리자에서 주입하고, 이 트리에 커밋하지 않는다(`.gitignore`).

### 금지 항목

| 항목 | 이유 |
|---|---|
| `/var/run/docker.sock` 마운트 | 데몬 소켓은 root 등가다. 해당 컨테이너 침해 = 호스트 침해 |
| `privileged: true` | 모든 capability 부여 + 장치 접근. 격리가 사라진다 |
| `network_mode: host` | 네트워크 네임스페이스 격리 해제. 포트 바인딩 통제가 무력화된다 |
| `pid: host`, `ipc: host` | 호스트 프로세스·IPC 네임스페이스 노출 |
| `:latest` 태그 | 재현 불가 |
| 볼륨 rw 기본 | 읽기만 필요하면 `:ro` 를 붙인다 |

### 검증

배포 전 — 파일이 아니라 **해석된 결과**를 확인한다.

```bash
docker compose config                      # 변수 치환·병합 결과 확인
docker compose config --images             # digest 고정 여부 확인
```

기동 후 — 실제 컨테이너 상태로 확인한다.

```bash
docker compose ps                          # 상태와 health

docker inspect app-api-1 --format \
  'readonly : {{.HostConfig.ReadonlyRootfs}}
capdrop  : {{.HostConfig.CapDrop}}
secopt   : {{.HostConfig.SecurityOpt}}
user     : {{.Config.User}}
pids     : {{.HostConfig.PidsLimit}}'

# 포트가 루프백에만 바인딩됐는지 — 호스트에서 확인
ss -ltnp | grep 8080

# internal 네트워크의 송신 차단 확인 (실패해야 정상)
docker compose exec db sh -c 'wget -qO- -T3 https://example.com' || echo "egress blocked"
```

기대 출력

```
readonly : true
capdrop  : [ALL]
secopt   : [no-new-privileges:true]
user     : 10001:10001
pids     : 128
LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*
egress blocked
```

## 잔여 위험

### 설치·데몬

- `icc=false` 는 기본 bridge 네트워크에만 적용된다. 사용자 정의 네트워크의
  컨테이너 간 통신은 통제되지 않는다.
- `no-new-privileges` 는 컨테이너 내 setuid 바이너리를 무력화한다. 이에 의존하는
  이미지는 실패한다.
- 방화벽(ufw/nftables)은 구성하지 않는다. Docker 는 자체 iptables 규칙을 삽입하므로
  `-p` 포트 공개 범위를 별도로 통제해야 한다.
- 스크립트는 패키지 버전을 고정하지 않는다. 재현 가능한 빌드가 필요하면
  `apt-get install docker-ce=<version>` 으로 핀을 건다.

### Compose 구성

- `internal: true` 는 컨테이너의 **외부 송신**만 막는다. 같은 네트워크에 속한
  컨테이너 간 통신은 그대로 허용된다. 서비스 간 격리는 네트워크 분리로 설계한다.
- `read_only: true` 는 마운트한 볼륨에는 적용되지 않는다. 볼륨은 별도로 `:ro` 를 건다.
- compose 의 file-based secret 은 호스트에 평문으로 존재한다. 디스크 암호화와
  파일 권한이 유일한 통제다.
- digest 고정은 재현성을 보장하지만 보안 패치를 자동으로 받지 못한다.
  갱신 주기와 담당을 별도로 정한다.
- 이 문서는 단일 호스트 compose 기준이다. 다중 노드로 확장하면 네트워크 격리
  전제(`internal`, 루프백 바인딩)가 성립하지 않는다.
- 본 예시는 로컬에서 `docker compose config` 로 검증하지 않았다. 적용 전
  대상 호스트에서 7절 절차를 수행한다.

### Swarm 클러스터

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
