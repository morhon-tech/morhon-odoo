"""Shared demo account restrictions; enabled only by the deployment environment.

Bootstrap is an offline process, never a request-context bypass. Business addons
are unchanged. sudo() retains these guards in the public worker.
"""
import os
import fcntl
import logging
import sys
from copy import deepcopy

from odoo import api, models, _, SUPERUSER_ID
from odoo.exceptions import AccessError
from odoo.tools import config

PUBLIC_DEMO = os.environ.get('MORHON_PUBLIC_DEMO') == '1'
BOOTSTRAP = os.environ.get('MORHON_DEMO_BOOTSTRAP') == '1'
LOCKED_MODELS = {
    'res.config.settings', 'res.company', 'res.groups', 'ir.config_parameter', 'ir.mail_server',
    'fetchmail.server', 'ir.module.module', 'ir.module.module.dependency',
    'ir.actions.actions', 'ir.actions.server', 'ir.actions.client',
    'ir.actions.act_window', 'ir.actions.act_url', 'ir.actions.report',
    'ir.cron', 'ir.cron.trigger', 'base.automation', 'mail.template',
    'ir.model', 'ir.model.fields', 'ir.model.data', 'ir.model.access', 'ir.rule',
    'ir.ui.view', 'ir.ui.menu', 'res.users.apikeys', 'auth.oauth.provider',
    'mh.ai.provider', 'payment.provider', 'mail.gateway', 'mail.gateway.member',
    'queue.job', 'queue.job.function', 'queue.job.channel',
    'ir.asset', 'ir.ui.view.custom', 'auth.passkey.key', 'auth.passkey.key.create',
    'auth_totp.device', 'auth_totp.wizard',
}
ACCOUNT_FIELDS = {
    'login', 'password', 'new_password', 'password_crypt', 'active', 'share',
    'group_ids', 'groups_id', 'company_id', 'company_ids', 'partner_id',
    'name', 'email', 'notification_type', 'totp_secret', 'totp_enabled',
    'oauth_uid', 'oauth_provider_id', 'oauth_access_token', 'api_key_ids',
    'auth_passkey_key_ids', 'totp_trusted_device_ids',
}


def restricted():
    return PUBLIC_DEMO and not BOOTSTRAP


def denied():
    # Diagnostic metadata only. The same unconditional AccessError remains
    # below; no permission check or rejection path is removed or bypassed.
    caller = sys._getframe(1)
    record = caller.f_locals.get('self', caller.f_locals.get('records'))
    values = caller.f_locals.get('values', {})
    fields = sorted(set(values).intersection(record._fields))[:16] if record is not None and isinstance(values, dict) else []
    logging.getLogger(__name__).warning('PUBLIC_DEMO_BLOCK model=%s operation=%s fields=%s',
        getattr(record, '_name', 'unknown'), caller.f_code.co_name, fields)
    raise AccessError('This is a shared public demo. Accounts, credentials and technical settings are fixed; business sample records remain available for testing.')


def check_budget(records, values, *, file_write=False):
    """Bound this shared synthetic instance, including deleted-file remnants."""
    records.env.cr.execute('SELECT pg_database_size(current_database())')
    if records.env.cr.fetchone()[0] >= 512 * 1024 * 1024:
        raise AccessError('Public demo storage is full. Please contact the operator to reset synthetic test data.')
    if file_write:
        root = os.path.join(config['data_dir'], 'filestore', records.env.cr.dbname)
        size, count = 0, 0
        for folder, _dirs, files in os.walk(root, followlinks=False):
            for name in files:
                p = os.path.join(folder, name)
                if os.path.islink(p):
                    denied()
                try:
                    size += os.stat(p).st_size
                    count += 1
                except FileNotFoundError:
                    continue
                if size >= 128 * 1024 * 1024 or count >= 20000:
                    raise AccessError('Public demo attachment storage is full; only synthetic samples are supported.')
        rows = values if isinstance(values, list) else [values]
        incoming = sum(len(row.get('raw') or row.get('datas') or row.get('db_datas') or b'') for row in rows)
        if size + incoming > 128 * 1024 * 1024:
            raise AccessError('Public demo attachment storage limit exceeded.')


class DemoAttachment(models.Model):
    _inherit = 'ir.attachment'

    @api.model_create_multi
    def create(self, values_list):
        if restricted() and self.env.uid != SUPERUSER_ID:
            defaults = self.default_get(['url', 'res_model'])
            for values in values_list:
                url = values.get('url', defaults.get('url')) or ''
                model = values.get('res_model', defaults.get('res_model'))
                if url.startswith('/web/assets') or model in LOCKED_MODELS:
                    denied()
        return super().create(values_list)

    def write(self, values):
        if restricted() and self.env.uid != SUPERUSER_ID:
            self.check_access('write')
            if self.sudo().filtered(lambda a: (a.url or '').startswith('/web/assets') or a.res_model in LOCKED_MODELS):
                denied()
            if (values.get('url') or '').startswith('/web/assets') or values.get('res_model') in LOCKED_MODELS:
                denied()
        return super().write(values)

    def unlink(self):
        # Native trusted bundle cleanup uses sudo; direct user operations do not.
        if restricted() and not self.env.su:
            self.check_access('unlink')
            if self.sudo().filtered(lambda a: (a.url or '').startswith('/web/assets') or a.res_model in LOCKED_MODELS):
                denied()
        return super().unlink()

    def _file_write(self, bin_value, checksum):
        if not restricted():
            return super()._file_write(bin_value, checksum)
        # A filesystem lock covers only the short physical write. Holding a
        # transaction lock across report rendering can deadlock asset requests.
        # Count physical orphans too: delete/create must not bypass the budget.
        lock = os.path.join(config['data_dir'], '.demo_attachment_budget.lock')
        with open(lock, 'a') as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            _name, path = self._get_path(bin_value, checksum)
            if not os.path.exists(path):
                check_budget(self, {'raw': bin_value}, file_write=True)
            return super()._file_write(bin_value, checksum)


