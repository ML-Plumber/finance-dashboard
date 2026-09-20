# WSL 기본 환경 설정

`setup-wsl.sh`는 이미 설치·초기화된 WSL2 배포판 내부에서 실행하는 기본 환경 설정 스크립트입니다.

이 스크립트는 WSL 자체를 설치하지 않습니다.
WSL 설치와 Windows 재부팅이 끝나 WSL 터미널을 사용할 수 있는 상태에서만 실행합니다.

## 사전 요구사항

다음 순서를 먼저 완료해야 합니다.

1. 관리자 권한 PowerShell에서 `wsl --install`을 실행합니다.
2. Windows를 재부팅합니다.
3. Ubuntu 배포판을 처음 실행하고, Linux 사용자 생성과 초기 설정을 완료합니다.
4. 생성한 사용자가 `sudo`를 사용할 수 있는지 확인합니다.

WSL 설치 또는 재부팅이 완료되지 않은 상태에서는 이 스크립트를 실행하지 않습니다. 스크립트는 WSL이 설치되어 있는지 확인하거나 설치를 시작하지 않습니다.

또한 다음 환경을 전제로 합니다.

- Windows 11 22H2 이상 및 WSL2
- apt 패키지와 Miniforge를 내려받을 수 있는 인터넷 연결
- 선택한 WSL 사용자의 홈 디렉터리와 `sudo` 권한

## 실행 순서

Windows에서 WSL 설치, 재부팅, 배포판 초기화를 완료한 뒤 WSL 터미널에서 스크립트를 실행합니다.

```bash
bash setup-wsl.sh
```

## 스크립트가 수행하는 작업

### 1. 공통 패키지 설치

WSL 내부에서 여러 개발·운영 작업에 공통으로 사용할 최소 패키지를 설치합니다.

- `curl`
- `ca-certificates`
- `iproute2`
- `iputils-ping`
- `openssh-server`

### 2. WSL 배포판 설정

`/etc/wsl.conf`를 변경하기 전에 기존 파일을 백업하고, 기존의 다른 설정은 보존하면서 다음 항목을 추가하거나 갱신합니다.

```ini
[boot]
systemd=true

[network]
generateHosts=false
```

- `systemd=true`는 WSL에서 systemd 기반 서비스 관리를 사용할 수 있게 합니다.
- `generateHosts=false`는 WSL이 `/etc/hosts`를 자동으로 다시 생성하지 않도록 합니다.

### 3. SSH 서버 설정

`openssh-server`를 설치하고, 현재 WSL의 `systemd` 상태에 맞춰 SSH 서비스가 실행되도록 설정합니다.

### 4. Miniforge 설치

현재 WSL 사용자의 홈 디렉터리 아래 `~/miniforge3`에 Miniforge를 설치합니다.

### 5. Windows `.wslconfig` 설정

현재 Windows 사용자 프로필의 `.wslconfig`를 찾고, 변경 전에 백업한 뒤 기존의 다른 설정을 보존하면서 다음 항목을 추가하거나 갱신합니다.

```ini
[wsl2]
networkingMode=mirrored

[experimental]
hostAddressLoopback=true
```

- `networkingMode=mirrored`는 WSL2 mirrored networking을 사용합니다.
- `hostAddressLoopback=true`는 호스트 주소 loopback 기능을 활성화합니다.

## 설정 적용 및 재시작

스크립트가 끝난 뒤에는 WSL을 종료한 다음 다시 시작해야 `/etc/wsl.conf`와 Windows `.wslconfig`가 적용됩니다.

```powershell
wsl --shutdown
```

그 후 WSL 배포판을 다시 실행합니다. 이 과정에는 Windows 전체 재부팅이 필요하지 않습니다. 다만 WSL 설치 직후 아직 재부팅하지 않은 상태라면, 스크립트 실행 전에 먼저 Windows 재부팅을 완료해야 합니다.

## 최종 확인 정보

스크립트는 마지막에 다음 상태를 요약해 출력합니다.

- 설치 또는 확인된 공통 패키지
- SSH 서비스 상태
- 네트워크 인터페이스와 주요 listening 상태
- conda 및 Miniforge 설치 상태
- `/etc/wsl.conf`의 적용 내용
- Windows `.wslconfig`의 적용 내용

## 재실행과 백업

스크립트는 기존 설정을 가능한 한 보존하고, 설정 파일을 변경하기 전에 백업을 생성합니다. 따라서 일부 단계가 이미 완료된 환경에서도 다시 실행할 수 있도록 구성합니다.

다만 패키지 설치, SSH 설정, WSL 설정 파일 변경은 시스템 상태를 바꾸는 작업이므로 실행 결과와 최종 출력 내용을 확인합니다.
