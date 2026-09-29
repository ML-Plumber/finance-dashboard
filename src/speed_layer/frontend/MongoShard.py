from typing_extensions import (
    Any,
    Mapping,
    Iterator,
)
from pymongo import MongoClient
from data_classes.BsonDocument import BsonDocument
from my_utils import green_print

class MongoShard :
    def __init__(self, source_id: str, client: MongoClient, db: str, collection: str) :
        self.source_id = str(source_id)
        self._client = client

        # exception 발생 가능성 존재하므로, MongoShard 생성 시 try except로 잡아주기.
        self._client.admin.command('ping')
        self._db = client[db]
        self._collection = self._db[collection]

        green_print("===== Connect to mongodb Successfully =====")
        green_print(f"connected database name : {db}")
        green_print(f"connected collection name : {collection}")

    def read_changes(
            self,
            resume_after: Mapping[str, Any] | None = None,
            cursor_options: dict[str, Any] | None = None,
    ) -> Iterator[BsonDocument]:
        if cursor_options is None :
            cursor_options = {
                "full_document": "updateLookup",
                "batch_size": 30,
                "max_await_time_ms": 100,
            }

        if resume_after is not None:
            cursor_options["resume_after"] = resume_after

        with self._collection.watch(**cursor_options) as cursor :
            for change in cursor :
                yield self._to_bson_document(change)

    def _to_bson_document(self, raw_event: Mapping[str, Any]) -> BsonDocument:
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

    def __del__(self) :
        print("MongoShard : Disconnecting from mongodb\n")
        self._client.close()
