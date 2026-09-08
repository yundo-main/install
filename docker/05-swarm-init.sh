#!/usr/bin/env bash
#
# 05-swarm-init.sh — Docker Swarm 매니저 노드를 초기화한다.
# plan.md 7~9 단계에 대응한다. 실행 위치: 매니저 노드 (10.10.10.150)
#
# 역할: 실행 도구. 절차의 근거와 기대 출력은 plan.md, 사용법은 USAGE.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 plan.md 와 어긋나면 plan.md 가 기준이다.
#       서버로 단독 scp 되므로 자기완결적이어야 한다.
#
# 전제: 02-install.sh 로 Docker CE 설치 완료.
#
set -euo pipefail

readonly DAEMON_JSON="/etc/docker/daemon.json"
readonly TOKEN_DIR="${HOME}/.swarm"

ADVERTISE_ADDR=""
KEEP_LIVE_RESTORE=0
AUTOLOCK=0
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 05-swarm-init.sh --advertise-addr <IP> [옵션]

  --advertise-addr <IP>   클러스터에 광고할 주소 (필수)
                          다중 인터페이스에서 Docker 가 주소를 고르지 못한다.
  --keep-live-restore     daemon.json 의 live-restore 를 제거하지 않는다
                          ── swarm 에서 무시되는 설정이 남는다. 권장하지 않는다.
  --autolock              Raft 로그를 암호화한다 (plan.md 9-2)
                          ── 데몬 재시작마다 수동 unlock 이 필요해진다.
  --verify-only           초기화하지 않고 검증만 수행한다
  -h, --help              도움말

토큰은 ~/.swarm 에 0600 으로 저장된다. 전달은 SSH 등 암호화 경로만 쓴다.
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
    --advertise-addr)    ADVERTISE_ADDR="${2:?}"; shift 2 ;;
    --keep-live-restore) KEEP_LIVE_RESTORE=1; shift ;;
    --autolock)          AUTOLOCK=1; shift ;;
    --verify-only)       VERIFY_ONLY=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage >&2; exit 2 ;;
  esac
done

# docker 그룹 멤버면 sudo 가 불필요하다. 무조건 sudo 를 붙이면 NOPASSWD 가 아닌
# 호스트에서 비대화형 실행이 막힌다.
if docker info > /dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

