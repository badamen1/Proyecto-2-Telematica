import socket
import time
import grpc
from concurrent import futures

from proto import monitor_pb2, monitor_pb2_grpc
from monitor_c.load_simulator import get_load

GRPC_PORT = 50051


class MonitorServicer(monitor_pb2_grpc.MonitorServiceServicer):
    def Ping(self, request, context):
        """
        Retorna la dirección IP, la marca de tiempo actual y una carga simulada para esta instancia.
        """
        return monitor_pb2.PongResponse(
            ip=socket.gethostbyname(socket.gethostname()),
            timestamp=int(time.time()),
            load=get_load(),
        )

    def GetLoad(self, request, context):
        """
        Retorna la carga simulada para esta instancia.
        """
        return monitor_pb2.LoadResponse(load=get_load())


def serve():
    """
    Metodo en cada instancia de MonitorC que inicia el servidor gRPC para escuchar las solicitudes de Ping y GetLoad.
    y el controlador puede consultar la carga de cada instancia a través de GetLoad para tomar decisiones de escalado.
    
    """
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    monitor_pb2_grpc.add_MonitorServiceServicer_to_server(MonitorServicer(), server)
    server.add_insecure_port(f'[::]:{GRPC_PORT}')
    server.start()
    print(f'[INFO] MonitorC listening on port {GRPC_PORT}')
    server.wait_for_termination()


if __name__ == '__main__':
    serve()
