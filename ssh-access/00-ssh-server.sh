#!/usr/bin/env bash
#
# 00-ssh-server.sh — Ubuntu 24.04 VM 에서 로컬로 실행해 SSH 서버·방화벽·
# 인증 정책을 구성한다. 근거·기대 출력·사용법은 00-ssh-server.md 에 있다.
# 실행 위치: Ubuntu 24.04 VM 게스트 콘솔 또는 로컬 세션 (SSH·클라이언트 불필요)
#
# 설계 원칙
#   - zero-trust 기본값: 인자 없이 실행하면 publickey 전용 + ufw deny incoming
#     (22/tcp 만 LAN 대역에 허용) 이다. 비밀번호 인증은 --password-auth 로,
#     방화벽 해제는 --firewall none 으로 명시할 때만 바뀐다.
#   - 최소 노출: 비밀번호 인증·22/tcp 모두 기본은 LAN 대역으로 한정한다.
#   - 예측 가능한 데몬: Ubuntu 24.04 의 소켓 활성화(ssh.socket) 를 끄고 상시
#     ssh.service 로 고정한다. 소켓 활성화에서는 sshd_config 의 Port/ListenAddress
#     가 무시되고 연결마다 인스턴스가 뜬다.
#   - 검증은 설정 파일이 아니라 sshd -T / ufw status 가 보고하는 유효 상태로 수행한다.
#   - 멱등: 재실행해도 상태가 수렴한다. 드롭인(60-auth-policy.conf) 과 ufw 규칙
#     (주석 태그로 식별) 을 이 스크립트가 소유·관리한다.
#
# 관계: 01-ssh-keys.sh 는 authorized_keys 배치(키 등록)를 담당한다. 02-ssh-client.sh
#       는 클라이언트 측(호스트 키 지문 대조, known_hosts, ~/.ssh/config, 무암호
#       접속 검증)을 담당한다. sshd 인증 정책은 SSH 위 원격 sudo 로 바꾸지 않고
#       이 스크립트가 게스트에서 로컬로 관리한다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 00-ssh-server.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 00-ssh-server.md 와 어긋나면
#       문서가 기준이다. 게스트에서 단독 실행되므로 자기완결적이어야 한다.
#
set -euo pipefail

readonly DROPIN="/etc/ssh/sshd_config.d/60-auth-policy.conf"
readonly LEGACY_DROPIN="/etc/ssh/sshd_config.d/60-no-password.conf"
readonly HOST_KEY_PUB="/etc/ssh/ssh_host_ed25519_key.pub"

PASSWORD_AUTH="off"                # off | lan | on
LAN_CIDR="10.10.10.0/24"
ALLOW_USERS=""
PERMIT_ROOT="prohibit-password"
FIREWALL="ufw"                     # ufw | none
SSH_FROM=""                        # CIDR | any  (미지정 시 LAN_CIDR 를 따른다)
VERIFY_ONLY=0

readonly UFW_TAG="00-ssh-server"   # 이 스크립트가 만든 ufw 규칙 식별 태그

usage() {
  cat <<'USAGE'
사용법: bash 00-ssh-server.sh [옵션]

  --password-auth <off|lan|on>  비밀번호 인증 정책 (기본: off — publickey 전용)
                                  off : 전 경로 차단
                                  lan : --lan-cidr 대역에서만 허용, 그 외 차단
                                  on  : 전 경로 허용 (무차별 대입 표면 노출 — 권장하지 않음)
  --lan-cidr <cidr>             --password-auth lan 의 허용 대역 (기본: 10.10.10.0/24)
  --allow-users <u1,u2,...>     AllowUsers 로 로그인 계정을 화이트리스트로 제한한다
  --permit-root <prohibit-password|no|yes>
                                PermitRootLogin (기본: prohibit-password)
  --firewall <ufw|none>        호스트 방화벽 (기본: ufw — deny incoming, 22 만 허용)
                                  none : 방화벽을 건드리지 않는다 (nftables 직접 운용 등)
  --ssh-from <cidr|any>        22/tcp 허용 출처 (기본: --lan-cidr 값)
                                  any : 전 경로 허용 (외부 노출 시에만)
  --verify-only                설치·변경 없이 유효 설정만 검증한다
  -h, --help                   도움말

공개키 등록(authorized_keys)은 이 스크립트가 아니라 01-ssh-keys.sh 가 한다.

종료 코드: 0 성공 / 1 검증·적용 실패 / 2 인자 오류
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
    --password-auth)       PASSWORD_AUTH="${2:?}"; shift 2 ;;
    --lan-cidr)            LAN_CIDR="${2:?}"; shift 2 ;;
    --allow-users)         ALLOW_USERS="${2:?}"; shift 2 ;;
    --permit-root)         PERMIT_ROOT="${2:?}"; shift 2 ;;
    --firewall)            FIREWALL="${2:?}"; shift 2 ;;
    --ssh-from)            SSH_FROM="${2:?}"; shift 2 ;;
    --verify-only)         VERIFY_ONLY=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage >&2; exit 2 ;;
  esac
