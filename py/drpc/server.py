import socket
from gevent.server import StreamServer

from drpc.encoders import ENCODERS
from drpc.socket_session import DRPCSocketSession


class DRPCServer:
    def __init__(self, server_address):
        self.server = StreamServer(server_address, self._handle_connection)

    def serve_forever(self):
        self.server.serve_forever()

    def start(self):
        self.server.start()

    def stop(self):
        self.server.stop()

    def _handle_connection(self, sock, addr):
        print 'handling connection from', sock
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setblocking(False)
        session = DRPCSocketSession(sock, ENCODERS, False, self.handle_request, self.handle_push)
        session.join()
        print 'connection from', addr, 'done'

    def handle_request(self, request, session):
        pass

    def handle_push(self, push, session):
        pass