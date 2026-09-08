# 네트워크 연결 진단

`10.10.10.150` (Ubuntu VM) 에 접속되지 않을 때의 판별 절차.
설치 절차는 [plan.md](plan.md) 참조.

---

## 1. 어느 쪽 문제인지 먼저 가른다

`ping` 은 반복마다 두 단계를 거친다.

```
① sendto()  — 패킷을 커널에 넘겨 밖으로 내보낸다
② 응답 대기 — 상대의 echo reply 를 기다린다
```

어느 단계에서 실패했는지가 출력에 드러난다.

| 출력 | 패킷이 어디까지 갔나 | 원인 위치 |
|---|---|---|
| `ping: sendto: ...` | **나가지 못함** | 송신측(Mac) |
| `Request timeout for icmp_seq N` | 나갔으나 응답 없음 | 경로 또는 수신측(게스트) |
| `64 bytes from ...` | 왕복 성공 | 정상 |

```bash
ping -c 2 10.10.10.150
```

`sendto:` 는 커널이 **송신 자체를 거부**했다는 뜻이다. 패킷이 네트워크에 올라간 적이
없으므로 상대의 상태와는 무관하다. 게스트 방화벽이나 sshd 를 확인해도 소용없다.

### errno 문자열만으로는 구분되지 않는다

macOS 의 로컬 네트워크 권한 차단은 소켓 계층에서 `EHOSTUNREACH` 를 돌려준다.
이는 "라우팅 경로 없음"과 **같은 errno** 이고, `nc` 도 동일한 문구를 쓴다.

```
ping: sendto: No route to host                  ← 송신 실패 (내 쪽)
nc: connectx to ... failed: No route to host    ← 문구는 같지만 판별 불가
```

구분해 주는 것은 `sendto:` 접두사뿐이다.

두 종류가 섞여 출력되기도 한다 — `ping` 은 송신에 실패한 시퀀스에 대해서도 타임아웃을
함께 보고한다. 이 경우 **`sendto:` 가 우선 신호**다.

```
ping: sendto: No route to host          ← ①에서 실패
ping: sendto: No route to host
PING 10.10.10.150 (10.10.10.150): 56 data bytes
Request timeout for icmp_seq 0          ← 보내지도 못한 seq 에 대한 타임아웃
ping: sendto: No route to host
Request timeout for icmp_seq 1
```

---

## 2. 송신측(Mac) — `sendto:` 가 보이는 경우

### 2-1. 로컬 네트워크 권한

가장 흔한 원인이다. macOS 는 로컬 네트워크 접근을 **앱 단위**로 통제한다.

**시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크** 에서 터미널을 실행하는 앱을
허용하고 재시작한다.

Terminal.app 에서는 되는데 다른 앱에서 안 된다면 이것이 원인이다.
어떤 앱의 권한이 필요한지는 프로세스 계보로 확인한다.

```bash
p=$PPID; for i in 1 2 3 4 5; do
  line=$(ps -o ppid=,comm= -p $p) || break
  echo "$p  $(echo $line | cut -d' ' -f2-)"
  p=$(echo $line | awk '{print $1}'); [ "$p" -le 1 ] && break
done
```
```
4160  .../anthropic.claude-code-.../claude
2878  /Applications/Visual Studio Code.app/.../Code Helper (Plugin)
841   /Applications/Visual Studio Code.app/Contents/MacOS/Code
```
최상위 `.app` 이 권한 부여 대상이다.

### 2-2. 라우팅·인터페이스

```bash
route -n get 10.10.10.150
netstat -rn -f inet | grep "^10.10.10"
ifconfig bridge101 | head -5
```

`route -n get` 이 인터페이스를 반환하고 플래그에 `UP` 이 있으면 경로는 정상이다.
`netstat` 의 Expire 열이 `!` 이면 ARP 해석에 실패해 무효화된 엔트리다.

### 2-3. 맥 방화벽

