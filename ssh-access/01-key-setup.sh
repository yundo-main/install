#!/usr/bin/env bash
#
# 01-key-setup.sh — Mac 에서 로컬로 실행해 노드 접속용 SSH 키페어를 만들고,
# 그 .pub 을 노드로 전송한다. 근거·기대 출력·사용법은 01-key-setup.md 에 있다.
# 실행 위치: macOS (클라이언트)
#
# 설계 원칙
#   - 개인키는 이 스크립트를 실행한 Mac 을 벗어나지 않는다. 노드로 가는 것은
#     .pub(공개키) 뿐이다.
#   - 비파괴: 대상 키 파일이 이미 있으면 덮어쓰지 않고 중단한다.
#   - 전송(2단계)은 비밀번호 인증이 이미 켜져 있어야 동작한다
#     (00-ssh-server.md 의 PasswordAuthentication yes/lan 설정). 꺼져 있으면
#     scp 자체가 안 되므로 --skip-transfer 로 생성까지만 하고, 전송은
#     00-ssh-server.md 의 콘솔 붙여넣기 절차를 수동으로 따른다.
#   - 등록(authorized_keys 반영)은 이 스크립트의 범위 밖이다 — 02-ssh-keys.sh
#     가 노드에서 직접 한다. 전송과 등록을 분리해, "개인키가 어디까지 갔는지"와
#     "누가 노드를 신뢰하는지"를 한 스크립트에 섞지 않는다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 01-key-setup.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 문서와 어긋나면 문서가 기준이다.
#
set -euo pipefail

KEY_NAME="lab_groom"
OUTDIR="${HOME}/.ssh"
KEY_TYPE="ed25519"
COMMENT=""
HOST="10.10.10.150"
USER_NAME="groom"
SKIP_TRANSFER=0
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: ./01-key-setup.sh [옵션]

  --name <label>    키 파일 이름 (기본: lab_groom) — <outdir>/<name>[.pub] 로 저장
  --outdir <dir>    저장 위치 (기본: ~/.ssh)
  --type <type>     ssh-keygen -t 값 (기본: ed25519)
  --comment <text>  키 코멘트 (기본: "<name>-<YYYYMM>")
  --host <ip>       전송 대상 노드 (기본: 10.10.10.150)
  --user <name>     원격 계정 (기본: groom)
  --skip-transfer   생성만 하고 전송은 하지 않는다 (비밀번호 인증이 꺼져 있을 때)
  --verify-only     생성·전송 없이 기존 키 상태만 표시한다
  -h, --help        도움말

전송(scp)은 대상 노드의 비밀번호 인증이 켜져 있어야 동작한다
(00-ssh-server.md --password-auth lan|on). 꺼져 있으면 --skip-transfer 로
생성까지만 하고, 00-ssh-server.md 의 콘솔 붙여넣기 절차로 수동 전송한다.

종료 코드: 0 성공 / 1 검증·생성·전송 실패 / 2 인자 오류
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
    --name)           KEY_NAME="${2:?}"; shift 2 ;;
    --outdir)         OUTDIR="${2:?}"; shift 2 ;;
    --type)           KEY_TYPE="${2:?}"; shift 2 ;;
    --comment)        COMMENT="${2:?}"; shift 2 ;;
    --host)           HOST="${2:?}"; shift 2 ;;
    --user)           USER_NAME="${2:?}"; shift 2 ;;
    --skip-transfer)  SKIP_TRANSFER=1; shift ;;
    --verify-only)    VERIFY_ONLY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; exit 2 ;;
  esac
done

KEYFILE="${OUTDIR}/${KEY_NAME}"
TARGET="${USER_NAME}@${HOST}"
[[ -n "$COMMENT" ]] || COMMENT="${KEY_NAME}-$(date +%Y%m)"

