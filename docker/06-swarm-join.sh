#!/usr/bin/env bash
#
# 06-swarm-join.sh — 워커 노드를 Swarm 클러스터에 가입시킨다.
# plan.md 10 단계에 대응한다. 실행 위치: 워커 노드 (10.10.10.151 / .152)
#
# 역할: 실행 도구. 절차의 근거와 기대 출력은 plan.md, 사용법은 USAGE.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 plan.md 와 어긋나면 plan.md 가 기준이다.
#       서버로 단독 scp 되므로 자기완결적이어야 한다.
#
# 전제: 02-install.sh 로 Docker CE 설치 완료.
#
set -euo pipefail

MANAGER=""
TOKEN_FILE=""
MANAGER_PORT="2377"
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 06-swarm-join.sh --manager <IP> --token-file <경로> [옵션]

  --manager <IP>        매니저 노드 주소 (필수)
  --token-file <경로>   워커 가입 토큰 파일 (필수)
                        ── 토큰을 인자로 직접 받지 않는다. argv 는 /proc 으로
                           노출되므로 파일 경로만 받는다.
  --port <포트>         매니저 관리 포트 (기본 2377)
  --verify-only         가입하지 않고 상태만 확인한다
  -h, --help            도움말

가입 후 매니저에서 토큰을 회전한다: docker swarm join-token --rotate worker
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
    --manager)     MANAGER="${2:?}"; shift 2 ;;
    --token-file)  TOKEN_FILE="${2:?}"; shift 2 ;;
    --port)        MANAGER_PORT="${2:?}"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; exit 2 ;;
  esac
done

if docker info > /dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

verify_all() {
  local rc=0
  step "검증 — 노드 상태"
  "${DOCKER[@]}" info --format 'swarm   : {{.Swarm.LocalNodeState}}
manager : {{.Swarm.ControlAvailable}}' || rc=1

  local state ctrl
  state="$("${DOCKER[@]}" info --format '{{.Swarm.LocalNodeState}}')"
  ctrl="$("${DOCKER[@]}" info --format '{{.Swarm.ControlAvailable}}')"

  [[ "$state" == "active" ]] || { warn "swarm 이 active 가 아니다"; rc=1; }

  # 워커는 제어 평면을 갖지 않아야 한다. true 면 매니저 토큰으로 가입한 것이며
  # 이 노드가 클러스터 완전 제어권을 가진다 — 권한 분리 실패다.
  if [[ "$ctrl" == "true" ]]; then
    warn "이 노드가 매니저다. 워커 토큰이 아니라 매니저 토큰으로 가입했다."
    warn "권한 분리가 깨졌다. 'docker node demote' 또는 재가입으로 정정한다."
    rc=1
  else
    ok "워커로 가입됨 (제어 평면 없음)"
  fi
  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다."
command -v docker > /dev/null || die "Docker CE 가 없다. 02-install.sh 를 먼저 실행한다."
ok "$(docker --version)"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

[[ -n "$MANAGER"    ]] || die "--manager 가 필요하다."
[[ -n "$TOKEN_FILE" ]] || die "--token-file 이 필요하다."
[[ -f "$TOKEN_FILE" ]] || die "토큰 파일이 없다: $TOKEN_FILE"

# 토큰 파일 권한 확인 — 자격 증명이 다른 계정에 읽히면 안 된다.
PERM="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE")"
[[ "$PERM" == "600" || "$PERM" == "400" ]] \
  || warn "토큰 파일 권한이 $PERM 이다. 0600 을 권장한다: chmod 0600 $TOKEN_FILE"

STATE="$("${DOCKER[@]}" info --format '{{.Swarm.LocalNodeState}}')"
if [[ "$STATE" == "active" ]]; then
  ok "이미 swarm 에 참여 중이다 — 가입 건너뜀"
  verify_all || die "검증 실패"
  exit 0
fi

# ── 1. 도달성 확인 ───────────────────────────────────────────────────────────
step "1. 매니저 도달성"

# 관리 평면 포트가 열려 있지 않으면 가입은 무의미하게 타임아웃된다.
if command -v nc > /dev/null 2>&1; then
  nc -z -w 4 "$MANAGER" "$MANAGER_PORT" \
    || die "${MANAGER}:${MANAGER_PORT} 에 도달할 수 없다. 매니저 초기화와 경로를 확인한다."
  ok "${MANAGER}:${MANAGER_PORT} 도달 가능"
else
  warn "nc 가 없어 사전 도달성 확인을 건너뛴다"
fi

# ── 2. 가입 ──────────────────────────────────────────────────────────────────
step "2. 클러스터 가입"

# 토큰은 argv 에 남아 /proc/<pid>/cmdline 으로 노출된다. 노출 창을 줄이기 위해
# 변수로만 읽고, 가입 직후 매니저에서 회전할 것을 전제한다.
TOKEN="$(< "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || die "토큰 파일이 비어 있다: $TOKEN_FILE"

"${DOCKER[@]}" swarm join --token "$TOKEN" "${MANAGER}:${MANAGER_PORT}"
unset TOKEN

# ── 3. 검증 ──────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

step "완료 — 다음 단계"
cat <<'NEXT'
  매니저에서 노드 목록을 확인한다.

    docker node ls        # MANAGER STATUS 가 비어 있어야 워커다

  전 노드 가입이 끝나면 토큰을 회전한다.

    docker swarm join-token --rotate worker

  이 노드의 토큰 사본을 삭제한다.

    shred -u ~/worker.token 2>/dev/null || rm -f ~/worker.token
NEXT
