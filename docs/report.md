# B4-1 요구사항 수행 내역서

## 1. 문단속 (SSH 포트·Root 차단·방화벽)

### 1-1. SSH 포트 20022 + Root 원격 로그인 차단

`/etc/ssh/sshd_config`의 `Port`와 `PermitRootLogin` 줄을 바꾸고, 문법 검사를 통과한 뒤에만 `ssh` 서비스를 재시작했다.

```bash
sudo sed -i -E 's/^#?Port .*/Port 20022/; s/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
grep -nE '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
sudo sshd -T | grep -E '^(port|permitrootlogin)'
sudo sshd -t && sudo systemctl restart ssh
```

- 설정 파일: 14행 `Port 20022`, 33행 `PermitRootLogin no`
- 실제 적용값(`sshd -T`): `port 20022`, `permitrootlogin no`

![sshd 설정](captures/step_1_01_sshd_config.png)

포트 LISTEN 확인(`sudo ss -tulnp | grep sshd`): sshd가 `0.0.0.0:20022`와 `[::]:20022`에서 LISTEN 중이고 22번은 없다.

![ss 결과](captures/step_1_02_ss_sshd.png)

### 1-2. 방화벽(UFW): 20022/tcp, 15034/tcp만 허용

기본 정책을 "들어오는 연결 전부 거부"로 두고 필요한 두 포트만 열었다. 허용 규칙을 먼저 넣고 `enable`을 나중에 해서, 켜는 순간 접속이 막히지 않게 했다.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp
sudo ufw allow 15034/tcp
sudo ufw enable
sudo ufw status verbose
```

`Status: active`, `Default: deny (incoming)`, 허용 규칙은 `20022/tcp`·`15034/tcp`(IPv4·IPv6 각각)뿐이다.

![ufw status](captures/step_1_03_ufw_status.png)

### 1-3. AWS 보안 그룹(`b4-1-sg`)

UFW는 서버 안쪽 방화벽이고 보안 그룹은 AWS가 서버 앞에 두는 바깥 방화벽이라 둘 다 열어야 접속된다. 인바운드 규칙은 TCP 15034, TCP 20022 두 개만 남겼고 기존 22번 규칙은 삭제했다.

![보안 그룹 인바운드](captures/step_1_04_sg_inbound.png)

### 1-4. 설계 선택 (왜)

- **새 포트를 먼저 열고 SSH 포트를 바꿈**: 보안 그룹과 UFW에서 20022를 열지 않은 채 sshd만 바꾸면 서버에 다시 들어갈 수 없다. 그래서 허용 → sshd 변경 → 22 삭제 순서로 했다.
- **`sshd -t && restart`**: 설정 문법이 틀린 채 재시작하면 sshd가 못 떠서 접속이 끊긴다. 검사를 통과해야만 재시작되게 묶었다.
- **`sshd -T`로 실제 적용값 확인**: 설정 파일 줄만 보면 `sshd_config.d/`의 다른 파일이 덮어쓴 값을 놓칠 수 있어서, 합쳐진 최종값도 함께 확인했다.
- **UFW 선택**: Ubuntu 기본 도구라 명령이 짧다.

## 2. 계정·그룹·디렉토리 권한

### 2-1. 그룹과 계정

비밀번호 없이(`--disabled-password`) 계정 3개를 만들고, `sudo -iu <계정>`으로 전환해 쓴다. 기록에 남을 비밀번호가 없다.

```bash
sudo groupadd agent-common
sudo groupadd agent-core
for u in agent-admin agent-dev agent-test; do sudo adduser --disabled-password --gecos "" "$u"; done
sudo usermod -aG agent-common,agent-core agent-admin
sudo usermod -aG agent-common,agent-core agent-dev
sudo usermod -aG agent-common agent-test
id agent-admin; id agent-dev; id agent-test
```

| 계정 | agent-common | agent-core |
|---|---|---|
| agent-admin | O | O |
| agent-dev | O | O |
| agent-test | O | X |

![id 결과](captures/step_2_01_id_groups.png)

### 2-2. 디렉토리와 권한

```bash
sudo apt install -y acl
A=/home/agent-admin/agent-app
sudo setfacl -m g:agent-common:x /home/agent-admin
sudo mkdir -p $A/upload_files $A/api_keys /var/log/agent-app
sudo chown agent-admin:agent-common $A $A/upload_files
sudo chmod 750 $A
sudo chmod 2770 $A/upload_files
sudo setfacl -d -m g:agent-common:rwx $A/upload_files
sudo chown agent-admin:agent-core $A/api_keys /var/log/agent-app
sudo chmod 2770 $A/api_keys /var/log/agent-app
sudo ls -ld /home/agent-admin $A $A/upload_files $A/api_keys /var/log/agent-app
sudo getfacl /home/agent-admin $A/upload_files
```

| 경로 | 소유자:그룹 | 권한 | 의미 |
|---|---|---|---|
| `/home/agent-admin/agent-app` | agent-admin:agent-common | 750 | 세 계정 모두 들어와 목록을 볼 수 있다 |
| `…/upload_files` | agent-admin:agent-common | 2770 + 기본 ACL | agent-common 읽기·쓰기 |
| `…/api_keys` | agent-admin:agent-core | 2770 | agent-core만 읽기·쓰기 |
| `/var/log/agent-app` | agent-admin:agent-core | 2770 | agent-core만 읽기·쓰기 |

![ls -ld와 getfacl](captures/step_2_02_dirs_acl.png)

### 2-3. 접근 확인

agent-test는 `api_keys`·로그 폴더에서 거부되고 `upload_files`에는 쓸 수 있다. agent-dev는 `api_keys`를 읽고 `upload_files`에 쓸 수 있다.

![접근 확인](captures/step_2_03_access_check.png)

### 2-4. 설계 선택 (왜)

- **앱 경로를 예시대로 `/home/agent-admin/agent-app`**: 평가자가 보는 값과 같다. 대신 `adduser`가 만든 홈 폴더(750)는 다른 계정이 지나가지 못하므로 `setfacl -m g:agent-common:x`로 통과(`x`)만 열었다. `chmod o+x`는 계정 밖 모두에게 여는 것이라 그룹 ACL로 범위를 좁혔다.
- **`api_keys`·로그 폴더는 agent-core 전용(770)**: others 권한을 0으로 두면 agent-test(agent-core 아님)가 열 수 없다. 키 파일이 있는 곳이라 최소 권한으로 잡았다.
- **디렉토리에 setgid(`2`)**: 새 파일이 만든 사람의 개인 그룹이 아니라 폴더의 그룹(agent-core / agent-common)을 물려받는다. 이게 없으면 agent-admin이 만든 키·로그 파일을 agent-dev가 못 읽는다.
- **`upload_files`에 기본 ACL(`setfacl -d`)**: 새로 생기는 파일에도 agent-common 쓰기 권한이 유지된다. 일반 권한만 쓰면 만든 사람의 umask에 따라 그룹 쓰기가 빠질 수 있다.

## 3. 환경 변수·키 파일·앱 실행

### 3-1. 앱 파일 배치

과제 첨부 앱 중 서버 구조(`uname -m` = `x86_64`)에 맞는 `agent-app-linux-x86`을 `scp -P 20022`로 EC2에 보내 `$AGENT_HOME`에 두고 agent-admin만 실행하게 했다.

```bash
A=/home/agent-admin/agent-app
sudo mv ~/agent-app-linux-x86 $A/
sudo chown agent-admin:agent-admin $A/agent-app-linux-x86
sudo chmod 750 $A/agent-app-linux-x86
```

### 3-2. 환경 변수와 키 파일

`agent-admin`(`sudo -iu agent-admin`)의 `~/.bashrc` 끝에 변수 5개를 `export`로 추가하고, 키 파일을 만들었다.

```bash
cat >> ~/.bashrc <<'EOF'
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
EOF
source ~/.bashrc
echo agent_api_key_test > $AGENT_KEY_PATH/t_secret.key
cp -p $AGENT_KEY_PATH/t_secret.key $AGENT_KEY_PATH/secret.key
chmod 640 $AGENT_KEY_PATH/t_secret.key $AGENT_KEY_PATH/secret.key
```

키 파일 내용 `agent_api_key_test`는 명세가 정한 테스트 값이다(실제 키 아님).

![환경 변수와 키 파일](captures/step_3_01_env_key.png)

### 3-3. 앱 실행: Boot Sequence와 포트

일반 계정(agent-admin)으로 백그라운드 실행했다. root로는 실행하지 않았다.

```bash
cd $AGENT_HOME
PYTHONUNBUFFERED=1 nohup ./agent-app-linux-x86 > ~/agent-app.out 2>&1 &
cat ~/agent-app.out
ss -ltnp | grep 15034
ps -o pid,ppid,cmd -p "$(pgrep -d, -f agent-app-linux)"
```

Boot Sequence 5단계가 모두 `[OK]`이고 마지막에 `Agent READY`가 출력됐다.

![Boot Sequence](captures/step_3_02_boot_ready.png)

앱이 `0.0.0.0:15034`에서 LISTEN 중이다(PID 50864). 같은 이름의 프로세스가 둘 보이는데, 50862가 부모, 50864가 자식이고 포트를 연 쪽은 자식이다.

![LISTEN](captures/step_3_03_listen.png)

### 3-4. 설계 선택 (왜)

- **명세와 제공 앱이 어긋난 곳을 앱에 맞췄다**: 명세는 `AGENT_KEY_PATH`를 `…/api_keys/t_secret.key`(파일)로 적었지만, 앱은 폴더(`…/api_keys`)를 기대해 `[2/5]`에서 `Key Path Mismatch`로 실패했다. 또 앱은 그 폴더 안의 `secret.key`를 찾아 `[3/5]`에서 `Missing File`로 실패했다. 변수를 폴더 경로로 바꾸고, 명세 이름의 `t_secret.key`는 두고 같은 내용의 `secret.key`를 복사해 둘 다 만족시켰다.
- **환경 변수는 `agent-admin`의 `~/.bashrc`에**: 앱을 터미널에서 켜므로 거기서 읽힌다. cron은 이 파일을 읽지 않아서 `monitor.sh`는 안쪽 기본값으로 따로 처리한다.
- **`nohup … &`로 백그라운드 실행**: 터미널을 닫아도 앱이 유지되어 cron 점검 동안 계속 돈다. `PYTHONUNBUFFERED=1`은 출력이 파일에 바로 쓰이게 한다.
- **프로세스 찾기**: PyInstaller 앱이라 같은 이름 프로세스가 둘(부모·자식) 뜬다. `monitor.sh`는 `pgrep -f agent-app-linux`로 찾는다.
