"""MORHON Odoo19 v8: fresh installation only, with an optional isolated demo.

The single-file shell release embeds these reviewed public sources. It never
adopts an existing database, upgrades Odoo17, or updates a running trade server.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time

if sys.flags.optimize:
    raise SystemExit('This installer requires Python assertions; disable PYTHONOPTIMIZE')

VERSION = '8.0'
IMAGE = 'registry.cn-hangzhou.aliyuncs.com/morhon_hub/morhon_odoo:19-20261117-trade-fcaf20d6d02e@sha256:c989bf96a3e14cdba5faa5dcb6ce0a0c80ba1e0ea25bc363cdfbc34fa2db0373'
POSTGRES = 'docker.io/library/postgres@sha256:8a7b3318a33b4c4b366d3ada884d5339d719114e837f0d43776835ff01dec927'
EDGE = 'nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284'
LOCAL_IMAGES = {
    'web': 'sha256:c9636b18802151905a790053bb5b48db5f6c0bbb05ea67bee16931b0104b684d',
    'db': 'sha256:86901ad21dd6f9aa6ee370188595a8bc5b7c36e1b8bdadcd33ecc21c1630135e',
    'edge': 'sha256:c318e336065b17ff460aeac6d14bce5d0b13e35f25d5cb1843b635359fc00c9a',
}
MODULES = 'mail_advance,mail_gateway,mail_gateway_instagram,mail_gateway_whatsapp,mh_ai_assistant,mh_ai_crm,mh_ai_library,mh_ai_mail_translate,mh_base,mh_bilingual_identity,mh_contact_points,mh_crm_metrics,mh_customs_documents,mh_payment_evidence,mh_paypal_invoicing,mh_social,mh_stock_performance,mh_trade_workflow,mh_whatsapp,mh_whatsapp_mail_advance,mh_whatsapp_marketing,mh_workspace_shell,purchase_request,queue_job,sale_advance,social_marketing,social_marketing_facebook,social_marketing_instagram,social_marketing_linkedin,spreadsheet_dashboard_purchase_oca,spreadsheet_dashboard_purchase_stock_oca,stock_delivery_advance'
FILES = None  # Replaced by build_release.py with the exact public source payload.


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def compose(root, *args, **kwargs):
    return run(['docker', 'compose', '--project-directory', str(root),
                '-f', str(root / 'compose.json'), *args], **kwargs)


def load(root):
    assert root.is_dir() and not root.is_symlink(), 'Not a managed installation directory'
    p = root / 'installation.json'
    assert p.is_file() and not p.is_symlink(), 'Refusing an unmanaged installation'
    meta = json.loads(p.read_text())
    assert meta['installer_version'] == VERSION and meta['root'] == str(root)
    assert meta['image'] == IMAGE and meta['postgres'] == POSTGRES
    for name, digest in meta['files'].items():
        p = root / name
        assert p.is_file() and not p.is_symlink()
        assert hashlib.sha256(p.read_bytes()).hexdigest() == digest, 'Managed file changed: ' + name
    return meta


def verify_local_images(root):
    """Offline imports must be the same content-addressed linux/amd64 images."""
    spec = json.loads((root / 'compose.json').read_text())
    expected = {name: LOCAL_IMAGES[name] for name in spec['services']}
    assert {n: s['image'] for n, s in spec['services'].items()} == expected
    result = run(['docker', 'image', 'inspect', *expected.values()], capture_output=True, text=True)
    images = json.loads(result.stdout)
    assert len(images) == len(expected)
    assert {i['Id'] for i in images} == set(expected.values()), 'Offline image identity mismatch'
    assert all(i['Os'] == 'linux' and i['Architecture'] == 'amd64' for i in images), 'Offline image platform mismatch'


def prepare(args):
    root = args.root
    assert not root.exists(), 'Refusing to overwrite an existing directory; use status'
    assert re.fullmatch(r'[a-z][a-z0-9_-]{2,39}', args.project)
    assert re.fullmatch(r'[a-z][a-z0-9_]{2,39}', args.database)
    assert 1024 <= args.http_port <= 65535 and 1024 <= args.bus_port <= 65535
    assert args.http_port != args.bus_port
    assert args.url.startswith(('http://', 'https://')) and '\n' not in args.url
    root.mkdir(mode=0o700, parents=True)
    db_secret, pg_secret, master = [secrets.token_hex(32) for _ in range(3)]
    payload = dict(FILES)
    addons = '/usr/lib/python3/dist-packages/odoo/addons,/mnt/custom'
    if args.demo:
        addons += ',/mnt/demo-addons'
    else:
        payload = {k: v for k, v in payload.items() if not k.startswith(('runtime/', 'demo_addons/')) and k != 'seed.py'}
    config = f'''[options]
addons_path = {addons}
data_dir = /var/lib/odoo
admin_passwd = {master}
db_host = db
db_port = 5432
db_user = odoo
db_password = {db_secret}
db_name = {args.database}
dbfilter = ^{args.database}$
list_db = False
proxy_mode = True
workers = 2
max_cron_threads = 0
limit_memory_soft = 805306368
limit_memory_hard = 1073741824
limit_time_cpu = 60
limit_time_real = 120
http_port = 8069
gevent_port = 8072
log_level = warn
'''
    payload['odoo.conf'] = config
    payload['postgres-password'] = pg_secret + '\n'
    payload['init.sql'] = (f"CREATE ROLE odoo LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '{db_secret}';\n"
        "ALTER ROLE odoo SET temp_file_limit = '128MB';\n"
        f'CREATE DATABASE "{args.database}" OWNER odoo ENCODING \'UTF8\' TEMPLATE template0;\n'
        'REVOKE CREATE ON SCHEMA public FROM PUBLIC;\n')
    if not args.demo:
        payload['admin-password'] = secrets.token_urlsafe(24) + '\n'
    app_volumes = [
        './odoo.conf:/etc/odoo/odoo.conf:ro', 'filestore:/var/lib/odoo',
    ]
    environment = {'HOST': 'db', 'USER': 'odoo', 'PYTHONDONTWRITEBYTECODE': '1'}
    if args.demo:
        app_volumes += ['./demo_addons:/mnt/demo-addons:ro',
                        './runtime:/opt/morhon-public-demo/runtime:ro', './seed.py:/opt/morhon-public-demo/seed.py:ro']
        environment.update({'MORHON_PUBLIC_DEMO': '1', 'MORHON_DEMO_DB': args.database,
            'ODOO_QUEUE_JOB_CHANNELS': 'root:0',
            'MORHON_DEMO_URL': args.url,
            'PYTHONPATH': '/opt/morhon-public-demo/runtime:/opt/mh81-python'})
    app = {
        'image': IMAGE, 'restart': 'unless-stopped',
        'command': ['odoo', '-c', '/etc/odoo/odoo.conf'],
        'ports': [f'127.0.0.1:{args.http_port}:8069', f'127.0.0.1:{args.bus_port}:8072'],
        'volumes': app_volumes, 'environment': environment,
        'depends_on': {'db': {'condition': 'service_healthy'}},
        'read_only': True, 'cap_drop': ['ALL'],
        'security_opt': ['no-new-privileges:true'],
        'tmpfs': ['/tmp:rw,nosuid,nodev,size=268435456', '/mnt/extra-addons:rw,nosuid,nodev,size=1048576'],
        'mem_limit': '1280m', 'cpus': 1.5, 'pids_limit': 256,
        'healthcheck': {'test': ['CMD', 'python3', '-c',
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8069/web/login', timeout=3).read()", '--no-http'],
            'interval': '10s', 'timeout': '5s', 'start_period': '30s', 'retries': 15},
        'logging': {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '3'}},
    }
    spec = {'name': args.project, 'services': {
        'db': {'image': POSTGRES, 'restart': 'unless-stopped', 'user': '999:999',
            'environment': {'POSTGRES_PASSWORD_FILE': '/run/secrets/postgres-password'},
            'volumes': ['pg:/var/lib/postgresql/data', './postgres-password:/run/secrets/postgres-password:ro',
                        './init.sql:/docker-entrypoint-initdb.d/10-morhon.sql:ro'],
            'healthcheck': {'test': ['CMD-SHELL', 'pg_isready -U postgres'], 'interval': '3s', 'timeout': '3s', 'retries': 40},
            'cap_drop': ['ALL'], 'security_opt': ['no-new-privileges:true'],
            'mem_limit': '384m', 'cpus': 1.0, 'pids_limit': 128,
            'logging': {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '3'}}},
        'web': app},
        'volumes': {'pg': {'name': args.project + '_pg'}, 'filestore': {'name': args.project + '_filestore'}},
        'networks': {'default': {'internal': bool(args.demo)}}}
    if args.demo:
        app['tmpfs'].append('/var/lib/odoo/sessions:rw,nosuid,nodev,size=33554432,uid=100,gid=101,mode=0700')
        # Docker does not publish host ports from internal-only networks.
        # Only a fixed, read-only relay joins the frontend network; Odoo and
        # PostgreSQL retain their internal-only network and process guards.
        app.pop('ports')
        payload['edge.conf'] = '''worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
  access_log off;
  proxy_temp_path /tmp/proxy;
  client_body_temp_path /tmp/body;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  limit_req_zone $binary_remote_addr zone=demo_requests:1m rate=20r/s;
  server {
    listen 8080;
    server_name _;
    client_max_body_size 8m;
    limit_req zone=demo_requests burst=80 nodelay;
    limit_req_status 429;
    location ~* ^/(web/database|web/signup|web/reset_password|xmlrpc|jsonrpc)(/|$) { return 403; }
    location /websocket {
      proxy_pass http://web:8072;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 120s;
    }
    location / {
      proxy_pass http://web:8069;
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 120s;
    }
  }
}
'''
        spec['services']['edge'] = {'image': EDGE, 'user': '101:101', 'restart': 'unless-stopped',
            'entrypoint': ['nginx', '-g', 'daemon off;'],
            'ports': [f'127.0.0.1:{args.http_port}:8080', f'127.0.0.1:{args.bus_port}:8080'],
            'networks': ['default', 'frontend'], 'read_only': True,
            'volumes': ['./edge.conf:/etc/nginx/nginx.conf:ro'],
            'cap_drop': ['ALL'], 'security_opt': ['no-new-privileges:true'],
            'tmpfs': ['/tmp:rw,nosuid,nodev,size=33554432'],
            'mem_limit': '64m', 'cpus': 0.25, 'pids_limit': 64,
            'depends_on': {'web': {'condition': 'service_healthy'}},
            'healthcheck': {'test': ['CMD', 'wget', '-qO-', 'http://127.0.0.1:8080/web/login'],
                            'interval': '10s', 'timeout': '5s', 'retries': 12},
            'logging': {'driver': 'json-file', 'options': {'max-size': '5m', 'max-file': '2'}}}
        spec['networks']['frontend'] = {}
    if args.cpu_shares_only:
        # Explicit legacy-kernel option: public servers keep hard CPU quotas.
        for name, weight in (('web', 512), ('db', 256), ('edge', 128)):
            if name not in spec['services']:
                continue
            spec['services'][name].pop('cpus')
            spec['services'][name]['cpu_shares'] = weight
    if args.offline_images:
        for name, service in spec['services'].items():
            service['image'] = LOCAL_IMAGES[name]
    payload['compose.json'] = json.dumps(spec, indent=2) + '\n'
    hashes = {}
    for name, content in payload.items():
        p = root / name
        p.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        p.write_text(content)
        p.chmod(0o644)
        hashes[name] = hashlib.sha256(p.read_bytes()).hexdigest()
    meta = {'installer_version': VERSION, 'root': str(root), 'project': args.project,
        'database': args.database, 'demo': args.demo, 'image': IMAGE, 'postgres': POSTGRES,
        'files': hashes, 'http_port': args.http_port, 'bus_port': args.bus_port,
        'url': args.url, 'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    meta['cpu_limit_mode'] = 'shares_only' if args.cpu_shares_only else 'hard_quota'
    meta['offline_images'] = args.offline_images
    (root / 'installation.json').write_text(json.dumps(meta, indent=2) + '\n')
    (root / 'installation.json').chmod(0o600)
    print(json.dumps({'status': 'PREPARED_NOT_STARTED', 'version': VERSION, 'root': str(root),
        'demo': args.demo, 'image': IMAGE, 'project': args.project}))


def install(args):
    root = args.root
    meta = load(root)
    assert not (root / 'installed.json').exists(), 'Already initialized; never rerun initialization on business data'
    if meta.get('offline_images'):
        verify_local_images(root)
    existing = []
    for suffix in ('pg', 'filestore'):
        found = subprocess.run(['docker', 'volume', 'inspect', meta['project'] + '_' + suffix],
                               capture_output=True, text=True)
        if found.returncode == 0:
            info = json.loads(found.stdout)[0]
            assert (info.get('Labels') or {}).get('com.docker.compose.project') == meta['project']
            existing.append(suffix)
    assert not existing or args.resume_empty, 'Existing volumes: refuse adoption; --resume-empty checks a pre-initialization failure only'
    compose(root, 'config', '--quiet')
    if not meta.get('offline_images'):
        compose(root, 'pull')
    compose(root, 'up', '-d', '--wait', 'db')
    if existing:
        assert sorted(existing) == ['filestore', 'pg'], 'Incomplete volume set'
        count = compose(root, 'exec', '-T', 'db', 'psql', '-U', 'postgres', '-d', meta['database'],
            '-Atc', "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S');",
            capture_output=True, text=True).stdout.strip()
        assert count == '0', 'Database is not empty; retain it and diagnose instead of retrying initialization'
    selected = MODULES + (',mh_public_demo' if meta['demo'] else '')
    extra = ['-e', 'MORHON_DEMO_BOOTSTRAP=1'] if meta['demo'] else []
    try:
        compose(root, 'run', '--rm', '--no-deps', '--entrypoint', 'odoo', *extra, 'web',
            '-c', '/etc/odoo/odoo.conf', '--no-http', '--workers=0', '--max-cron-threads=0',
            '--without-demo=True', '-i', selected, '--stop-after-init')
        if meta['demo']:
            seed = 'from odoo import Command\nfrom markupsafe import Markup\n' + (root / 'seed.py').read_text()
        else:
            password = (root / 'admin-password').read_text().strip()
            seed = ("env.ref('base.user_admin').write({'password': " + repr(password) + "})\n"
                "env.company.write({'iap_enrich_auto_done': True})\n"
                "env['ir.config_parameter'].set_param('crm.iap.lead.enrich.setting', 'manual')\n"
                "env['ir.cron'].with_context(active_test=False).search([]).write({'active': False})\n"
                "env.cr.commit()\n")
        verify = '''import ast,json
from pathlib import Path
expected={p.parent.name:ast.literal_eval(p.read_text())['version'] for p in Path('/mnt/custom').glob('*/__manifest__.py')}
assert len(expected)==32, 'Unexpected image module set'
for name,version in expected.items():
    module=env['ir.module.module'].search([('name','=',name)])
    assert len(module)==1 and module.state=='installed' and module.latest_version==version, (name,module.state,module.latest_version,version)
assert expected['mh_ai_crm']=='19.0.1.10.12'
print('MORHON_INSTALLED_MODULES='+json.dumps(expected,sort_keys=True))
'''
        seed = verify + '\n' + seed
        compose(root, 'run', '--rm', '--no-deps', '-T', '--entrypoint', 'odoo', *extra, 'web', 'shell',
            '-c', '/etc/odoo/odoo.conf', '--no-http', '--workers=0', '--max-cron-threads=0',
            input=seed, text=True)
    except BaseException:
        # Retain failed initialization and its volumes for diagnosis, never retry -i
        # over partial data or delete an existing database as automatic recovery.
        compose(root, 'stop', 'web')
        raise
    proof = {'status': 'FRESH_DATABASE_INITIALIZED', 'image': IMAGE, 'demo': meta['demo'],
             'database': meta['database'], 'modules': selected.split(',')}
    (root / 'installed.json').write_text(json.dumps(proof, indent=2) + '\n')
    compose(root, 'up', '-d', '--wait', '--wait-timeout', '180')
    print(json.dumps(proof))


def backup(args):
    root = args.root
    meta = load(root)
    assert (root / 'installed.json').exists()
    destination = root / 'backups' / time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    destination.mkdir(parents=True, mode=0o700)
    running = compose(root, 'ps', '--status', 'running', '--services', capture_output=True, text=True).stdout.split()
    web_was_running = 'web' in running
    # Only this installation is paused. No existing host PostgreSQL/site is touched.
    if web_was_running:
        compose(root, 'stop', '-t', '30', 'web')
    try:
        with (destination / 'database.dump').open('xb') as stream:
            compose(root, 'exec', '-T', 'db', 'pg_dump', '-U', 'postgres', '-Fc', meta['database'], stdout=stream)
        with (destination / 'filestore.tar').open('xb') as stream:
            compose(root, 'run', '--rm', '--no-deps', '-T', '--entrypoint', 'tar', 'web',
                    '-C', '/var/lib/odoo', '-cf', '-', 'filestore', stdout=stream)
        import shutil
        for name in ('installation.json', 'installed.json', *meta['files']):
            target = destination / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copy2(root / name, target)
        manifest = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in destination.rglob('*') if p.is_file()}
        (destination / 'sha256.json').write_text(json.dumps(manifest, indent=2))
    finally:
        if web_was_running:
            compose(root, 'start', 'web')
    print(json.dumps({'status': 'BACKUP_CREATED', 'directory': str(destination),
                     'restore_tested': False}))


def main():
    parser = argparse.ArgumentParser(description='MORHON Odoo19 v8.0 — new installation, never an Odoo17 migration or trade updater')
    parser.add_argument('action', choices=['prepare', 'install', 'start', 'stop', 'status', 'backup'])
    parser.add_argument('--root', type=lambda x: Path(x).expanduser().absolute(), default=Path('/opt/morhon-odoo19'))
    parser.add_argument('--project', default='morhon19')
    parser.add_argument('--database', default='morhon19')
    parser.add_argument('--demo', action='store_true', help='Fixed shared admin/admin and user/user; external services disabled')
    parser.add_argument('--offline-images', action='store_true', help='Prepare using only the exact preloaded linux/amd64 image IDs; never substitutes tags')
    parser.add_argument('--http-port', type=int, default=18069)
    parser.add_argument('--bus-port', type=int, default=18072)
    parser.add_argument('--url', default='http://localhost:18069')
    parser.add_argument('--cpu-shares-only', action='store_true',
                        help='Explicit legacy NAS kernel option; public servers should retain default hard quotas')
    parser.add_argument('--resume-empty', action='store_true',
                        help='Resume only a managed pre-initialization failure; refuses any database objects')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args)
    elif args.action == 'install':
        install(args)
    elif args.action == 'backup':
        backup(args)
    else:
        load(args.root)
        if args.action == 'start':
            assert (args.root / 'installed.json').exists(), 'Initialization has not completed'
            compose(args.root, 'up', '-d')
        elif args.action == 'stop':
            compose(args.root, 'stop')
        else:
            compose(args.root, 'ps', '--format', 'json')


if __name__ == '__main__':
    main()
