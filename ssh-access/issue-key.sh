#!/usr/bin/env bash
#
# issue-key.sh — "AWS EC2 에서 .pem 받기"와 같은 경험을 로컬 랩에서 재현한다.
# Mac 에서 실행해 새 키페어를 만들고, 이미 동작하는 자격증명으로 노드에
# authorized_keys 등록까지 자동으로 끝낸 뒤 접속 명령을 출력한다.
# 근거·전제·잔여 위험은 01-ssh-keys.md 「AWS 스타일 키 발급」 절에 있다.
# 실행 위치: macOS (10.10.10.1)
#
# EC2 와의 구조적 차이 — 반드시 읽는다:
#   EC2 는 인스턴스 최초 부팅 시 클라우드 제어평면(cloud-init)이 키를 심는다.
#   사전 SSH 접근이 전혀 없어도 된다. 이 랩에는 그 제어평면이 없다 — 새 키를
#   노드에 넣으려면 "이미 동작하는 자격증명"이 하나 있어야 한다. 이 스크립트는
#   그 자격증명(기본 SSH 설정으로 --host 에 이미 접속되는 키)을 통해 새 키를
#   찍어낸다. 즉 무(無)에서 부팅하는 게 아니라 기존 신뢰를 증폭한다 — 겉보기
#   경험은 같아도 신뢰 모델은 다르다.
#
# 역할: 실행 도구. 01-ssh-keys.sh 의 authorized_keys 등록 로직을 그대로
#       재사용한다(중복 구현하지 않는다) — 원격으로 그 스크립트를 옮겨 실행한다.
#
set -euo pipefail

HOST="10.10.10.150"
USER_NAME="groom"
KEY_NAME=""
RESTRICT_CIDR=""
OUTDIR="${HOME}/.ssh/issued"

usage() {
  cat <<'USAGE'
사용법: ./issue-key.sh [옵션]

  --host <ip>            대상 노드 (기본: 10.10.10.150)
  --user <name>          원격 계정 (기본: groom)
  --name <label>         키 이름/코멘트 (기본: <user>-<host 마지막 옥텟>-<타임스탬프>)
  --restrict-cidr <cidr> 원격 01-ssh-keys.sh 에 전달 — authorized_keys 의 from= 제한
  --outdir <dir>         발급 키 저장 위치 (기본: ~/.ssh/issued)
  -h, --help             도움말

전제: --host 에 이미 접속 가능한 SSH 신원(에이전트·~/.ssh/config·기본 키)이
있어야 한다. 이 스크립트는 새 키를 "무(無)에서" 심지 않는다 — 기존 신뢰를
증폭할 뿐이다. 아무 신원도 없으면 게스트 콘솔에서 01-ssh-keys.sh 를 먼저 실행한다.

종료 코드: 0 성공 / 1 전제·검증 실패 / 2 인자 오류
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
    --host)           HOST="${2:?}"; shift 2 ;;
    --user)           USER_NAME="${2:?}"; shift 2 ;;
    --name)           KEY_NAME="${2:?}"; shift 2 ;;
    --restrict-cidr)  RESTRICT_CIDR="${2:?}"; shift 2 ;;
    --outdir)         OUTDIR="${2:?}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; exit 2 ;;
  esac
done

