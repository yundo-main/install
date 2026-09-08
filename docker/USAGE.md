# 실행 절차

> **역할: 운영 매뉴얼.** 무엇을 어떤 순서로 실행하는지, 어떤 위험을 수용하는지 다룬다.
> 절차의 근거와 기대 출력은 [plan.md](plan.md), 디렉터리 구성은 [README.md](README.md) 에 있다.

## 실행 순서

### 1. 클라이언트 — SSH 키 인증

게스트 콘솔에서 호스트 키 지문을 먼저 확인한다.

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Mac 에서 그 값을 넘겨 실행한다.

```bash
./ssh-setup.sh --expect-fpr SHA256:HzsGa1MYvEl4YPh4sZ5kZGQ4mBcv6zVGmKYD8LqnS5A
```

비밀번호 인증 차단은 키 인증이 **검증된 뒤** 별도 실행으로 적용한다.

```bash
./ssh-setup.sh --disable-password
```

`--expect-fpr` 를 생략하면 지문을 출력하고 대화형 확인을 요구한다.
`--yes` 는 `--expect-fpr` 없이는 동작하지 않는다 — 무검증 TOFU 를 허용하지 않는다.

### 2. 서버 — Docker CE

```bash
scp docker-install.sh groom@10.10.10.150:~/
ssh -t groom@10.10.10.150 'bash ~/docker-install.sh'
```

`sudo` 비밀번호 프롬프트 때문에 `-t` 가 필요하다.

## 주요 옵션

`ssh-setup.sh`

| 옵션 | 설명 |
|---|---|
| `--host` / `--user` / `--key` | 대상·계정·배포할 공개키 (기본 `10.10.10.150` / `groom` / `~/.ssh/id_rsa.pub`) |
| `--expect-fpr <SHA256:...>` | 호스트 키 지문 고정. 불일치 시 중단 |
| `--disable-password` | 키 인증 검증 성공 후에만 비밀번호 인증 차단 |

`docker-install.sh`

| 옵션 | 설명 |
|---|---|
| (기본) | docker 그룹 미부여. `sudo docker` 로 사용 |
| `--docker-group` | 호출 계정을 docker 그룹에 추가 (**root 등가 권한 부여**) |
| `--skip-daemon-config` | `/etc/docker/daemon.json` 구성 생략 |
| `--force-daemon-config` | 기존 daemon.json 이 다르면 백업 후 덮어쓰기 |
| `--verify-only` | 설치 없이 검증만 수행 |

## 설계상 고정한 통제

- **GPG 지문 고정**: `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` 과 대조한 뒤에만
  `/etc/apt/keyrings` 에 배치한다. 불일치 시 중단한다.
- **`signed-by=`**: 키의 서명 권한을 Docker 저장소로만 한정한다. `apt-key add` 는 쓰지 않는다.
- **순서 강제**: 키 인증 검증(`ssh -o PasswordAuthentication=no`)이 성공하지 않으면
  비밀번호 인증을 차단하지 않는다.
- **상태 기반 검증**: 설정 파일이 아니라 `docker info`, `docker network inspect`,
  컨테이너 내 `/proc/self/status` 로 확인한다.
- **최소 권한 기본값**: docker 그룹 부여는 명시적 opt-in 이다.
- **비파괴 기본값**: 기존 `daemon.json` 은 명시적 `--force-daemon-config` 없이 덮어쓰지 않는다.

## 잔여 위험

- `icc=false` 는 기본 bridge 네트워크에만 적용된다. 사용자 정의 네트워크의
  컨테이너 간 통신은 통제되지 않는다.
- `no-new-privileges` 는 컨테이너 내 setuid 바이너리를 무력화한다. 이에 의존하는
  이미지는 실패한다.
- 방화벽(ufw/nftables)은 구성하지 않는다. Docker 는 자체 iptables 규칙을 삽입하므로
  `-p` 포트 공개 범위를 별도로 통제해야 한다.
- 스크립트는 패키지 버전을 고정하지 않는다. 재현 가능한 빌드가 필요하면
  `apt-get install docker-ce=<version>` 으로 핀을 건다.
