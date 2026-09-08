#!/usr/bin/env bash
#
# 04-node-prepare.sh — 복제(clone)된 노드의 신원을 분리한다.
# plan.md 7-4 단계에 대응한다. 실행 위치: 복제된 워커 노드
#
# 역할: 실행 도구. 절차의 근거와 기대 출력은 plan.md, 사용법은 USAGE.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 plan.md 와 어긋나면 plan.md 가 기준이다.
#       서버로 단독 scp 되므로 자기완결적이어야 한다.
#
# 문제: VM 복제본은 원본의 SSH 호스트 키·machine-id·Docker engine-id 를 승계한다.
#       호스트 키가 같으면 known_hosts 검증이 노드를 구별하지 못한다. 잘못된 노드에
#       접속해도 검증이 통과하므로, 매니저인 줄 알고 워커를 조작하는 사고를 막을
#       수단이 사라진다.
#
# 주의: 호스트 키를 재생성하면 클라이언트의 known_hosts 항목이 무효가 된다.
#       원본 노드에서 실행하지 않는다.
#
set -euo pipefail

NEW_HOSTNAME=""
SKIP_HOST_KEYS=0
SKIP_MACHINE_ID=0
RESET_DOCKER_ID=0
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 04-node-prepare.sh --hostname <name> [옵션]

  --hostname <name>     이 노드의 호스트명 (필수, 예: worker-01)
  --skip-host-keys      SSH 호스트 키를 재생성하지 않는다
  --skip-machine-id     machine-id 를 재생성하지 않는다
  --reset-docker-id     Docker engine-id 를 재생성한다 (데몬 재시작 필요)
  --verify-only         변경 없이 현재 신원만 출력한다
  -h, --help            도움말

호스트 키 재생성 후에는 클라이언트에서 known_hosts 를 갱신해야 한다.
스크립트가 새 지문을 출력하므로 그 값으로 대조한다.

원본 노드에서 실행하지 않는다 — 기존 접속 신뢰가 깨진다.
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
    --hostname)        NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --skip-host-keys)  SKIP_HOST_KEYS=1; shift ;;
    --skip-machine-id) SKIP_MACHINE_ID=1; shift ;;
    --reset-docker-id) RESET_DOCKER_ID=1; shift ;;
    --verify-only)     VERIFY_ONLY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; exit 2 ;;
  esac
done

show_identity() {
  step "노드 신원"
  printf '  hostname   : %s\n' "$(hostname)"
  printf '  machine-id : %s\n' "$(cat /etc/machine-id)"
  printf '  MAC        : %s\n' \
    "$(ip -o link show | grep -v ' lo:' | grep -vE 'docker|veth|br-' | awk '{print $(NF-2)}' | head -1)"
  printf '  IP         : %s\n' \
    "$(ip -4 -o addr show | grep -v ' lo ' | grep -v docker | awk '{print $4}' | head -1)"
  step "SSH 호스트 키 지문"
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
  # 키 코멘트가 다른 호스트명이면 복제본이라는 신호다.
  local cmt
  cmt="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $3}')"
  if [[ "$cmt" != *"$(hostname)"* ]]; then
    warn "키 코멘트($cmt)가 현재 호스트명($(hostname))과 다르다 — 복제본 신호"
  fi
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다."

if [[ $VERIFY_ONLY -eq 1 ]]; then
  show_identity
  exit 0
fi

[[ -n "$NEW_HOSTNAME" ]] || die "--hostname 이 필요하다."
command -v sudo > /dev/null || die "sudo 가 없다."
sudo -v || die "sudo 권한 확인 실패."

step "변경 전 상태"
show_identity

# ── 1. SSH 호스트 키 재생성 ──────────────────────────────────────────────────
step "1. SSH 호스트 키 재생성"

if [[ $SKIP_HOST_KEYS -eq 1 ]]; then
  warn "건너뜀 — 원본과 호스트 키를 공유한 상태가 유지된다"
else
  OLD_FPR="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
  sudo rm -f /etc/ssh/ssh_host_*
  # -A 는 없는 유형만 기본 설정으로 생성한다. dpkg-reconfigure 와 달리 비대화형이다.
  sudo ssh-keygen -A
  sudo sshd -t || die "sshd 설정 검증 실패 — 키 재생성 후 데몬을 재시작하지 않았다."
  sudo systemctl restart ssh
  NEW_FPR="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
  [[ "$OLD_FPR" != "$NEW_FPR" ]] || die "지문이 바뀌지 않았다. 재생성이 실패했다."
  ok "재생성 완료"
  printf '  이전 : %s\n  신규 : %s\n' "$OLD_FPR" "$NEW_FPR"
fi

# ── 2. machine-id 재생성 ─────────────────────────────────────────────────────
step "2. machine-id 재생성"

if [[ $SKIP_MACHINE_ID -eq 1 ]]; then
  warn "건너뜀 — 원본과 machine-id 를 공유한 상태가 유지된다"
else
  OLD_MID="$(cat /etc/machine-id)"
  sudo rm -f /etc/machine-id
  sudo systemd-machine-id-setup > /dev/null
  # dbus 는 /etc/machine-id 를 심볼릭 링크로 참조하는 구성이 표준이다.
  if [[ -e /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]]; then
    sudo rm -f /var/lib/dbus/machine-id
    sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
  fi
  NEW_MID="$(cat /etc/machine-id)"
  [[ "$OLD_MID" != "$NEW_MID" ]] || die "machine-id 가 바뀌지 않았다."
  ok "재생성 완료"
  printf '  이전 : %s\n  신규 : %s\n' "$OLD_MID" "$NEW_MID"
fi

# ── 3. 호스트명 ──────────────────────────────────────────────────────────────
step "3. 호스트명 설정"

if [[ "$(hostname)" == "$NEW_HOSTNAME" ]]; then
  ok "이미 $NEW_HOSTNAME 이다"
else
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  # /etc/hosts 의 127.0.1.1 항목도 맞춘다. 남겨두면 sudo 가 이름 해석에서 지연된다.
  if grep -q '^127.0.1.1' /etc/hosts; then
    sudo sed -i "s/^127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
  fi
  ok "설정 완료: $NEW_HOSTNAME"
fi

# ── 4. Docker engine-id ──────────────────────────────────────────────────────
step "4. Docker engine-id"

ENGINE_ID="/var/lib/docker/engine-id"
if ! command -v docker > /dev/null 2>&1; then
  ok "Docker 미설치 — 해당 없음"
elif ! sudo test -f "$ENGINE_ID"; then
  ok "engine-id 파일 없음 — 해당 없음"
elif [[ $RESET_DOCKER_ID -eq 1 ]]; then
  sudo systemctl stop docker
  sudo rm -f "$ENGINE_ID"
  sudo systemctl start docker
  ok "engine-id 재생성 (데몬 재시작)"
else
  warn "engine-id 가 원본과 동일할 수 있다. 재생성하려면 --reset-docker-id 를 쓴다."
fi

# ── 5. 결과 ──────────────────────────────────────────────────────────────────
step "변경 후 상태"
show_identity

step "완료 — 클라이언트에서 할 일"
cat <<'NEXT'
  호스트 키가 바뀌었다. 클라이언트의 known_hosts 를 갱신한다.

    ssh-keygen -R <이 노드 IP>
    ssh-keyscan -t ed25519 <이 노드 IP> | ssh-keygen -lf -    # 위 신규 지문과 대조
    ssh-keyscan -t ed25519 <이 노드 IP> >> ~/.ssh/known_hosts

  대조 없이 등록하지 않는다. 지문이 위 출력과 다르면 중간자 가능성을 검토한다.
NEXT
