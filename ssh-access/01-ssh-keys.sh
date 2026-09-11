#!/usr/bin/env bash
#
# 01-ssh-keys.sh — 대상 노드에서 로컬로 실행해 공개키를 authorized_keys 에
# 등록한다. 근거·기대 출력·사용법은 01-ssh-keys.md 에 있다.
# 실행 위치: Ubuntu 24.04 VM 게스트 콘솔 또는 로컬 세션 (SSH·클라이언트 불필요)
#
# 설계 원칙
#   - 키페어는 생성하지 않는다. 사전에 준비된 공개키 파일을 받아 배치만 한다 —
#     개인키 취급(생성·보관·전달)을 이 스크립트의 신뢰 경계 밖에 둔다.
#   - 비파괴: 이미 있는 키(타입+본문 동일)는 옵션이 다르면 건너뛰고 경고한다.
#     authorized_keys 의 기존 줄을 자동으로 고쳐 쓰지 않는다 — 접속 수단을
#     스크립트가 실수로 좁히는 것을 막는다.
#   - 최소 노출: --restrict-cidr 로 개인키 유출 시 피해 범위를 LAN 대역으로
#     한정하는 옵션을 기본 제공한다 (authorized_keys 의 from= 제한).
#
# 관계: 00-ssh-server.sh 가 sshd·방화벽·인증 정책을, 02-ssh-client.sh 가
#       클라이언트 측 호스트 키 대조·접속 검증을 담당한다. 이 스크립트는 그
#       사이 — "이 공개키로 로그인을 허용한다"만 다룬다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 01-ssh-keys.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 01-ssh-keys.md 와 어긋나면
#       문서가 기준이다. 게스트에서 단독 실행되므로 자기완결적이어야 한다.
#
set -euo pipefail

readonly KEY_TYPES_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]'

AUTHORIZED_KEY_FILE=""
RESTRICT_CIDR=""
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: bash 01-ssh-keys.sh --authorized-key-file <path> [옵션]

  --authorized-key-file <path>  호출 계정 ~/.ssh/authorized_keys 에 추가할 공개키
                                  파일 (여러 줄 가능). 키 문자열을 인자로 받지
                                  않는 이유는 셸 history 노출을 피하기 위함이다.
  --restrict-cidr <cidr>        추가하는 각 키에 authorized_keys 의 from="<cidr>"
                                  제한을 붙인다. 개인키가 유출돼도 이 대역 밖에서는
                                  무효화된다.
  --verify-only                 변경 없이 authorized_keys 현재 상태만 표시한다
  -h, --help                    도움말

키 생성은 이 스크립트의 범위 밖이다. 미리 준비한 키를 쓴다:
  ssh-keygen -t ed25519 -f ~/.ssh/lab_groom -C "lab-groom-$(date +%Y%m)" -N ''

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
    --authorized-key-file) AUTHORIZED_KEY_FILE="${2:?}"; shift 2 ;;
    --restrict-cidr)       RESTRICT_CIDR="${2:?}"; shift 2 ;;
    --verify-only)         VERIFY_ONLY=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage >&2; exit 2 ;;
  esac
done

readonly AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"

# ── 검증 (적용 후 및 --verify-only 공용) ─────────────────────────────────────
verify_all() {
  local rc=0

  step "검증 — ${HOME}/.ssh 권한"
  if [[ -d "${HOME}/.ssh" ]]; then
    stat -c '  %a %n' "${HOME}/.ssh" 2>/dev/null || stat -f '  %Lp %N' "${HOME}/.ssh"
    [[ "$(stat -c '%a' "${HOME}/.ssh" 2>/dev/null || stat -f '%Lp' "${HOME}/.ssh")" == "700" ]] \
      || { warn "${HOME}/.ssh 가 700 이 아니다"; rc=1; }
  else
    warn "${HOME}/.ssh 없음"; rc=1
  fi

  step "검증 — authorized_keys"
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    local perm
    perm="$(stat -c '%a' "$AUTHORIZED_KEYS" 2>/dev/null || stat -f '%Lp' "$AUTHORIZED_KEYS")"
    printf '  권한: %s (600 이어야 한다)\n' "$perm"
    [[ "$perm" == "600" ]] || { warn "authorized_keys 가 600 이 아니다"; rc=1; }
    printf '  등록된 키 %s개:\n' "$(grep -cE "$KEY_TYPES_RE" "$AUTHORIZED_KEYS" || true)"
    grep -E "$KEY_TYPES_RE" "$AUTHORIZED_KEYS" | sed -E 's/^/    /; s/(AAAA[A-Za-z0-9+\/=]{20}).*/\1.../' || true
  else
    warn "authorized_keys 없음 — 이 계정으로 키 로그인이 불가하다"; rc=1
  fi

  return $rc
}

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

