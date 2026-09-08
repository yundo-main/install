#!/usr/bin/env bash
#
# 03-compose.sh — Ubuntu 24.04 에 Docker Compose V2 플러그인을 설치한다.
# USAGE.md 실행 순서 3절에 대응한다. 실행 위치: Ubuntu 24.04 VM (대상 호스트)
#
# 역할: 실행 도구. 사용법과 구성 표준은 USAGE.md 에 있다.
#       여기에 구성 표준을 복제하지 않는다.
#       서버로 단독 scp 되므로 자기완결적이어야 한다.
#
# 전제: 02-install.sh 가 Docker CE 와 서명된 저장소 설정을 이미 구성했다.
#       Compose V2 는 독립 바이너리가 아니라 Docker CLI 플러그인이므로
#       GitHub 릴리스 바이너리를 받지 않고 서명된 저장소의 패키지로 설치한다.
#
set -euo pipefail

readonly KEYRING="/etc/apt/keyrings/docker.asc"
readonly REPO_LIST="/etc/apt/sources.list.d/docker.list"
readonly PLUGIN_DIRS=(/usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins)

VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 03-compose.sh [옵션]

  --verify-only   설치하지 않고 검증만 수행한다
  -h, --help      도움말

전제: 02-install.sh 실행 완료 (Docker CE + 서명된 Docker 저장소).
      구성 표준은 USAGE.md 「Compose 구성 표준」 절을 따른다.
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
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; exit 2 ;;
  esac
done

plugin_path() {
  local d
  for d in "${PLUGIN_DIRS[@]}"; do
    [[ -x "$d/docker-compose" ]] && { printf '%s\n' "$d/docker-compose"; return 0; }
  done
  return 1
}

verify_all() {
  local rc=0

  step "검증 — 플러그인 인식"
  if docker compose version; then
    ok "docker compose 인식"
  else
    warn "docker compose 를 인식하지 못한다"; rc=1
  fi

  step "검증 — 패키지 출처"
  # 바이너리가 패키지 관리자의 추적 아래 있는지 확인한다.
  # 수동으로 내려받은 바이너리는 dpkg -S 에서 잡히지 않는다.
  dpkg -l docker-compose-plugin 2>/dev/null | tail -1 || { warn "패키지 미설치"; rc=1; }

  local p
  if p="$(plugin_path)"; then
    printf '  경로: %s\n' "$p"
    if dpkg -S "$p" > /dev/null 2>&1; then
      ok "패키지 소유 파일 — 갱신·제거 경로 확보"
    else
      warn "패키지가 소유하지 않는 파일이다. 수동 설치본으로 보인다."; rc=1
    fi
  else
    warn "플러그인 바이너리를 찾지 못했다"; rc=1
  fi

  step "검증 — 레거시 V1 부재"
  if command -v docker-compose > /dev/null 2>&1; then
    warn "레거시 docker-compose(V1) 가 있다: $(command -v docker-compose)"
    warn "2023년 지원 종료됐다. 제거하고 'docker compose' 를 쓴다."
    rc=1
  else
    ok "레거시 V1 없음"
  fi

  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다. sudo 권한을 가진 일반 계정으로 실행한다."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu 전용 스크립트다 (감지: ${ID:-unknown})."

command -v docker > /dev/null || die "Docker CE 가 없다. 02-install.sh 를 먼저 실행한다."
ok "$(docker --version)"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

command -v sudo > /dev/null || die "sudo 가 없다."
sudo -v || die "sudo 권한 확인 실패."

# 서명된 저장소가 구성돼 있어야 한다. 없으면 02-install.sh 의 2단계가 누락된 것이다.
[[ -f "$KEYRING"   ]] || die "$KEYRING 이 없다. 02-install.sh 를 먼저 실행한다."
[[ -f "$REPO_LIST" ]] || die "$REPO_LIST 가 없다. 02-install.sh 를 먼저 실행한다."
grep -q "signed-by=${KEYRING}" "$REPO_LIST" \
  || die "저장소가 signed-by 로 고정돼 있지 않다. 02-install.sh 로 재구성한다."
ok "서명된 Docker 저장소 확인 (signed-by=${KEYRING})"

# ── 1. 설치 ──────────────────────────────────────────────────────────────────
step "1. docker-compose-plugin 설치"

if dpkg -s docker-compose-plugin > /dev/null 2>&1; then
  ok "이미 설치돼 있다 — apt 로 최신 상태만 확인한다"
fi

sudo apt-get update -qq
sudo apt-get install -y docker-compose-plugin

# ── 2. 검증 ──────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

step "설치 완료"
cat <<'NEXT'
  구성 표준은 USAGE.md 「Compose 구성 표준」 절을 따른다. 요점:
    - 컨테이너 간 격리는 데몬의 icc=false 가 아니라 compose 네트워크 설계 책임이다
    - 포트는 127.0.0.1 바인딩이 기본이다 (Docker 규칙이 ufw 정책보다 먼저 평가된다)
    - 비밀값은 environment 가 아니라 secrets 로 주입한다
    - 이미지는 태그가 아니라 digest 로 고정한다
NEXT
