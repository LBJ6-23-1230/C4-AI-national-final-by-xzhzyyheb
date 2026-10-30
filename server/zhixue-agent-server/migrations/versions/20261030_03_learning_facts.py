"""Durable account-owned courses and assignments."""
from alembic import op
from sqlalchemy import MetaData, Table, Column, Text, Integer, DateTime, Index, CheckConstraint, func
from sqlalchemy.dialects.postgresql import JSONB

revision = '20261030_03'
down_revision = '20261028_02'
branch_labels = None
depends_on = None


def upgrade():
    for name in ('learning_courses', 'learning_assignments'):
        table = Table(name, MetaData(), Column('item_id', Text, primary_key=True),
            Column('user_id', Text), Column('status', Text),
            Column('version', Integer, nullable=False, server_default='0'),
            Column('created_at', DateTime(timezone=True), nullable=False, server_default=func.now()),
            Column('updated_at', DateTime(timezone=True), nullable=False, server_default=func.now()),
            Column('value', JSONB, nullable=False), CheckConstraint('version >= 0', name=f'ck_{name}_version'))
        Index(f'ix_{name}_user_created', table.c.user_id, table.c.created_at, table.c.item_id)
        table.create(op.get_bind())
    op.execute("""DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zhixue_api') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON learning_courses, learning_assignments TO zhixue_api;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zhixue_worker') THEN
        GRANT SELECT ON learning_courses, learning_assignments TO zhixue_worker;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='zhixue_readonly') THEN
        GRANT SELECT ON learning_courses, learning_assignments TO zhixue_readonly;
      END IF;
    END $$""")


def downgrade():
    raise RuntimeError('Keep learning facts intact; use a compatible application rollback')
