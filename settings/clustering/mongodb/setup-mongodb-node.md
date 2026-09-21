# MongoDB Ubuntu 단일 멤버 Replica Set 구성 (Draft)

- MongoDB Community Server 설치 여부 확인
- MongoDB가 없을 때 공식 MongoDB APT 저장소를 통한 설치
- mongod 서비스 실행
- Standalone 인스턴스를 Replica Set으로 전환
- Replica Set 초기화와 PRIMARY 상태 확인
- Change Streams를 사용할 수 있는 기본 연결 정보 출력

이 문서와 스크립트는 현재 실행 중인 Ubuntu 한 대를 `rs0` 단일 멤버 Replica Set으로 전환하는 데 초점을 둡니다. 노드 수를 입력받아 여러 노드를 한 번에 구성하거나 원격 노드를 SSH로 설정하지는 않습니다.

## 실행 전제와 실행

- Ubuntu 20.04 또는 22.04 64-bit 환경
- `systemd`가 PID 1로 실행되는 환경
- 현재 사용자가 `sudo`를 사용할 수 있는 환경
- 외부 클라이언트가 접속해야 한다면 현재 호스트 이름이 클러스터의 모든 클라이언트에서 해석 가능해야 함

```bash
bash setup-mongodb-node.sh
```

## 1. MongoDB 설치 여부 확인

mongosh는 MongoDB 클라이언트이므로, mongosh가 있다는 사실만으로 서버가 설치되었다고 판단하지 않습니다.

스크립트는 다음 상태를 별도로 확인합니다.

1. mongod 서버 바이너리 존재 여부
2. mongosh 클라이언트 존재 여부
3. mongod.service가 등록 여부
4. 실제 서버에 연결하여 ping 성공 여부

개념적으로 사용하는 확인 명령은 다음과 같습니다.

```bash
command -v mongod
command -v mongosh
sudo systemctl is-active mongod
mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok'
```

이미 호환되는 `mongod`가 설치되어 있으면 현재 버전과 상태를 출력한 뒤 필요한 Replica Set 전환을 계속합니다. Ubuntu의 비공식 `mongodb` 패키지나 다른 주요 버전이 설치되어 있으면 기존 패키지를 자동으로 제거하지 않고 중단합니다.

## 2. MongoDB가 없을 때의 설치 방식

MongoDB는 MongoDB Inc.의 공식 APT 저장소를 등록한 뒤 mongodb-org 패키지를 설치합니다.

설치 흐름은 다음과 같습니다.

1. Ubuntu 릴리스와 CPU 아키텍처 확인
2. 사용할 MongoDB 주요 버전 결정
3. MongoDB 공식 GPG 키 등록
    - 공식 GPG 키를 가져오기 위해 `curl`을 사용합니다.
4. Ubuntu 코드명에 맞는 MongoDB 공식 APT 저장소 등록
5. `apt-get update`
6. `mongodb-org` 구성 패키지와 `mongodb-mongosh` 설치
7. mongod.service 시작 및 연결 확인

### 버전 선택

MongoDB 서버 버전은 7.0.39로 고정합니다. 단순히 mongodb-org만 설치하지 않고, 저장소에서 7.0.39 패키지를 확인한 뒤 서버 구성 패키지들을 같은 버전으로 설치합니다. mongosh는 별도 클라이언트 패키지인 mongodb-mongosh로 명시적으로 설치합니다. 설치 후 `mongod --version`, `mongosh --version`과 `db.version()`으로 실제 버전을 검증합니다.

MongoDB 7.0 공식 저장소는 Ubuntu 20.04(Focal)와 22.04(Jammy)를 지원 대상으로 안내합니다. 다른 Ubuntu 릴리스에서는 저장소에 7.0.39 패키지가 존재하는지 확인하지 못하면 설치를 진행하지 않습니다.

설치 스크립트는 다음 상황에서 자동으로 기존 패키지를 제거하지 않습니다.

- Ubuntu의 mongodb 패키지가 이미 설치된 경우
- 다른 MongoDB 주요 버전의 공식 패키지가 이미 설치된 경우

위 두 경우에는 현재 설치 상태를 출력하고 종료합니다. 기존 `/etc/mongod.conf`와 데이터 디렉터리가 발견되어도 삭제하거나 초기화하지 않고, 현재 설정을 백업한 뒤 계속 진행합니다.

## 3. 서비스 시작과 연결 확인

MongoDB 설치 또는 설정 변경 후에는 systemd를 통해 서비스를 관리합니다.

```bash
sudo systemctl enable --now mongod
sudo systemctl is-active mongod
mongosh --quiet --eval 'db.adminCommand({ ping: 1 })'
```

