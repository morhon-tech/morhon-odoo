"""CLI guards with no real Docker daemon or network access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('morhon-odoo19.sh')


class InstallerGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='morhon19-installer-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.root = self.directory / 'instance'

    def cli(self, action, *options, okay=True, extra_env=None):
        result = subprocess.run(['bash', str(SCRIPT), action, '--root', str(self.root), *options],
            capture_output=True, text=True, env=dict(os.environ, **(extra_env or {})))
        if okay:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_regular_is_private_random_and_not_demo(self):
        self.cli('prepare')
        meta = json.loads((self.root / 'installation.json').read_text())
        spec = json.loads((self.root / 'compose.json').read_text())
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertFalse(meta['demo'])
        self.assertFalse((self.root / 'demo_addons').exists())
        self.assertNotIn((self.root / 'admin-password').read_text().strip(), ('admin', 'user', ''))
        self.assertNotIn('MORHON_PUBLIC_DEMO', spec['services']['web']['environment'])
        self.assertIn('NOSUPERUSER NOCREATEDB NOCREATEROLE', (self.root / 'init.sql').read_text())
        self.assertEqual(spec['services']['web']['ports'][0], '127.0.0.1:18069:8069')
        self.assertNotIn('ports', spec['services']['db'])
        self.assertTrue('@sha256:' in spec['services']['web']['image'])
        self.assertNotIn('latest', spec['services']['db']['image'])

    def test_demo_is_offline_and_protected(self):
        self.cli('prepare', '--demo')
        spec = json.loads((self.root / 'compose.json').read_text())
        self.assertTrue(spec['networks']['default']['internal'])
        web = spec['services']['web']
        self.assertEqual(web['environment']['MORHON_PUBLIC_DEMO'], '1')
        self.assertNotIn('MORHON_DEMO_BOOTSTRAP', web['environment'])
        self.assertTrue(web['read_only'])
        self.assertEqual(web['cap_drop'], ['ALL'])
        self.assertEqual(web['cpus'], 1.5)
        self.assertNotIn('ports', web)
        self.assertNotIn('networks', web)
        self.assertEqual(spec['services']['edge']['networks'], ['default', 'frontend'])
        self.assertEqual(spec['services']['edge']['ports'][0], '127.0.0.1:18069:8080')
        self.assertTrue(any('/sessions:' in x and 'uid=100,gid=101' in x for x in web['tmpfs']))
        self.assertEqual(web['environment']['ODOO_QUEUE_JOB_CHANNELS'], 'root:0')
        self.assertTrue((self.root / 'demo_addons/mh_public_demo/models.py').exists())
        self.assertFalse((self.root / 'admin-password').exists())

    def test_preloaded_images_keep_isolation_and_fixed_sources(self):
        self.cli('prepare', '--demo', '--offline-images')
        meta = json.loads((self.root / 'installation.json').read_text())
        spec = json.loads((self.root / 'compose.json').read_text())
        self.assertTrue(meta['offline_images'])
        self.assertIn('@sha256:40f5b959', meta['image'])
        self.assertEqual(spec['services']['web']['image'], 'sha256:336f2f7bb619def66a8036a5b5cdab9cee815dd15367b04f3d8ac38b6f80b6da')
        self.assertEqual(spec['services']['db']['image'], 'sha256:86901ad21dd6f9aa6ee370188595a8bc5b7c36e1b8bdadcd33ecc21c1630135e')
        self.assertEqual(spec['services']['edge']['image'], 'sha256:c318e336065b17ff460aeac6d14bce5d0b13e35f25d5cb1843b635359fc00c9a')
        self.assertTrue(spec['networks']['default']['internal'])
        self.assertEqual(spec['services']['web']['cpus'], 1.5)
        self.assertEqual(spec['services']['web']['environment']['MORHON_PUBLIC_DEMO'], '1')

    def offline_docker(self, platform='amd64', missing=False, ids=None):
        executable = self.directory / 'docker'
        executable.write_text('''#!/usr/bin/env python3
import sys,json,pathlib
p=pathlib.Path(__file__).parent
with (p/'docker-calls.jsonl').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if a[:2]==['image','inspect']:
 supplied=''' + repr(ids) + '''
 print(json.dumps([{'Id':v,'Os':'linux','Architecture':''' + repr(platform) + '''} for v in (a[2:] if supplied is None else supplied)][:''' + ('1' if missing else '3') + ''']))
elif a[:2]==['volume','inspect']:
 print(json.dumps([{'Labels':{'com.docker.compose.project':'foreign'}}]))
else:
 raise SystemExit('Unexpected mutation in image-validation test')
''')
        executable.chmod(0o755)
        return {'PATH': str(self.directory) + os.pathsep + os.environ['PATH']}

    def test_offline_images_validated_before_volume_or_database_mutations(self):
        self.cli('prepare', '--demo', '--offline-images')
        result = self.cli('install', okay=False, extra_env=self.offline_docker())
        calls = [json.loads(v) for v in (self.directory / 'docker-calls.jsonl').read_text().splitlines()]
        self.assertEqual(calls[0][:2], ['image', 'inspect'])
        self.assertEqual(calls[1][:2], ['volume', 'inspect'])
        self.assertEqual(len(calls), 2)  # The foreign-volume guard still refuses adoption.
        self.assertFalse((self.root / 'installed.json').exists())

    def test_offline_wrong_platform_refused_before_volume_inspection(self):
        self.cli('prepare', '--demo', '--offline-images')
        result = self.cli('install', okay=False, extra_env=self.offline_docker(platform='arm64'))
        self.assertIn('Offline image platform mismatch', result.stderr)
        self.assertEqual(len((self.directory / 'docker-calls.jsonl').read_text().splitlines()), 1)

    def test_offline_incomplete_image_set_refused_before_volume_inspection(self):
        self.cli('prepare', '--demo', '--offline-images')
        self.cli('install', okay=False, extra_env=self.offline_docker(missing=True))
        self.assertEqual(len((self.directory / 'docker-calls.jsonl').read_text().splitlines()), 1)

    def test_containerd_requires_explicit_offline_mode(self):
        self.cli('prepare', '--image-store', 'containerd', okay=False)
        self.assertFalse(self.root.exists())
        self.cli('prepare', '--offline-images', '--image-store', 'arbitrary', okay=False)
        self.assertFalse(self.root.exists())

    def test_containerd_fixed_set_is_reloaded_from_metadata(self):
        self.cli('prepare', '--demo', '--offline-images', '--image-store', 'containerd')
        meta = json.loads((self.root / 'installation.json').read_text())
        self.assertEqual(meta['image_store'], 'containerd')
        spec = json.loads((self.root / 'compose.json').read_text())
        expected = {
            'web': 'sha256:40f5b959728ef81840ac0e853f596897b6bba438ea54420231210f3e3eb0df0e',
            'db': 'sha256:ae81e497630eb7dd45f34f2088c0618d5b330b0d5b648f2b88ad8453ac55bc06',
            'edge': 'sha256:dc8e6d3967a06c0c9bb10d16cfc5770686de05da4c34d4224ef2aec61142e8f1',
        }
        self.assertEqual({n: s['image'] for n, s in spec['services'].items()}, expected)
        self.cli('install', '--image-store', 'classic', okay=False, extra_env=self.offline_docker())
        calls = [json.loads(v) for v in (self.directory / 'docker-calls.jsonl').read_text().splitlines()]
        self.assertEqual(set(calls[0][2:]), set(expected.values()))
        self.assertEqual(calls[1][:2], ['volume', 'inspect'])
        self.assertEqual(len(calls), 2)

    def test_containerd_refuses_classic_or_wrong_identity_set(self):
        self.cli('prepare', '--demo', '--offline-images', '--image-store', 'containerd')
        result = self.cli('install', okay=False, extra_env=self.offline_docker(ids=[
            'sha256:336f2f7bb619def66a8036a5b5cdab9cee815dd15367b04f3d8ac38b6f80b6da',
            'sha256:86901ad21dd6f9aa6ee370188595a8bc5b7c36e1b8bdadcd33ecc21c1630135e',
            'sha256:c318e336065b17ff460aeac6d14bce5d0b13e35f25d5cb1843b635359fc00c9a']))
        self.assertIn('Offline image identity mismatch', result.stderr)
        self.assertEqual(len((self.directory / 'docker-calls.jsonl').read_text().splitlines()), 1)

    def test_offline_wrong_digest_refused(self):
        self.cli('prepare', '--offline-images')
        result = self.cli('install', okay=False, extra_env=self.offline_docker(ids=['sha256:' + '0' * 64, 'sha256:' + '1' * 64]))
        self.assertIn('Offline image identity mismatch', result.stderr)
        self.assertEqual(len((self.directory / 'docker-calls.jsonl').read_text().splitlines()), 1)

    def test_existing_root_never_overwritten(self):
        self.cli('prepare')
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.cli('prepare', '--demo', okay=False)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_tampered_managed_file_refused_before_docker(self):
        self.cli('prepare')
        (self.root / 'compose.json').write_text('{}')
        result = self.cli('install', okay=False)
        self.assertIn('Managed file changed', result.stderr)

    def test_start_requires_completed_initialization(self):
        self.cli('prepare')
        result = self.cli('start', okay=False)
        self.assertIn('Initialization has not completed', result.stderr)

    def test_python_optimization_cannot_disable_guards(self):
        result = self.cli('prepare', okay=False, extra_env={'PYTHONOPTIMIZE': '1'})
        self.assertIn('requires Python assertions', result.stderr)
        self.assertFalse(self.root.exists())

    def test_invalid_database_and_duplicate_ports_refused(self):
        self.cli('prepare', '--database', 'old;drop', okay=False)
        self.assertFalse(self.root.exists())
        self.cli('prepare', '--http-port', '18072', okay=False)
        self.assertFalse(self.root.exists())

    def fake_docker(self, volume_project, objects):
        executable = self.directory / 'docker'
        executable.write_text('''#!/usr/bin/env python3
import sys,json,pathlib
p=pathlib.Path(__file__).parent
with (p/'docker-calls.jsonl').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if a[:2]==['volume','inspect']:
 print(json.dumps([{'Labels':{'com.docker.compose.project': ''' + repr(volume_project) + '''}}]))
elif 'psql' in a:
 print(''' + repr(str(objects)) + ''')
''')
        executable.chmod(0o755)
        return {'PATH': str(self.directory) + os.pathsep + os.environ['PATH']}

    def test_foreign_volume_refused_without_compose_actions(self):
        self.cli('prepare')
        result = self.cli('install', okay=False, extra_env=self.fake_docker('other-project', 0))
        calls = [json.loads(v) for v in (self.directory / 'docker-calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ['volume', 'inspect'])

    def test_resume_rejects_nonempty_database_before_any_init(self):
        self.cli('prepare')
        self.cli('install', '--resume-empty', okay=False, extra_env=self.fake_docker('morhon19', 7))
        calls = [json.loads(v) for v in (self.directory / 'docker-calls.jsonl').read_text().splitlines()]
        self.assertFalse(any('run' in call for call in calls))
        self.assertFalse((self.root / 'installed.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