done

case "$PASSWORD_AUTH" in off|lan|on) ;; *) usage >&2; exit 2 ;; esac
case "$PERMIT_ROOT" in prohibit-password|no|yes) ;; *) usage >&2; exit 2 ;; esac
case "$FIREWALL" in ufw|none) ;; *) usage >&2; exit 2 ;; esac

# --ssh-from 미지정 시 LAN 대역을 따른다.
[[ -n "$SSH_FROM" ]] || SSH_FROM="$LAN_CIDR"

# ── 검증 루틴 (적용 후 및 --verify-only 공용) ────────────────────────────────
# 근거는 sshd -T 의 유효 설정이다. 드롭인 파일 내용이 아니라 데몬이 병합한 결과다.
verify_all() {
  local rc=0 v lan_probe

  step "검증 — sshd 문법"
  sudo sshd -t || { warn "sshd -t 실패 — 설정 파일에 오류가 있다"; return 1; }
  ok "sshd -t 통과"

  step "검증 — 유효 설정 (sshd -T)"
  sudo sshd -T 2>/dev/null \
    | grep -iE '^(passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries|logingracetime|allowusers) ' \
    | sed 's/^/  /' || true

  step "검증 — Match Address 해석 (LAN vs 비 LAN)"
  lan_probe="${LAN_CIDR%/*}"
  v="$(sudo sshd -T -C "addr=${lan_probe},user=root,host=probe" 2>/dev/null \
        | awk '/^passwordauthentication /{print $2}')"
  printf '  LAN(%s) -> passwordauthentication %s\n' "$LAN_CIDR" "${v:-?}"
  v="$(sudo sshd -T -C "addr=198.51.100.1,user=root,host=probe" 2>/dev/null \
        | awk '/^passwordauthentication /{print $2}')"
  printf '  비 LAN(198.51.100.1) -> passwordauthentication %s\n' "${v:-?}"

  step "검증 — 서비스·리슨"
  printf '  ssh.service enabled=%s active=%s\n' \
    "$(systemctl is-enabled ssh.service 2>/dev/null || echo n/a)" \
    "$(systemctl is-active  ssh.service 2>/dev/null || echo n/a)"
  printf '  ssh.socket  enabled=%s active=%s (상시 데몬 운용에서는 둘 다 비활성이어야 한다)\n' \
    "$(systemctl is-enabled ssh.socket 2>/dev/null || echo n/a)" \
    "$(systemctl is-active  ssh.socket 2>/dev/null || echo n/a)"
  [[ "$(systemctl is-active ssh.service 2>/dev/null)" == "active" ]] || rc=1
  [[ "$(systemctl is-active ssh.socket  2>/dev/null)" == "active" ]] && { warn "ssh.socket 이 아직 활성 — 소켓 활성화가 남아 있다"; rc=1; }
  # cmd | grep -q 는 grep 이 매치 즉시 파이프를 닫아 cmd 를 SIGPIPE 로 죽이고,
  # pipefail 이 그 141 을 실패로 만들어 판정이 뒤집힌다. 출력을 먼저 받아 검사한다.
  local ss_out ufw_out
  ss_out="$(sudo ss -tlnp 2>/dev/null || true)"
  if grep -qE '(:|\.)22 ' <<<"$ss_out"; then
    ok "22/tcp LISTEN"
  else
    warn "22/tcp LISTEN 안 됨"; rc=1
  fi

  step "검증 — 방화벽"
  if [[ "$FIREWALL" == "ufw" ]]; then
    ufw_out="$(sudo ufw status verbose 2>/dev/null || true)"
    if grep -q "Status: active" <<<"$ufw_out"; then
      ok "ufw active"
      grep -E "^(Default:|To|22/tcp|.* 22 )" <<<"$ufw_out" | sed 's/^/  /' || true
    else
      warn "ufw 비활성"; rc=1
    fi
  else
    printf '  방화벽: 미구성 (--firewall none) — 22/tcp 노출을 상위 계층에서 통제한다\n'
  fi

  step "검증 — 호스트 키 지문 (클라이언트 known_hosts 대조용)"
  if [[ -f "$HOST_KEY_PUB" ]]; then
    ssh-keygen -lf "$HOST_KEY_PUB" | sed 's/^/  /'
  else
    warn "$HOST_KEY_PUB 없음"; rc=1
  fi

  step "검증 — 호출 계정 암호 상태"
  local pst
  pst="$(sudo passwd -S "$USER" 2>/dev/null | awk '{print $2}')"
  case "$pst" in
    P)  ok "${USER}: 암호 설정됨 — 비밀번호 인증 가능" ;;
    NP) warn "${USER}: 암호 미설정 — 비밀번호 인증이 실패한다. 'sudo passwd ${USER}' 로 설정한다." ;;
    L)  warn "${USER}: 계정 잠김(L). 'sudo passwd -u ${USER}'." ;;
    *)  warn "${USER}: 암호 상태 확인 불가 ('${pst:-}')" ;;
  esac

  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다. sudo 권한을 가진 일반 계정으로 실행한다."