서비스가 실행된 직후 바로 Replica Set 초기화를 시도하지 않고, ping이 성공할 때까지 제한된 횟수로 대기합니다.

systemd가 PID 1로 실행되지 않는 Ubuntu 환경이면 MongoDB 설정 단계에서 중단하고, systemd 서비스 관리가 가능한 환경에서 다시 실행합니다.

## 4. Standalone 상태 확인

MongoDB에 연결한 뒤 현재 상태를 확인합니다.

- `db.hello().setName`이 비어 있으면 Standalone 상태로 판단합니다.
- `db.hello().setName`이 rs0이면 이미 목표 Replica Set으로 구성된 상태입니다.
- 다른 Replica Set 이름이 반환되면 자동으로 이름을 바꾸지 않고 중단합니다.
- 연결 또는 인증에 실패하면 자동으로 우회하지 않고 중단합니다. 인증이 활성화된 환경은 인증 정보를 사용하는 별도 실행 절차가 필요합니다.

이미 rs0으로 구성된 경우 `rs.initiate()`를 다시 실행하지 않고 `rs.status()`와 `rs.conf()`만 검증 후 이 사실을 사용자가 인지할 수 있도록 출력합니다.

## 5. Standalone을 단일 Replica Set으로 전환

### 5.1 백업

설정 파일을 수정하기 전에 timestamp가 포함된 백업을 만듭니다.

- `/etc/mongod.conf`: 설정 파일 자체를 백업합니다.
- `storage.dbPath`: 실제 데이터 디렉터리의 위치를 확인하고 기록합니다. 경로 문자열만 기록하는 것은 데이터 백업이 아닙니다.
- 현재 MongoDB 버전과 패키지 정보

`storage.dbPath` 아래의 파일을 복사하는 데이터 디렉터리 전체 백업은 기본 동작에 포함하지 않습니다. 전체 데이터 백업이 필요하면 `mongodump`를 사용하거나, 모든 쓰기를 중지하고 `storage.dbPath` 디렉터리 전체를 별도로 복사해야 합니다. 스크립트가 기존 데이터 디렉터리를 삭제하거나 초기화하지 않도록 합니다.

### 5.2 MongoDB 중지

APT 패키지와 systemd가 관리하는 서버라면 다음 방식으로 중지합니다.

    sudo systemctl stop mongod

mongosh의 db.shutdownServer()는 수동으로 실행한 mongod를 종료해야 하는 특별한 경우에만 사용합니다. 서비스 관리 방식과 수동 --fork 방식을 한 과정에서 섞지 않습니다.

### 5.3 설정 파일 병합

/etc/mongod.conf에 다음 설정을 추가하거나 기존 값을 갱신합니다.

    replication:
      replSetName: "rs0"

이미 replication 섹션이 있으면 두 번째 섹션을 덧붙이지 않고 기존 섹션 안의 replSetName을 확인합니다.

원격 클라이언트가 접속해야 하면 기존 `net.bindIp` 값을 보존하면서 현재 호스트의 해석 가능한 hostname을 추가합니다. 기존 `net.bindIpAll: true` 설정은 임의로 변경하지 않습니다.

### 5.4 Replica Set 주소와 bind 주소

단일 멤버의 주소는 Replica Set 클라이언트가 실제로 접근할 수 있는 주소여야 합니다. MongoDB 7.0 Replica Set 구성에서는 IP 문자열만 `members[n].host`에 넣지 않고, 모든 클라이언트에서 해석 가능한 hostname을 사용합니다.

스크립트는 `hostname -f`로 `MY_HOSTNAME`을 확인한 뒤, `hostname -I` 후보 중 해당 hostname으로 해석되는 첫 번째 non-loopback IPv4 주소를 `MY_IP`로 저장해 실제 접근 주소와 방화벽 확인에 출력합니다. `MY_HOSTNAME`은 `net.bindIp`와 Replica Set 멤버 주소에 사용합니다.

개념적으로 주소를 결정하는 방식은 다음과 같습니다.

```bash
MY_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
# hostname -I 후보 중 MY_HOSTNAME으로 해석되는 non-loopback IPv4를 MY_IP로 선택
```

    ${MY_HOSTNAME}:27017

non-loopback IPv4 주소나 해석 가능한 hostname을 찾지 못하면 Replica Set 초기화를 진행하지 않고 중단합니다. `localhost:27017`은 같은 Ubuntu 호스트에서만 사용할 때 적절하므로 자동으로 사용하지 않습니다. 다른 호스트나 Kafka Connector가 접속하려면 `MY_HOSTNAME`이 모든 클라이언트에서 해석 가능해야 합니다. 스크립트는 `/etc/hosts`를 자동으로 수정하지 않습니다.

