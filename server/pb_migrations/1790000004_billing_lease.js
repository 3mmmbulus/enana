// 2.3.16: 24-hour slot leases instead of a permanent (address, amount) unique index,
// one-hour payment countdown field, transaction hash, recheck timestamp, and a manual
// review queue. Money is never moved by this migration; existing rows are kept.
migrate((app) => {
  const orders = app.findCollectionByNameOrId('billing_orders');
  orders.removeIndex('idx_order_quote');
  orders.fields.add(new DateField({ name: 'pay_by' }));
  orders.fields.add(new TextField({ name: 'tx_hash', max: 80 }));
  orders.fields.add(new DateField({ name: 'recheck_at' }));
  orders.fields.getByName('status').values = ['pending', 'paid', 'expired', 'cancelled', 'credited_late', 'manual'];
  app.save(orders);
  const users = app.findCollectionByNameOrId('users');
  const dates = [{ name: 'created', type: 'autodate', onCreate: true }, { name: 'updated', type: 'autodate', onCreate: true, onUpdate: true }];
  const manual = new Collection({
    name: 'billing_manual', type: 'base',
    fields: [
      { name: 'event_key', type: 'text', required: true, max: 80 },
      { name: 'address', type: 'text', required: true, max: 34 },
      { name: 'amount', type: 'number', onlyInt: true, min: 1, max: 9000000000000 },
      { name: 'chain_at', type: 'date', required: true },
      { name: 'reason', type: 'select', required: true, values: ['unmatched', 'underpaid', 'overpaid', 'late', 'duplicate', 'ambiguous', 'not_payable'], maxSelect: 1 },
      { name: 'user', type: 'relation', collectionId: users.id, maxSelect: 1, cascadeDelete: false },
      { name: 'order_id', type: 'text', max: 15 },
      { name: 'status', type: 'select', required: true, values: ['open', 'resolved'], maxSelect: 1 },
      { name: 'resolution', type: 'select', values: ['none', 'activated', 'refunded', 'noted'], maxSelect: 1 },
      { name: 'refund_tx', type: 'text', max: 80 },
      { name: 'actions', type: 'json', maxSize: 20000 },
    ].concat(dates),
  });
  manual.addIndex('idx_manual_event', true, 'event_key');
  manual.addIndex('idx_manual_status', false, 'status, created');
  app.save(manual);
}, (app) => { /* Financial rows and the manual queue are retained; rollback never destroys funds. */ });
