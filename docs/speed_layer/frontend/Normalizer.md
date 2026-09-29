# `Normalizer`

`Normalizer`는 [`BsonDocument`](./data_classes/BsonDocument.md)를 포맷 중립적인 [`NormalizedDocument`](./data_classes/NormalizedDocument.md)로 변환한다.

이 계층은 JSON에 맞춘 dictionary를 만드는 계층이 아니다. 여러 출력 포맷에서 같은 의미를 유지할 수 있도록 공통 의미와 타입을 정하는 계층이다.

## 위치와 흐름

```text
BsonDocument
    ↓
Normalizer
    ↓
NormalizedDocument
    ├── JsonSerializer
    └── AvroSerializer
```

## 인터페이스

```python
class Normalizer(ABC):
    @abstractmethod
    def normalize(
        self,
        document: BsonDocument,
    ) -> NormalizedDocument:
        ...
```

`NormalizedDocument`의 필드와 공통 데이터 타입은 [`NormalizedDocument.md`](./data_classes/NormalizedDocument.md)에서 정의한다.

## 초기 공통 변환 규칙

| BSON/PyMongo 타입 | `NormalizedDocument` 표현 예시 |
|---|---|
| `ObjectId` | 정규화된 식별자 문자열 또는 전용 값 객체 |
| `datetime` | UTC timezone-aware `datetime` |
| `Decimal128` | 정밀도를 보존하는 `Decimal` 또는 전용 Decimal 값 객체 |
| `Binary` | `bytes` |
| `Timestamp` | `seconds`와 `increment`를 가진 전용 구조 |

`full_document`와 `document_key` 안의 중첩 값도 동일한 규칙으로 재귀적으로 정규화한다. 어떤 값으로 변환할지는 프로젝트의 데이터 계약으로 확정한다.

JSON 문자열 표현을 `Normalizer` 단계에서 미리 결정하지 않는 것이 좋다. JSON Serializer는 `datetime`을 ISO-8601 문자열로 만들 수 있고, Avro Serializer는 같은 값을 `timestamp-millis` 또는 `timestamp-micros`로 만들 수 있기 때문이다.

## 책임

- MongoDB/BSON 타입을 공통 애플리케이션 타입으로 변환
- 필드명과 공통 이벤트 메타데이터 정리
- 시간대와 timestamp 표현 규칙 적용
- `Decimal128`의 정밀도와 scale 정책 적용
- JSON과 Avro가 같은 의미를 사용하도록 정규화

## 담당하지 않는 일

- JSON 또는 Avro bytes 생성
- Kafka 전송
- MongoDB 연결
- 여러 이벤트를 모아 aggregation이나 windowing 수행

## 1:1 변환 계약

`Normalizer`는 한 이벤트를 한 이벤트로 변환하는 1:1 변환을 기본 계약으로 한다.

```text
BsonDocument 1개 → NormalizedDocument 1개
```

필터링, aggregation, windowing처럼 여러 입력을 모으거나 하나의 이벤트를 여러 이벤트로 분리하는 작업은 resume token과 checkpoint 처리에 영향을 준다. 초기 `Normalizer`에는 포함하지 않고, 필요해지면 별도의 `StreamTransformer` 또는 `BatchProcessor` 계층으로 분리한다.

## Identity Normalizer

정규화 규칙이 아직 단순한 초기 구현에서는 `IdentityNormalizer`를 둘 수 있다.

```python
class IdentityNormalizer(Normalizer):
    def normalize(self, document: BsonDocument) -> NormalizedDocument:
        ...
```

Identity 구현을 사용하더라도 Pipeline의 `BsonDocument → NormalizedDocument` 경계는 유지한다. 이후 BSON 타입 변환 규칙을 강화해도 Serializer의 계약을 변경하지 않도록 하기 위해서다.

## Serializer와의 분리

`Normalizer`와 Serializer는 서로 독립된 계층이다. Serializer가 내부에 서로 다른 Normalizer를 소유하면 포맷에 따라 정규화 결과가 달라질 수 있다. 전체 호출 순서는 `src/speed_layer/frontend/main.py`에서 확인하고, Serializer의 입력과 반환 구조는 [`Serializer.md`](./Serializer.md)를 참조한다.

## 현재 구현

실제 구현은 `src/speed_layer/frontend/Normalizer.py`에 있다. `Normalizer(normalize_func=None)`는 기본 변환 함수를 사용하고, 사용자가 `normalize_func`를 전달하면 해당 callable을 `normalize()`에서 그대로 호출한다. 사용자 callable 경로에서는 기본 재귀 변환이 자동으로 수행되지 않는다.

기본 경로의 순서는 다음과 같다.

1. `dataclasses.asdict(bson_document)`로 dataclass 내용을 dictionary로 만든다.
2. 변환 함수가 dictionary 값을 순회하면서 nested dictionary를 재귀 처리한다.
3. BSON `Timestamp`는 `as_datetime()` 결과로 바꾼다.
4. `ObjectId`는 문자열로 바꾼다.
5. 그 외에 key 이름이 `_time`으로 끝나면 값을 epoch millisecond로 간주해 `datetime.fromtimestamp(value / 1000.0, tz=timezone.utc)`로 UTC-aware datetime을 만든다.
6. 위 규칙에 맞지 않는 값은 그대로 둔 뒤 `NormalizedDocument(**converted)`를 생성한다.

## 현재 코드의 한계

- 현재 재귀 함수는 값이 `dict`인 경우만 재귀 처리한다. list 안의 dictionary나 BSON 값은 별도로 순회하지 않는다.
- `_time` suffix만으로 epoch millisecond라고 판단하므로 해당 이름의 값은 숫자 milliseconds라는 입력 계약이 필요하다. 값의 타입·단위 검증이나 source별 schema 검사는 아직 없다.
- 문자열 날짜, 이미 datetime인 값, 비숫자 값은 변환 중 예외가 발생할 수 있다. 초 단위 정수는 오류 없이 millisecond로 처리되어 잘못된 시각으로 변환될 수 있다.
- BSON `Timestamp`는 현재 `as_datetime()`으로 바뀌므로 원래의 increment 정보는 `NormalizedDocument`에 보존되지 않는다.
- 현재 변환 분기에는 `Decimal128`이나 `Binary` 전용 처리가 없어 입력 값이 그대로 남는다.
- 사용자 정의 `normalize_func`의 반환 타입이나 필드 구조를 별도로 검증하지 않는다.

위 내용은 현재 파일에 구현된 동작을 기록한 것이며, 기존의 공통 변환 규칙 표와 구분한다. 특히 `_time` 필드 변환은 source schema의 의미를 확인한 뒤 적용해야 한다.