verify_all() {
  local rc=0

  step "검증 — swarm 상태"
  "${DOCKER[@]}" info --format 'swarm   : {{.Swarm.LocalNodeState}}
manager : {{.Swarm.ControlAvailable}}
nodes   : {{.Swarm.Nodes}}
managers: {{.Swarm.Managers}}' || rc=1

  [[ "$("${DOCKER[@]}" info --format '{{.Swarm.LocalNodeState}}')" == "active" ]] \
    || { warn "swarm 이 active 가 아니다"; rc=1; }

  step "검증 — live-restore (swarm 에서 무시되는 설정)"
  local lr
  lr="$("${DOCKER[@]}" info --format '{{.LiveRestoreEnabled}}')"
  if [[ "$lr" == "true" ]]; then
    warn "live-restore 가 켜져 있다. swarm 에서 효력이 없다 — 오해의 소지."
    rc=1
  else
    ok "live-restore 비활성"
  fi

  step "검증 — 수신 포트 (plan.md 8절)"
  # 2377 관리 평면, 7946 노드 탐색, 4789 overlay 데이터 평면
  if ss -lntup 2>/dev/null | grep -qE ':2377'; then ok "2377/tcp LISTEN"; else warn "2377/tcp 미수신"; rc=1; fi
  if ss -lntup 2>/dev/null | grep -qE ':7946'; then ok "7946 LISTEN"; else warn "7946 미수신"; rc=1; fi

  step "검증 — 노드 목록"
  "${DOCKER[@]}" node ls || rc=1

  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다."
command -v docker > /dev/null || die "Docker CE 가 없다. 02-install.sh 를 먼저 실행한다."
ok "$(docker --version)"

SWARM_STATE="$("${DOCKER[@]}" info --format '{{.Swarm.LocalNodeState}}')"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

[[ -n "$ADVERTISE_ADDR" ]] || die "--advertise-addr 가 필요하다. plan.md 9절 참조."

# daemon.json 수정과 데몬 재시작에 sudo 가 필요하다. 비밀번호가 걸려 있고 tty 가
# 없으면 여기서 멈춘다. 확인하지 못한 상태를 '변경 없음'으로 넘기지 않기 위함이다.
if ! sudo -n true 2>/dev/null; then
  [[ -t 0 ]] || die "sudo 에 비밀번호가 필요하다. tty 가 있어야 한다 — 'ssh -t' 로 실행한다."
  sudo -v || die "sudo 권한 확인 실패."
fi
ip -4 -o addr show 2>/dev/null | grep -q " ${ADVERTISE_ADDR}/" \
  || die "$ADVERTISE_ADDR 가 이 호스트의 인터페이스에 없다."
ok "advertise-addr: $ADVERTISE_ADDR"

# ── 1. live-restore 제거 ─────────────────────────────────────────────────────
step "1. live-restore 처리"

if [[ $KEEP_LIVE_RESTORE -eq 1 ]]; then
  warn "live-restore 를 유지한다. swarm 에서 무시되는 설정이 남는다."
elif [[ "$("${DOCKER[@]}" info --format '{{.LiveRestoreEnabled}}')" != "true" ]]; then
  ok "이미 비활성 — 변경 없음"
elif [[ -f "$DAEMON_JSON" ]]; then
  BAK="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp -a "$DAEMON_JSON" "$BAK"
  ok "기존 설정 백업: $BAK"

  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  # live-restore 키만 제거한다. 나머지 설정(no-new-privileges, 로그 제한, icc)은 유지.
  python3 -c \
    'import json,sys; d=json.load(open(sys.argv[1])); d.pop("live-restore",None); print(json.dumps(d,indent=2,ensure_ascii=False))' \
    "$DAEMON_JSON" > "$TMP" || die "daemon.json 파싱 실패 — 수동으로 확인한다."

  sudo install -m 0644 -o root -g root "$TMP" "$DAEMON_JSON"
  sudo dockerd --validate --config-file "$DAEMON_JSON" \
    || die "daemon.json 검증 실패 — 백업($BAK)에서 복원한다."
  sudo systemctl restart docker
  ok "live-restore 제거 및 데몬 재시작"
else
  warn "live-restore 가 켜져 있으나 $DAEMON_JSON 이 없다."
  warn "명령행 플래그나 systemd 드롭인으로 설정된 것이다. 수동 확인이 필요하다."
  die "자동 처리할 수 없다 — swarm init 은 live-restore 와 공존할 수 없다."
fi

# ── 2. swarm 초기화 ──────────────────────────────────────────────────────────
step "2. swarm 초기화"

if [[ "$SWARM_STATE" == "active" ]]; then
  ok "이미 swarm 에 참여 중이다 — init 건너뜀"
else
  "${DOCKER[@]}" swarm init --advertise-addr "$ADVERTISE_ADDR"
fi

# ── 3. 가입 토큰 ─────────────────────────────────────────────────────────────
step "3. 가입 토큰 저장"

install -m 0700 -d "$TOKEN_DIR"
# 토큰은 자격 증명이다. 표준출력으로 흘리지 않고 0600 파일로만 남긴다.
umask 077
"${DOCKER[@]}" swarm join-token -q worker  > "${TOKEN_DIR}/worker.token"
"${DOCKER[@]}" swarm join-token -q manager > "${TOKEN_DIR}/manager.token"
chmod 0600 "${TOKEN_DIR}"/*.token
ls -l "${TOKEN_DIR}"
ok "저장 완료 — 화면에 출력하지 않았다"

warn "manager.token 은 클러스터 완전 제어권이다. 워커 가입에는 worker.token 만 쓴다."

# ── 4. autolock ──────────────────────────────────────────────────────────────
if [[ $AUTOLOCK -eq 1 ]]; then
  step "4. Raft 로그 암호화 (autolock)"
  "${DOCKER[@]}" swarm update --autolock=true
  warn "unlock 키를 안전한 곳에 보관한다. 분실 시 매니저 복구가 불가능하다."
  warn "이후 데몬 재시작마다 'docker swarm unlock' 이 필요하다 — 무인 재부팅 불가."
else
  warn "autolock 미적용 — Raft 로그의 시크릿이 디스크에 평문이다 (plan.md 9-2)"
fi

# ── 5. 검증 ──────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

step "완료 — 다음 단계"
cat <<NEXT
  워커 노드에서 가입한다. 토큰은 암호화 경로로만 전달한다.

    scp ${TOKEN_DIR}/worker.token <worker>:~/
    ssh <worker> 'bash ~/06-swarm-join.sh --manager ${ADVERTISE_ADDR} --token-file ~/worker.token'

  가입 완료 후 토큰을 회전한다.

    docker swarm join-token --rotate worker
NEXT
