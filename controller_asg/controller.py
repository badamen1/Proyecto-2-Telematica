import os
import time
import boto3
import redis as redis_lib
from dotenv import load_dotenv

load_dotenv()

MIN_INSTANCES = 2
MAX_INSTANCES = 5
SCALE_OUT_THRESHOLD = 70.0
SCALE_IN_THRESHOLD = 30.0
COOLDOWN_SECONDS = 120
CYCLE_INTERVAL = 15
DRAIN_WAIT = 30

AMI_ID = os.environ.get('AMI_ID', '')
SUBNET_ID = os.environ.get('SUBNET_ID', '')
SECURITY_GROUP_ID = os.environ.get('SECURITY_GROUP_ID', '')
KEY_NAME = os.environ.get('KEY_NAME', 'vockey')
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
REDIS_HOST = os.environ.get('REDIS_HOST', 'localhost')
REDIS_PORT = int(os.environ.get('REDIS_PORT', '6379'))

#Consigue el estado de la flota desde Redis, devolviendo una lista de diccionarios con IP y carga de cada instancia.
def get_fleet_state(redis_client) -> list:
    """
    Este método consulta Redis para obtener el estado actual de las instancias.
    Busca claves con el patrón 'instance:*' y extrae la dirección IP 
    """
    keys = redis_client.keys('instance:*')
    fleet = []
    for key in keys:
        data = redis_client.hgetall(key)
        if data:
            ip = key.split(':', 1)[1]
            fleet.append({'ip': ip, 'load': float(data.get('load', 0))})
    return fleet


def is_cooldown_active(redis_client) -> bool:
    """
    Verifica si el período de enfriamiento está activo consultando 
    Redis para la última acción de escalado.
    """
    last = redis_client.get('last_scaling_action')
    if not last:
        return False
    return (time.time() - float(last)) < COOLDOWN_SECONDS


def set_cooldown(redis_client) -> None:
    """
    Establece el tiempo del último escalado en Redis para activar el período de enfriamiento.
    """
    redis_client.set('last_scaling_action', time.time())


def scale_out(ec2_client, elbv2_client, redis_client, target_group_arn: str, monitor_s_ip: str) -> None:
    """
    Lanza una nueva instancia EC2, espera a que esté en ejecución, 
    la registra en el Target Group y establece el período de enfriamiento.
    """
    user_data = '#!/bin/bash\nsystemctl start monitor_c\n'
    try:
        #Usamos por defectos la AMI de Amazon Linux 2
        response = ec2_client.run_instances(
            ImageId=AMI_ID,
            InstanceType='t3.micro',
            KeyName=KEY_NAME,
            MinCount=1,
            MaxCount=1,
            SubnetId=SUBNET_ID,
            SecurityGroupIds=[SECURITY_GROUP_ID],
            UserData=user_data,
            TagSpecifications=[{
                'ResourceType': 'instance',
                'Tags': [{'Key': 'Role', 'Value': 'AppInstance'}],
            }],
        )
        instance_id = response['Instances'][0]['InstanceId']
        #Esperamos a que la instancia esté en estado 'running' antes de registrarla en el Target Group
        ec2_client.get_waiter('instance_running').wait(InstanceIds=[instance_id])

        #Registramos la nueva instancia en el Target Group para que comience a recibir tráfico
        elbv2_client.register_targets(
            TargetGroupArn=target_group_arn,
            Targets=[{'Id': instance_id}],
        )
        #Establecemos el período de enfriamiento para evitar escalados rápidos consecutivos
        set_cooldown(redis_client)
        print(f'[INFO] Scale-out: launched {instance_id}')
    except Exception as e:
        print(f'[ERROR] Scale-out failed: {e}')


