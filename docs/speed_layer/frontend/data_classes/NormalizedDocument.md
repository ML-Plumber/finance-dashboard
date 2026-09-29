# `NormalizedDocument`

`NormalizedDocument`는 [`BsonDocument`](./BsonDocument.md)의 이벤트 구조를 유지하면서 BSON/PyMongo 타입을 애플리케이션의 공통 의미 타입으로 변환한 결과다.

```python
@dataclass(frozen=True)
class NormalizedDocument:
    source_id: str
    namespace: str
    operation_type: str
    document_key: Mapping[str, Any] | None
    full_document: Mapping[str, Any] | None
    resume_token: Mapping[str, Any]
    cluster_time: Any
    wall_time: datetime | None
```

* 해당 클래스의 실제 예시
```text
NormalizedDocument(
    source_id='0',
    namespace='datalake.bronze',
    operation_type='insert',
    document_key={'_id': '6abb64446030da41daeeaecc'},
    full_document={'_id': '6abb64446030da41daeeaecc',
                    'event_type': 'aggTrade',
                    'event_time': datetime.datetime(2026, 9, 29, 7, 9, 56, 118000, tzinfo=datetime.timezone.utc),
                    'symbol': 'BTCUSDT',
                    'trade_id': 4076450347,
                    'price': '84041.36000000',
                    'quantity': '0.00414000',
                    'first_trade_id': 6721221798,
                    'last_trade_id': 6721221798,
                    'trade_time': datetime.datetime(2026, 9, 29, 7, 9, 56, 117000, tzinfo=datetime.timezone.utc),
                    'is_buyer_maker': True,
                    'M': True},
    resume_token={'_data': '826ABB6444000000012B042C0100296E5A1004363B1922266B44CEA54F5C3E11517B3D463C6F7065726174696F6E54797065003C696E736572740046646F63756D656E744B65790046645F696400646ABB64446030DA41DAEEAECC000004'},
    cluster_time=datetime.datetime(2026, 9, 29, 7, 9, 56, tzinfo=FixedOffset(datetime.timedelta(0), 'UTC'))
)
```
* normalized_document.fulldocument가 가끔 아래와 같이 출력되는 경우가 존재
```text

    {'_id': '6abb7292610a31b38671a7aa', 'result': None, 'id': 1}
    {'_id': '6abb7292610a31b38671a7aa', 'result': None, 'id': 1}
```

## 초기 공통 변환 규칙

| BSON/PyMongo 타입 | `NormalizedDocument` 표현 예시 |
|---|---|
| `ObjectId` | 정규화된 식별자 문자열 또는 전용 값 객체 |
| `datetime` | UTC timezone-aware `datetime` |
| `Decimal128` | 정밀도를 보존하는 `Decimal` 또는 전용 Decimal 값 객체 |
| `Binary` | `bytes` |
| `Timestamp` | `seconds`와 `increment`를 가진 전용 구조 |

`full_document`와 `document_key` 내부의 중첩 값에도 같은 규칙을 재귀적으로 적용한다. 다만 JSON 문자열 표현을 이 단계에서 미리 결정하지 않는다. JSON Serializer는 `datetime`을 ISO-8601 문자열로 만들 수 있고, Avro Serializer는 같은 값을 `timestamp-millis` 또는 `timestamp-micros`로 표현할 수 있다.

## 포맷 중립 계약

`NormalizedDocument`는 JSON과 Avro가 같은 비즈니스 의미를 공유하기 위한 경계다. 동일한 입력에 대해 두 Serializer가 서로 다른 의미를 만들지 않도록 필드명, 시간대, Decimal 정밀도, binary 표현 정책을 데이터 계약으로 확정한다.

## 현재 구현

실제 dataclass는 `src/speed_layer/frontend/data_classes/NormalizedDocument.py`에 정의되어 있다.

```python
@dataclass(frozen=True)
class NormalizedDocument:
    source_id: str
    namespace: str
    operation_type: str
    document_key: Mapping[str, Any] | None
    full_document: Mapping[str, Any] | None
    resume_token: Mapping[str, Any]
    cluster_time: datetime
```

현재 dataclass에는 위 초기 인터페이스 예시의 `wall_time` 필드가 없고, 실제 `cluster_time` annotation은 `datetime`이다.

기본 Normalizer와 현재 실행 예시에서는 `document_key`와 `full_document` 내부 `ObjectId`를 문자열로 바꾸고, 이름이 `_time`으로 끝나는 숫자 필드를 UTC-aware Python `datetime`으로 바꾼다. `resume_token`은 이 변환 규칙에 해당하지 않으므로 mapping 형태로 유지된다. `cluster_time`은 Normalizer가 datetime으로 바꿔 넣는다. 상세한 변환 조건과 한계는 [`Normalizer.md`](./Normalizer.md)의 현재 구현 및 현재 코드의 한계 섹션을 참조한다.

## 현재 코드의 한계

- dataclass annotation은 런타임 타입 검증을 수행하지 않는다.
- `frozen=True`는 필드 재할당만 막으며, 내부 mapping이나 중첩 값의 변경까지 막지는 않는다.
- `cluster_time`은 필수 `datetime`으로 선언되어 있지만, 원본 이벤트에 값이 없으면 Normalizer가 `None`을 전달할 수 있다.
- `document_key`와 `full_document`는 `Mapping[str, Any]`로 열려 있어 내부 필드 구조나 값 타입을 검증하지 않는다.
