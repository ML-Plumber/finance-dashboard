# `BsonDocument`

`BsonDocument`는 MongoDB Change Stream에서 읽은 이벤트 하나를 표현하는 내부 데이터 클래스다. 초기에는 PyMongo가 반환한 BSON 기반 Python 타입을 그대로 보존할 수 있다.

```python
@dataclass(frozen=True)
class BsonDocument:
    source_id: str
    namespace: str
    operation_type: str
    document_key: Mapping[str, Any] | None
    full_document: Mapping[str, Any] | None
    resume_token: Mapping[str, Any]
    cluster_time: Any
```

## 필드

| 필드 | 의미 |
|---|---|
| `source_id` | 이벤트를 읽은 논리적 MongoDB source 또는 shard 식별자 |
| `namespace` | `db.collection` 형식의 대상 namespace |
| `operation_type` | insert, update, replace, delete 등 Change Stream 연산 종류 |
| `document_key` | 실제 MongoDB 문서 식별자 정보 |
| `full_document` | 이벤트에 포함된 전체 문서. 없을 수 있다. |
| `resume_token` | 다음 재시작 위치를 가리키는 Change Stream resume token |
| `cluster_time` | MongoDB cluster time |

`full_document`와 `document_key` 안의 필드는 collection마다 동적으로 달라질 수 있으므로 `Mapping[str, Any]`로 표현하는 것이 현실적이다.

## BSON/PyMongo 값

다음과 같은 BSON/PyMongo 타입이 포함될 수 있다.

- `ObjectId`
- `datetime`
- `Decimal128`
- `Binary`
- 중첩 dictionary와 list
- Change Stream resume token

`BsonDocument`가 JSON 또는 Avro 형식일 필요는 없다. 애플리케이션 내부의 Python 표현이며, Kafka로 전달되는 최종 bytes와는 다른 계층이다.

실제 문서의 `_id`와 Change Stream 이벤트의 `resume_token`은 서로 다른 값이다. `resume_token`은 문서 식별자가 아니라 Change Stream 재개 위치이며, 실제 문서 식별자는 `document_key`에 포함될 수 있다.

