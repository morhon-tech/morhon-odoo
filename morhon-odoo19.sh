#!/usr/bin/env bash
# MORHON Odoo19 fresh installer v8.1; no automatic upgrade of existing databases.
set -euo pipefail
exec python3 - "$@" <<'MORHON_ODOO19_PY'
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

VERSION = '8.1'
IMAGE = 'registry.cn-hangzhou.aliyuncs.com/morhon_hub/morhon_odoo:19-20261117-ai144-1b4480efef7e@sha256:1ef7c0de0772c67a5d6e668ca0fb604a00bfecf96b98f9407d8e645d0cd52755'
POSTGRES = 'docker.io/library/postgres@sha256:8a7b3318a33b4c4b366d3ada884d5339d719114e837f0d43776835ff01dec927'
EDGE = 'nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284'
LOCAL_IMAGES = {
    'web': 'sha256:47559a65c45f800dca746cc9d71150a6255e817812c02697e7f1f604b8046fb8',
    'db': 'sha256:86901ad21dd6f9aa6ee370188595a8bc5b7c36e1b8bdadcd33ecc21c1630135e',
    'edge': 'sha256:c318e336065b17ff460aeac6d14bce5d0b13e35f25d5cb1843b635359fc00c9a',
}
# Exact manifests produced by this release's verified legacy archive import.
# Other import/conversion results are intentionally not accepted.
CONTAINERD_IMAGES = {
    'web': 'sha256:1ef7c0de0772c67a5d6e668ca0fb604a00bfecf96b98f9407d8e645d0cd52755',
    'db': 'sha256:ae81e497630eb7dd45f34f2088c0618d5b330b0d5b648f2b88ad8453ac55bc06',
    'edge': 'sha256:dc8e6d3967a06c0c9bb10d16cfc5770686de05da4c34d4224ef2aec61142e8f1',
}
MODULES = 'mail_advance,mail_gateway,mail_gateway_instagram,mail_gateway_whatsapp,mh_ai_assistant,mh_ai_crm,mh_ai_library,mh_ai_mail_translate,mh_base,mh_bilingual_identity,mh_contact_points,mh_crm_metrics,mh_customs_documents,mh_payment_evidence,mh_paypal_invoicing,mh_social,mh_stock_performance,mh_trade_workflow,mh_whatsapp,mh_whatsapp_mail_advance,mh_whatsapp_marketing,mh_workspace_shell,purchase_request,queue_job,sale_advance,social_marketing,social_marketing_facebook,social_marketing_instagram,social_marketing_linkedin,spreadsheet_dashboard_purchase_oca,spreadsheet_dashboard_purchase_stock_oca,stock_delivery_advance'
FILES = {'seed.py': '"""Fresh synthetic public demo only; executed offline before HTTP is enabled."""\nimport base64\nimport json\nimport os\nimport secrets\n\n\ndef ensure_system_keeper(env):\n    """Satisfy native admin invariant without giving shared accounts Settings."""\n    keeper = env[\'res.users\'].with_context(active_test=False).search([(\'login\', \'=\', \'__demo_system_keeper__\')])\n    if keeper:\n        assert len(keeper) == 1 and keeper.active\n        assert keeper.company_id != env.ref(\'base.main_company\')\n        assert keeper.has_group(\'base.group_system\')\n        return keeper\n    isolated = env[\'res.company\'].with_context(install_demo=True).create({\n        \'name\': \'DEMO System Maintenance — no public access\',\n        \'email\': \'system-company@example.invalid\', \'iap_enrich_auto_done\': True,\n    })\n    keeper = env[\'res.users\'].with_context(no_reset_password=True).create({\n        \'name\': \'Demo System Maintenance\', \'login\': \'__demo_system_keeper__\',\n        \'password\': secrets.token_urlsafe(64),\n        \'email\': \'system-user@example.invalid\', \'notification_type\': \'inbox\',\n        \'company_id\': isolated.id, \'company_ids\': [Command.set(isolated.ids)],\n        \'group_ids\': [Command.set([env.ref(\'base.group_system\').id])],\n    })\n    # Random credentials are not printed, returned, or stored in a public file.\n    return keeper\n\nassert os.environ.get(\'MORHON_PUBLIC_DEMO\') == \'1\'\nassert os.environ.get(\'MORHON_DEMO_BOOTSTRAP\') == \'1\'\nassert env.cr.dbname == os.environ[\'MORHON_DEMO_DB\']\nparams = env[\'ir.config_parameter\'].sudo()\nassert not params.get_param(\'morhon.public_demo.seeded\'), \'Never overwrite an existing demo\'\nparams.set_param(\'crm.iap.lead.enrich.setting\', \'manual\')\nassert env[\'sale.order\'].search_count([]) == 0\nassert env[\'crm.lead\'].search_count([]) == 0\n\ncompany = env.ref(\'base.main_company\')\ncompany.write({\n    \'name\': \'MORHON DEMO — Synthetic Company\',\n    \'email\': \'demo@example.invalid\', \'phone\': False,\n    \'street\': \'100 Example Street — synthetic data\',\n    \'city\': \'Example City\', \'zip\': \'00000\',\n    \'country_id\': env.ref(\'base.us\').id,\n    \'mh_name_en\': \'MORHON DEMO — Synthetic Company\',\n    \'mh_address_en\': \'100 Example Street, Example City — synthetic data only\',\n    # Native Odoo uses the same flag to suppress enrichment in test companies.\n    \'iap_enrich_auto_done\': True,\n})\nadmin = env.ref(\'base.user_admin\')\nadmin.write({\'login\': \'admin\', \'password\': \'admin\', \'name\': \'Demo Administrator\',\n             \'email\': \'admin@example.invalid\', \'notification_type\': \'inbox\',\n             \'lang\': \'en_US\'})\nmanager_groups = [\n    \'base.group_user\', \'sales_team.group_sale_manager\',\n    \'purchase.group_purchase_manager\', \'stock.group_stock_manager\',\n    \'account.group_account_manager\', \'crm.group_use_lead\',\n]\nensure_system_keeper(env)\nadmin.write({\'group_ids\': [Command.set([env.ref(x).id for x in manager_groups])]})\nuser = env[\'res.users\'].with_context(no_reset_password=True).create({\n    \'name\': \'Demo Salesperson\', \'login\': \'user\', \'password\': \'user\',\n    \'email\': \'user@example.invalid\', \'notification_type\': \'inbox\', \'lang\': \'en_US\',\n    \'company_id\': company.id, \'company_ids\': [Command.set(company.ids)],\n    \'group_ids\': [Command.set([env.ref(x).id for x in (\n        \'base.group_user\', \'sales_team.group_sale_salesman\', \'crm.group_use_lead\')])],\n})\nteam = env[\'crm.team\'].create({\'name\': \'Demo Sales Team\', \'company_id\': company.id,\n    \'user_id\': admin.id, \'member_ids\': [Command.set([admin.id, user.id])]})\ncustomer = env[\'res.partner\'].create({\n    \'name\': \'Example Industrial Buyer — DEMO\', \'is_company\': True,\n    \'email\': \'buyer@example.invalid\', \'street\': \'200 Sample Road\',\n    \'city\': \'Example City\', \'country_id\': env.ref(\'base.us\').id,\n    \'lang\': \'en_US\', \'user_id\': user.id, \'company_id\': company.id,\n})\ncontact = env[\'res.partner\'].create({\'name\': \'Sample Buyer\',\n    \'parent_id\': customer.id, \'email\': \'sample-buyer@example.invalid\',\n    \'type\': \'contact\', \'lang\': \'en_US\', \'user_id\': user.id, \'company_id\': company.id})\nproduct = env[\'product.product\'].create({\'name\': \'Demo Process Component\',\n    \'default_code\': \'DEMO-001\', \'type\': \'consu\', \'sale_ok\': True,\n    \'purchase_ok\': True, \'list_price\': 25.0, \'standard_price\': 10.0,\n    \'description_sale\': \'Synthetic demonstration component; no real product commitment.\'})\nlead = env[\'crm.lead\'].with_context(mail_create_nosubscribe=True).create({\n    \'name\': \'DEMO: Repeat purchase with a new requirement\', \'type\': \'lead\',\n    \'partner_id\': contact.id, \'contact_name\': contact.name,\n    \'email_from\': contact.email, \'company_id\': company.id,\n    \'user_id\': user.id, \'team_id\': team.id,\n    \'description\': \'<p>Synthetic enquiry: 10 demo components; please quote delivery options.</p>\',\n})\npooled = env[\'crm.lead\'].with_context(mail_create_nosubscribe=True).create({\n    \'name\': \'DEMO: Unassigned enquiry\', \'type\': \'lead\', \'user_id\': False,\n    \'team_id\': team.id, \'company_id\': company.id, \'email_from\': \'new-buyer@example.invalid\',\n    \'description\': \'<p>Synthetic enquiry. Assignment rules are not enabled automatically.</p>\',\n})\nquote = env[\'sale.order\'].with_context(mail_create_nosubscribe=True).create({\n    \'partner_id\': customer.id, \'company_id\': company.id,\n    \'user_id\': user.id, \'team_id\': team.id,\n    \'order_line\': [Command.create({\'product_id\': product.id,\n        \'name\': \'Demo component — editable quotation description\',\n        \'product_uom_qty\': 10.0, \'price_unit\': 25.0})],\n})\nattachment = env[\'ir.attachment\'].create({\n    \'name\': \'DEMO-request.txt\', \'mimetype\': \'text/plain\',\n    \'datas\': base64.b64encode(b\'SYNTHETIC DEMO ONLY\\nPlease quote 10 demonstration components.\\n\'),\n    \'res_model\': \'crm.lead\', \'res_id\': lead.id,\n})\nlead.message_post(subject=\'DEMO: Synthetic customer enquiry\',\n    body=Markup(\'<p>This is synthetic demo mail, not a real customer message.</p>\'),\n    message_type=\'comment\', subtype_xmlid=\'mail.mt_comment\',\n    attachment_ids=attachment.ids, partner_ids=[user.partner_id.id])\n\nenv[\'ir.cron\'].with_context(active_test=False).search([]).write({\'active\': False})\nenv[\'ir.mail_server\'].search([]).write({\'active\': False})\nenv[\'fetchmail.server\'].search([]).write({\'active\': False})\nenv[\'mh.ai.provider\'].with_context(active_test=False).search([]).unlink()\nenv[\'payment.provider\'].with_context(active_test=False).search([]).write({\'state\': \'disabled\'})\nenv[\'mail.mail\'].search([]).unlink()\nparams.set_param(\'web.base.url\', os.environ.get(\'MORHON_DEMO_URL\', \'http://localhost\'))\nparams.set_param(\'web.base.url.freeze\', \'True\')\nparams.set_param(\'report.url\', \'http://127.0.0.1:8069\')\nparams.set_param(\'auth_signup.invitation_scope\', \'b2b\')\nparams.set_param(\'auth_signup.reset_password\', \'False\')\nparams.set_param(\'morhon.public_demo.seeded\', \'2026-11-17/v8.0\')\nenv.cr.commit()\nprint(\'DEMO_SEED=\' + json.dumps({\'users\': {\'admin\': admin.id, \'user\': user.id},\n    \'customer\': customer.id, \'lead\': lead.id, \'unassigned_lead\': pooled.id,\n    \'quotation\': quote.id, \'synthetic_only\': True}))\n', 'demo_addons/mh_public_demo/__init__.py': 'from . import models\n', 'demo_addons/mh_public_demo/__manifest__.py': "{\n    'name': 'MORHON Public Demo Isolation',\n    'author': 'MORHON',\n    'version': '19.0.1.0.0',\n    'license': 'LGPL-3',\n    'depends': ['base', 'mail', 'auth_signup', 'auth_totp', 'auth_passkey', 'partner_autocomplete'],\n    'data': [],\n    'application': False,\n    'installable': True,\n}\n", 'demo_addons/mh_public_demo/models.py': '"""Shared demo account restrictions; enabled only by the deployment environment.\n\nBootstrap is an offline process, never a request-context bypass. Business addons\nare unchanged. sudo() retains these guards in the public worker.\n"""\nimport os\nimport fcntl\nimport logging\nimport sys\nfrom copy import deepcopy\n\nfrom odoo import api, models, _, SUPERUSER_ID\nfrom odoo.exceptions import AccessError\nfrom odoo.tools import config\n\nPUBLIC_DEMO = os.environ.get(\'MORHON_PUBLIC_DEMO\') == \'1\'\nBOOTSTRAP = os.environ.get(\'MORHON_DEMO_BOOTSTRAP\') == \'1\'\nLOCKED_MODELS = {\n    \'res.config.settings\', \'res.company\', \'res.groups\', \'ir.config_parameter\', \'ir.mail_server\',\n    \'fetchmail.server\', \'ir.module.module\', \'ir.module.module.dependency\',\n    \'ir.actions.actions\', \'ir.actions.server\', \'ir.actions.client\',\n    \'ir.actions.act_window\', \'ir.actions.act_url\', \'ir.actions.report\',\n    \'ir.cron\', \'ir.cron.trigger\', \'base.automation\', \'mail.template\',\n    \'ir.model\', \'ir.model.fields\', \'ir.model.data\', \'ir.model.access\', \'ir.rule\',\n    \'ir.ui.view\', \'ir.ui.menu\', \'res.users.apikeys\', \'auth.oauth.provider\',\n    \'mh.ai.provider\', \'payment.provider\', \'mail.gateway\', \'mail.gateway.member\',\n    \'queue.job\', \'queue.job.function\', \'queue.job.channel\',\n    \'ir.asset\', \'ir.ui.view.custom\', \'auth.passkey.key\', \'auth.passkey.key.create\',\n    \'auth_totp.device\', \'auth_totp.wizard\',\n}\nACCOUNT_FIELDS = {\n    \'login\', \'password\', \'new_password\', \'password_crypt\', \'active\', \'share\',\n    \'group_ids\', \'groups_id\', \'company_id\', \'company_ids\', \'partner_id\',\n    \'name\', \'email\', \'notification_type\', \'totp_secret\', \'totp_enabled\',\n    \'oauth_uid\', \'oauth_provider_id\', \'oauth_access_token\', \'api_key_ids\',\n    \'auth_passkey_key_ids\', \'totp_trusted_device_ids\',\n}\n\n\ndef restricted():\n    return PUBLIC_DEMO and not BOOTSTRAP\n\n\ndef denied():\n    # Diagnostic metadata only. The same unconditional AccessError remains\n    # below; no permission check or rejection path is removed or bypassed.\n    caller = sys._getframe(1)\n    record = caller.f_locals.get(\'self\', caller.f_locals.get(\'records\'))\n    values = caller.f_locals.get(\'values\', {})\n    fields = sorted(set(values).intersection(record._fields))[:16] if record is not None and isinstance(values, dict) else []\n    logging.getLogger(__name__).warning(\'PUBLIC_DEMO_BLOCK model=%s operation=%s fields=%s\',\n        getattr(record, \'_name\', \'unknown\'), caller.f_code.co_name, fields)\n    raise AccessError(\'This is a shared public demo. Accounts, credentials and technical settings are fixed; business sample records remain available for testing.\')\n\n\ndef check_budget(records, values, *, file_write=False):\n    """Bound this shared synthetic instance, including deleted-file remnants."""\n    records.env.cr.execute(\'SELECT pg_database_size(current_database())\')\n    if records.env.cr.fetchone()[0] >= 512 * 1024 * 1024:\n        raise AccessError(\'Public demo storage is full. Please contact the operator to reset synthetic test data.\')\n    if file_write:\n        root = os.path.join(config[\'data_dir\'], \'filestore\', records.env.cr.dbname)\n        size, count = 0, 0\n        for folder, _dirs, files in os.walk(root, followlinks=False):\n            for name in files:\n                p = os.path.join(folder, name)\n                if os.path.islink(p):\n                    denied()\n                try:\n                    size += os.stat(p).st_size\n                    count += 1\n                except FileNotFoundError:\n                    continue\n                if size >= 128 * 1024 * 1024 or count >= 20000:\n                    raise AccessError(\'Public demo attachment storage is full; only synthetic samples are supported.\')\n        rows = values if isinstance(values, list) else [values]\n        incoming = sum(len(row.get(\'raw\') or row.get(\'datas\') or row.get(\'db_datas\') or b\'\') for row in rows)\n        if size + incoming > 128 * 1024 * 1024:\n            raise AccessError(\'Public demo attachment storage limit exceeded.\')\n\n\nclass DemoAttachment(models.Model):\n    _inherit = \'ir.attachment\'\n\n    @api.model_create_multi\n    def create(self, values_list):\n        if restricted() and self.env.uid != SUPERUSER_ID:\n            defaults = self.default_get([\'url\', \'res_model\'])\n            for values in values_list:\n                url = values.get(\'url\', defaults.get(\'url\')) or \'\'\n                model = values.get(\'res_model\', defaults.get(\'res_model\'))\n                if url.startswith(\'/web/assets\') or model in LOCKED_MODELS:\n                    denied()\n        return super().create(values_list)\n\n    def write(self, values):\n        if restricted() and self.env.uid != SUPERUSER_ID:\n            self.check_access(\'write\')\n            if self.sudo().filtered(lambda a: (a.url or \'\').startswith(\'/web/assets\') or a.res_model in LOCKED_MODELS):\n                denied()\n            if (values.get(\'url\') or \'\').startswith(\'/web/assets\') or values.get(\'res_model\') in LOCKED_MODELS:\n                denied()\n        return super().write(values)\n\n    def unlink(self):\n        # Native trusted bundle cleanup uses sudo; direct user operations do not.\n        if restricted() and not self.env.su:\n            self.check_access(\'unlink\')\n            if self.sudo().filtered(lambda a: (a.url or \'\').startswith(\'/web/assets\') or a.res_model in LOCKED_MODELS):\n                denied()\n        return super().unlink()\n\n    def _file_write(self, bin_value, checksum):\n        if not restricted():\n            return super()._file_write(bin_value, checksum)\n        # A filesystem lock covers only the short physical write. Holding a\n        # transaction lock across report rendering can deadlock asset requests.\n        # Count physical orphans too: delete/create must not bypass the budget.\n        lock = os.path.join(config[\'data_dir\'], \'.demo_attachment_budget.lock\')\n        with open(lock, \'a\') as stream:\n            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)\n            _name, path = self._get_path(bin_value, checksum)\n            if not os.path.exists(path):\n                check_budget(self, {\'raw\': bin_value}, file_write=True)\n            return super()._file_write(bin_value, checksum)\n\n\nclass DemoBase(models.AbstractModel):\n    _inherit = \'base\'\n\n    @api.model_create_multi\n    def create(self, values_list):\n        if restricted() and self._name in LOCKED_MODELS:\n            denied()\n        if restricted():\n            check_budget(self, values_list)\n        return super().create(values_list)\n\n    def write(self, values):\n        if restricted() and self._name in LOCKED_MODELS and values:\n            denied()\n        if restricted() and values:\n            check_budget(self, values)\n        return super().write(values)\n\n    def unlink(self):\n        if restricted() and self._name in LOCKED_MODELS:\n            denied()\n        return super().unlink()\n\n    @api.model\n    def _get_view(self, view_id=None, view_type=\'form\', **options):\n        arch, view = super()._get_view(view_id=view_id, view_type=view_type, **options)\n        if restricted():\n            arch = deepcopy(arch)\n            # Keep native local lookup/editing. The IAP-enhanced widgets are\n            # inappropriate for a demo with no enabled external services.\n            for node in arch.xpath(".//field[@widget=\'field_partner_autocomplete\']"):\n                node.set(\'widget\', \'char\')\n            for node in arch.xpath(".//field[@widget=\'res_partner_many2one\']"):\n                node.set(\'widget\', \'many2one\')\n            if self._name == \'res.users\':\n                for node in arch.xpath(\'.//field\'):\n                    if node.get(\'name\') in ACCOUNT_FIELDS:\n                        node.set(\'readonly\', \'1\')\n                for node in arch.xpath(\'.//button\'):\n                    if node.get(\'name\') in {\'action_change_password_wizard\', \'preference_change_password\',\n                        \'action_reset_password\', \'action_totp_enable_wizard\', \'action_totp_disable\', \'action_create_passkey\'}:\n                        node.set(\'invisible\', \'1\')\n        return arch, view\n\n\nclass DemoUsers(models.Model):\n    _inherit = \'res.users\'\n\n    @api.model_create_multi\n    def create(self, values_list):\n        if restricted():\n            denied()\n        return super().create(values_list)\n\n    def write(self, values):\n        if restricted() and ACCOUNT_FIELDS.intersection(values):\n            denied()\n        return super().write(values)\n\n    def unlink(self):\n        if restricted():\n            denied()\n        return super().unlink()\n\n    @api.model\n    def change_password(self, old_passwd, new_passwd):\n        if restricted():\n            denied()\n        return super().change_password(old_passwd, new_passwd)\n\n    def _change_password(self, new_passwd):\n        if restricted():\n            denied()\n        return super()._change_password(new_passwd)\n\n    def action_reset_password(self):\n        if restricted():\n            denied()\n        return super().action_reset_password()\n\n    @api.model\n    def reset_password(self, login):\n        if restricted():\n            denied()\n        return super().reset_password(login)\n\n    def _totp_try_setting(self, secret, code):\n        if restricted():\n            denied()\n        return super()._totp_try_setting(secret, code)\n\n    def action_totp_enable_wizard(self):\n        if restricted():\n            denied()\n        return super().action_totp_enable_wizard()\n\n    def action_totp_disable(self):\n        if restricted():\n            denied()\n        return super().action_totp_disable()\n\n    def action_create_passkey(self):\n        if restricted():\n            denied()\n        return super().action_create_passkey()\n\n    def action_change_password_wizard(self):\n        if restricted():\n            denied()\n        return super().action_change_password_wizard()\n\n    def preference_change_password(self):\n        if restricted():\n            denied()\n        return super().preference_change_password()\n\n\nclass DemoApiKeys(models.Model):\n    _inherit = \'res.users.apikeys\'\n\n    def _generate(self, scope, name, expiration_date):\n        # Native key-description and trusted-device flows use this method\n        # rather than ORM create(). Preserve the same contract and deny here.\n        if restricted():\n            denied()\n        return super()._generate(scope, name, expiration_date)\n\n\nclass DemoPartner(models.Model):\n    _inherit = \'res.partner\'\n\n    def write(self, values):\n        if restricted() and {\'name\', \'email\', \'active\', \'user_ids\'}.intersection(values):\n            if self.env[\'res.users\'].sudo().with_context(active_test=False).search_count([(\'partner_id\', \'in\', self.ids)], limit=1):\n                denied()\n        return super().write(values)\n\n    def unlink(self):\n        if restricted() and self.env[\'res.users\'].sudo().with_context(active_test=False).search_count([(\'partner_id\', \'in\', self.ids)], limit=1):\n            denied()\n        return super().unlink()\n\n\nclass DemoMail(models.Model):\n    _inherit = \'mail.mail\'\n\n    def send(self, *args, **kwargs):\n        if restricted():\n            raise AccessError(_(\'Public demo: real email delivery is disabled. You can prepare and inspect drafts.\'))\n        return super().send(*args, **kwargs)\n\n\nclass DemoModule(models.Model):\n    _inherit = \'ir.module.module\'\n\n    def button_immediate_install(self):\n        if restricted():\n            denied()\n        return super().button_immediate_install()\n\n    def button_immediate_upgrade(self):\n        if restricted():\n            denied()\n        return super().button_immediate_upgrade()\n\n    def button_immediate_uninstall(self):\n        if restricted():\n            denied()\n        return super().button_immediate_uninstall()\n', 'runtime/sitecustomize.py': '"""Demo-only process guard: exact database and no external service connections."""\nimport errno\nimport os\nimport socket\nimport sys\n\ndef install_guard():\n    if os.environ.get(\'MORHON_DEMO_BOOTSTRAP\') == \'1\' and \'--no-http\' not in sys.argv:\n        raise SystemExit(\'Offline demo bootstrap must never start an HTTP worker\')\n\n    DB = os.environ[\'MORHON_DEMO_DB\']\n    HOST = \'db\'\n    PORT = 5432\n    DB_IPS = {v[4][0] for v in socket.getaddrinfo(HOST, PORT)}\n\n    def check(address):\n        if isinstance(address, tuple):\n            host, port = address[:2]\n            if host in {HOST, *DB_IPS} and port == PORT:\n                return\n            if host in (\'127.0.0.1\', \'::1\') and port in (8069, 8072):\n                return\n        raise OSError(errno.ENETUNREACH, \'Public demo: external connections are disabled\')\n\n    def protect_socket():\n        cls = socket.socket\n        if getattr(cls.connect, \'_morhon_demo_guard\', False):\n            return\n        connect, connect_ex = cls.connect, cls.connect_ex\n\n        def guarded(self, address):\n            check(address)\n            return connect(self, address)\n\n        def guarded_ex(self, address):\n            try:\n                check(address)\n            except OSError:\n                return errno.ENETUNREACH\n            return connect_ex(self, address)\n\n        guarded._morhon_demo_guard = True\n        cls.connect, cls.connect_ex = guarded, guarded_ex\n\n    protect_socket()\n    # The evented worker replaces socket.socket; apply the same guard afterward.\n    from gevent import events\n\n    def after_patch(event):\n        if isinstance(event, events.GeventDidPatchBuiltinModulesEvent):\n            protect_socket()\n\n    events.subscribers.append(after_patch)\n\n    import psycopg2\n    from psycopg2.extensions import parse_dsn\n    original_pg = psycopg2.connect\n\n    def pg_connect(dsn=None, *args, **kwargs):\n        values = parse_dsn(dsn) if dsn else {}\n        values.update(kwargs)\n        name = values.get(\'dbname\', values.get(\'database\'))\n        if name not in (DB, \'postgres\') or values.get(\'host\') not in {HOST, *DB_IPS} or int(values.get(\'port\', PORT)) != PORT:\n            raise OSError(errno.ENETUNREACH, \'Public demo: other databases are disabled\')\n        if name == \'postgres\':\n            kwargs[\'options\'] = values.get(\'options\', \'\') + \' -c default_transaction_read_only=on\'\n        return original_pg(dsn, *args, **kwargs)\n\n    psycopg2.connect = pg_connect\n\n\nif os.environ.get(\'MORHON_PUBLIC_DEMO\') == \'1\':\n    try:\n        install_guard()\n    except BaseException as error:\n        # Python otherwise prints and ignores sitecustomize import errors.\n        sys.stderr.write(\'Public demo guard initialization failed: \' + type(error).__name__ + \'\\n\')\n        os._exit(78)\n'}


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
    assert meta.get('image_store', 'classic') in ('classic', 'containerd')
    assert meta.get('image_store', 'classic') == 'classic' or meta.get('offline_images') is True
    for name, digest in meta['files'].items():
        p = root / name
        assert p.is_file() and not p.is_symlink()
        assert hashlib.sha256(p.read_bytes()).hexdigest() == digest, 'Managed file changed: ' + name
    return meta


