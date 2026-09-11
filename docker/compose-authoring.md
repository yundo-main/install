# Compose 파일 저작 표준

> **역할: 주제 문서.** 설치가 아니라 **compose 파일을 작성하는 기준**이다.
> 플러그인 설치는 [01-compose.md](01-compose.md), 데몬 설정은 [00-docker-ce.md](00-docker-ce.md) 6절.
> 다중 노드는 [02-swarm-cluster.md](02-swarm-cluster.md) — 아래 전제(네트워크 격리, 루프백 바인딩)가 성립하지 않는다.

전제: `docker-compose-plugin` 설치 완료(v5.5.0), `/etc/docker/daemon.json` 에
`no-new-privileges`, `icc=false`, `live-restore`, 로그 제한이 적용된 상태.

---

## 데몬 설정이 compose 에 미치는 영향

플랫폼 설정을 모르면 compose 에서 중복 통제하거나, 반대로 통제 공백이 생긴다.

| 데몬 설정 | compose 에서의 실제 효과 |
|---|---|
| `icc: false` | **적용되지 않는다.** compose 는 프로젝트마다 사용자 정의 네트워크(`<project>_default`)를 만든다. `icc` 는 기본 bridge(`docker0`)에만 적용되므로 같은 프로젝트의 컨테이너는 서로 통신한다. 격리는 compose 측 네트워크 분리로 직접 설계해야 한다. |
| `no-new-privileges: true` | 전역 적용. setuid 바이너리(`ping`, `sudo`, `passwd`)에 의존하는 이미지가 실패한다. |
| `live-restore: true` | 데몬 재시작 시 컨테이너 유지. `docker compose` 조작에는 영향 없다. Swarm 모드와는 함께 쓸 수 없다. |
| `log-opts 10m x 3` | 서비스별 `logging` 으로 덮어쓸 수 있다. 명시하지 않으면 데몬 기본값이 적용된다. |

`icc=false` 가 compose 에 적용되지 않는다는 점이 가장 흔한 오해다.
**컨테이너 간 통신 통제는 데몬이 아니라 compose 파일의 책임이다.**

---

## 파일 배치

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

---

## 서비스 정의 표준

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
      APP_ENV: production        # 비밀값을 여기에 두지 않는다 (아래 「시크릿」)
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

### 각 통제의 근거

| 키 | 근거 |
|---|---|
| `image` digest 고정 | 태그는 가변이다. 동일 태그가 다른 이미지를 가리키면 재현 불가하며, 공급망 변조 탐지 지점이 사라진다 |
| `user` | 이미지가 uid 0 으로 실행하도록 만들어졌다는 전제를 제거한다. 볼륨 소유권을 미리 맞춰야 한다 |
| `read_only` + `tmpfs` | 침해 후 지속성(persistence) 확보를 어렵게 한다. 쓰기 경로를 명시적으로 열어야 한다 |
| `cap_drop: [ALL]` | 기본 capability 셋은 필요 이상이다. `NET_BIND_SERVICE` 등이 필요하면 `cap_add` 로 개별 추가한다 |
| `pids_limit` | fork 폭탄으로 호스트 PID 고갈을 막는다 |
| `deploy.resources.limits` | compose v2 이상은 swarm 없이도 이 값을 적용한다 |
| `networks` 분리 | `backend` 를 `internal: true` 로 두면 DB 컨테이너의 외부 송신 경로가 없다. 데이터 반출 경로를 좁힌다 |
| `127.0.0.1` 바인딩 | 아래 「포트 공개」 |
| `healthcheck` + `depends_on.condition` | 기동 순서만 맞추는 `depends_on` 은 준비 상태를 보장하지 않는다 |

---

## 포트 공개

**기본값은 `127.0.0.1` 바인딩이다.**

```yaml
ports: ["127.0.0.1:8080:8080"]   # 루프백만
# ports: ["8080:8080"]           # 금지 — 0.0.0.0 바인딩
```

Docker 는 자체 iptables 규칙을 `DOCKER` 체인에 삽입한다. 이 규칙은 `ufw` 의 INPUT
체인 정책보다 먼저 평가되므로, **`ufw deny` 상태에서도 `0.0.0.0` 으로 공개한 포트는
LAN 에 노출된다.** 방화벽으로 막았다고 가정하면 안 된다.

Mac 에서의 접근은 SSH 포트 포워딩을 쓴다 ([../ssh-access/02-ssh-client.md](../ssh-access/02-ssh-client.md) 접속 방법).

```bash
ssh -L 8080:localhost:8080 groom@10.10.10.150
```

---

## 시크릿

**`environment` 에 비밀값을 두지 않는다.** 환경변수는 `docker inspect`,
`/proc/<pid>/environ`, 컨테이너 로그, 오류 리포트로 유출된다.

`secrets:` 는 `/run/secrets/<name>` 에 tmpfs 로 마운트된다. 많은 이미지가 `*_FILE`
규약을 지원하므로 파일 경로를 넘긴다.

```yaml
environment:
  POSTGRES_PASSWORD_FILE: /run/secrets/db_password
```

```bash
chmod 0600 ./secrets/*; ls -l ./secrets/
```

compose 의 file-based secret 은 **호스트 파일이 평문**이다. 암호화 저장이 필요하면
외부 시크릿 관리자에서 주입하고, 이 트리에 커밋하지 않는다(`.gitignore`).

---

## 금지 항목

| 항목 | 이유 |
|---|---|
| `/var/run/docker.sock` 마운트 | 데몬 소켓은 root 등가다. 해당 컨테이너 침해 = 호스트 침해 |
| `privileged: true` | 모든 capability 부여 + 장치 접근. 격리가 사라진다 |
| `network_mode: host` | 네트워크 네임스페이스 격리 해제. 포트 바인딩 통제가 무력화된다 |
| `pid: host`, `ipc: host` | 호스트 프로세스·IPC 네임스페이스 노출 |
| `:latest` 태그 | 재현 불가 |
| 볼륨 rw 기본 | 읽기만 필요하면 `:ro` 를 붙인다 |

---

## 검증

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

---

## 잔여 위험

- `internal: true` 는 컨테이너의 **외부 송신**만 막는다. 같은 네트워크에 속한
  컨테이너 간 통신은 그대로 허용된다. 서비스 간 격리는 네트워크 분리로 설계한다.
- `read_only: true` 는 마운트한 볼륨에는 적용되지 않는다. 볼륨은 별도로 `:ro` 를 건다.
- compose 의 file-based secret 은 호스트에 평문으로 존재한다. 디스크 암호화와
  파일 권한이 유일한 통제다.
- digest 고정은 재현성을 보장하지만 보안 패치를 자동으로 받지 못한다.
  갱신 주기와 담당을 별도로 정한다.
- 이 문서는 단일 호스트 compose 기준이다. 다중 노드로 확장하면 네트워크 격리
  전제(`internal`, 루프백 바인딩)가 성립하지 않는다 → [02-swarm-cluster.md](02-swarm-cluster.md).
- 본 예시는 로컬에서 `docker compose config` 로 검증하지 않았다. 적용 전 대상
  호스트에서 위 「검증」 절차를 수행한다.
