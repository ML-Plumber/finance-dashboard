# `Serializer`

`Serializer`는 [`NormalizedDocument`](./data_classes/NormalizedDocument.md)의 `full_document`만 선택해 value serializer로 변환하고, Kafka 전송에 사용할 값을 일반 dictionary로 반환한다. 아직은 별도의 record dataclass나 interface는 만들지 않는다.

## 설정

생성자에서 `topic`, key serializer(`ks`), value serializer(`vs`), delivery callback을 받아 인스턴스에 저장한다.

현재는 key를 만들지 않으므로 `ks`는 보관만 하고 사용하지 않는다. key 생성 규칙이 정해지면 그때 적용한다.

## 변환 흐름

```text
NormalizedDocument
    → full_document 선택
    → vs로 value 직렬화
    → 전송 인자 dictionary 반환
```

`serialize(normalized_document)`는 다음과 같은 일반 dictionary를 반환한다.

```python
{
    "topic": self.topic,
    "value": self.vs.serialize(normalized_document.full_document),
    "key": None,
    "headers": None,
    "callback": self.callback,
}
```

이 dictionary는 Kafka 전송 인자를 준비하는 임시 구조이며, 전용 데이터 클래스로 고정하지 않는다. 실제 `Producer.produce()`에 전달할 때 callback 인자명은 사용 중인 `confluent-kafka` API에 맞춘다.

## 파이프라인에서의 위치

```text
BsonDocument → Normalizer → NormalizedDocument → Serializer → Producer
```

현재 문서는 이 흐름의 설계만 정의한다. Producer 호출과 CheckPointSaver 연동은 pipeline 구현 단계에서 연결한다.
