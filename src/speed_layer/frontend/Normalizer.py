from typing_extensions import Callable, Mapping, Any
from data_classes.BsonDocument import BsonDocument
from data_classes.NormalizedDocument import NormalizedDocument

from bson.timestamp import Timestamp
from bson.objectid import ObjectId

from datetime import datetime, timezone
from dataclasses import asdict

class Normalizer :
    def __init__(
        self,
        normalize_func: Callable[[BsonDocument], NormalizedDocument] | None = None,
    ) :
        if normalize_func is None :
            self._normalize_func = self._default_normalize_func
        else :
            self._normalize_func = normalize_func

    def normalize(self, bson_document: BsonDocument) -> NormalizedDocument :
        ret_val = self._normalize_func(bson_document)
        return ret_val

    def _default_normalize_func(self, bson_document: BsonDocument) -> NormalizedDocument :
        dict_bson = asdict(bson_document)
        d = self._conversion_to_python_obj_recur(dict_bson)

        normalized_document = NormalizedDocument(**d)
        return normalized_document

    def _conversion_to_python_obj_recur(self, target: dict[str, Any]) -> dict : 
        ret_dict = {}
        for k, v in target.items() :
            if isinstance(v, dict) :
                ret_dict[k] = self._conversion_to_python_obj_recur(v)
            elif isinstance(v, Timestamp) :
                ret_dict[k] = v.as_datetime()
            elif isinstance(v, ObjectId) :
                ret_dict[k] = str(v)
            elif k.endswith("_time") :
                ret_dict[k] = datetime.fromtimestamp(v / 1000.0, tz=timezone.utc)
            else :
                ret_dict[k] = v

        return ret_dict

