# PyMongo Change Stream 이벤트와 BSON 값

## 1. 이 데이터가 의미하는 것

다음 값은 `collection.watch()`가 반환하는 Change Stream 이벤트를 PyMongo가 Python 객체로 변환한 결과다.

```python
{
    "_id": {
        "_data": "826...004"
    },
    "operationType": "insert",
    "clusterTime": Timestamp(1790009557, 1),
    "wallTime": datetime.datetime(2026, 9, 21, 16, 52, 37, 302000),
    "fullDocument": {
        "_id": ObjectId("6ab160d5a312a9a292a89588"),
        "event_type": "aggTrade",
        "event_time": 1790009556283,
        "symbol": "BTCUSDT",
        "trade_id": 4069847026,
        "price": "85893.94000000",
        "quantity": "0.00030000",
        "first_trade_id": 6700793630,
        "last_trade_id": 6700793630,
        "trade_time": 1790009556283,
        "is_buyer_maker": False,
        "M": True,
    },
    "ns": {
        "db": "datalake",
        "coll": "bronze",
    },
    "documentKey": {
        "_id": ObjectId("6ab160d5a312a9a292a89588")
    },
}
```

이 객체는 MongoDB에 저장된 Raw Document와는 다르다. MongoDB에서 발생한 하나의 변경 이벤트를 표현하는 **Change Stream event envelope**다.

```text
Change Stream event
├── 이벤트 위치 정보       (_id / resume token)
├── 변경 종류               (operationType)
├── MongoDB 시간 정보       (clusterTime, wallTime)
├── 대상 namespace          (ns)
├── 변경 문서의 식별자      (documentKey)
└── 변경된 문서의 내용      (fullDocument)
```

PyMongo는 BSON 문서를 Python `dict`와 BSON 전용 Python 타입으로 변환해 반환한다. 따라서 출력 결과는 JSON 문자열이 아니라 Python 객체의 표현이다.

### BSON 저장 표현과 PyMongo 디코딩

MongoDB Document와 PyMongo 객체의 관계는 다음과 같이 이해할 수 있다.

1. MongoDB의 Document 모델은 BSON을 기반으로 한다. BSON은 JSON과 유사한 바이너리 직렬화 형식이며, 클라이언트와 MongoDB 서버 간 통신 및 MongoDB가 관리하는 Document 표현에 사용된다. 다만 실제 디스크상의 물리적 저장 구조는 WiredTiger와 같은 Storage Engine이 관리하므로, BSON Document가 디스크에 단순한 파일 형태로 그대로 저장된다고 이해해서는 안 된다.

2. PyMongo는 MongoDB에서 받은 BSON Document를 Python 객체로 디코딩한다. 기본적으로 최상위 Document는 `dict` 형태이며, BSON의 특수 타입은 `ObjectId`, `datetime`, `Decimal128`, `Binary`, `Timestamp` 등으로 변환된다. 따라서 PyMongo가 반환한 값은 BSON 원본 바이트나 JSON 문자열이 아니라, 애플리케이션 메모리 안의 Python 객체 구조다.

3. 이 디코딩 과정은 단일 Document에서는 일반적으로 문제가 되지 않는다. 그러나 많은 Document를 동시에 메모리에 보관하거나, Change Stream의 생산 속도가 후속 처리 속도보다 빠른 경우 Python 객체와 버퍼가 누적되어 메모리 사용량이 커질 수 있다. 따라서 Change Stream은 가능한 한 순차적으로 처리하고, 무제한 리스트나 큐에 이벤트를 쌓지 않도록 주의해야 한다.

이때 메모리 증가는 BSON 디코딩 하나만의 문제가 아니다. 다음 요소들이 함께 영향을 준다.

- Document 하나의 크기와 중첩 구조
- 한 번에 읽어오는 Change Stream 배치 크기
- 동시에 실행되는 Change Stream의 수
- Kafka 전송 전후의 애플리케이션 버퍼와 큐
- 이벤트를 읽는 속도와 후속 처리 속도의 차이