TARGET="${USER_NAME}@${HOST}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -n "$KEY_NAME" ]] || KEY_NAME="${USER_NAME}-${HOST##*.}-$(date +%Y%m%d%H%M%S)"
KEYFILE="${OUTDIR}/${KEY_NAME}.pem"

# ── 0. 부트스트랩 자격증명 확인 ───────────────────────────────────────────────
step "0. 부트스트랩 자격증명 확인 — ${TARGET}"

ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" true 2>/dev/null \
  || die "이미 동작하는 SSH 신원이 없다. EC2 의 cloud-init 에 해당하는 제어평면이
       이 랩엔 없다 — 게스트 콘솔에서 01-ssh-keys.sh 를 먼저 실행하거나,
       기존에 등록된 키가 ~/.ssh/config·에이전트로 잡히는지 확인한다."
ok "부트스트랩 신원으로 ${TARGET} 접속 확인"

[[ -e "$KEYFILE" || -e "${KEYFILE}.pub" ]] \
  && die "이미 있다: ${KEYFILE}(.pub). --name 을 바꾸거나 기존 파일을 정리한다."

# ── 1. 키페어 발급 ───────────────────────────────────────────────────────────
step "1. 키페어 발급 — ${KEYFILE}"

install -d -m 700 "$OUTDIR"
# -m PEM: AWS 콘솔이 주는 .pem 과 같은 PKCS1 형식(-----BEGIN RSA PRIVATE KEY-----).
ssh-keygen -q -t rsa -b 2048 -m PEM -f "$KEYFILE" -N '' -C "$KEY_NAME" \
  || die "키 생성 실패"
chmod 400 "$KEYFILE"
ok "생성 완료, 권한 400"

# ── 2. authorized_keys 원격 등록 (01-ssh-keys.sh 재사용) ─────────────────────
step "2. 노드에 공개키 등록"

REMOTE_TMP="/tmp/issue-key.$$"
ssh "$TARGET" "install -d -m 700 '$REMOTE_TMP'" || die "원격 임시 디렉터리 생성 실패"
scp -q "${SCRIPT_DIR}/01-ssh-keys.sh" "${TARGET}:${REMOTE_TMP}/01-ssh-keys.sh" \
  || die "01-ssh-keys.sh 전송 실패"
scp -q "${KEYFILE}.pub" "${TARGET}:${REMOTE_TMP}/${KEY_NAME}.pub" \
  || die "공개키 전송 실패"

REMOTE_CMD="bash '${REMOTE_TMP}/01-ssh-keys.sh' --authorized-key-file '${REMOTE_TMP}/${KEY_NAME}.pub'"
[[ -n "$RESTRICT_CIDR" ]] && REMOTE_CMD+=" --restrict-cidr '${RESTRICT_CIDR}'"
REMOTE_CMD+="; rc=\$?; rm -rf '${REMOTE_TMP}'; exit \$rc"

ssh "$TARGET" "$REMOTE_CMD" || die "원격 등록 실패 (01-ssh-keys.sh 출력 참조)"
ok "authorized_keys 등록 완료"

# ── 3. 새 키 단독 검증 ────────────────────────────────────────────────────────
step "3. 새 키만으로 접속 검증 (기존 신원 배제)"

ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 \
    -i "$KEYFILE" "$TARGET" true \
  || die "새 키로 접속 실패 — 등록은 됐는데 인증이 안 된다. sshd 설정을 확인한다."
ok "새 키 단독 인증 성공"

step "발급 완료"
cat <<NEXT

  ──────────────────────────────────────────────────────────────
   키가 발급됐다. 이 파일을 잘 보관한다 — 분실 시 재발급 절차가 없다
   (이 스크립트를 다시 돌려 새 키를 추가로 발급하는 것 외에는 복구 수단이 없다).

     키 파일:  ${KEYFILE}   (권한 400)

   접속:
     ssh -i ${KEYFILE} ${TARGET}
  ──────────────────────────────────────────────────────────────

NEXT

cat <<'RESIDUAL'
  잔여 위험 / 전제
    - "이미 동작하는 자격증명"으로 부트스트랩한다. EC2 의 cloud-init 처럼 무에서
      키를 심는 게 아니다 — 그 자격증명이 이미 침해돼 있으면 이 스크립트도 그
      침해를 물려받는다.
    - 발급한 개인키(.pem)는 이 스크립트가 유일하게 아는 사본이다. 백업·회전
      절차는 별도로 정한다. 폐기하려면 노드의 authorized_keys 에서 해당 줄을
      직접 지운다 (01-ssh-keys.md 참조 — 이 스크립트는 폐기를 하지 않는다).
    - RSA 2048 PEM 은 AWS 콘솔 키와 형태를 맞추기 위한 선택이다. 신규 발급
      기본값으로는 ed25519 가 낫다 — 데모 목적이 아니면 -t ed25519 로 바꾼다.
    - --restrict-cidr 를 주지 않으면 이 키는 무제한이다. 실습 키를 배포·보관할
      계획이면 지정한다.
RESIDUAL
