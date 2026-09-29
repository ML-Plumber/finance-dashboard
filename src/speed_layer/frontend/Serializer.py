import json
from data_classes.NormalizedDocument import NormalizedDocument
from typing_extensions import Any

from my_utils import (
    green_print,
    red_print
)

def _default_on_delivery(err, msg) :
    if err is not None :
        red_print(f'error occurred while sending message to kafka broker: {err} with msg: {msg}')
    else :
        green_print(f'send message successfully: {msg}')
        green_print('have to add counter and store offset, commit, CheckPointSaver myself')

class Serializer :
    def __init__(self, topic: str, vs=None, ks = None, header = None, on_delivery = None) :
        self._topic = topic
        self._vs = vs
        self._ks = ks
        self._header = header
        if on_delivery is not None :
            self._on_delivery = on_delivery
        else :
            self._on_delivery = _default_on_delivery

    def serialize(self, normalized_document: NormalizedDocument) -> dict[str, Any] :
        full_document = normalized_document.full_document

        ret_dict = {
            'topic' : self._topic,
            'key' : None,
            'headers' : None,
            'value' : json.dumps(str(full_document)), # 나중에 반드시 변경이 필요 'value' : self._vs()
            'on_delivery' : self._on_delivery
        }

        return ret_dict
