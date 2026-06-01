import os
import time
import grpc
import redis as redis_lib
import boto3
from dotenv import load_dotenv

load_dotenv()

GRPC_TIMEOUT = 2
REDIS_TTL = 15
POLL_INTERVAL = 5

AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
REDIS_HOST = os.environ.get('REDIS_HOST', 'localhost')
REDIS_PORT = int(os.environ.get('REDIS_PORT', '6379'))

from proto import monitor_pb2, monitor_pb2_grpc


def get_app_instances(ec2_client) -> list:
    """
    Metodo que consulta EC2 para obtener las instancias que están etiquetadas como 'AppInstance'
    y en estado 'running'.

    """
    response = ec2_client.describe_instances(
        Filters=[
            {'Name': 'tag:Role', 'Values': ['AppInstance']},
            {'Name': 'instance-state-name', 'Values': ['running']},
        ]
    )
    ips = []
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            ips.append(instance['PrivateIpAddress'])
    return ips


def _make_grpc_stub(ip: str):
    """
    crea un stub gRPC para comunicarse con una instancia de MonitorC dada su dirección IP.
    """
    channel = grpc.insecure_channel(f'{ip}:50051')
    return monitor_pb2_grpc.MonitorServiceStub(channel)


def poll_instance(ip: str, redis_client, _stub_factory=None) -> None:
    if _stub_factory is None:
        _stub_factory = _make_grpc_stub
    try:
        stub = _stub_factory(ip)
        pong = stub.Ping(monitor_pb2.PingRequest(), timeout=GRPC_TIMEOUT)
        key = f'instance:{ip}'
        redis_client.hset(key, mapping={'load': pong.load, 'status': 'healthy'})
        redis_client.expire(key, REDIS_TTL)
    except grpc.RpcError as e:
        print(f'[WARN] Ping failed for {ip}: {e}')


def run(ec2_client, redis_client) -> None:
    print('[INFO] MonitorS started')
    while True:
        try:
            ips = get_app_instances(ec2_client)
            print(f'[INFO] Polling {len(ips)} instances')
            for ip in ips:
                poll_instance(ip, redis_client)
        except Exception as e:
            print(f'[ERROR] EC2 describe_instances failed: {e}')
        time.sleep(POLL_INTERVAL)


if __name__ == '__main__':
    ec2 = boto3.client('ec2', region_name=AWS_REGION)
    r = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    run(ec2, r)
