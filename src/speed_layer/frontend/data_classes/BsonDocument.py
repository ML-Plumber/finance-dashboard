from typing_extensions import Mapping, Any
from dataclasses import dataclass

#from BsonDocument import BsonDocument
@dataclass(frozen=True)
class BsonDocument:
    source_id: str
    namespace: str
    operation_type: str
    document_key: Mapping[str, Any] | None
    full_document: Mapping[str, Any] | None
    resume_token: Mapping[str, Any]
    cluster_time: Any
