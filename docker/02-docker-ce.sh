#!/usr/bin/env bash
#
# 02-docker-ce.sh — Ubuntu 24.04 에 Docker 공식 저장소로 Docker CE 를 설치한다.
# 근거·기대 출력·사용법은 02-docker-ce.md 에 있다. 실행 위치: Ubuntu 24.04 VM (대상 호스트)
#
# 설계 원칙
#   - 신뢰 경로 우선: GPG 키는 지문을 대조한 뒤에만 keyrings 에 배치한다.
#   - signed-by 로 키의 서명 권한을 Docker 저장소로만 한정한다 (apt-key 미사용).
#   - 검증은 설정 파일이 아니라 데몬·컨테이너의 실제 상태로 수행한다.
#   - 멱등: 재실행해도 상태가 수렴한다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 02-docker-ce.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 02-docker-ce.md 와 어긋나면 문서가 기준이다.
#       서버로 단독 scp 되므로 자기완결적이어야 한다 — 외부 라이브러리를 참조하지 않는다.
#
set -euo pipefail

# Docker 공식 저장소 서명 키 지문 (2017-02-22, rsa4096)
readonly DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
readonly KEYRING="/etc/apt/keyrings/docker.asc"
readonly REPO_LIST="/etc/apt/sources.list.d/docker.list"
readonly DAEMON_JSON="/etc/docker/daemon.json"

ADD_DOCKER_GROUP=0
SKIP_DAEMON_CONFIG=0
FORCE_DAEMON_CONFIG=0
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 02-docker-ce.sh [옵션]

  --docker-group          호출 계정을 docker 그룹에 추가한다 (기본: 비활성)
                          ── docker 그룹은 root 등가 권한이다. 아래 경고 참조.
  --skip-daemon-config    /etc/docker/daemon.json 구성을 건너뛴다
  --force-daemon-config   기존 daemon.json 이 다르면 백업 후 덮어쓴다
  --verify-only           설치하지 않고 검증만 수행한다
  -h, --help              도움말

경고: docker 그룹 멤버는 임의 호스트 경로를 컨테이너에 마운트해 uid 0 으로
      접근할 수 있다. 이 그룹 부여는 해당 계정에 root 를 주는 것과 같다.
      sudo docker 만 사용할 경우 --docker-group 을 지정하지 않는다.
USAGE
}

if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '%s  [OK]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s  [FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker-group)        ADD_DOCKER_GROUP=1; shift ;;
    --skip-daemon-config)  SKIP_DAEMON_CONFIG=1; shift ;;
    --force-daemon-config) FORCE_DAEMON_CONFIG=1; shift ;;
    --verify-only)         VERIFY_ONLY=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage >&2; exit 2 ;;
  esac
done

# ── 검증 루틴 (설치 후 및 --verify-only 에서 공용) ───────────────────────────
# docker CLI 실행 접두사를 결정한다.
# docker 그룹 멤버면 sudo 가 불필요하다. sudo 를 무조건 붙이면 NOPASSWD 가 아닌
# 호스트에서 비밀번호 프롬프트 때문에 비대화형 검증이 막힌다.
set_docker_cmd() {
  if docker info > /dev/null 2>&1; then
    DOCKER=(docker)
  else
    DOCKER=(sudo docker)
  fi
}