예를 들어 아래처럼 전체 Change Stream을 리스트로 materialize하면 모든 이벤트가 Python 객체로 메모리에 남는다.

```python
changes = list(collection.watch())
```

반면 다음처럼 순차적으로 처리하면 애플리케이션이 모든 이벤트를 한꺼번에 보관하지 않는다.

```python
with collection.watch() as stream:
    for change in stream:
        process(change)
```

단, `process()`가 이벤트를 별도의 무제한 큐에 다시 넣거나 Kafka 전송보다 느리다면 큐가 계속 증가할 수 있으므로, 이 경우에는 bounded queue와 backpressure를 고려해야 한다.

## 2. 최상위 필드 설명

| 키 | Python 값의 형태 | 의미 |
|---|---|---|
| `_id` | `dict` 또는 BSON document | Change Stream 이벤트의 식별자이자 resume token |
| `operationType` | `str` | 발생한 변경의 종류 |
| `clusterTime` | `bson.timestamp.Timestamp` | 해당 operation의 oplog timestamp |
| `wallTime` | `datetime.datetime` | 같은 operation에 대한 MongoDB 서버의 wall-clock 시간 |
| `fullDocument` | `dict` | 변경된 문서의 내용인 payload |
| `ns` | `dict` | 변경이 발생한 database와 collection 정보 |
| `documentKey` | `dict` | 변경된 문서를 식별하는 key |

이 예시는 `operationType`이 `insert`인 이벤트다. 즉, `datalake.bronze` collection에 새 문서가 추가되었다는 의미다.

## 3. `_id`: Change Stream resume token

```python
change["_id"]
```

예시에서는 다음 값이다.

```python
{
    "_data": "826AB160D5000000012B042C..."
}
```

이 `_id`는 `fullDocument["_id"]`나 `documentKey["_id"]`와 다른 값이다. 문서의 식별자가 아니라 **Change Stream에서 해당 이벤트의 위치를 식별하는 값**이다.

다음 실행에서 이 이벤트 이후부터 읽고 싶다면 `_id` 전체를 `resume_after`에 전달한다.

```python
last_token = change["_id"]

with collection.watch(resume_after=last_token) as stream:
    for next_change in stream:
        ...
```

`resume_after=last_token`은 token에 해당하는 이벤트를 다시 포함하는 것이 아니라, 그 이벤트 **다음 이벤트부터** Change Stream을 재개한다.

`_data` 문자열의 내부 구조는 애플리케이션이 해석하거나 직접 생성할 대상이 아니다. resume token은 opaque value로 취급하고, `_id` document 전체를 그대로 저장해야 한다.

## 4. `operationType`: 변경 종류

```python
change["operationType"] == "insert"
```

`operationType`은 Change Stream이 보고하는 변경의 종류다.

대표적인 값은 다음과 같다.

| 값 | 의미 |
|---|---|
| `insert` | 새 문서가 추가됨 |
| `update` | 기존 문서의 일부 필드가 변경됨 |
| `replace` | 기존 문서가 전체 문서로 교체됨 |
| `delete` | 문서가 삭제됨 |
| `invalidate` | collection drop, rename 등으로 기존 stream을 계속 사용할 수 없음 |

MongoDB 설정과 Change Stream scope에 따라 `create`, `drop`, `rename`, `modify`, `createIndexes` 같은 DDL 관련 이벤트가 나타날 수도 있다. 이런 이벤트는 일반적인 문서 CRUD 이벤트와 필드 구성이 다를 수 있으므로 `operationType`을 기준으로 분기할 수 있어야 한다.

## 5. `clusterTime`: oplog timestamp

```python
change["clusterTime"]
# Timestamp(1790009557, 1)
```

PyMongo의 `Timestamp`는 일반적인 Python `datetime`이 아니다. Change Stream 이벤트의 `clusterTime`은 해당 database operation을 나타내는 oplog entry의 `ts`를 반영한다. 보통 다음 두 값을 가진다.

