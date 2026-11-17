"""Demo-only process guard: exact database and no external service connections."""
import errno
import os
import socket
import sys

def install_guard():
    if os.environ.get('MORHON_DEMO_BOOTSTRAP') == '1' and '--no-http' not in sys.argv:
        raise SystemExit('Offline demo bootstrap must never start an HTTP worker')

    DB = os.environ['MORHON_DEMO_DB']
    HOST = 'db'
    PORT = 5432
    DB_IPS = {v[4][0] for v in socket.getaddrinfo(HOST, PORT)}

    def check(address):
        if isinstance(address, tuple):
            host, port = address[:2]
            if host in {HOST, *DB_IPS} and port == PORT:
                return
            if host in ('127.0.0.1', '::1') and port in (8069, 8072):
                return
        raise OSError(errno.ENETUNREACH, 'Public demo: external connections are disabled')

    def protect_socket():
        cls = socket.socket
        if getattr(cls.connect, '_morhon_demo_guard', False):
            return
        connect, connect_ex = cls.connect, cls.connect_ex

        def guarded(self, address):
            check(address)
            return connect(self, address)

        def guarded_ex(self, address):
            try:
                check(address)
            except OSError:
                return errno.ENETUNREACH
            return connect_ex(self, address)

        guarded._morhon_demo_guard = True
        cls.connect, cls.connect_ex = guarded, guarded_ex

    protect_socket()
    # The evented worker replaces socket.socket; apply the same guard afterward.
    from gevent import events

    def after_patch(event):
        if isinstance(event, events.GeventDidPatchBuiltinModulesEvent):
            protect_socket()

    events.subscribers.append(after_patch)

    import psycopg2
    from psycopg2.extensions import parse_dsn
    original_pg = psycopg2.connect

    def pg_connect(dsn=None, *args, **kwargs):
        values = parse_dsn(dsn) if dsn else {}
        values.update(kwargs)
        name = values.get('dbname', values.get('database'))
        if name not in (DB, 'postgres') or values.get('host') not in {HOST, *DB_IPS} or int(values.get('port', PORT)) != PORT:
            raise OSError(errno.ENETUNREACH, 'Public demo: other databases are disabled')
        if name == 'postgres':
            kwargs['options'] = values.get('options', '') + ' -c default_transaction_read_only=on'
        return original_pg(dsn, *args, **kwargs)

    psycopg2.connect = pg_connect


if os.environ.get('MORHON_PUBLIC_DEMO') == '1':
    try:
        install_guard()
    except BaseException as error:
        # Python otherwise prints and ignores sitecustomize import errors.
        sys.stderr.write('Public demo guard initialization failed: ' + type(error).__name__ + '\n')
        os._exit(78)