[[ "$(id -u)" -ne 0 ]] || die "root 로 직접 실행하지 않는다. sudo 권한을 가진 일반 계정으로 실행한다."
[[ "$(uname -s)" == "Linux" ]] \
  || die "이 스크립트는 대상 노드(Linux)에서 실행한다. macOS 클라이언트 설정은 02-ssh-client.sh."

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

[[ -n "$AUTHORIZED_KEY_FILE" ]] || { usage >&2; die "--authorized-key-file 가 필요하다."; }
[[ -f "$AUTHORIZED_KEY_FILE" ]] || die "키 파일이 없다: $AUTHORIZED_KEY_FILE"

# ── 1. authorized_keys 배치 ──────────────────────────────────────────────────
step "1. authorized_keys 배치 — ${AUTHORIZED_KEYS}"

install -d -m 700 "${HOME}/.ssh"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

added=0 skipped=0 conflicts=0
while IFS= read -r line; do
  # 유효한 키 타입으로 시작하는 줄만 취한다. 주석·빈 줄·옵션 붙은 줄은 무시.
  [[ "$line" =~ $KEY_TYPES_RE ]] || continue

  # 옵션(from=...)·코멘트 유무와 무관하게 "타입 base64" 만으로 동일 키를 식별한다.
  core="$(awk '{print $1, $2}' <<<"$line")"

  if [[ -n "$RESTRICT_CIDR" ]]; then
    out="from=\"${RESTRICT_CIDR}\" ${line}"
  else
    out="$line"
  fi

  if grep -qF "$core" "$AUTHORIZED_KEYS"; then
    if grep -qxF "$out" "$AUTHORIZED_KEYS"; then
      skipped=$((skipped + 1))
    else
      warn "이미 등록된 키인데 옵션이 다르다 — 자동으로 바꿔 쓰지 않는다."
      warn "  키: ${core:0:30}...  기존 줄과 authorized_keys 를 직접 비교해 정리한다."
      conflicts=$((conflicts + 1))
    fi
    continue
  fi

  printf '%s\n' "$out" >> "$AUTHORIZED_KEYS"
  added=$((added + 1))
done < "$AUTHORIZED_KEY_FILE"

ok "추가 ${added} / 중복 건너뜀 ${skipped} / 옵션 충돌(수동 확인 필요) ${conflicts}"
[[ $conflicts -eq 0 ]] || warn "충돌이 있다 — authorized_keys 를 열어 의도한 줄만 남긴다."

# ── 2. 검증 ─────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

step "완료 — 다음 단계"
cat <<NEXT
  클라이언트(Mac)에서 무암호 접속 확인:
    ssh <user>@<이 VM IP> true && echo OK

  아직 안 됐으면 00-ssh-server.sh 로 sshd·방화벽·인증 정책을 먼저 구성했는지,
  02-ssh-client.sh 로 호스트 키 지문을 대조했는지 확인한다.
NEXT

cat <<'RESIDUAL'

  잔여 위험 / 전제
    - 이 스크립트는 키를 생성하지 않는다. 개인키의 생성·보관·전달(scp/wget/콘솔
      붙여넣기)은 운영자 책임이다. 실습 등 개인키를 git 에 올려야 하는 상황이면
      --restrict-cidr 로 최소한 사용 범위를 LAN 대역으로 좁힌다.
    - --restrict-cidr 는 authorized_keys 의 from= 만 건다. 개인키 자체의 비밀성은
      보장하지 않는다 — 유출 시 회전(authorized_keys 에서 제거)이 유일한 대응이다.
    - 옵션이 다른 동일 키가 이미 있으면 자동으로 병합·교체하지 않는다. 무제한
      키(from= 없음)가 남아 있으면 --restrict-cidr 로 추가한 제한이 무의미해진다 —
      conflicts 경고가 뜨면 직접 정리한다.
    - authorized_keys 자체는 이 스크립트가 유일하게 관리하지 않는다. 다른 도구
      (ssh-copy-id 등)가 같은 파일에 쓸 수 있다 — 02-ssh-client.sh 의 ssh-copy-id
      경로와 병행 사용 시 위 옵션 충돌 검사로 걸러진다.
RESIDUAL