command -v sudo > /dev/null || die "sudo 가 없다."
[[ $VERIFY_ONLY -eq 1 ]] || sudo -v || die "sudo 권한 확인 실패."

. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu 전용 스크립트다 (감지: ${ID:-unknown})."
ok "${PRETTY_NAME} / $(dpkg --print-architecture)"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

# ── 1. openssh-server 설치·기동 ─────────────────────────────────────────────
step "1. openssh-server 설치·기동"

# apt 캐시가 오래됐거나 openssh-server 가 없으면 갱신 후 설치한다.
if dpkg -s openssh-server > /dev/null 2>&1; then
  ok "openssh-server 이미 설치됨 ($(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null))"
else
  sudo apt-get update -qq || die "apt-get update 실패 — 게스트 네트워크를 확인한다."
  sudo apt-get install -y -qq openssh-server > /dev/null || die "openssh-server 설치 실패"
  ok "openssh-server 설치 완료"
fi

# Ubuntu 22.10+ / 24.04 는 기본이 소켓 활성화(ssh.socket)다. 소켓 활성화에서는
# sshd_config 의 Port·ListenAddress·MaxStartups 가 무시되고 연결마다 인스턴스가
# 뜬다. 클러스터 노드는 상시 데몬이 예측 가능하므로 ssh.service 로 고정한다.
if systemctl list-unit-files ssh.socket > /dev/null 2>&1 \
   && { systemctl is-enabled --quiet ssh.socket || systemctl is-active --quiet ssh.socket; }; then
  sudo systemctl disable --now ssh.socket > /dev/null 2>&1 || true
  warn "ssh.socket(소켓 활성화) 비활성화 — 상시 ssh.service 로 전환"
fi

sudo systemctl unmask ssh.service > /dev/null 2>&1 || true
sudo systemctl enable --now ssh.service > /dev/null 2>&1 || die "ssh.service 기동 실패"
# 소켓 해제 후 서비스가 즉시 포트를 잡았는지 확인한다.
# 출력을 먼저 받아 검사한다 — cmd|grep -q 는 grep 이 파이프를 먼저 닫아 ss 를
# SIGPIPE 로 죽이고 pipefail 이 그 141 을 실패로 만들어 restart 가 헛돈다.
if ! grep -qE '(:|\.)22 ' <<<"$(sudo ss -tlnp 2>/dev/null || true)"; then
  sudo systemctl restart ssh.service; sleep 1
fi
ok "ssh.service enabled + active"