```text
Timestamp(time, increment)
```

- `time`: Unix epoch 기준 초 단위 시간. PyMongo에서는 `clusterTime.time` 또는 tuple의 첫 번째 값에 해당한다.
- `increment`: 같은 초 안에서 oplog operation을 구분하기 위한 ordinal. PyMongo에서는 `clusterTime.inc` 또는 tuple의 두 번째 값에 해당한다.

따라서 예시의 값은 다음 의미를 가진다.

```text
time      = 1790009557
increment = 1
```

이 값은 `wallTime`과 전혀 다른 operation의 시간이 아니다. 두 필드는 같은 database operation에 대해 서로 다른 정밀도와 표현 방식을 제공한다.

```text
clusterTime.time = 1790009557
  → 초 단위 timestamp

clusterTime.inc = 1
  → 해당 초 안에서의 oplog ordinal
```

`clusterTime.time`은 초 단위로 기록되므로 밀리초 이하의 정밀도를 표현하지 않는다. `clusterTime.inc`는 시간의 소수 부분이 아니라 같은 초 안에서 operation을 구분하기 위한 순번이다. 따라서 `clusterTime`은 oplog에서 operation을 정렬하고 식별하기 위한 timestamp이며, operation의 시작·종료 시간이나 Change Stream client가 event를 받은 시간을 의미하지 않는다.

정확한 Change Stream event를 재개하기 위한 위치는 `clusterTime`이 아니라 최상위 `_id`의 resume token을 사용한다. 여러 이벤트가 같은 `clusterTime`을 공유할 수 있기 때문이다.

## 6. `wallTime`: 서버 작업 시각

```python
change["wallTime"]
# datetime.datetime(2026, 9, 21, 16, 52, 37, 302000)
```

`wallTime`은 같은 database operation에 대해 MongoDB 서버가 기록한 wall-clock 시간이다. 예시에서는 다음과 같이 해석할 수 있다.

```text
2026-09-21 16:52:37.302000
```

두 필드는 같은 operation을 서로 다른 방식으로 표현한다.

```text
clusterTime.time
  2026-09-21 16:52:37 정도의 초 단위 oplog timestamp

wallTime
  2026-09-21 16:52:37.302000의 datetime
```

이 예시에서 보이는 약 302ms의 차이는 oplog 기록이 그만큼 늦었다는 뜻이 아니다. `clusterTime.time`은 초 단위이고 `wallTime`은 밀리초 정밀도의 datetime이므로 발생하는 표현 정밀도 차이다. 이 두 필드만으로 operation의 정확한 시작·종료 시각 또는 oplog 기록 완료 시각을 계산할 수는 없다.

PyMongo의 timezone 설정에 따라 `datetime`이 timezone-naive 또는 timezone-aware 형태로 반환될 수 있다. JSON이나 Avro로 변환할 때는 timezone 정책과 표현 형식을 별도로 정해야 한다.

## 7. `fullDocument`: payload

```python
change["fullDocument"]
```

이 필드는 변경된 문서의 실제 내용인 payload다. 이 문서에서는 `fullDocument` 내부 필드의 의미는 다루지 않는다.

현재 예시가 `insert` 이벤트이므로 새로 추가된 전체 문서가 들어 있다. `update`, `replace`, `delete` 이벤트에서는 `watch()` 옵션과 작업 종류에 따라 `fullDocument`의 존재 여부와 내용이 달라질 수 있다.

## 8. `ns`: 변경 대상 namespace

```python
change["ns"]
# {"db": "datalake", "coll": "bronze"}
```

`ns`는 변경이 발생한 MongoDB namespace를 나타낸다.

```text
database = datalake
collection = bronze
namespace = datalake.bronze
```

`ns` 내부의 필드는 다음과 같다.

