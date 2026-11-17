"""Fresh synthetic public demo only; executed offline before HTTP is enabled."""
import base64
import json
import os
import secrets


def ensure_system_keeper(env):
    """Satisfy native admin invariant without giving shared accounts Settings."""
    keeper = env['res.users'].with_context(active_test=False).search([('login', '=', '__demo_system_keeper__')])
    if keeper:
        assert len(keeper) == 1 and keeper.active
        assert keeper.company_id != env.ref('base.main_company')
        assert keeper.has_group('base.group_system')
        return keeper
    isolated = env['res.company'].with_context(install_demo=True).create({
        'name': 'DEMO System Maintenance — no public access',
        'email': 'system-company@example.invalid', 'iap_enrich_auto_done': True,
    })
    keeper = env['res.users'].with_context(no_reset_password=True).create({
        'name': 'Demo System Maintenance', 'login': '__demo_system_keeper__',
        'password': secrets.token_urlsafe(64),
        'email': 'system-user@example.invalid', 'notification_type': 'inbox',
        'company_id': isolated.id, 'company_ids': [Command.set(isolated.ids)],
        'group_ids': [Command.set([env.ref('base.group_system').id])],
    })
    # Random credentials are not printed, returned, or stored in a public file.
    return keeper

assert os.environ.get('MORHON_PUBLIC_DEMO') == '1'
assert os.environ.get('MORHON_DEMO_BOOTSTRAP') == '1'
assert env.cr.dbname == os.environ['MORHON_DEMO_DB']
params = env['ir.config_parameter'].sudo()
assert not params.get_param('morhon.public_demo.seeded'), 'Never overwrite an existing demo'
params.set_param('crm.iap.lead.enrich.setting', 'manual')
assert env['sale.order'].search_count([]) == 0
assert env['crm.lead'].search_count([]) == 0

company = env.ref('base.main_company')
company.write({
    'name': 'MORHON DEMO — Synthetic Company',
    'email': 'demo@example.invalid', 'phone': False,
    'street': '100 Example Street — synthetic data',
    'city': 'Example City', 'zip': '00000',
    'country_id': env.ref('base.us').id,
    'mh_name_en': 'MORHON DEMO — Synthetic Company',
    'mh_address_en': '100 Example Street, Example City — synthetic data only',
    # Native Odoo uses the same flag to suppress enrichment in test companies.
    'iap_enrich_auto_done': True,
})
admin = env.ref('base.user_admin')
admin.write({'login': 'admin', 'password': 'admin', 'name': 'Demo Administrator',
             'email': 'admin@example.invalid', 'notification_type': 'inbox',
             'lang': 'en_US'})
manager_groups = [
    'base.group_user', 'sales_team.group_sale_manager',
    'purchase.group_purchase_manager', 'stock.group_stock_manager',
    'account.group_account_manager', 'crm.group_use_lead',
]
ensure_system_keeper(env)
admin.write({'group_ids': [Command.set([env.ref(x).id for x in manager_groups])]})
user = env['res.users'].with_context(no_reset_password=True).create({
    'name': 'Demo Salesperson', 'login': 'user', 'password': 'user',
    'email': 'user@example.invalid', 'notification_type': 'inbox', 'lang': 'en_US',
    'company_id': company.id, 'company_ids': [Command.set(company.ids)],
    'group_ids': [Command.set([env.ref(x).id for x in (
        'base.group_user', 'sales_team.group_sale_salesman', 'crm.group_use_lead')])],
})
team = env['crm.team'].create({'name': 'Demo Sales Team', 'company_id': company.id,
    'user_id': admin.id, 'member_ids': [Command.set([admin.id, user.id])]})
customer = env['res.partner'].create({
    'name': 'Example Industrial Buyer — DEMO', 'is_company': True,
    'email': 'buyer@example.invalid', 'street': '200 Sample Road',
    'city': 'Example City', 'country_id': env.ref('base.us').id,
    'lang': 'en_US', 'user_id': user.id, 'company_id': company.id,
})
contact = env['res.partner'].create({'name': 'Sample Buyer',
    'parent_id': customer.id, 'email': 'sample-buyer@example.invalid',
    'type': 'contact', 'lang': 'en_US', 'user_id': user.id, 'company_id': company.id})
product = env['product.product'].create({'name': 'Demo Process Component',
    'default_code': 'DEMO-001', 'type': 'consu', 'sale_ok': True,
    'purchase_ok': True, 'list_price': 25.0, 'standard_price': 10.0,
    'description_sale': 'Synthetic demonstration component; no real product commitment.'})
lead = env['crm.lead'].with_context(mail_create_nosubscribe=True).create({
    'name': 'DEMO: Repeat purchase with a new requirement', 'type': 'lead',
    'partner_id': contact.id, 'contact_name': contact.name,
    'email_from': contact.email, 'company_id': company.id,
    'user_id': user.id, 'team_id': team.id,
    'description': '<p>Synthetic enquiry: 10 demo components; please quote delivery options.</p>',
})
pooled = env['crm.lead'].with_context(mail_create_nosubscribe=True).create({
    'name': 'DEMO: Unassigned enquiry', 'type': 'lead', 'user_id': False,
    'team_id': team.id, 'company_id': company.id, 'email_from': 'new-buyer@example.invalid',
    'description': '<p>Synthetic enquiry. Assignment rules are not enabled automatically.</p>',
})
quote = env['sale.order'].with_context(mail_create_nosubscribe=True).create({
    'partner_id': customer.id, 'company_id': company.id,
    'user_id': user.id, 'team_id': team.id,
    'order_line': [Command.create({'product_id': product.id,
        'name': 'Demo component — editable quotation description',
        'product_uom_qty': 10.0, 'price_unit': 25.0})],
})
attachment = env['ir.attachment'].create({
    'name': 'DEMO-request.txt', 'mimetype': 'text/plain',
    'datas': base64.b64encode(b'SYNTHETIC DEMO ONLY\nPlease quote 10 demonstration components.\n'),
    'res_model': 'crm.lead', 'res_id': lead.id,
})
lead.message_post(subject='DEMO: Synthetic customer enquiry',
    body=Markup('<p>This is synthetic demo mail, not a real customer message.</p>'),
    message_type='comment', subtype_xmlid='mail.mt_comment',
    attachment_ids=attachment.ids, partner_ids=[user.partner_id.id])

env['ir.cron'].with_context(active_test=False).search([]).write({'active': False})
env['ir.mail_server'].search([]).write({'active': False})
env['fetchmail.server'].search([]).write({'active': False})
env['mh.ai.provider'].with_context(active_test=False).search([]).unlink()
env['payment.provider'].with_context(active_test=False).search([]).write({'state': 'disabled'})
env['mail.mail'].search([]).unlink()
params.set_param('web.base.url', os.environ.get('MORHON_DEMO_URL', 'http://localhost'))
params.set_param('web.base.url.freeze', 'True')
params.set_param('report.url', 'http://127.0.0.1:8069')
params.set_param('auth_signup.invitation_scope', 'b2b')
params.set_param('auth_signup.reset_password', 'False')
params.set_param('morhon.public_demo.seeded', '2026-11-17/v8.0')
env.cr.commit()
print('DEMO_SEED=' + json.dumps({'users': {'admin': admin.id, 'user': user.id},
    'customer': customer.id, 'lead': lead.id, 'unassigned_lead': pooled.id,
    'quotation': quote.id, 'synthetic_only': True}))