def scale_in(ec2_client, elbv2_client, redis_client, instances: list, target_group_arn: str) -> None:

    """
    Metodo para escalar hacia adentro (scale-in). Selecciona la instancia con menor carga,
    la desregistra del Target Group, espera a que se acabe el tráfico, la termina y establece el período de enfriamiento.
    """


    target = min(instances, key=lambda x: x['load'])
    try:
        response = ec2_client.describe_instances(
            Filters=[
                {'Name': 'private-ip-address', 'Values': [target['ip']]},
                {'Name': 'instance-state-name', 'Values': ['running']},
            ]
        )
        instance_id = response['Reservations'][0]['Instances'][0]['InstanceId']
        elbv2_client.deregister_targets(
            TargetGroupArn=target_group_arn,
            Targets=[{'Id': instance_id}],
        )
        print(f'[INFO] Scale-in: draining {instance_id} for {DRAIN_WAIT}s')
        time.sleep(DRAIN_WAIT)
        ec2_client.terminate_instances(InstanceIds=[instance_id])
        set_cooldown(redis_client)
        print(f'[INFO] Scale-in: terminated {instance_id}')
    except Exception as e:
        print(f'[ERROR] Scale-in failed: {e}')


def _count_ec2_app_instances(ec2_client) -> int:
    """Cuenta las instancias EC2 con tag Role=AppInstance en estado running o pending."""
    try:
        response = ec2_client.describe_instances(
            Filters=[
                {'Name': 'tag:Role', 'Values': ['AppInstance']},
                {'Name': 'instance-state-name', 'Values': ['running', 'pending']},
            ]
        )
        count = 0
        for reservation in response['Reservations']:
            count += len(reservation['Instances'])
        return count
    except Exception as e:
        print(f'[ERROR] Failed to count EC2 instances: {e}')
        return 0


def run(ec2_client, elbv2_client, redis_client, target_group_arn: str, monitor_s_ip: str) -> None:
    """
    Metodo principal que ejecuta el ciclo de control. En cada iteración, obtiene el estado de la flota,
    calcula la carga promedio y decide si escalar hacia afuera o hacia adentro según los umbrales definidos.
    También maneja el período de enfriamiento para evitar escalados rápidos consecutivos.
    """
    print('[INFO] ControllerASG started')
    while True:
        try:
            fleet = get_fleet_state(redis_client)
            fleet_size = len(fleet)

            # Bootstrapping: consultar EC2 directamente para saber cuantas instancias
            # existen (running + pending), porque Redis no tiene datos hasta que MonitorC responda
            ec2_count = _count_ec2_app_instances(ec2_client)

            if ec2_count < MIN_INSTANCES:
                needed = MIN_INSTANCES - ec2_count
                print(f'[INFO] EC2 fleet below minimum ({ec2_count}/{MIN_INSTANCES}), launching {needed} instance(s)')
                for _ in range(needed):
                    scale_out(ec2_client, elbv2_client, redis_client, target_group_arn, monitor_s_ip)
                # Esperar mas tiempo despues del bootstrap para que las instancias arranquen
                set_cooldown(redis_client)
                time.sleep(CYCLE_INTERVAL)
                continue

            if not fleet:
                print(f'[INFO] {ec2_count} EC2 instances exist but not yet in Redis, waiting for MonitorC...')
                time.sleep(CYCLE_INTERVAL)
                continue

            avg_load = sum(i['load'] for i in fleet) / len(fleet)
            print(f'[INFO] avg_load={avg_load:.1f}% fleet_size={fleet_size} ec2_count={ec2_count}')

            if is_cooldown_active(redis_client):
                print('[INFO] Cooldown active, skipping')
            elif avg_load > SCALE_OUT_THRESHOLD and fleet_size < MAX_INSTANCES:
                print(f'[INFO] Scale-out triggered (avg={avg_load:.1f}%)')
                scale_out(ec2_client, elbv2_client, redis_client, target_group_arn, monitor_s_ip)
            elif avg_load < SCALE_IN_THRESHOLD and fleet_size > MIN_INSTANCES:
                print(f'[INFO] Scale-in triggered (avg={avg_load:.1f}%)')
                scale_in(ec2_client, elbv2_client, redis_client, fleet, target_group_arn)
        except Exception as e:
            print(f'[ERROR] Controller cycle failed: {e}')

        time.sleep(CYCLE_INTERVAL)


if __name__ == '__main__':
    ec2 = boto3.client('ec2', region_name=AWS_REGION)
    elbv2 = boto3.client('elbv2', region_name=AWS_REGION)
    r = redis_lib.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    target_group_arn = os.environ['TARGET_GROUP_ARN']
    monitor_s_ip = os.environ['MONITOR_S_IP']
    run(ec2, elbv2, r, target_group_arn, monitor_s_ip)
