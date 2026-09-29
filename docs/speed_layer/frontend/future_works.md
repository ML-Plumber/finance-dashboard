# Frontend Future Works

이 문서는 Frontend Layer에서 아직 구현되지 않았거나 검증이 필요한 작업 목록이다. 현재 동작은 [`frontend.md`](./frontend.md), 모듈별 구현과 한계는 각 모듈 문서를 기준으로 한다. 작업을 완료로 표시하기 전에는 아래 확인 조건을 검증한다.

## 1. MongoDB에서 Kafka까지 end-to-end 검증

- [ ] `Serializer`의 임시 `json.dumps(str(full_document))`를 실제 value serialization으로 교체한다.
- [ ] `vs`가 설정된 경우 `NormalizedDocument.full_document`를 value serializer에 전달하고, serializer 출력이 Consumer에서 기대한 형태로 읽히는지 확인한다.
- [ ] 아직 필요한 key와 headers 정책이 없다면 `None`을 유지한다. 필요해질 때만 `ks`, key, header 값을 정하고 Producer 인자와 연결한다.
- [ ] 반환 dictionary의 callback 필드명을 native Producer API의 `on_delivery`에 맞춘다. 별도의 Producer wrapper나 `SerializedData` 데이터 클래스는 추가하지 않는다.
- [ ] MongoDB Change Stream 이벤트 하나를 Kafka로 보내고, Kafka consumer에서 topic과 value를 확인하는 재현 가능한 smoke test를 만든다.

## 2. 진입점과 구성 요소 생성 분리

- [ ] `main.py`에서 환경 설정, client 생성, 구성 요소 생성, 이벤트 처리 루프를 분리한다.
- [ ] `config.py`는 환경 변수 읽기와 필수 설정 검증을, `bootstrap.py`는 MongoClient/Producer와 의존성 생성·연결을 맡긴다.
- [ ] `pipeline.py`에 normalize → serialize → produce → poll의 실행 조정을 둔다. `main.py`는 설정·구성·실행을 이어주는 진입점으로 유지한다.
- [ ] `__init__.py`는 필요하면 패키지 공개 심볼만 제공한다. import 시 네트워크 연결이나 객체 생성 같은 부수 효과는 발생시키지 않는다.
- [ ] `sys.path` 직접 수정에 의존하지 않는 패키지 import 및 실행 방식을 정하고, 환경별 실행을 검증한다.
- [ ] `source_id`의 환경 변수 타입과 `MongoShard` 생성자 타입 계약을 일치시킨다.

## 3. Checkpoint 저장과 재시작

- [ ] `gen_get_log_files()`가 오늘, 오늘 - 1일, 오늘 - 2일 순으로 실제 `log_dir`에 존재하는 파일 이름만 yield한다.
- [ ] `_get_checkpoint_from_log_file()`가 파일에서 version, saved_at, source_id, namespace, last_offset을 갖춘 유효한 record를 찾는다.
- [ ] `_read_checkpoint_from_log_file()`가 최신 파일부터 탐색하고, `source_id`와 `namespace`가 현재 설정과 일치하는 record의 `last_offset`을 반환한다. 유효한 record가 없으면 `None`을 반환한다.
- [ ] 시작 시 복구한 offset을 `MongoShard.read_changes(resume_after=...)`에 전달한다.
- [ ] 각 이벤트의 resume token을 delivery callback과 연결하고 Kafka 전달 성공이 확인된 뒤에만 checkpoint를 저장한다.
- [ ] 파일이 없거나 비어 있음, 잘못된 JSON/필드, 다른 source/namespace, 저장 도중 프로세스 종료, 로그 날짜 경계 상황을 테스트한다.
- [ ] Kafka 성공 후 checkpoint 저장 전 종료하면 이벤트가 다시 처리될 수 있음을 전제로 at-least-once와 중복 처리 방식을 검증한다.

## 4. 정규화 계약과 테스트

- [ ] 기본 정규화의 현재 규칙인 ObjectId, BSON Timestamp, `*_time` epoch millisecond 변환을 테스트로 고정한다.
- [ ] list 안의 dictionary 및 BSON 값도 재귀 변환할지 결정하고, 선택한 동작을 테스트한다.
- [ ] Decimal128, Binary, null 및 delete/update 이벤트의 `full_document`처럼 현재 별도 정책이 없는 입력을 결정한다.
- [ ] `*_time` 이름만으로 단위를 가정하는 현재 동작에 대해 입력 타입, epoch 단위, UTC timezone 및 정밀도 계약을 검증한다.
- [ ] 사용자 제공 normalize callable이 올바른 `NormalizedDocument`를 반환하는지 검증한다.

## 5. 자원 수명과 오류 처리

- [ ] 정상 종료, 예외, 종료 신호에서 Change Stream cursor와 `MongoClient`가 닫히는 것을 보장한다.
- [ ] Producer의 `flush()` 결과와 delivery callback 오류를 확인하고, 실패를 성공으로 취급하지 않도록 한다.
- [ ] MongoDB 연결/Change Stream 오류와 Kafka 전송 오류의 중단·재시도 정책을 정한다.
- [ ] retry, producer queue backpressure, 로그 및 source별 metrics가 필요할 때 적용하고, checkpoint 순서와 함께 검증한다.

## 6. 후속 확장

- [ ] 추가 Confluent serializer/schema가 실제 요구될 때 JSON/Avro value 계약과 호환성을 검증한다.
- [ ] 처리량이나 장애 격리 요구가 생긴 경우에만 shard 병렬화와 source별 checkpoint 분리를 설계한다.
