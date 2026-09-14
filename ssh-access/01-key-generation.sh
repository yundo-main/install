#!/usr/bin/env bash
#
# 01-key-generation.sh — Mac 에서 로컬로 실행해 노드 접속용 SSH 키페어를
# 만든다. 근거·기대 출력·사용법은 01-key-generation.md 에 있다.
# 실행 위치: macOS (클라이언트)
#
# 설계 원칙
#   - 개인키는 이 스크립트를 실행한 Mac 을 벗어나지 않는다. 노드로 가는 것은
#     02-ssh-keys.sh 에 넘기는 .pub(공개키) 뿐이다.
#   - 비파괴: 대상 파일이 이미 있으면 덮어쓰지 않고 중단한다. 새 키가 필요하면
#     --name 으로 다른 이름을 쓴다.
#   - 기본은 무암호(-N '') 자동화 키다 — 파일 시스템 권한(600)이 유일한 방어선
#     이라는 것을 잔여 위험에 명시한다.
#
# 관계: 여기서 만든 .pub 을 02-ssh-keys.sh(노드 로컬)로 등록한다. 이후 반복
#       발급이 필요하면 04-issue-key.sh(Mac)가 이 단계+등록+검증을 대신한다.
#
# 역할: 실행 도구. 절차의 근거·기대 출력·사용법은 01-key-generation.md 에 있다.
#       여기에 절차 설명을 복제하지 않는다. 코드가 문서와 어긋나면 문서가 기준이다.
#
set -euo pipefail

KEY_NAME="lab_groom"
OUTDIR="${HOME}/.ssh"
KEY_TYPE="ed25519"
COMMENT=""
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
사용법: ./01-key-generation.sh [옵션]

  --name <label>    키 파일 이름 (기본: lab_groom) — <outdir>/<name>[.pub] 로 저장
  --outdir <dir>    저장 위치 (기본: ~/.ssh)
  --type <type>     ssh-keygen -t 값 (기본: ed25519)
  --comment <text>  키 코멘트 (기본: "<name>-<YYYYMM>")
  --verify-only     생성 없이 기존 키 상태만 표시한다
  -h, --help        도움말

이미 있는 키를 재사용하려면 이 스크립트를 건너뛰고 그 파일의 .pub 을 바로
02-ssh-keys.sh 에 넘긴다. 이 스크립트는 새 키를 만드는 경로만 다룬다.

종료 코드: 0 성공 / 1 검증·생성 실패 / 2 인자 오류
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
    --name)         KEY_NAME="${2:?}"; shift 2 ;;
    --outdir)       OUTDIR="${2:?}"; shift 2 ;;
    --type)         KEY_TYPE="${2:?}"; shift 2 ;;
    --comment)      COMMENT="${2:?}"; shift 2 ;;
    --verify-only)  VERIFY_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; exit 2 ;;
  esac
done

KEYFILE="${OUTDIR}/${KEY_NAME}"
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

# ── 2. 검증 ─────────────────────────────────────────────────────────────────
verify_all || die "검증 실패 — 위 항목을 확인한다."

step "완료 — 다음 단계"
cat <<NEXT
  공개키(.pub)만 노드로 옮긴다 — 개인키는 이 Mac 을 벗어나지 않는다.

    ${KEYFILE}.pub

  노드로 전달(git clone, wget, 공유 폴더, 콘솔 붙여넣기 중 택1) 후, 노드에서:
    bash 02-ssh-keys.sh --authorized-key-file ~/$(basename "$KEYFILE").pub
NEXT

cat <<'RESIDUAL'

  잔여 위험 / 전제
    - 무암호(-N '') 키다. 개인키 파일 권한(600)이 유일한 방어선이다 — 이 Mac
      계정 자체가 침해되면 이 키도 함께 침해된다.
    - 이미 있는 파일은 덮어쓰지 않는다(비파괴). 키를 교체하려면 --name 으로
      새 이름을 쓰고, 노드의 authorized_keys 에서 구 키를 수동으로 제거한다.
    - 실습·랩 환경에서 개인키를 git 에 두어야 한다면: 가능하면 공개키만
      커밋하고(.gitignore 로 개인키 차단), 부득이하면 private 리포 + 이 노드
      전용 폐기 가능한 키 + 02-ssh-keys.sh --restrict-cidr 조합을 쓴다.
RESIDUAL
