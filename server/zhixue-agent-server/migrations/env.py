import os
from alembic import context
from app.settings import load_environment
from app.repositories.postgresql_repository import make_engine
from app.repositories.pg_schema import metadata

load_environment()

if context.is_offline_mode():
    context.configure(url=os.environ["DATABASE_URL"], target_metadata=metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = make_engine(os.getenv("MIGRATION_DATABASE_URL") or os.environ["DATABASE_URL"])
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
