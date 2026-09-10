# 03 · Compose V2 플러그인

> **역할: 단계 문서.** 근거·기대 출력·옵션·검증을 한곳에 둔다.
> 실행 도구는 [`03-compose.sh`](03-compose.sh). compose 파일 **저작 표준**은
> 별도 문서 [compose-authoring.md](compose-authoring.md).

필요한 노드에서만 실행한다. Docker CE 만 필요한 노드에 Compose 를 강제하지 않으며,
클러스터에서는 `docker service` 를 쓴다 ([04-swarm-cluster.md](04-swarm-cluster.md)).

**전제:** [02-docker-ce.md](02-docker-ce.md) 완료 — Docker CE + 서명된 저장소 설정
(`signed-by=`). 스크립트가 이를 먼저 확인하고 없으면 중단한다.

---

## 실행

```bash
scp 03-compose.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/03-compose.sh'
```

또는 노드에서 직접 받는다 ([02-docker-ce.md](02-docker-ce.md) 「`wget` 로 노드에서
직접 받기」와 동일 절차 — 커밋 SHA 고정 → `sha256sum` 대조 → 육안 검토 → 실행,
`\| bash` 금지):

```bash
REF=46e8c040acadf70a6097fcceb8272236ee0a2db7
wget -q "https://raw.githubusercontent.com/yundo-main/install/${REF}/docker/03-compose.sh" -O 03-compose.sh
sha256sum 03-compose.sh && less 03-compose.sh && bash 03-compose.sh
```

Compose V2 는 독립 바이너리가 아니라 **Docker CLI 플러그인**이므로 GitHub 릴리스
바이너리를 받지 않고 서명된 저장소의 `docker-compose-plugin` 패키지로 설치한다.

```bash
sudo apt-get update && sudo apt-get install -y docker-compose-plugin
```

### 옵션

| 옵션 | 설명 |
|---|---|
| (기본) | 서명된 저장소 확인 후 `docker-compose-plugin` 설치·검증 |
| `--verify-only` | 설치 없이 검증만 (패키지 출처, 레거시 V1 부재 포함) |

---

## 검증

```bash
docker compose version
dpkg -l docker-compose-plugin | tail -1
ls -l /usr/libexec/docker/cli-plugins/docker-compose
```
```
Docker Compose version v5.5.0
ii  docker-compose-plugin 5.5.0-1~ubuntu.24.04~noble arm64  Docker Compose (V2) plugin for the Docker CLI.
-rwxr-xr-x 1 root root 46470638  8월 17 21:04 /usr/libexec/docker/cli-plugins/docker-compose
```

스크립트는 설치 후 바이너리가 **패키지 소유**인지(`dpkg -S`)까지 검증한다. 수동으로
내려받은 바이너리는 여기서 잡히지 않는다 — 갱신·제거 경로가 없다는 뜻이다.

```bash
ssh groom@10.10.10.150 'bash ~/03-compose.sh --verify-only'
```

---

## 배제·정정 항목

- **GitHub 릴리스 바이너리** (`curl -L .../docker-compose -o /usr/local/bin/...`):
  APT 서명 검증을 우회하고 패키지 관리자가 추적하지 못한다. 갱신·제거·무결성
  확인 경로가 사라진다. [02-docker-ce.md](02-docker-ce.md) 2-2 의 지문 대조가 무효화된다.
- **레거시 `docker-compose`(V1)**: Python 구현 독립 바이너리, 2023년 지원 종료.
  설치돼 있으면 제거한다. 명령은 하이픈 없는 `docker compose` 를 쓴다. 스크립트가
  V1 존재를 검증 실패로 처리한다.

---

## 다음

compose 파일을 작성할 때의 표준·금지 항목·검증은 [compose-authoring.md](compose-authoring.md).
데몬 설정([02-docker-ce.md](02-docker-ce.md) 6절)이 compose 에 미치는 영향을 먼저 읽는다 —
`icc=false` 는 compose 네트워크에 적용되지 않는다.
