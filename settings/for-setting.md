# Windows 및 WSL 기본 설정

이 문서는 Windows와 WSL을 처음 구성할 때의 전체 실행 순서만 설명합니다.
각 스크립트의 상세 동작과 옵션은 해당 스크립트의 전용 문서에서 확인합니다.

## 전체 실행 순서

1. 관리자 권한 PowerShell에서 WSL을 설치합니다.
2. WSL 설치가 끝나면 Windows를 재부팅합니다.
3. 재부팅 후 WSL 배포판을 처음 실행하고 Linux 사용자 초기 설정을 완료합니다.
4. WSL 설치 상태와 사용자 권한을 확인하고 Git을 설치합니다.
5. Git으로 설정 저장소를 Linux 홈 디렉터리에 clone합니다.
6. 관리자 권한 PowerShell에서 Windows 설정 스크립트를 실행합니다.
7. WSL 터미널에서 WSL 설정 스크립트를 실행합니다.
8. WSL 터미널을 종료하고 PowerShell에서 `wsl --shutdown`을 실행합니다.
9. WSL 배포판을 다시 실행합니다.

WSL 설치 단계의 재부팅을 제외하면, 이후에는 Windows 전체를 다시 재부팅할 필요가 없습니다.

## 1. WSL 설치와 최초 재부팅

WSL이 설치되지 않은 Windows 환경에서는 관리자 권한 PowerShell에서 다음을 실행합니다.

```powershell
wsl --install
```

설치가 완료되면 반드시 Windows를 재부팅합니다. 재부팅 전에는 설정 스크립트를 실행하지 않습니다.

재부팅 후 사용할 WSL 배포판을 처음 실행하여 Linux 사용자 생성과 초기 설정을 완료합니다.

## 2. WSL 설치 상태와 사용자 권한 확인

Windows 재부팅 후 관리자 권한 PowerShell에서 WSL2 사용 여부를 확인합니다.

```powershell
wsl --status
wsl --list --verbose
```

사용할 배포판의 `VERSION`이 `2`인지 확인합니다.

WSL 터미널에서는 현재 사용자와 sudo 권한을 확인합니다.

```bash
command -v sudo
sudo -v
sudo whoami
```

- `sudo -v`가 성공하고 `sudo whoami`가 `root`를 출력하면 sudo 권한이 준비된 상태입니다.

## 3. Git 설치 및 설정 저장소 clone

설정 파일을 저장소에서 내려받기 위해 WSL에서 Git을 설치합니다.

```bash
sudo apt-get update
sudo apt-get install -y git
git --version
```

저장소는 Linux 사용자의 홈 디렉터리 아래 `~/finance-dashboard`에 clone합니다.

```bash
git clone https://github.com/ML-Plumber/finance-dashboard ~/finance-dashboard
cd ~/finance-dashboard
```

이미 clone된 저장소가 있으면 다음 명령으로 갱신합니다.

```bash
git -C ~/finance-dashboard pull
cd ~/finance-dashboard
```

## 4. Windows 설정 스크립트 실행

WSL 설치, Windows 재부팅, 배포판 초기화가 끝난 뒤 관리자 권한 PowerShell에서 실행합니다.


- `$env:USERNAME`으로 확인한 값을 cd 명령어 이후에, `username`에 넣어 경로를 수정한 뒤 실행합니다.

```powershell
$env:USERNAME
cd Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\<username>\finance-dashboard\settings\windows
```

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-windows.ps1
```

WSL 기본 설정이 아직 완료되지 않았기 때문에 `setup-windows.ps1`을 실행했더라도 곧바로 `ping`으로 포트 연결을 확인할 수는 없습니다. 

스크립트의 상세 전제 조건과 실행 방법은 다음 문서에서 확인합니다.

- [setup-windows.md](windows/setup-windows.md)

## 5. WSL 설정 스크립트 실행

Windows 설정 스크립트가 끝난 뒤 WSL 터미널에서 실행합니다.

```bash
cd ~/finance-dashboard/settings/wsl
bash setup-wsl.sh
```

스크립트의 상세 동작과 WSL 설정 내용은 다음 문서에서 확인합니다.

- [setup-wsl.md](wsl/setup-wsl.md)

## 6. `wsl --shutdown` 실행 시점

`setup-wsl.sh`가 정상적으로 끝난 뒤 WSL 터미널을 종료하고, Windows PowerShell에서 실행합니다.

```powershell
wsl --shutdown
```

이 명령은 실행 중인 WSL 배포판을 종료하고 WSL 설정을 다음 시작 시 다시 읽도록 합니다. 실행 중인 작업은 먼저 저장하고 종료합니다.

그 후 WSL 배포판을 다시 실행합니다. 이 단계는 WSL 설정 적용을 위한 재시작이며 Windows 전체 재부팅은 아닙니다.

## 관련 문서

| 문서 | 내용 |
| --- | --- |
| [setup-windows.md](windows/setup-windows.md) | Windows 및 Hyper-V 방화벽 설정 |
| [setup-wsl.md](wsl/setup-wsl.md) | WSL 기본 환경 설정 |

두 스크립트 모두 WSL 설치를 대신하지 않습니다. 새 Windows 환경에서는 반드시 `wsl --install` → Windows 재부팅 → WSL 배포판 초기화 순서를 먼저 완료합니다.

## 7. Kafka 클러스터 설정

Windows와 WSL 기본 설정이 끝난 뒤, Kafka를 사용할 각 WSL 노드에서 다음 순서로 실행한다.

1. Kafka 설정 디렉터리로 이동한다.

   ```bash
   cd ~/finance-dashboard/settings/clustering/kafka
   ```

2. Kafka 노드 설치 스크립트를 실행한다.

   ```bash
   bash setup-kafka-node.sh
   ```

3. 새 클러스터를 구성하는 경우 생성된 `CLUSTER_ID`와 `directory-id`를 모든 노드에서 공유한다.
4. `kafka` Conda 환경을 활성화한 뒤, 스크립트가 마지막에 출력한 Kafka 시작 명령을 각 노드에서 실행한다.

스크립트의 상세 동작과 입력값, ID 공유 규칙, WSL 네트워크 주의사항 등의 내용은 다음 문서에서 확인합니다.

- [setup-kafka-node.md](clustering/kafka/setup-kafka-node.md)

## 8. Spark Standalone 노드 설정

Spark를 사용할 각 WSL 노드에서 다음 순서로 실행한다.

1. Spark 설정 디렉터리로 이동한다.

   ```bash
   cd ~/finance-dashboard/settings/clustering/spark
   ```

2. Spark 노드 설치 스크립트를 실행한다.

   ```bash
   bash setup-spark-node.sh
   ```

3. local IP는 자동으로 감지되며, Master 주소와 포트 및 Worker 자원 설정값을 입력한다.
4. Master 노드에서는 출력된 Master 시작 명령을, Worker 노드에서는 출력된 Worker 시작 명령을 실행한다.
5. Master Web UI에서 Master와 Worker의 연결 상태를 확인한다.

스크립트의 상세 동작과 설치 경로 초기화, Conda 버전 확인, `spark-env.sh` 설정 및 실행 방법은 다음 문서에서 확인합니다.
- [setup-spark-node.md](clustering/spark/setup-spark-node.md)
