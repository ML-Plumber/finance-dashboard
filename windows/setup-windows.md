# Windows PowerShell: Cluster Firewall Rule Setup

`setup-windows.ps1`은 입력한 Cluster IP와 포트를 기준으로 Windows Defender Firewall과 Hyper-V Firewall에 허용 규칙을 생성합니다.

## 전제 조건

- Windows 11 22H2(빌드 22621) 이상
- 관리자 권한 PowerShell
- `NetSecurity` 방화벽 PowerShell 명령 사용 가능

## 실행

관리자 권한 PowerShell에서 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-windows.ps1
```

## Cluster IP 입력

Cluster IP를 한 줄에 하나씩 입력하고, 마지막에 `EOF`를 입력합니다. `EOF`는 입력 종료를 위한 문자열입니다.

```text
Cluster IP: 192.168.0.101
Cluster IP: 192.168.0.102
Cluster IP: 192.168.0.103
Cluster IP: EOF
```

입력한 IP는 원격 주소 조건으로 사용됩니다. 중복 IP는 한 번만 등록되며, IPv4와 IPv6 주소를 모두 입력할 수 있습니다.

## 포트 입력

Cluster IP 입력이 끝나면 허용할 포트를 한 줄에 하나씩 입력하고, 다시 `EOF`를 입력합니다.

```text
Port: 9092
Port: 9093
Port: 8080
Port: EOF
```

포트는 `1`부터 `65535`까지 입력할 수 있으며 중복 포트는 한 번만 등록됩니다.

## 주요 서비스 기본 포트 참고

아래 포트는 일반적인 기본값입니다. 실제 설치 파일이나 서비스 설정에서 포트를 변경했다면 변경된 값을 입력해야 합니다.

기본적으로, `9092`, `9093`, `7077`, `8080`, `8081`, `4040`, `27017`, `3306`, `6379`, `22` 를 열면 잘 동작합니다.

| 서비스 | 기본 포트 | 프로토콜 | 용도·참고 |
| --- | ---: | --- | --- |
| Kafka broker/client | `9092` | TCP | broker 및 client 통신 |
| Kafka KRaft controller | `9093` | TCP | 현재 구성 예시의 controller listener |
| Spark standalone master | `7077` | TCP | master 통신 |
| Spark master Web UI | `8080` | TCP | master 상태 화면 |
| Spark worker Web UI | `8081` | TCP | worker 상태 화면 |
| Spark application Web UI | `4040` | TCP | 실행 중인 애플리케이션 화면, 필요 시 사용 |
| Spark History Server | `18080` | TCP | 이벤트 로그 기반 이력 화면, 필요 시 사용 |
| MongoDB | `27017` | TCP | `mongod`/`mongos` 기본 포트 |
| MySQL classic protocol | `3306` | TCP | 일반 MySQL client/server 연결 |
| MySQL X Protocol | `33060` | TCP | X Protocol 사용 시 |
| SSH | `22` | TCP | 원격 관리 |
| Redis | `6379` | TCP | client 연결 |
| Redis Cluster bus | `16379` | TCP | Redis Cluster 사용 시 |
| Redis Sentinel | `26379` | TCP | Sentinel 사용 시 |

## 방화벽 규칙 동작

입력한 포트에 대해 TCP와 UDP 규칙을 각각 생성합니다. Windows 방화벽의 포트 조건은 TCP 또는 UDP 프로토콜에만 적용할 수 있으므로, `Protocol=Any`와 특정 포트를 하나의 규칙으로 조합하지 않습니다.

각 프로토콜에 대해 다음 네 가지 규칙을 생성합니다.

- `Windows` 방화벽 `Inbound`
- `Windows` 방화벽 `Outbound`
- `Hyper-V` 방화벽 `Inbound`
- `Hyper-V` 방화벽 `Outbound`

따라서 전체적으로 다음 8개 규칙이 생성됩니다.

| 위치 | 프로토콜 | 방향 | 규칙 이름 |
| --- | --- | --- | --- |
| Windows Firewall | TCP | Inbound | `MLOps-Cluster-Internal-TCP-Inbound` |
| Windows Firewall | TCP | Outbound | `MLOps-Cluster-Internal-TCP-Outbound` |
| Windows Firewall | UDP | Inbound | `MLOps-Cluster-Internal-UDP-Inbound` |
| Windows Firewall | UDP | Outbound | `MLOps-Cluster-Internal-UDP-Outbound` |
| Hyper-V Firewall | TCP | Inbound | `WSL-MLOps-Cluster-Internal-TCP-Inbound` |
| Hyper-V Firewall | TCP | Outbound | `WSL-MLOps-Cluster-Internal-TCP-Outbound` |
| Hyper-V Firewall | UDP | Inbound | `WSL-MLOps-Cluster-Internal-UDP-Inbound` |
| Hyper-V Firewall | UDP | Outbound | `WSL-MLOps-Cluster-Internal-UDP-Outbound` |

모든 규칙은 다음 조건을 사용합니다.

- Action: `Allow`
- Windows Profile: `Any`
- Hyper-V Profiles: `Any`
- 입력한 Cluster IP만 원격 주소로 허용
- 입력한 포트만 허용
- 모든 로컬 주소와 네트워크 인터페이스에 적용

Hyper-V 규칙은 다음 WSL VM Creator ID를 대상으로 합니다.

```text
{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}
```

같은 이름의 기존 규칙은 새 규칙을 만들기 전에 제거합니다. 이전 버전에서 생성된 전체 포트 허용 규칙인 다음 두 규칙도 제거합니다.
- `MLOps-Cluster-Internal`
- `WSL-MLOps-Cluster-Internal`

## 최종 출력

스크립트 마지막에 다음 정보를 실제 방화벽 규칙에서 다시 조회해 출력합니다.

- 전체 Cluster IP 목록
- 전체 허용 포트 목록
- Windows 방화벽 4개 규칙의 방향, 프로토콜, 로컬·원격 포트, 원격 주소, Action, Profile
- Hyper-V 방화벽 4개 규칙의 방향, 프로토콜, 로컬·원격 포트, 원격 주소, VM Creator ID, Action, Profiles
