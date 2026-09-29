import os
import sys

CURRENT_PATH = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.abspath(os.path.join(CURRENT_PATH, '../../'))

if SRC_DIR not in sys.path :
    sys.path.insert(0, SRC_DIR)

from dotenv import load_dotenv
from colorama import init
from my_utils import red_print
from MongoShard import MongoShard
from Normalizer import Normalizer
from Serializer import Serializer
from confluent_kafka import Producer
from pymongo.errors import (
    ConnectionFailure,
    PyMongoError,
)

def get_shard_config() :
    from pymongo import MongoClient

    config ={
        'source_id' : os.environ.get("SOURCE_ID"),
        'client' : MongoClient(os.environ.get("MONGO_URL")),
        'db' : os.environ.get("DB_NAME"),
        'collection' : os.environ.get("COLLECTION_NAME")
    }
    return config

def main() :
    #initialization 수행
    load_dotenv()
    init(autoreset=True)

    mongo_config = get_shard_config()
    producer_config = {'bootstrap.servers': 'localhost:9092'}
    try :
        # Producing을 위한 각 Instance 생성
        mongoshard = MongoShard(**mongo_config)
        normalizer = Normalizer()
        serializer = Serializer(topic='test_topic', )
        producer = Producer(producer_config)
    except ConnectionFailure as e :
        red_print(f"Network error occured during connection : {e}")
        return None

    # @@@CheckPointSaver사용 시 여기서 호출@@@

    try :
        while True :
            for raw in mongoshard.read_changes() :
                normalized_document = normalizer.normalize(raw)
                serialized_data = serializer.serialize(normalized_document)
                producer.produce(**serialized_data) # header에 manifest data 어떤 식으로 전달할지 고려가 필요함.
                producer.poll(1)
    except PyMongoError as e :
        red_print(f"error occured from change stream")

    producer.flush()
    del mongoshard

if __name__ == "__main__" :
    main()
