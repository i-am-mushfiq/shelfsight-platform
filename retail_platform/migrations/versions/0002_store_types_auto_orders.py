"""store types, visit store type, order metadata

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-10 12:00:00
"""
from alembic import op
import sqlalchemy as sa


revision = '0002'
down_revision = '0001'
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table('channel', schema=None) as batch_op:
        batch_op.add_column(sa.Column('is_store_type', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('sort_order', sa.Integer(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('icon', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('units_per_facing', sa.Integer(), nullable=True))
    # Existing taxonomies: every leaf channel becomes a store type officers can pick.
    op.execute(
        "UPDATE channel SET is_store_type = TRUE "
        "WHERE id NOT IN (SELECT parent_id FROM channel WHERE parent_id IS NOT NULL)"
    )

    with op.batch_alter_table('visit', schema=None) as batch_op:
        batch_op.add_column(sa.Column('store_type_id', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('previous_store_type_id', sa.String(length=32), nullable=True))
        batch_op.create_foreign_key('fk_visit_store_type_id_channel', 'channel', ['store_type_id'], ['id'])
        batch_op.create_foreign_key('fk_visit_previous_store_type_id_channel', 'channel',
                                    ['previous_store_type_id'], ['id'])

    with op.batch_alter_table('sales_order', schema=None) as batch_op:
        batch_op.add_column(sa.Column('meta', sa.JSON(), nullable=False, server_default=sa.text("'{}'")))

    with op.batch_alter_table('sales_order_item', schema=None) as batch_op:
        batch_op.add_column(sa.Column('sources', sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('sales_order_item', schema=None) as batch_op:
        batch_op.drop_column('sources')

    with op.batch_alter_table('sales_order', schema=None) as batch_op:
        batch_op.drop_column('meta')

    with op.batch_alter_table('visit', schema=None) as batch_op:
        batch_op.drop_constraint('fk_visit_previous_store_type_id_channel', type_='foreignkey')
        batch_op.drop_constraint('fk_visit_store_type_id_channel', type_='foreignkey')
        batch_op.drop_column('previous_store_type_id')
        batch_op.drop_column('store_type_id')

    with op.batch_alter_table('channel', schema=None) as batch_op:
        batch_op.drop_column('units_per_facing')
        batch_op.drop_column('icon')
        batch_op.drop_column('sort_order')
        batch_op.drop_column('is_store_type')