# ── 2. 방화벽 (ufw) ─────────────────────────────────────────────────────────
if [[ "$FIREWALL" == "ufw" ]]; then
  step "2. 방화벽 — ufw (deny incoming, 22/tcp 만 허용)"

  if ! command -v ufw > /dev/null 2>&1; then
    sudo apt-get install -y -qq ufw > /dev/null || die "ufw 설치 실패"
    ok "ufw 설치"
  fi

  # 이 스크립트가 이전에 넣은 규칙만 골라 제거한다(주석 태그로 식별). 사용자가
  # 수동으로 넣은 22 규칙은 건드리지 않는다. 번호는 내림차순으로 지워야 유효하다.
  mapfile -t _ufw_old < <(sudo ufw status numbered 2>/dev/null \
    | grep -F "# ${UFW_TAG}" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)
  for _n in "${_ufw_old[@]}"; do sudo ufw --force delete "$_n" > /dev/null; done
  [[ ${#_ufw_old[@]} -gt 0 ]] && warn "기존 ${UFW_TAG} 규칙 ${#_ufw_old[@]}건 재적용을 위해 제거"

  # 허용 규칙을 enable 보다 먼저 넣는다 — 순서를 뒤집으면 원격 세션이 끊긴다.
  if [[ "$SSH_FROM" == "any" ]]; then
    sudo ufw allow proto tcp from any to any port 22 comment "${UFW_TAG}: sshd any" > /dev/null
    warn "22/tcp 를 전 경로에 허용 (--ssh-from any)"
  else
    sudo ufw allow proto tcp from "$SSH_FROM" to any port 22 comment "${UFW_TAG}: sshd ${SSH_FROM}" > /dev/null
    ok "22/tcp 허용: ${SSH_FROM}"
  fi

  sudo ufw default deny incoming  > /dev/null
  sudo ufw default allow outgoing > /dev/null
  sudo ufw logging low            > /dev/null   # 차단 로그 — 감사 흔적

  # sed -n 1p 는 입력을 끝까지 읽어 SIGPIPE 경합이 없다 (grep -q 와 달리).
  if [[ "$(sudo ufw status 2>/dev/null | sed -n '1p')" == *"Status: active"* ]]; then
    sudo ufw reload > /dev/null
    ok "ufw 활성 — reload"
  else
    sudo ufw --force enable > /dev/null   # --force: 대화형 경고 프롬프트 생략
    ok "ufw 활성화"
  fi
else
  step "2. 방화벽 — 건너뜀 (--firewall none)"
  warn "방화벽을 구성하지 않는다. 22/tcp 노출 범위를 상위 계층에서 통제한다."
fi

# ── 3. 인증 정책 드롭인 생성 ────────────────────────────────────────────────
step "3. 인증 정책 드롭인 — ${DROPIN}"

if [[ -f "$LEGACY_DROPIN" ]]; then
  sudo rm -f "$LEGACY_DROPIN"
  warn "레거시 드롭인 제거: ${LEGACY_DROPIN} — 이 스크립트가 ${DROPIN} 하나로 관리한다"
fi

NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT

{
  printf '# %s 가 생성·관리한다. 수동 편집하지 않는다.\n' "$(basename "$0")"
  printf '# 근거는 00-ssh-server.md. 생성: %s\n\n' "$(date -Is)"
  printf 'PubkeyAuthentication yes\n'
  printf 'KbdInteractiveAuthentication no\n'
  printf 'PermitRootLogin %s\n' "$PERMIT_ROOT"
  printf 'MaxAuthTries 3\n'
  printf 'LoginGraceTime 20\n'
  [[ -n "$ALLOW_USERS" ]] && printf 'AllowUsers %s\n' "${ALLOW_USERS//,/ }"
  printf '\n'
  case "$PASSWORD_AUTH" in
    off)
      printf '# 비밀번호 인증: 전 경로 차단 (zero-trust 기본값)\n'
      printf 'PasswordAuthentication no\n'
      ;;
    lan)
      printf '# 비밀번호 인증: 기본 차단, LAN 격리 대역에서만 허용\n'
      printf 'PasswordAuthentication no\n\n'
      printf 'Match Address %s\n' "$LAN_CIDR"
      printf '    PasswordAuthentication yes\n'
      # Match all 종결자 필수 — Include 이후의 메인 설정 라인이 이 Match 블록에
      # 흡수되는 것을 막는다.
      printf 'Match all\n'
      ;;
    on)
      printf '# 비밀번호 인증: 전 경로 허용 (권장하지 않음)\n'
      printf 'PasswordAuthentication yes\n'
      ;;
  esac
} > "$NEW"

