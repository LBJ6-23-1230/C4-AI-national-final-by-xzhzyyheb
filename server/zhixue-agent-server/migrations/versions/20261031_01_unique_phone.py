"""One normalized phone per active account; duplicate groups must be resolved first."""
from alembic import op
from sqlalchemy import text

revision = '20261031_01'
down_revision = '20261030_03'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    # Fail before normalization or DDL; no account is chosen or deleted here.
    groups = conn.execute(text("""SELECT count(*) FROM (
        SELECT regexp_replace(regexp_replace(coalesce(phone,''),'[^0-9]','','g'), '^86(?=[0-9]{11}$)', '') AS normalized
        FROM users WHERE status='active' AND coalesce(phone,'')<>''
        GROUP BY normalized HAVING count(*)>1) duplicates""")).scalar_one()
    if groups:
        raise RuntimeError('Duplicate active phones exist. Run audit_phone_accounts.py and explicit primary migration first.')
    conn.execute(text("""UPDATE users SET phone=regexp_replace(regexp_replace(phone,'[^0-9]','','g'), '^86(?=[0-9]{11}$)', ''),
        value=jsonb_set(value,'{phone}',to_jsonb(regexp_replace(regexp_replace(phone,'[^0-9]','','g'), '^86(?=[0-9]{11}$)', '')))
        WHERE coalesce(phone,'')<>''"""))
    op.create_index('uq_users_active_phone', 'users', ['phone'], unique=True,
        postgresql_where=text("status='active' AND phone IS NOT NULL AND phone<>''"))


def downgrade():
    op.drop_index('uq_users_active_phone', table_name='users')
