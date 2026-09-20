# Kafka 4.3.1: WSL 기반 KRaft 클러스터 설치

## Conda 실행 환경

이 스크립트의 모든 Kafka 작업은 Conda 환경 kafka 안에서 수행됩니다.

- kafka 환경이 없으면 스크립트가 python 3.12와 openjdk 17을 포함한 환경을 먼저 생성합니다.
- 환경을 생성하거나 기존 환경을 찾은 뒤 kafka 환경을 활성화하고 작업을 수행합니다.
- Kafka 바이너리 다운로드, UUID 생성, node.properties 작성, KRaft metadata 포맷이 모두 활성화된 환경에서 실행됩니다.

`setup-kafka-node.sh`은 노드 수가 고정되지 않은 Kafka KRaft 클러스터 설치 스크립트입니다.
- 같은 스크립트를 모든 WSL 노드에서 한 번씩 실행합니다.
- 입력한 노드 수만큼 controller와 broker를 구성합니다.

## 입력 순서

스크립트는 아래 순서로 값을 받습니다. 현재 노드의 IP는 로컬 설정에서 조회하고, `directory-id`의 입력 여부는 `CLUSTER_ID` 입력 여부에 따라 달라집니다.

1. `클러스터 노드 수`
2. `CLUSTER_ID` : `uuid` 또는 빈 문자열
3. `현재 노드의 node.id` : integer
4. 현재 노드를 제외한 각 `node`의 IP : IPv4
5. `CLUSTER_ID`가 입력된 경우 각 `node`의 `directory-id` : `uuid`

### 새 클러스터를 처음 구성하는 경우

`CLUSTER_ID`에 빈 문자열을 입력하면 새 클러스터를 시작하는 실행으로 간주합니다.

예를 들어 3개 노드에서 현재 `node.id`가 `2`이면 다음과 같이 진행합니다.

1. 노드 수 `3` 입력
2. `CLUSTER_ID`에 빈 문자열 입력
3. 현재 `node.id`로 `2` 입력
4. `node 1`과 `node 3`의 IP만 입력
5. `node 2`의 IP는 WSL 내부 네트워크 설정에서 조회
6. `CLUSTER_ID` 1개와 `node 1`부터 `node 3`까지의 `directory-id` 3개를 스크립트가 생성

이 경우 다른 노드의 `directory-id`를 입력하지 않습니다. 생성된 ID 목록은 마지막 출력에서 확인하여 모든 노드에 공유합니다.

### 기존 클러스터에 노드를 구성하는 경우

`CLUSTER_ID`에 특정 값을 입력하면 기존 클러스터 구성으로 간주합니다.

1. 현재 노드를 제외한 각 노드의 IP를 입력
2. 현재 노드의 IP는 WSL 내부 네트워크 설정에서 조회
3. 모든 노드의 `directory-id`를 node 번호 순서대로 입력

이 경우에는 새로운 `CLUSTER_ID`나 `directory-id`를 생성하지 않습니다. 처음 클러스터를 만든 실행에서 출력된 값을 그대로 입력해야 합니다.

- 모든 노드에서 최종적으로 **동일한 IP, directory ID, CLUSTER_ID 목록**을 사용해야 합니다.
- `현재 노드의 node.id`는 각 노드에서 서로 다른 고유 정수값이어야 합니다.
- 새 클러스터 실행에서 생성된 `directory-id`는 다른 노드의 입력에 사용할 수 있도록 마지막 요약에 출력합니다.

### 현재 노드 IP 조회 원칙

- `node.id`는 클러스터에서 현재 노드를 식별하는 번호입니다.
- 현재 노드의 IP는 WSL 내부 네트워크 인터페이스와 라우팅 설정에 실제로 할당된 주소를 조회합니다. 예를 들어 `ip -4 addr` 또는 `hostname -I`로 확인할 수 있는 로컬 주소가 대상입니다.
    - loopback이나 임의로 만든 주소를 사용하지 않습니다. 여러 후보가 있어 하나를 확정할 수 없으면 후보를 보여주고 중단해야 하며, 임의의 주소를 조용히 선택하지 않습니다.
- `directory-id`는 스크립트를 처음 실행한 노드의 `kafka-storage.sh`가 생성하고, 기존 클러스터 실행에서는 입력받은 값을 사용합니다.
- Kafka의 controller와 broker endpoint에는 실제 IP를 사용합니다.

## ID 생성 규칙

Kafka 바이너리를 내려받고 압축을 푼 뒤 `kafka-storage.sh`를 사용해 필요한 UUID를 생성합니다.

```bash
~/kafka_2.13-4.3.1/bin/kafka-storage.sh random-uuid
```

- 해당 명령어를 직접 입력하는게 아닙니다. 이는, 스크립트가 내부적으로 수행할 명령어입니다.

### `CLUSTER_ID`

- `CLUSTER_ID` 입력 프롬프트에서 값을 입력하면 해당 값을 사용합니다.
- 빈 문자열을 입력하면 위 명령으로 새 UUID를 자동 생성합니다.
- 새 클러스터를 처음 구성하는 노드에서만 빈 문자열을 입력해야 합니다.
- 자동 생성된 `CLUSTER_ID`는 모든 노드에서 동일하게 사용하도록 다른 노드에 공유합니다.

