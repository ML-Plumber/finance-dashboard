import os

from MongoShard import MongoShard
from data_classes import (
    BsonDocument,
    NormalizedDocument
)

from pymongo import MongoClient
from pymongo.errors import ConnectionFailure
from dotenv import load_dotenv
from confluent_kafka import Producer

def get_config() :
    config ={
        'source_id' : os.environ.get("SOURCE_ID"),
        'client' : MongoClient(os.environ.get("MONGO_URL")),
        'db' : os.environ.get("DB_NAME"),
        'collection' : os.environ.get("COLLECTION_NAME")
    }
    return config

def main() :
    load_dotenv()
    config = get_config()
    try :
        mongoshard = MongoShard(**config)
    except ConnectionFailure as e :
        print(f"Network error occured during connection : {e}")

    # CheckPointSaver사용 시 여기서 호출

    while True :
        for raw in mongoshard.read_changes() :
            print(raw) # BsonDocument(source_id='0', namespace='datalake.bronze', operation_type='insert', document_key={'_id': ObjectId('6abb21420adb1ad7c6257482')}, full_document={'_id': ObjectId('6abb21420adb1ad7c6257482'), 'event_type': 'aggTrade', 'event_time': 1790648642459, 'symbol': 'BTCUSDT', 'trade_id': 4076323231, 'price': '83024.09000000', 'quantity': '0.08416000', 'first_trade_id': 6720823739, 'last_trade_id': 6720823741, 'trade_time': 1790648642459, 'is_buyer_maker': True, 'M': True}, resume_token={'_data': '826ABB2142000000012B042C01002B546E5A1004363B1922266B44CEA54F5C3E11517B3D463C6F7065726174696F6E54797065003C696E736572740046646F63756D656E744B65790046645F696400646ABB21420ADB1AD7C6257482000004'}, cluster_time=Timestamp(1790648642, 1))

if __name__ == "__main__" :
    main()