sudo install -m 0644 -o root -g root "$NEW" "$DROPIN"

if ! sudo sshd -t; then
  sudo rm -f "$DROPIN"
  die "sshd -t 실패 — 드롭인을 제거했다. 실행 중 설정은 그대로다."
fi
ok "sshd -t 통과"

sudo systemctl reload ssh || die "reload 실패 — 이전 설정이 유지된다."
ok "reload 완료 (기존 세션 무중단)"

# ── 4. 검증 ─────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

# ── 완료 ────────────────────────────────────────────────────────────────────
step "완료 — 다음 단계"
cat <<NEXT
  기록할 것 — 클라이언트 known_hosts 대조용 호스트 키 지문:
$(ssh-keygen -lf "$HOST_KEY_PUB" 2>/dev/null | sed 's/^/    /')

  다음: 01-ssh-keys.sh 로 공개키를 authorized_keys 에 등록한다 (아직 배치 전이면
        --password-auth lan 없이는 이 노드에 로그인할 수단이 없다).

  등록 후 클라이언트(Mac)에서:
    ssh-keyscan -t ed25519 <이 VM IP> | ssh-keygen -lf -   # 지문 대조
    ssh <user>@<이 VM IP> true && echo OK                  # 접속 확인
    ── 클라이언트가 22/tcp 허용 대역(${SSH_FROM}) 밖이면 방화벽에서 차단된다.

  방화벽 상태:  sudo ufw status verbose
  Docker 설치는 ../docker/00-docker-ce.sh (SSH 접속 구성 완료 후).
NEXT

cat <<'RESIDUAL'

  잔여 위험 / 전제
    - --password-auth lan|on 은 비밀번호 무차별 대입 표면을 연다. OpenSSH 9.6 에는
      PerSourcePenalties(9.8+) 가 없다. 자동 소스 차단이 필요하면 fail2ban 을
      별도 도입한다 — 운영 부담 발생.
    - lan 한정은 Match Address / ufw from 기반이다. VM 에 브리지·추가 NIC 가 붙어
      비 LAN 경로가 생겨도 그 경로에는 22/tcp·비밀번호가 노출되지 않는다 (의도된 동작).
    - 비밀번호 인증이 유효하려면 해당 계정에 강한 암호가 설정돼 있어야 한다.
      암호 미설정(NP)·약한 암호에서는 이 정책이 순손실이다.
    - ufw 는 호스트 자신의 인바운드만 통제한다. 이후 ../docker/00-docker-ce.sh 로
      Docker 를 설치하면 -p 로 게시한 컨테이너 포트는 ufw 를 우회한다 (Docker 가 nat/DOCKER
      체인에 직접 규칙을 삽입, ufw FORWARD 평가보다 먼저). 컨테이너 포트는
      127.0.0.1 바인딩 또는 DOCKER-USER 체인으로 별도 통제한다.
    - ufw 규칙은 --ssh-from 의 주소군만 처리한다. sshd 가 IPv6(::)로도 리슨하면
      v6 경로는 default deny 로 차단된다. vmnet 격리 구성에서는 의도에 부합한다.
    - --firewall none 은 방화벽을 건드리지 않는다. nftables 를 직접 운용하는
      환경에서 쓰고, 22/tcp 범위 통제 책임은 그 계층으로 넘어간다.
    - PermitRootLogin 기본값 prohibit-password 는 root 의 암호·kbd-interactive
      로그인만 차단한다. root 키 로그인은 별도로 통제한다.
    - ssh.socket 을 끄고 ssh.service 로 고정한다. 소켓 활성화를 의도적으로 쓰는
      환경이라면 이 스크립트를 그대로 적용하지 않는다.
    - 호스트 키는 재생성하지 않는다. 기존 클라이언트 known_hosts 를 깨지 않기
      위함이다. 회전이 필요하면 수동으로 수행하고 전 클라이언트에서 지문을 재대조한다.
RESIDUAL
