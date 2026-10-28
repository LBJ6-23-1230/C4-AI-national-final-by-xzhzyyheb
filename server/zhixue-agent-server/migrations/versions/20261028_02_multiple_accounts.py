"""Allow multiple accounts per phone."""
from alembic import op
from sqlalchemy import inspect
revision = "20261028_02"
down_revision = "20261027_01"
branch_labels = None
depends_on = None

def upgrade():
    for constraint in inspect(op.get_bind()).get_unique_constraints("users"):
        if constraint["column_names"] == ["phone"]:
            op.drop_constraint(constraint["name"], "users", type_="unique")
    op.create_index("ix_users_phone", "users", ["phone"])

def downgrade():
    # Fails safely if duplicate phones exist; never delete accounts for downgrade.
    op.create_unique_constraint("users_phone_key", "users", ["phone"])
    op.drop_index("ix_users_phone", table_name="users")
