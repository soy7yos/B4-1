# B4-1 컴퓨터가 알아서 자기 상태를 점검하게 만들기

AWS EC2(Ubuntu 22.04)에 보안·계정·권한을 설정하고, 과제 첨부 앱(`agent-app`)의 프로세스·포트·CPU/MEM/DISK를 매분 점검해 `monitor.log`에 남기는 Bash 스크립트 `monitor.sh`를 만든 기록입니다. 스크립트와 **수행내역서**가 결과물입니다. (첨부 앱은 재배포하지 않아 repo에 없습니다.)

- 스크립트: [bin/monitor.sh](bin/monitor.sh)
- 수행내역서: [docs/report.md](docs/report.md) — 설정 명령, 증거 캡처, 설계 이유가 절마다 들어 있습니다.
- 증거 캡처: [docs/captures/](docs/captures/)

## 사용법

서버에 `$AGENT_HOME/bin/monitor.sh`로 설치해 두고, `agent-core` 그룹 계정(`agent-admin`, `agent-dev`)이 실행합니다.

```bash
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh; echo "exit=$?"
sudo tail -n 5 /var/log/agent-app/monitor.log
```

| 상황 | 출력 | 종료 코드 |
|---|---|---|
| 앱 정상 | `[OK]` + 방화벽·자원 상태, 임계값 초과 시 `[WARNING]` | 0 |
| 앱 프로세스 없음 / 15034 LISTEN 아님 | `[ERROR] ...` + 로그에 `HEALTH_CHECK_FAILED` | 1 |
| 방화벽(UFW) 꺼짐 | `[WARNING] Firewall (ufw) is not enabled` | 0 |

임계값은 CPU 20% · MEM 10% · DISK 80%이고, 넘으면 경고만 하고 종료하지 않습니다. 로그 한 줄은 `[YYYY-MM-DD HH:MM:SS] PID:<앱 PID> CPU:..% MEM:..% DISK_USED:..%`입니다.

매분 자동 실행은 `agent-admin`의 crontab에 등록했습니다.

```
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >/dev/null 2>&1
```

## 설정 항목

| 구분 | 설정 | 값 |
|---|---|---|
| 포트 | SSH | TCP 20022 (Root 원격 로그인 `PermitRootLogin no`) |
| 포트 | 앱 | TCP 15034 |
| 방화벽 | UFW | 기본 `deny incoming`, 20022·15034/tcp만 허용 (AWS 보안 그룹도 같은 두 개) |
| 계정 | `agent-admin` / `agent-dev` / `agent-test` | 비밀번호 없는 계정, `sudo -iu`로 전환 |
| 그룹 | `agent-common` | admin · dev · test |
| 그룹 | `agent-core` | admin · dev (test 제외) |

| 경로 | 소유자:그룹 | 권한 | 용도 |
|---|---|---|---|
| `/home/agent-admin/agent-app` (`$AGENT_HOME`) | agent-admin:agent-common | 750 | 앱 루트 |
| `$AGENT_HOME/upload_files` | agent-admin:agent-common | 2770 + 기본 ACL | 공유 폴더 |
| `$AGENT_HOME/api_keys` | agent-admin:agent-core | 2770 | 키 파일 (보안 폴더) |
| `/var/log/agent-app` | agent-admin:agent-core | 2770 | `monitor.log` |
| `$AGENT_HOME/bin/monitor.sh` | agent-dev:agent-core | 750 | 점검 스크립트 |

환경 변수(`agent-admin`의 `~/.bashrc`): `AGENT_HOME` `AGENT_PORT` `AGENT_UPLOAD_DIR` `AGENT_KEY_PATH` `AGENT_LOG_DIR`. 키 파일 내용은 명세가 정한 테스트 값이라 repo에 넣지 않았습니다.

## 설계 선택

- **`pgrep -fn`으로 프로세스 찾기**: 제공 앱은 PyInstaller 실행 파일이라 같은 이름의 프로세스가 둘(부모·자식) 뜹니다. `-n`으로 가장 늦게 뜬 자식, 즉 포트를 연 쪽을 고릅니다.
- **방화벽 상태는 `/etc/ufw/ufw.conf`로 판단**: `ufw status`는 sudo가 필요한데 cron 실행 계정에는 sudo가 없습니다.
- **임계값 비교는 `awk`**: Bash `[ ]`는 정수만 비교해 `20.9` 같은 값을 못 다룹니다.
- **로그 회전은 스크립트 안에서**: 10MB 이상이면 쓰기 직전에 `.9`를 지우고 번호를 밀어 `monitor.log`와 `.1`~`.9`, 최대 10개를 유지합니다. 매분 실행이 곧 점검이라 별도 logrotate 설정이 필요 없습니다.
- **cron은 `~/.bashrc`를 읽지 않음**: `monitor.sh` 안에 `AGENT_PORT` 기본값을 두고 crontab에는 전체 경로만 적었습니다.
- **명세와 제공 앱이 어긋난 곳은 앱에 맞춤**: 앱은 `AGENT_KEY_PATH`를 파일이 아닌 폴더로, 키 파일은 `secret.key` 이름으로 찾아 둘 다 맞췄습니다([수행내역서 §3-4](docs/report.md)).

## 검증

| 확인 항목 | 방법 | 결과 | 캡처 |
|---|---|---|---|
| SSH·Root 차단 | `sshd -T`, `ss -tulnp` | port 20022, permitrootlogin no | `step_1_01` `step_1_02` |
| 방화벽 | `ufw status verbose` | 20022·15034만 허용 | `step_1_03` `step_1_04` |
| 계정·권한 | `id`, `ls -ld`, `getfacl`, `agent-test` 접근 시도 | api_keys·로그는 test 거부 | `step_2_01`~`03` |
| 앱 기동 | Boot Sequence, `ss -ltnp` | 5단계 `[OK]`, `Agent READY`, 15034 LISTEN | `step_3_02` `step_3_03` |
| `monitor.sh` | 정상 / 앱 종료 / UFW 끔 실행 후 `echo $?` | 0 / 1 / 0(경고) | `step_4_01`~`03` |
| 로그·회전 | `tail`, 10MB 테스트 파일 12회 실행 | 한 줄 누적, 10개 유지 | `step_5_01`~`03` |
| cron | 등록 후 손대지 않고 대기 | 1분 간격으로 로그 증가 | `step_6_01` `step_6_02` |

모든 확인 결과는 위 캡처와 수행내역서에 있습니다.