class DemoBase(models.AbstractModel):
    _inherit = 'base'

    @api.model_create_multi
    def create(self, values_list):
        if restricted() and self._name in LOCKED_MODELS:
            denied()
        if restricted():
            check_budget(self, values_list)
        return super().create(values_list)

    def write(self, values):
        if restricted() and self._name in LOCKED_MODELS and values:
            denied()
        if restricted() and values:
            check_budget(self, values)
        return super().write(values)

    def unlink(self):
        if restricted() and self._name in LOCKED_MODELS:
            denied()
        return super().unlink()

    @api.model
    def _get_view(self, view_id=None, view_type='form', **options):
        arch, view = super()._get_view(view_id=view_id, view_type=view_type, **options)
        if restricted():
            arch = deepcopy(arch)
            # Keep native local lookup/editing. The IAP-enhanced widgets are
            # inappropriate for a demo with no enabled external services.
            for node in arch.xpath(".//field[@widget='field_partner_autocomplete']"):
                node.set('widget', 'char')
            for node in arch.xpath(".//field[@widget='res_partner_many2one']"):
                node.set('widget', 'many2one')
            if self._name == 'res.users':
                for node in arch.xpath('.//field'):
                    if node.get('name') in ACCOUNT_FIELDS:
                        node.set('readonly', '1')
                for node in arch.xpath('.//button'):
                    if node.get('name') in {'action_change_password_wizard', 'preference_change_password',
                        'action_reset_password', 'action_totp_enable_wizard', 'action_totp_disable', 'action_create_passkey'}:
                        node.set('invisible', '1')
        return arch, view


class DemoUsers(models.Model):
    _inherit = 'res.users'

    @api.model_create_multi
    def create(self, values_list):
        if restricted():
            denied()
        return super().create(values_list)

    def write(self, values):
        if restricted() and ACCOUNT_FIELDS.intersection(values):
            denied()
        return super().write(values)

    def unlink(self):
        if restricted():
            denied()
        return super().unlink()

    @api.model
    def change_password(self, old_passwd, new_passwd):
        if restricted():
            denied()
        return super().change_password(old_passwd, new_passwd)

    def _change_password(self, new_passwd):
        if restricted():
            denied()
        return super()._change_password(new_passwd)

    def action_reset_password(self):
        if restricted():
            denied()
        return super().action_reset_password()

    @api.model
    def reset_password(self, login):
        if restricted():
            denied()
        return super().reset_password(login)

    def _totp_try_setting(self, secret, code):
        if restricted():
            denied()
        return super()._totp_try_setting(secret, code)

    def action_totp_enable_wizard(self):
        if restricted():
            denied()
        return super().action_totp_enable_wizard()

    def action_totp_disable(self):
        if restricted():
            denied()
        return super().action_totp_disable()

    def action_create_passkey(self):
        if restricted():
            denied()
        return super().action_create_passkey()

    def action_change_password_wizard(self):
        if restricted():
            denied()
        return super().action_change_password_wizard()

    def preference_change_password(self):
        if restricted():
            denied()
        return super().preference_change_password()


class DemoApiKeys(models.Model):
    _inherit = 'res.users.apikeys'

    def _generate(self, scope, name, expiration_date):
        # Native key-description and trusted-device flows use this method
        # rather than ORM create(). Preserve the same contract and deny here.
        if restricted():
            denied()
        return super()._generate(scope, name, expiration_date)


class DemoPartner(models.Model):
    _inherit = 'res.partner'

    def write(self, values):
        if restricted() and {'name', 'email', 'active', 'user_ids'}.intersection(values):
            if self.env['res.users'].sudo().with_context(active_test=False).search_count([('partner_id', 'in', self.ids)], limit=1):
                denied()
        return super().write(values)

    def unlink(self):
        if restricted() and self.env['res.users'].sudo().with_context(active_test=False).search_count([('partner_id', 'in', self.ids)], limit=1):
            denied()
        return super().unlink()


class DemoMail(models.Model):
    _inherit = 'mail.mail'

    def send(self, *args, **kwargs):
        if restricted():
            raise AccessError(_('Public demo: real email delivery is disabled. You can prepare and inspect drafts.'))
        return super().send(*args, **kwargs)


class DemoModule(models.Model):
    _inherit = 'ir.module.module'

    def button_immediate_install(self):
        if restricted():
            denied()
        return super().button_immediate_install()

    def button_immediate_upgrade(self):
        if restricted():
            denied()
        return super().button_immediate_upgrade()

    def button_immediate_uninstall(self):
        if restricted():
            denied()
        return super().button_immediate_uninstall()