외부 접속을 허용하는 경우 다음을 함께 검토합니다.

- `net.bindIp`에 자동으로 결정한 `MY_HOSTNAME`을 포함하되, 기존 loopback 주소는 보존
- 호스트 또는 네트워크 방화벽에서 TCP 27017 허용
- MongoDB 인증과 TLS 적용
- 공개 네트워크에 MongoDB를 무방비로 노출하지 않기

### 5.5 서비스 재시작과 초기화

설정 파일을 저장한 뒤 MongoDB를 다시 시작하고, 연결 가능할 때까지 대기합니다.

그 다음 단일 멤버 구성으로 한 번만 초기화합니다.

    rs.initiate({
      _id: "rs0",
      members: [
        { _id: 0, host: "${MY_HOSTNAME}:27017" }
      ]
    })

초기화 후에는 다음 상태를 확인합니다.

- Replica Set 이름이 rs0인지
- 멤버가 1개인지
- 현재 멤버 상태가 PRIMARY인지
- rs.conf()의 host 주소가 실제 접속 가능한 주소인지
- rs.status()가 오류 없이 반환되는지

MongoDB 공식 절차도 설정 변경 후 서버를 시작하고 rs.initiate()를 한 번 실행한 뒤 rs.conf()와 rs.status()로 검증하도록 안내합니다.

## 6. 애플리케이션 접속 정보

구성이 완료되면 다음 형태의 연결 정보를 확인합니다.

    mongodb://${MY_HOSTNAME}:27017/?replicaSet=rs0

`MY_IP`는 방화벽·접속 확인용으로 함께 출력되지만, MongoDB Replica Set 설정과 연결 문자열에는 hostname을 사용합니다.

## 7. 나중에 멤버를 추가하는 방법

현재 스크립트는 단일 멤버 Replica Set만 구성합니다. 나중에 새 Ubuntu 노드를 추가하려면 새 노드를 동일한 `replSetName`으로 준비하고, 기존 PRIMARY에서 다음처럼 한 번씩 추가합니다.

```javascript
rs.add("mongo2.example.local:27017")
rs.add("mongo3.example.local:27017")
```

이때 새 노드에서 `rs.initiate()`를 다시 실행하지 않습니다. 새 멤버는 추가 후 기존 Replica Set으로 초기 동기화됩니다.

## 8. 스크립트의 권장 실행 단계

setup-mongodb-node.sh는 다음 순서로 동작합니다.

1. Ubuntu, systemd, sudo 사전 조건 확인
2. MongoDB 버전·Ubuntu 코드명·CPU 아키텍처 확인
3. mongod, mongosh, mongod.service 존재 여부 확인
4. MongoDB가 없을 때만 공식 APT 저장소와 mongodb-org, mongodb-mongosh 설치
5. mongod 서비스 시작 및 ping 확인
6. 현재 Standalone/Replica Set 상태 확인
7. `hostname -I`로 `MY_IP`를 확인하고 `hostname -f`로 `MY_HOSTNAME`을 확인
8. 설정 파일과 데이터 경로 위치 백업
9. 필요한 경우 replication.replSetName: rs0와 hostname 기반 bind 설정 병합
10. 서비스 재시작 및 연결 대기
11. 필요한 경우 rs.initiate() 실행
12. PRIMARY, rs.conf(), rs.status() 검증
13. MongoDB 버전, 서비스 상태, Replica Set 이름, 멤버 주소, `MY_IP`, 연결 문자열 출력

## 9. 안전 장치와 재실행 규칙

- 기존 /etc/mongod.conf와 데이터 경로를 삭제하지 않습니다.
- 설정 변경 전 백업을 만듭니다.
- 이미 rs0이면 초기화를 반복하지 않습니다.
- 다른 Replica Set 이름이 있으면 자동으로 변경하지 않습니다.
- 기존 인증 설정을 비활성화하지 않습니다.
- MongoDB 서비스가 시작되지 않으면 Replica Set 초기화를 진행하지 않습니다.
- 고정된 sleep만 사용하지 않고 ping과 Replica Set 상태를 반복 확인합니다.

## 참고 문서

- [MongoDB 7.0 Ubuntu 설치](https://www.mongodb.com/docs/v7.0/tutorial/install-mongodb-on-ubuntu/)
- [Replica Set 멤버 hostname 변경 및 사용](https://www.mongodb.com/docs/v7.0/tutorial/change-hostnames-in-a-replica-set/)
- [기존 Replica Set에 멤버 추가](https://www.mongodb.com/docs/v7.0/tutorial/expand-replica-set/)
