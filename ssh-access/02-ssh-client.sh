#!/usr/bin/env bash
#
# 02-ssh-client.sh — macOS 클라이언트에서 Ubuntu 24.04 VM 접속을 구성·검증한다.
# 근거·기대 출력·사용법은 02-ssh-client.md 에 있다. 실행 위치: macOS (10.10.10.1)
#
# 신뢰 경계: 이 스크립트는 클라이언트에서만 실행된다. 서버로 전송되는 것은
#            공개키뿐이며, sshd 설정 변경은 SSH 세션 위에서 sudo 로 수행한다.
#            authorized_keys 배치는 01-ssh-keys.sh(노드 로컬)가 우선 경로다 —
#            여기의 ssh-copy-id 는 SSH·비밀번호가 이미 되는 경우의 대안이다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 02-ssh-client.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 02-ssh-client.md 와 어긋나면 문서가 기준이다.
#
set -euo pipefail

HOST="10.10.10.150"
USER_NAME="groom"
PUBKEY="${HOME}/.ssh/id_rsa.pub"
EXPECT_FPR=""
DISABLE_PASSWORD=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
사용법: ./02-ssh-client.sh [옵션]

  --host <ip>           대상 서버 주소            (기본: 10.10.10.150)
  --user <name>         원격 계정                 (기본: groom)
  --key <path>          배포할 공개키             (기본: ~/.ssh/id_rsa.pub)
  --expect-fpr <fpr>    호스트 키 지문 (SHA256:...) — 게스트 콘솔에서
                        `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
                        으로 확인한 값. 생략 시 대화형 확인을 요구한다.
  --disable-password    키 인증 검증 성공 후 비밀번호 인증을 차단한다 (SSH-only 폴백; 콘솔 접근 가능하면 00-ssh-server.sh --password-auth 사용)
  --yes                 대화형 확인을 생략한다 (--expect-fpr 필요)
  -h, --help            도움말

종료 코드: 0 성공 / 1 검증 실패 / 2 인자 오류
USAGE
}

if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
# sshd 가 실제로 광고하는 인증 수단. 설정 파일이 아니라 데몬의 응답이 근거다.
advertised_auths() {
  ssh "${SSH_OPTS[@]}" -v -o BatchMode=yes -o PubkeyAuthentication=no "$TARGET" true 2>&1 \
    | grep 'Authentications that can continue' | tail -1 || true
}
ok()   { printf '%s  [OK]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s  [FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)             HOST="${2:?}"; shift 2 ;;
    --user)             USER_NAME="${2:?}"; shift 2 ;;
    --key)              PUBKEY="${2:?}"; shift 2 ;;
    --expect-fpr)       EXPECT_FPR="${2:?}"; shift 2 ;;
    --disable-password) DISABLE_PASSWORD=1; shift ;;
    --yes)              ASSUME_YES=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; exit 2 ;;
  esac
done

TARGET="${USER_NAME}@${HOST}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=(-o ConnectTimeout=8)

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건 — 도달성 확인"

[[ -f "$PUBKEY" ]] || die "공개키가 없다: $PUBKEY (ssh-keygen 으로 먼저 생성한다)"
ok "공개키: $PUBKEY"

if ping -c 2 -W 2000 "$HOST" > /dev/null 2>&1; then
  ok "ICMP 응답: $HOST"
else
  warn "ICMP 무응답. macOS 로컬 네트워크 권한 또는 VM 네트워크를 확인한다."
  warn "시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크 → 터미널 앱 허용 후 재시작"
fi

nc -z -w 4 "$HOST" 22 > /dev/null 2>&1 \
  || die "22/tcp 미개방. 게스트에서 'sudo systemctl enable --now ssh' 를 먼저 실행한다."
ok "22/tcp OPEN"

# ── 1-1. 호스트 키 확인 ──────────────────────────────────────────────────────
step "1-1. 호스트 키 지문 대조"

mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/known_hosts"; chmod 600 "${HOME}/.ssh/known_hosts"

if ssh-keygen -F "$HOST" > /dev/null 2>&1; then
  ok "known_hosts 에 이미 등록됨 — 건너뜀"
else
  SCAN="$(ssh-keyscan -t ed25519 "$HOST" 2>/dev/null)" || true
  [[ -n "$SCAN" ]] || die "ssh-keyscan 실패. 서버의 ed25519 호스트 키를 확인한다."
  SCAN_FPR="$(printf '%s\n' "$SCAN" | ssh-keygen -lf - | awk '{print $2}')"
  printf '  수집된 지문: %s\n' "$SCAN_FPR"

  if [[ -n "$EXPECT_FPR" ]]; then
    [[ "$SCAN_FPR" == "$EXPECT_FPR" ]] \
      || die "지문 불일치. 기대=$EXPECT_FPR 실제=$SCAN_FPR — MITM 가능성. 중단한다."
    ok "지문 일치"
  elif [[ $ASSUME_YES -eq 1 ]]; then
    die "--yes 사용 시 --expect-fpr 가 필수다 (무검증 TOFU 를 허용하지 않는다)."
  else
    warn "게스트 콘솔의 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' 출력과 대조한다."
    read -r -p "  위 지문이 일치하는가? [y/N] " ans
    [[ "$ans" == [yY] ]] || die "사용자가 중단했다."
  fi

  printf '%s\n' "$SCAN" >> "${HOME}/.ssh/known_hosts"
  ok "known_hosts 등록 완료"
fi

# ── 1-2. 공개키 배포 ─────────────────────────────────────────────────────────
step "1-2. 공개키 배포"

if ssh "${SSH_OPTS[@]}" -o PasswordAuthentication=no -o BatchMode=yes "$TARGET" 'true' 2>/dev/null; then
  ok "키 인증이 이미 동작한다 — ssh-copy-id 건너뜀"
else
  printf '  %s 의 비밀번호를 입력한다.\n' "$TARGET"
  ssh-copy-id -i "$PUBKEY" "$TARGET" || die "ssh-copy-id 실패"
fi

# ── 검증: 비밀번호 없이 접속 ─────────────────────────────────────────────────
step "검증 — 키 단독 인증"

ID_OUT="$(ssh "${SSH_OPTS[@]}" -o PasswordAuthentication=no -o BatchMode=yes "$TARGET" 'id' 2>/dev/null)" \
  || die "키 인증 실패. 비밀번호 인증을 차단하면 접속 수단이 사라진다. 중단한다."
printf '  %s\n' "$ID_OUT"
ok "키 단독 인증 성공"

grep -q '(sudo)' <<<"$ID_OUT" \
  || warn "$USER_NAME 이 sudo 그룹에 없다. 서버 측 Docker 설치 스크립트가 실패한다."

# ── 1-3. 비밀번호 인증 차단 ──────────────────────────────────────────────────
if [[ $DISABLE_PASSWORD -eq 1 ]]; then
  step "1-3. 비밀번호 인증 차단"

  # 원격 sudo 는 tty 가 필요하다. 스크립트를 stdin 으로 넘기면 sudo 프롬프트가
  # heredoc 을 읽어버리므로, 명령 인자로 전달하고 -t 로 tty 를 할당한다.
  REMOTE_CMD='set -euo pipefail
printf "%s\n" "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
  | sudo tee /etc/ssh/sshd_config.d/60-no-password.conf > /dev/null
sudo sshd -t && sudo systemctl reload ssh.service && echo "configuration OK"'

  ssh "${SSH_OPTS[@]}" -t "$TARGET" "$REMOTE_CMD" \
    || die "sshd 설정 적용 실패 — 비밀번호 인증은 그대로 유지된다."

  # 검증: 파일이 아니라 데몬이 광고하는 인증 수단으로 확인한다.
  AUTHS="$(advertised_auths)"
  printf '  %s\n' "${AUTHS:-<없음>}"
  if grep -q 'password' <<<"$AUTHS"; then
    die "password 가 목록에 남아 있다. reload 가 반영되지 않았다."
  fi
  ok "publickey 단독"

  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" 'echo OK' > /dev/null \
    || die "키 로그인이 깨졌다. 게스트 콘솔에서 60-no-password.conf 를 제거한다."
  ok "키 로그인 정상"
else
  step "비밀번호 인증 상태 확인"
  AUTHS="$(advertised_auths)"
  printf '  %s\n' "${AUTHS:-<확인 불가>}"
  if grep -q 'password' <<<"$AUTHS"; then
    warn "비밀번호 인증이 활성 상태다. 차단하려면 --disable-password 로 재실행한다."
  else
    ok "비밀번호 인증은 이미 차단돼 있다"
  fi
fi

# ── 다음 단계 안내 ───────────────────────────────────────────────────────────
step "완료 — 다음 단계"
cat <<NEXT
  서버에서 Docker 를 설치한다:

    scp ${SCRIPT_DIR}/../docker/00-docker-ce.sh ${SCRIPT_DIR}/../docker/01-compose.sh ${TARGET}:~/
    ssh -t ${TARGET} 'bash ~/00-docker-ce.sh'
    ssh -t ${TARGET} 'bash ~/01-compose.sh'   # Compose 가 필요한 경우

  ~/.ssh/config 별칭 등록(선택):

    Host ub24
        HostName       ${HOST}
        User           ${USER_NAME}
        IdentityFile   ${PUBKEY%.pub}
        IdentitiesOnly yes
NEXT