# ── 검증 (생성 후 및 --verify-only 공용) ─────────────────────────────────────
verify_all() {
  local rc=0

  step "검증 — 키 파일"
  if [[ -f "$KEYFILE" && -f "${KEYFILE}.pub" ]]; then
    local perm
    perm="$(stat -f '%Lp' "$KEYFILE" 2>/dev/null || stat -c '%a' "$KEYFILE")"
    printf '  개인키: %s (권한 %s, 600 이어야 한다)\n' "$KEYFILE" "$perm"
    [[ "$perm" == "600" ]] || { warn "개인키 권한이 600 이 아니다"; rc=1; }
    printf '  공개키: %s\n' "${KEYFILE}.pub"
    ssh-keygen -lf "${KEYFILE}.pub" | sed 's/^/  지문: /'
  else
    warn "${KEYFILE}(.pub) 없음"; rc=1
  fi

  return $rc
}

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_all && { step "검증 통과"; exit 0; } || die "검증 실패"
fi

# ── 0. 사전 요건 ─────────────────────────────────────────────────────────────
step "0. 사전 요건"

command -v ssh-keygen > /dev/null || die "ssh-keygen 이 없다."
[[ -e "$KEYFILE" || -e "${KEYFILE}.pub" ]] \
  && die "이미 있다: ${KEYFILE}(.pub). --name 을 바꾸거나 기존 파일을 정리한다."
install -d -m 700 "$OUTDIR"
ok "저장 위치: $OUTDIR"

# ── 1. 키페어 생성 ───────────────────────────────────────────────────────────
step "1. 키페어 생성 — ${KEYFILE}"

# 무암호(-N ''): 자동화·실습용. 개인키 파일 권한(600)이 유일한 방어선이다.
ssh-keygen -q -t "$KEY_TYPE" -f "$KEYFILE" -N '' -C "$COMMENT" \
  || die "키 생성 실패"
chmod 600 "$KEYFILE"
chmod 644 "${KEYFILE}.pub"
ok "생성 완료"

verify_all || die "검증 실패 — 위 항목을 확인한다."

# ── 2. 노드로 전송 ───────────────────────────────────────────────────────────
if [[ $SKIP_TRANSFER -eq 1 ]]; then
  step "2. 전송 — 건너뜀 (--skip-transfer)"
  warn "00-ssh-server.md 의 콘솔 붙여넣기 절차로 ${KEYFILE}.pub 을 직접 옮긴다."
else
  step "2. 노드로 전송 — 비밀번호를 입력한다 (${TARGET})"
  if scp -q "${KEYFILE}.pub" "${TARGET}:~/$(basename "$KEYFILE").pub"; then
    ok "전송 완료: ~/$(basename "$KEYFILE").pub (노드, ${TARGET})"
  else
    warn "전송 실패 — 비밀번호 인증이 꺼져 있으면 scp 자체가 안 된다."
    warn "00-ssh-server.md 의 콘솔 붙여넣기 절차로 수동 전송한다."
  fi
fi

step "완료 — 다음 단계"
cat <<NEXT
  노드에서 (콘솔 또는 비밀번호로 SSH 접속해서):
    bash 02-ssh-keys.sh --authorized-key-file ~/$(basename "$KEYFILE").pub

  등록 후, 아직 첫 접속·지문 대조를 안 했다면 00-ssh-server.md 의 수동 접속
  절차를 따른다.
NEXT

cat <<'RESIDUAL'

  잔여 위험 / 전제
    - 무암호(-N '') 키다. 개인키 파일 권한(600)이 유일한 방어선이다 — 이 Mac
      계정 자체가 침해되면 이 키도 함께 침해된다.
    - 이미 있는 파일은 덮어쓰지 않는다(비파괴). 키를 교체하려면 --name 으로
      새 이름을 쓰고, 노드의 authorized_keys 에서 구 키를 수동으로 제거한다.
    - 전송(scp)은 비밀번호 인증에 의존한다 — 부트스트랩 자격증명으로 쓰는
      실습 지름길이다. 콘솔 붙여넣기와 달리 노드에 도착한 파일의 지문을 눈으로
      대조하는 단계가 없다: scp 성공 자체를 신뢰의 근거로 삼는다.
    - 실습·랩 환경에서 개인키를 git 에 두어야 한다면: 가능하면 공개키만
      커밋하고(.gitignore 로 개인키 차단), 부득이하면 private 리포 + 이 노드
      전용 폐기 가능한 키 + 02-ssh-keys.sh --restrict-cidr 조합을 쓴다.
RESIDUAL
