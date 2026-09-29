# Speed Layer Frontend

## 목적과 범위

Speed Layer의 Frontend Layer는 MongoDB Change Stream의 변경 이벤트를 읽어 공통 이벤트 모델로 변환하고, python 객체 타입으로 정규화 및 전송 포맷으로 직렬화한 뒤 Kafka에 전달하는 진입 계층이다.

Spark의 집계, 조인, 상태 관리, 윈도우 연산은 이 계층의 책임이 아니다. Spark는 Kafka에 기록된 데이터를 소비하는 독립적인 Backend Layer의 책임으로 둔다.

## 현재 구현 상태

현재 실행 진입점은 `main.py`이며, 설정 읽기·객체 생성·이벤트 처리 루프가 한 파일에 함께 있다.

```text
main.main()
  → MongoShard, Normalizer, Serializer, Producer 생성
  → MongoShard.read_changes()
  → Normalizer.normalize(raw)
  → Serializer.serialize(normalized_document)
  → Producer.produce(**serialized_data)
  → Producer.poll()
```

- `MongoShard.read_changes()` → `Normalizer.normalize()` → `Serializer.serialize()` → `Producer.produce()` 순서로 이벤트를 전달한다. `produce()`는 비동기 호출이며 기본 callback은 결과를 로그로 남긴다.
- `main.py`의 import 경로 조정과 자원 종료 방식은 아직 정리되지 않았다. 미완료 보완은 [`future_works.md`](./future_works.md)에서 추적한다.
- 현재 Serialization Layer는 임시적 구현이며 세부 동작과 한계는 [`Serializer.md`](./Serializer.md)에 기록한다.

## 계층 경계와 책임

| 구성 요소 | 한 문장 책임 | 상세 문서 |
|---|---|---|
| `MongoShard` | MongoDB Change Stream을 읽어 `BsonDocument` 이벤트를 반환한다. | [`MongoShard.md`](./MongoShard.md) |
| `BsonDocument` | Change Stream 이벤트 하나와 resume token을 담는다. | [`BsonDocument.md`](./data_classes/BsonDocument.md) |
| `Normalizer` | 이벤트를 포맷 중립적인 `NormalizedDocument`로 변환한다. | [`Normalizer.md`](./Normalizer.md) |
| `NormalizedDocument` | 정규화된 이벤트의 데이터 계약을 표현한다. | [`NormalizedDocument.md`](./data_classes/NormalizedDocument.md) |
| `Serializer` | `full_document`을 Kafka 전송 value로 만들고 `produce()` 인자 dict를 준비한다. | [`Serializer.md`](./Serializer.md) |
| Kafka 전송 | 별도 producer wrapper 없이 native `confluent_kafka.Producer`를 직접 사용한다. | [현재 구현 상태](#현재-구현-상태) |
| 실행 조정 | 설정과 객체 생성, 이벤트 처리를 현재 `main.py`가 담당한다. | [`implementation-plan.md`](./implementation-plan.md) |
| 미완료 작업 | 구현되지 않았거나 보완할 항목을 한곳에서 추적한다. | [`future_works.md`](./future_works.md) |

Kafka의 `Producer`를 별도의 Wrapper 클래스로 감싸지 않고 직접 사용한다. 각 모듈의 현재 동작과 한계는 해당 모듈 문서에, 남은 작업의 목록과 순서는 `future_works.md`에 둔다.

## 미완료 작업

Checkpoint와 전달 보장 등 현재 구현되지 않은 항목의 기준 목록은 [`future_works.md`](./future_works.md)에서 관리한다.


## 데이터 계약의 핵심

- `BsonDocument`는 MongoDB/PyMongo의 원래 타입을 보존할 수 있다.
- `NormalizedDocument`는 MongoDB의 고유 데이터 타입(ex, `ObjectId`)을 Python 데이터 타입으로 변환하여 다른 Layer에서 사용할 수 있도록 한 데이터 타입이다.
- 별도의 `SerializedData` 데이터 클래스는 두지 않는다. `Serializer`가 `Producer`호출 인자를 python dict로 반환한다.

## 모듈별 문서

- 데이터 객체: [`BsonDocument.md`](./data_classes/BsonDocument.md), [`NormalizedDocument.md`](./data_classes/NormalizedDocument.md)
- MongoDB 입력: [`MongoShard.md`](./MongoShard.md)
- 공통 정규화: [`Normalizer.md`](./Normalizer.md)
- Kafka 전송 인자 준비: [`Serializer.md`](./Serializer.md)
- 전체 호출 구조와 구현 계획: [`implementation-plan.md`](./implementation-plan.md)
- BSON과 PyMongo 타입 참고: [`bson-python.md`](./bson-python.md)
- 미완료 작업의 단일 목록: [`future_works.md`](./future_works.md)
