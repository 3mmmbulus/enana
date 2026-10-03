// Integer micro-USDT only. Every financial mutation uses a DB transaction.
migrate((app) => {
  const users=app.findCollectionByNameOrId('users');
  const dates=[{name:'created',type:'autodate',onCreate:true},{name:'updated',type:'autodate',onCreate:true,onUpdate:true}];
  const user={name:'user',type:'relation',required:true,collectionId:users.id,maxSelect:1,cascadeDelete:false};
  function table(name,fields,indexes){
    const c=new Collection({name:name,type:'base',fields:fields.concat(dates)});
    (indexes||[]).forEach(i=>c.addIndex(i[0],i[1],i[2],i[3]||''));app.save(c);
  }
  table('billing_wallets',[user,{name:'balance',type:'number',onlyInt:true,min:0,max:9000000000000},{name:'auto_renew',type:'bool'}],[['idx_wallet_user',true,'user']]);
  table('billing_orders',[user,
    {name:'request_key',type:'text',required:true,max:80},
    {name:'kind',type:'select',required:true,values:['plan','topup'],maxSelect:1},
    {name:'sku',type:'text',max:20},{name:'months',type:'number',onlyInt:true,min:0,max:60},
    {name:'price',type:'number',onlyInt:true,min:1,max:1000000000},
    {name:'amount',type:'number',onlyInt:true,min:1,max:1000010000},
    {name:'address',type:'text',required:true,min:34,max:34},
    {name:'expires_at',type:'date',required:true},
    {name:'status',type:'select',required:true,values:['pending','paid','expired','cancelled','credited_late'],maxSelect:1},
    {name:'paid_at',type:'date'},{name:'event_key',type:'text',max:80},
  ],[['idx_order_request',true,'user, request_key'],['idx_order_quote',true,'address, amount'],['idx_order_user',false,'user, created']]);
  table('billing_ledger',[user,{name:'entry_key',type:'text',required:true,max:150},
    {name:'delta',type:'number',onlyInt:true,min:-9000000000000,max:9000000000000},
    {name:'balance_after',type:'number',onlyInt:true,min:0,max:9000000000000},
    {name:'kind',type:'text',required:true,max:30},{name:'order_id',type:'text',max:15},
    {name:'sku',type:'text',max:20},{name:'expires_after',type:'date'},
  ],[['idx_ledger_key',true,'entry_key'],['idx_ledger_user',false,'user, created']]);
  table('billing_events',[{name:'event_key',type:'text',required:true,max:80},
    {name:'address',type:'text',required:true,max:34},{name:'amount',type:'number',onlyInt:true,min:1,max:9000000000000},
    {name:'chain_at',type:'date',required:true},{name:'order_id',type:'text',max:15},
    {name:'status',type:'select',required:true,values:['matched','unmatched'],maxSelect:1},
  ],[['idx_chain_event',true,'event_key']]);
  table('billing_health',[{name:'code',type:'text',required:true,max:30},{name:'checked_at',type:'date'},
    {name:'healthy',type:'bool'},{name:'message',type:'text',max:120}], [['idx_billing_health',true,'code']]);
  table('email_requests',[user,{name:'requested_at',type:'date'}],[['idx_email_request_user',true,'user']]);
  table('official_nodes',[{name:'node_key',type:'text',required:true,max:64},
    {name:'label',type:'text',max:100},{name:'outbound',type:'json',maxSize:16000},
    {name:'owner',type:'relation',collectionId:users.id,maxSelect:1,cascadeDelete:true},
    {name:'origin',type:'select',required:true,values:['official','shared'],maxSelect:1},
    {name:'consent',type:'bool'},{name:'approved',type:'bool'},{name:'enabled',type:'bool'},
    {name:'consent_at',type:'date'},{name:'fresh_until',type:'date'},
    {name:'capability',type:'select',values:['general','claude_clean'],maxSelect:1},
  ],[['idx_official_node_key',true,'node_key'],['idx_official_owner',false,'owner']]);
  let pro;try{pro=app.findFirstRecordByData('plans','code','pro')}catch(_){pro=new Record(app.findCollectionByNameOrId('plans'));pro.set('code','pro')}
  pro.set('title','Pro');pro.set('active',true);pro.set('max_devices_per_platform',pro.getInt('max_devices_per_platform')||3);
  pro.set('features',['core','sync','vps_deploy','official_proxy']);app.save(pro);
  // No fabricated verification for existing users; unverified users retain
  // local/free functionality and verify before purchasing or receiving nodes.
  users.verificationToken.duration=86400;
  users.verificationTemplate.subject='Activate your enana email';
  users.verificationTemplate.body='<p>Confirm your enana email address:</p><p><a href="{APP_URL}/verify#token={TOKEN}">Activate email</a></p><p>This link expires in 24 hours. If you did not request it, ignore this message.</p>';
  app.save(users);
  const s=app.settings();s.meta.senderAddress='gococms@gmail.com';s.meta.senderName='enana';
  s.rateLimits.rules.unshift({label:'/api/enana/v1/email/',audience:'',maxRequests:3,duration:60});app.save(s);
}, (app) => { /* Financial rows are retained; rollback never destroys funds. */ });
