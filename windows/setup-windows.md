Windows PowerShell: WSL 클러스터 네트워크 초기 설정

`setup-wsl-cluster-network.ps1`은 Windows에서 실행하는 관리자 PowerShell 스크립트입니다.

- WSL 설치 및 초기화 완료
- WSL2 mirrored networking 설정
- Windows 방화벽 설정
- Hyper-V 방화벽 설정
- 입력한 Cluster IP의 최종 연결 상태 출력

## 전제 조건

- Windows 11 22H2(빌드 22621) 이상
- 관리자 권한 PowerShell
- 인터넷 연결
- WSL 설치 및 초기화 완료

## 실행 전 필수 작업

이 스크립트는 WSL을 설치하지 않습니다. 반드시 먼저 관리자 PowerShell에서 아래 명령을 실행하세요.

```powershell
wsl --install
```

그 다음 Windows를 재부팅하고, 설치된 Ubuntu 등 WSL 배포판의 최초 사용자 설정을 완료해야 합니다.

스크립트는 시작할 때 WSL 설치 여부만 확인합니다. WSL이 설치되지 않은 경우 설정을 진행하지 않고 `wsl --install` 실행과 PC 재부팅을 안내한 뒤 종료합니다.

## 실행

관리자 권한 PowerShell에서 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-windows.ps1
```

WSL 설치·재부팅·최초 사용자 설정이 완료된 뒤에만 이 스크립트를 실행하세요. 조건이 충족되지 않으면 스크립트가 오류 메시지를 출력하고 중단합니다.

## Cluster IP 입력

한 줄에 하나씩 IP를 입력하고, 마지막에 `EOF`를 그대로 입력합니다. 이는 실제 키보드 EOF가 아니라 입력 종료를 위한 문자열입니다.

```text
Cluster IP: 192.168.0.101
Cluster IP: 192.168.0.102
Cluster IP: 192.168.0.103
Cluster IP: EOF
```

입력한 값은 PowerShell 배열 변수 `$ClusterIPs`에 저장되어 Windows와 Hyper-V 방화벽 규칙의 원격 주소 목록으로 사용됩니다.

## `.wslconfig` 설정

Windows 사용자 프로필의 `%USERPROFILE%\.wslconfig`에 아래 항목을 보존·갱신합니다.

```ini
[wsl2]
networkingMode=mirrored

[experimental]
hostAddressLoopback=true
```

`.wslconfig`은 모든 WSL2 배포판에 적용되는 Windows 설정입니다. 기존 `.wslconfig`에 `[network]` 섹션의 `generateHosts` 키가 있다면 이 스크립트에서는 제거합니다.

설정 파일을 저장한 뒤 `wsl --shutdown`을 실행해 다음 WSL 시작 때 변경 사항이 적용되도록 합니다.

## 방화벽 규칙

다음 두 규칙을 생성하거나 같은 이름의 기존 규칙을 교체합니다.

| 이름 | 위치 | 허용 범위 |
| --- | --- | --- |
| `MLOps-Cluster-Internal` | Windows Defender Firewall | 입력한 Cluster IP의 모든 프로토콜 |
| `WSL-MLOps-Cluster-Internal` | Hyper-V Firewall | 입력한 Cluster IP의 모든 프로토콜 |

Hyper-V 규칙은 지정된 WSL Creator ID `{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}`를 고정해서 사용합니다. `New-NetFirewallHyperVRule`은 VM Creator ID와 원격 주소 조건을 지원합니다. [Microsoft PowerShell 문서](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallhypervrule?view=windowsserver2025-ps)

## 최종 출력

마지막에 스크립트는 다음을 화면에 출력합니다.

- `.wslconfig`의 실제 내용
- Windows/Hyper-V 방화벽 규칙의 원격 주소
- 입력한 모든 Cluster IP에 대한 ICMP 연결 결과

Ping 결과가 `False`여도 원격 노드가 아직 실행되지 않았거나 ICMP를 차단하는 경우일 수 있습니다. 출력된 방화벽 설정과 원격 노드 상태를 함께 확인하세요.