def verify_local_images(root):
    """Offline imports must be the same content-addressed linux/amd64 images."""
    spec = json.loads((root / 'compose.json').read_text())
    meta = load(root)
    identities = CONTAINERD_IMAGES if meta.get('image_store') == 'containerd' else LOCAL_IMAGES
    expected = {name: identities[name] for name in spec['services']}
    assert {n: s['image'] for n, s in spec['services'].items()} == expected
    result = run(['docker', 'image', 'inspect', *expected.values()], capture_output=True, text=True)
    images = json.loads(result.stdout)
    assert len(images) == len(expected)
    assert {i['Id'] for i in images} == set(expected.values()), 'Offline image identity mismatch'
    assert all(i['Os'] == 'linux' and i['Architecture'] == 'amd64' for i in images), 'Offline image platform mismatch'


def prepare(args):
    root = args.root
    assert args.image_store == 'classic' or args.offline_images, 'containerd selection requires explicit offline images'
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
        identities = CONTAINERD_IMAGES if args.image_store == 'containerd' else LOCAL_IMAGES
        for name, service in spec['services'].items():
            service['image'] = identities[name]
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
    meta['image_store'] = args.image_store
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
    parser.add_argument('--image-store', choices=['classic', 'containerd'], default='classic',
        help='Offline ID set: classic config IDs, or this release verified containerd import manifests')
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

MORHON_ODOO19_PY