verify_all() {
  local rc=0
  set_docker_cmd

  step "검증 — 바이너리 버전"
  docker --version        || rc=1
  containerd --version    || rc=1
  runc --version | head -1 || rc=1
  docker buildx version   || rc=1
  # compose 는 03-compose.sh 소관이다. 미설치는 실패로 보지 않는다.
  docker compose version 2>/dev/null || warn "compose 미설치 — 필요하면 03-compose.sh 를 실행한다"

  step "검증 — systemd 유닛"
  local u
  for u in docker.service docker.socket containerd.service; do
    printf "  %-20s enabled=%-9s active=%s\n" "$u" \
      "$(systemctl is-enabled "$u" 2>/dev/null || echo n/a)" \
      "$(systemctl is-active  "$u" 2>/dev/null || echo n/a)"
    [[ "$(systemctl is-active "$u" 2>/dev/null)" == "active" ]] || rc=1
  done

  step "검증 — 전 경로 (registry pull -> containerd -> runc)"
  if "${DOCKER[@]}" run --rm hello-world 2>&1 | grep -q "Hello from Docker!"; then
    ok "hello-world 정상"
  else
    warn "hello-world 실패 — 레지스트리 도달성 또는 런타임을 확인한다"; rc=1
  fi

  if [[ $SKIP_DAEMON_CONFIG -eq 0 ]]; then
    step "검증 — 데몬 설정 (실제 상태 기준)"
    "${DOCKER[@]}" info --format 'live-restore : {{.LiveRestoreEnabled}}
security     : {{.SecurityOptions}}' || rc=1
    "${DOCKER[@]}" network inspect bridge \
      --format 'icc          : {{index .Options "com.docker.network.bridge.enable_icc"}}' || rc=1
    "${DOCKER[@]}" run -d --name logchk alpine sleep 10 > /dev/null
    "${DOCKER[@]}" inspect logchk --format 'log          : {{.HostConfig.LogConfig.Config}}' || rc=1
    "${DOCKER[@]}" rm -f logchk > /dev/null
    "${DOCKER[@]}" run --rm alpine grep NoNewPrivs /proc/self/status || rc=1
  fi

  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다. sudo 권한을 가진 일반 계정으로 실행한다."
command -v sudo > /dev/null || die "sudo 가 없다."
# 검증 전용 실행은 설치를 하지 않으므로 sudo 권한을 미리 요구하지 않는다.
[[ $VERIFY_ONLY -eq 1 ]] || sudo -v || die "sudo 권한 확인 실패."

. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu 전용 스크립트다 (감지: ${ID:-unknown})."
ok "${PRETTY_NAME} / $(dpkg --print-architecture)"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

# ── 2-1. 충돌 패키지 확인 ────────────────────────────────────────────────────
step "2-1. 배포판 기본 패키지 확인"

CONFLICTS=()
for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  dpkg -s "$p" > /dev/null 2>&1 && CONFLICTS+=("$p")
done
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
  warn "충돌 패키지 제거: ${CONFLICTS[*]}"
  sudo apt-get remove -y "${CONFLICTS[@]}"
else
  ok "충돌 패키지 없음"
fi

sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg > /dev/null

# ── 2-2. GPG 키 — 지문 대조 후 등록 ──────────────────────────────────────────
step "2-2. GPG 키 지문 대조"

TMP_ASC="$(mktemp)"
trap 'rm -f "$TMP_ASC"' EXIT

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TMP_ASC" \
  || die "GPG 키 다운로드 실패"

ACTUAL_FPR="$(gpg --show-keys --with-colons --with-fingerprint "$TMP_ASC" \
              | awk -F: '$1=="fpr" {print $10; exit}')"
printf '  기대 지문: %s\n  실제 지문: %s\n' "$DOCKER_GPG_FPR" "$ACTUAL_FPR"

[[ "$ACTUAL_FPR" == "$DOCKER_GPG_FPR" ]] \
  || die "지문 불일치. 신뢰 경로에 넣지 않고 중단한다."
ok "지문 일치 — 신뢰 경로에 배치"

sudo install -m 0755 -d /etc/apt/keyrings
sudo install -m 0644 -o root -g root "$TMP_ASC" "$KEYRING"

# ── 2-3. 저장소 등록 ─────────────────────────────────────────────────────────
step "2-3. 저장소 등록"

# signed-by= 는 이 키의 서명 권한을 Docker 저장소로만 한정한다.
# apt-key add 는 전역 키링에 넣어 모든 저장소를 서명 가능하게 하므로 쓰지 않는다.
echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING}] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | sudo tee "$REPO_LIST" > /dev/null

UPDATE_LOG="$(mktemp)"
if ! sudo apt-get update 2>&1 | tee "$UPDATE_LOG" | tail -3; then
  rm -f "$UPDATE_LOG"; die "apt-get update 실패"
fi
if grep -qiE 'NO_PUBKEY|GPG error|not signed' "$UPDATE_LOG"; then
  rm -f "$UPDATE_LOG"; die "GPG 오류 발생 — 키 등록이 잘못됐다."