### `directory-id`

- `CLUSTER_ID`가 비어 있으면 위 명령을 node 수만큼 실행하여 모든 노드의 `directory-id`를 이번 실행에서 생성합니다.
- `CLUSTER_ID`가 입력되어 있으면 모든 노드의 `directory-id`를 입력받고, 새로운 값을 생성하지 않습니다.
- 각 노드의 `directory-id`는 서로 달라야 하며, 클러스터 전체에서 같은 node 번호에 같은 값을 사용해야 합니다.
- 예를 들어 5개 노드라면 최종적으로 `CLUSTER_ID` 1개와 `directory-id` 5개가 필요합니다.

## 실행 방법

1. 모든 WSL 노드에 [setup-kafka-node.sh](setup-kafka-node.sh)를 복사합니다.
2. 각 노드에서 스크립트를 실행합니다.

   ```bash
   bash setup-kafka-node.sh
   ```

3. 첫 번째 노드에서는 `node.id`에 `1`, 두 번째에서는 `2`처럼 각 노드의 고유 번호를 입력합니다.
4. 첫 번째 실행에서 생성된 `CLUSTER_ID`와 모든 `directory-id`를 다른 노드의 입력에 반영하여 모든 노드에서 같은 목록을 사용합니다.
5. 마지막 요약에서 모든 node 번호, IP, `directory-id`, `CLUSTER_ID`를 확인합니다.
6. Kafka 시작 전에 Conda 환경 `kafka`를 활성화합니다.
   `conda activate kafka`
7. 활성화된 `kafka` 환경에서 마지막에 출력된 `kafka-server-start.sh` 명령으로 각 노드를 시작합니다.

## 스크립트가 하는 일

1. 사용자의 홈 디렉터리에 Kafka 4.3.1 압축 파일을 내려받고 압축을 풉니다.
2. `~/kafka_2.13-4.3.1/logs`를 만듭니다.
3. `CLUSTER_ID`가 비어 있으면 `kafka-storage.sh random-uuid`로 클러스터 UUID와 모든 node의 `directory-id`를 생성합니다.
4. `CLUSTER_ID`가 입력되어 있으면 모든 node의 `directory-id`를 입력받습니다.
5. WSL 내부 네트워크 설정에서 현재 노드의 실제 IP를 조회합니다.
6. 입력값과 생성값으로 `config/node.properties`를 작성합니다.
7. `~/.bashrc`에 `CLUSTER_ID`, `NODE_COUNT`, 각 `DIRECTORY_N`, `INITIAL_CONTROLLERS`를 저장합니다.
8. KRaft metadata를 포맷합니다.
9. Kafka 시작 명령과 전체 ID 요약을 출력합니다.

`node.properties`의 `node.id`와 `advertised.listeners`는 현재 실행 중인 노드 값으로 만들어집니다. 반면 controller quorum에는 모든 노드가 들어갑니다. Kafka 4.3 형식의 `INITIAL_CONTROLLERS`는 아래와 같습니다.

```text
1@node-1-ip:9093:node-1-directory-id,2@node-2-ip:9093:node-2-directory-id,...
```

## 종료 전 최종 출력

KRaft metadata 포맷이 끝나면 스크립트는 종료하기 전에 다음 정보를 모두 출력합니다.

그 다음 최종 출력의 Kafka 시작 명령을 실행합니다.

```text
CLUSTER_ID: <cluster-uuid>

node.id    IP address       directory-id
1          <node-1-ip>      <node-1-directory-id>
2          <node-2-ip>      <node-2-directory-id>
...
```

새 클러스터 실행에서 생성된 모든 `directory-id` 또는 기존 클러스터 실행에서 입력한 모든 `directory-id`가 이 목록에 포함됩니다. 이 최종 출력은 다른 노드의 입력값을 맞추고, 클러스터 전체의 ID 목록을 확인하는 데 사용합니다.

## 스크립트 종료 후

최종 출력에 표시되는 Kafka 시작 명령은 단독으로 실행하지 않습니다. 먼저 새 터미널에서 Conda 환경을 활성화한 뒤 실행해야 합니다.

`conda activate kafka`

## 복제 설정

확장성을 위해 스크립트는 `default.replication.factor`, offsets topic, transaction state log의 replication factor를 **입력한 노드 수**로 설정합니다. `min.insync.replicas`는 1개 노드일 때 `1`, 그 외에는 `노드 수 - 1`입니다.

예를 들어 3개 노드에서는 replication factor가 `3`, min ISR이 `2`가 되어 기존 설정과 같습니다. 운영 controller quorum은 장애 허용을 위해 보통 홀수 노드(3, 5 등)를 권장합니다.

## WSL 주의 사항

기본 WSL2 NAT 모드의 IP는 다른 Windows PC의 WSL에서 접근하지 못할 수 있습니다. 모든 Kafka 노드가 서로 도달할 수 있는 실제 IP를 입력해야 하며, 다른 PC에 분산했다면 mirrored networking 또는 Windows의 포트 전달·방화벽 설정이 필요할 수 있습니다.

## 안전 장치

Kafka 설치 디렉터리가 이미 있으면 스크립트는 중단합니다. 기존 `logs`에 있는 KRaft metadata를 실수로 덮어쓰지 않기 위한 동작입니다.
