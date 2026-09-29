# `MongoShard`

`MongoShard`는 하나의 논리적 MongoDB shard 또는 shard Replica Set에 연결하여 Change Stream을 읽고, 각 raw event를 [`BsonDocument`](./BsonDocument.md)으로 감싸서 반환한다.

## 책임

- MongoDB Replica Set 연결
- 대상 database와 collection 선택
- Change Stream 열기
- MongoDB에서 이벤트 읽기
- 읽은 이벤트를 `BsonDocument`로 변환
- `source_id`와 resume token을 이벤트에 포함
- 연결 장애를 감지하고 재연결 정책을 적용하거나 오류 전달

## 담당하지 않는 일

- Avro 또는 JSON 직렬화
- Kafka 전송
- Spark 처리
- resume token 저장
- 이벤트 처리가 최종적으로 성공했는지 판단

## 기본 인터페이스

```python
class MongoShard:
    source_id: str

    def read_changes(
        self,
        resume_after: Mapping[str, Any] | None = None,
    ) -> Iterator[BsonDocument]:
        """Change Stream 이벤트를 순서대로 반환한다."""
        ...
```

Change Stream은 종료되지 않는 스트림이므로 하나의 `BsonDocument`나 전체 목록보다 `Iterator[BsonDocument]` 또는 `AsyncIterator[BsonDocument]`를 반환하는 형태가 적합하다.

## Cursor를 이벤트 iterator로 감싸기

PyMongo의 `collection.watch()`는 Change Stream cursor를 반환한다. `MongoShard`는 이 cursor를 외부에 그대로 노출하지 않고, generator 함수로 감싸 raw dictionary를 `BsonDocument`로 변환해 `yield`한다.

```python
class MongoShard:
    def read_changes(
        self,
        resume_after: Mapping[str, Any] | None = None,
    ) -> Iterator[BsonDocument]:
        cursor_options: dict[str, Any] = {
            "full_document": "default",
            "batch_size": 100,
            "max_await_time_ms": 5_000,
        }

        if resume_after is not None:
            cursor_options["resume_after"] = resume_after

        with self._collection.watch(**cursor_options) as cursor:
            for raw_event in cursor:
                yield self._to_bson_document(raw_event)

    def _to_bson_document(
        self,
        raw_event: Mapping[str, Any],
    ) -> BsonDocument:
        namespace = raw_event["ns"]

        return BsonDocument(
            source_id=self.source_id,
            namespace=f'{namespace["db"]}.{namespace["coll"]}',
            operation_type=raw_event["operationType"],
            document_key=raw_event.get("documentKey"),
            full_document=raw_event.get("fullDocument"),
            resume_token=raw_event["_id"],
            cluster_time=raw_event.get("clusterTime"),
        )
```

이 흐름은 다음과 같다.

```text
collection.watch()
  → raw_event 1개 읽기
  → BsonDocument 1개 생성
  → yield
  → 호출자가 이벤트 처리
  → 다음 raw_event 읽기
```

전체 cursor 결과를 `list()`로 변환하지 않으므로 모든 이벤트를 메모리에 쌓지 않는다. 호출자가 다음 이벤트를 요청할 때까지 다음 MongoDB 이벤트를 읽지 않으므로 streaming과 backpressure가 자연스럽게 유지된다.

`with self._collection.watch(...) as cursor`를 사용하면 iterator가 정상적으로 끝나거나 close될 때 cursor가 닫힌다. 직접 cursor를 생성한다면 반드시 `try/finally`에서 `cursor.close()`를 호출한다.

```python
cursor = self._collection.watch(**cursor_options)
try:
    for raw_event in cursor:
        yield self._to_bson_document(raw_event)
finally:
    cursor.close()
```

Change Stream 이벤트의 `raw_event["_id"]`는 문서의 `_id`가 아니라 resume token이다. 실제 MongoDB 문서 식별자는 `raw_event.get("documentKey")` 안에 있을 수 있으므로 두 값을 구분한다.

## 단일 이벤트 API와 iterator API

외부에 노출하는 기본 메서드는 iterator 기반 `read_changes()`로 둔다.

```python
for document in mongo_shard.read_changes():
    ...
```

현재 cursor에서 이벤트 하나만 읽는 저수준 메서드가 필요하다면 별도로 둘 수 있다.

```python
def read_one(self) -> BsonDocument | None:
    """현재 cursor에서 이벤트 하나를 읽는다."""
    ...
```

장기 실행되는 Change Stream의 일반적인 사용 방식으로는 `read_one()`보다 generator 기반 `read_changes()`가 적합하다. `read_one()`을 반복 호출한다면 cursor 생성, 유지, close, 재연결 책임을 별도로 명확히 한다.

## Resume token과 cursor 오류

`yield`는 이벤트를 읽었다는 뜻이지 Kafka 전송이나 downstream 처리가 성공했다는 뜻이 아니다. 따라서 `MongoShard`는 이벤트를 `yield`할 때 resume token을 저장하지 않는다.

권장 흐름은 다음과 같다.

```text
CheckPointSaver에서 마지막 last_offset 읽기
  → MongoShard.read_changes(resume_after=last_offset)
  → BsonDocument yield
  → Normalizer와 Serializer
  → KafkaProducer 전송 성공 확인
  → CheckPointSaver.set_last_offset(document.resume_token)
  → save_interval에 도달하면 maybe_save()
```

cursor가 오류로 종료되면 `MongoShard`가 임의의 새 위치에서 다시 시작하기보다, 마지막으로 성공적으로 commit된 resume token을 Pipeline이 다시 전달하도록 한다. 장애 이후 중복 이벤트가 발생할 수 있지만 이벤트 유실을 피할 수 있으며, 중복 처리는 downstream의 멱등성으로 해결한다.

`batch_size`와 `max_await_time_ms`는 외부 설정으로 둔다. `full_document="updateLookup"`은 update 이벤트마다 추가 조회를 유발할 수 있으므로 실제로 전체 문서가 필요한 경우에만 사용한다.

## Shard와 Replica Set의 관계

`MongoShard`는 Replica Set의 모든 노드에 각각 하나씩 stream을 열기 위한 객체가 아니다. 향후 shard별 병렬 처리를 도입할 때 논리적 shard마다 하나의 인스턴스를 생성한다.

```text
MongoShard("shard01") → shard01의 변경 이벤트
MongoShard("shard02") → shard02의 변경 이벤트
```

Replica Set의 각 멤버는 같은 데이터를 복제하므로 같은 Replica Set의 모든 멤버에서 동시에 Change Stream을 읽으면 이벤트가 분할되지 않고 중복될 수 있다.