fi
rm -f "$UPDATE_LOG"
ok "GPG 오류 없음"

apt-cache policy docker-ce | head -5

# ── 3. 패키지 설치 ───────────────────────────────────────────────────────────
step "3. 패키지 설치"

# Compose 플러그인은 03-compose.sh 소관이다. 여기서 설치하지 않는다.
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin
ok "설치 완료"

# ── 6. 데몬 설정 (서비스 검증 전에 적용해 재시작을 1회로 줄인다) ─────────────
if [[ $SKIP_DAEMON_CONFIG -eq 0 ]]; then
  step "6. 데몬 설정 — ${DAEMON_JSON}"

  NEW_JSON="$(mktemp)"
  cat > "$NEW_JSON" <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true,
  "icc": false
}
JSON

  APPLY=1
  if sudo test -f "$DAEMON_JSON"; then
    if sudo cmp -s "$NEW_JSON" "$DAEMON_JSON"; then
      ok "동일한 설정이 이미 적용돼 있다"
      APPLY=0
    elif [[ $FORCE_DAEMON_CONFIG -eq 1 ]]; then
      BAK="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
      sudo cp -a "$DAEMON_JSON" "$BAK"
      warn "기존 설정을 ${BAK} 로 백업했다"
    else
      warn "기존 ${DAEMON_JSON} 이 다르다. 덮어쓰지 않는다 (--force-daemon-config 로 강제)."
      sudo diff -u "$DAEMON_JSON" "$NEW_JSON" || true
      APPLY=0
      SKIP_DAEMON_CONFIG=1   # 아래 검증에서 이 설정을 기대하지 않는다
    fi
  fi

  if [[ $APPLY -eq 1 ]]; then
    sudo install -m 0644 -o root -g root -D "$NEW_JSON" "$DAEMON_JSON"
    sudo dockerd --validate --config-file "$DAEMON_JSON" \
      || die "daemon.json 검증 실패 — 데몬을 재시작하지 않았다."
    sudo systemctl restart docker
    ok "적용 및 재시작 완료"
  fi
  rm -f "$NEW_JSON"
else
  warn "데몬 설정을 건너뛴다 (--skip-daemon-config)"
fi

# ── 4. 서비스 기동 확인 + 5. 검증 ────────────────────────────────────────────
sudo systemctl enable --now docker.service > /dev/null 2>&1 || true

verify_all || die "검증 실패 — 위 항목을 확인한다."

# ── 5. 권한 모델 ─────────────────────────────────────────────────────────────
step "5. 권한 모델 — docker 그룹"

if [[ $ADD_DOCKER_GROUP -eq 1 ]]; then
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    ok "${USER} 는 이미 docker 그룹 멤버다"
  else
    sudo usermod -aG docker "$USER"
    warn "${USER} 를 docker 그룹에 추가했다 — 이 계정은 실질적으로 root 권한을 갖는다."
    warn "새 로그인 세션부터 반영된다. SSH 를 재접속한 뒤 'docker run --rm hello-world' 로 확인한다."
  fi
else
  ok "docker 그룹 미부여 — sudo docker 로 사용한다 (최소 권한 기본값)"
fi

step "설치 완료"
printf '  Compose 가 필요하면 별도로 설치한다: bash 03-compose.sh\n'
cat <<'RESIDUAL'
  잔여 위험 / 전제
    - icc=false 는 기본 bridge 네트워크에만 적용된다. 사용자 정의 네트워크의
      컨테이너 간 통신은 여전히 허용된다.
    - no-new-privileges 는 컨테이너 내 setuid 바이너리(ping, sudo)를 무력화한다.
      해당 동작에 의존하는 이미지는 실패한다.
    - Docker 데몬 소켓(/var/run/docker.sock)은 root 등가 권한이다. 컨테이너에
      마운트하지 않는다.
    - 이 스크립트는 방화벽(ufw/nftables)을 구성하지 않는다. docker 는 자체
      iptables 규칙을 삽입하므로 -p 포트 공개 범위를 별도로 통제한다.
RESIDUAL
