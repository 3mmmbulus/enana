// 2.3.25: a payable amount is the base price plus a tail of at most three decimals (+0.1 … +0.999), and a top-up
// can be 1000 USDT, so billing_orders.amount must accept up to 1000.999 USDT (1000999000 micro-USDT; the old
// bound 1000010000 refused any tail above +0.01 on a 1000 USDT top-up). Only the upper bound changes; the field
// keeps its id, name and options, and no row, index or other collection is touched. Money is never moved.
migrate((app) => {
  const orders = app.findCollectionByNameOrId('billing_orders');
  const old = orders.fields.getByName('amount');
  orders.fields.add(new Field({
    id: old.id, name: 'amount', type: 'number', onlyInt: true, min: 1, max: 1000999000,
    required: old.required, hidden: old.hidden, presentable: old.presentable, system: old.system,
  }));
  app.save(orders);
}, (app) => { /* The wider bound is kept: narrowing it again could make existing orders invalid. Financial rows are retained. */ });
