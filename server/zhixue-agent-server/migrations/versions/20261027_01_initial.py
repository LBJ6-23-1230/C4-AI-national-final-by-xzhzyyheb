"""Initial PostgreSQL domain tables. Existing JSON IDs are unchanged."""
from alembic import op
from migrations.schema_v1 import metadata

revision = "20261027_01"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    metadata.create_all(op.get_bind())


def downgrade():
    raise RuntimeError("Destructive downgrade is disabled. Restore to a separate database and verify first.")