```bash
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

---

## 3. 수신측(게스트) — 타임아웃만 보이는 경우

패킷은 나갔다. VM 또는 그 네트워크가 원인이다.

### 3-1. VM 이 실행 중인가

```bash
ps aux | grep -i vmware-vmx | grep -v grep
```

### 3-2. 게스트가 네트워크에 올라왔는가

호스트에서 ARP·DHCP 기록을 본다.

```bash
arp -a -n | grep bridge101
grep -E "^lease|hardware ethernet" /var/db/vmware/vmnet-dhcpd-vmnet3.leases | tail -8
```

VM 의 MAC 은 `.vmx` 에서 확인한다.

```bash
grep -iE "^ethernet0|displayName" /Users/jarrod/vm/ub24-00.vmwarevm/ub24-00.vmx
```

> **ARP 엔트리는 근거가 약하다.** 캐시 잔존일 수 있고, 다른 터미널에서 실행한 `ping` 이
> 채워 넣은 것일 수도 있다. 같은 MAC 이 여러 IP 에 매핑돼 있으면 DHCP 로 받았던
> 이전 주소가 남은 것이다 — 현재 주소로 오인하지 말 것.

서브넷 전수 확인:

```bash
for i in $(seq 2 254); do
  (ping -c 1 -t 1 10.10.10.$i >/dev/null 2>&1 && echo "UP 10.10.10.$i") &
done; wait
```

### 3-3. 게스트 콘솔에서 확인

여기까지 좁혀지면 원격에서 볼 수 있는 것이 없다. VMware Fusion 콘솔에서 직접 확인한다.

```bash
ip -br a                    # 인터페이스 상태 / 실제 할당 IP / 넷마스크
systemctl status ssh        # sshd 기동 여부
sudo ufw status verbose     # 방화벽 정책
```

| `ip -br a` 결과 | 조치 |
|---|---|
| 인터페이스 `DOWN` | `sudo ip link set <dev> up`, netplan 설정 확인 |
| `UP` 인데 IP 없음 | netplan/DHCP 미적용. 정적 IP 부여 |
| IP 가 다른 값 | 문서의 대상 IP 를 실제 값으로 정정 |
| IP 정상인데 SSH 만 실패 | `openssh-server` 설치 여부, ufw 정책 확인 |

넷마스크도 함께 본다. `/24` 가 아니면 게스트가 `10.10.10.1` 을 같은 네트워크로 보지 않아
응답 경로가 없다.

---

## 4. TCP 계층 — ICMP 는 되는데 SSH 만 안 되는 경우

```bash
nc -v -z -w 4 10.10.10.150 22
```

| 결과 | 의미 |
|---|---|
| `succeeded!` | 포트 도달 정상 |
| `Connection refused` | 호스트 도달 O, **그 포트에 리스너 없음** — sshd 미기동/미설치 |
| `No route to host` | 호스트에 도달 못함 — 1~3 절로 돌아간다 |
| 응답 없이 타임아웃 | 방화벽 DROP |

`Connection refused`(ECONNREFUSED)와 `No route to host`(EHOSTUNREACH)는 다르다.
전자만이 "sshd 를 확인하라"는 신호다.

게스트에서 리스너 확인:

```bash
ss -lntp | grep ":22 "
```

---

## 5. SSH 인증 계층

도달은 되는데 인증에서 막히는 경우.

```bash
ssh -o BatchMode=yes groom@10.10.10.150 true && echo OK
ssh -v groom@10.10.10.150 true 2>&1 | grep "Authentications that can continue"
```

```
debug1: Authentications that can continue: publickey
```

- `publickey` 만 → 비밀번호 인증 차단 적용됨. 키가 없으면 접속 불가
- `publickey,password` → 비밀번호 인증이 열려 있다

> **설정 파일과 데몬 상태는 다르다.** `sshd -T` 는 디스크의 설정을 읽을 뿐이다.
> 상시 데몬(`ssh.service`)이 `:22` 를 잡고 있으면 기동 시점의 설정을 메모리에 유지하므로,
> `reload` 전까지 변경이 반영되지 않는다. **실제 적용 여부의 유일한 증거는
> 서버가 광고하는 인증 수단 목록**이다.

```bash
systemctl is-active ssh.socket ssh.service
sudo systemctl reload ssh.service
```

키가 여러 개인 환경에서 `MaxAuthTries` 초과로 거부된다면 `~/.ssh/config` 에
`IdentitiesOnly yes` 를 지정한다.