| 키 | 값 | 의미 |
|---|---|---|
| `db` | `"datalake"` | database 이름 |
| `coll` | `"bronze"` | collection 이름 |

MongoDB에서 namespace는 일반적으로 `database.collection` 조합을 뜻한다. shard 번호는 MongoDB namespace의 일부가 아니다.

## 9. `documentKey`: 변경된 문서의 식별자

```python
change["documentKey"]
# {"_id": ObjectId("6ab160d5a312a9a292a89588")}
```

`documentKey`는 CRUD 작업의 대상이 된 문서를 식별하는 key다.

예시에서는 문서의 `_id`만 포함되어 있다.

```python
document_id = change["documentKey"]["_id"]
# ObjectId("6ab160d5a312a9a292a89588")
```

sharded collection에서는 `documentKey`에 문서의 `_id`뿐 아니라 shard key 필드가 함께 포함될 수 있다. 따라서 `documentKey`를 항상 `_id` 하나만 가진다고 가정하면 안 된다.

`documentKey["_id"]`는 실제 MongoDB 문서의 식별자이고, 최상위 `change["_id"]`는 Change Stream resume token이다.

## 10. BSON 값과 Python 타입

이벤트에는 JSON에 기본적으로 존재하지 않는 BSON 타입이 포함될 수 있다.

| BSON 값 | PyMongo에서 보이는 Python 타입 | 주의할 점 |
|---|---|---|
| `ObjectId` | `bson.objectid.ObjectId` | 문자열로 변환할지, 12바이트/24자리 hex로 표현할지 규칙 필요 |
| `Timestamp` | `bson.timestamp.Timestamp` | `datetime`과 다르며, `time`과 `increment`를 가짐 |
| `BSON Date` | `datetime.datetime` | timezone 및 ISO-8601/epoch 표현 규칙 필요 |
| `Binary` | `bson.binary.Binary` | base64 등 전송 표현 규칙 필요 |
| `Decimal128` | `bson.decimal128.Decimal128` | 문자열 또는 정밀도를 보존하는 decimal 표현 규칙 필요 |

따라서 PyMongo가 반환한 Python 객체는 애플리케이션 내부 표현이지, JSON이나 Avro로 바로 전송할 최종 byte format은 아니다. `Serializer`는 이 BSON 타입을 대상 포맷의 규칙에 맞게 변환해야 한다.

## 11. 현재 이벤트를 `BsonDocument`로 해석하는 방법

현재 설계에서 하나의 Change Stream 이벤트는 다음처럼 나눌 수 있다.

```python
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from bson.timestamp import Timestamp


@dataclass(frozen=True)
class BsonDocument:
    resume_token: Mapping[str, Any]
    operation_type: str
    cluster_time: Timestamp
    wall_time: datetime
    namespace: Mapping[str, str]
    document_key: Mapping[str, Any]
    full_document: Mapping[str, Any] | None
```

필드 매핑은 다음과 같다.

```python
BsonDocument(
    resume_token=change["_id"],
    operation_type=change["operationType"],
    cluster_time=change["clusterTime"],
    wall_time=change["wallTime"],
    namespace=change["ns"],
    document_key=change["documentKey"],
    full_document=change.get("fullDocument"),
)
```

여기서 `resume_token`은 checkpoint 저장을 위해 보존하고, `full_document`는 Serializer가 Kafka payload로 변환할 대상이다. `document_key`, `namespace`, `operation_type`, 시간 정보는 Kafka message key, metadata, partitioning, 추적 및 중복 제거에 사용할 수 있다.

## 12. 참고 자료

- [MongoDB PyMongo Driver - Monitor Data with Change Streams](https://www.mongodb.com/docs/languages/python/pymongo-driver/current/monitoring-and-logging/change-streams/)
- [MongoDB Database Manual - Insert Change Event](https://www.mongodb.com/docs/manual/reference/change-events/insert/)
- [MongoDB Database Manual - Change Stream Events](https://www.mongodb.com/docs/manual/reference/change-events/)
