from dataclasses import dataclass
from typing_extensions import Mapping, Any
from datetime import datetime

@dataclass(frozen=True)
class NormalizedDocument :
    source_id: str # shard 번호
    namespace: str # db.collection 정보
    operation_type: str # insert, update 등의 정보 반영
    document_key: Mapping[str, Any] | None # mongoDB document 식별자 정보
    full_document: Mapping[str, Any] | None # document의 원본 내용
    resume_token: Mapping[str, Any] # 나중에 CheckPointSaver가 사용할 token value
    cluster_time: datetime # oplog에서 event를 식별하기 위해서 사용될 수 있는 값
