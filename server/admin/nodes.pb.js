// Local CLI only. No admin import/review routes exist on the public API.
const nodeDomain=require(__hooks+'/../pb_hooks/enana_nodes_domain.js');
$app.rootCmd.addCommand(new Command({use:'enana-nodes-import',run:(cmd,args)=>{
 if(args.length!==1)throw Error('Private catalog input required');
 const d=JSON.parse(toString($os.readFile(args[0]))),t=Math.floor(Date.now()/1000);
 if(!Array.isArray(d.nodes)||!d.nodes.length||d.nodes.length>300||!Number.isInteger(d.fresh_until)||d.fresh_until<=t||d.fresh_until>t+7*86400)throw Error('Invalid catalog');
 const keys={};const nodes=d.nodes.map(n=>{if(!/^[a-f0-9]{32}$/.test(n.key)||keys[n.key])throw Error('Invalid catalog key');keys[n.key]=true;return {key:'official-'+n.key,label:nodeDomain.label(n.label),outbound:nodeDomain.outbound(n.outbound)}});
 $app.runInTransaction(tx=>{
  const seen={};for(const n of nodes){let r;try{r=tx.findFirstRecordByData('official_nodes','node_key',n.key)}catch(_){r=new Record(tx.findCollectionByNameOrId('official_nodes'));r.set('node_key',n.key)}
   if(r.getString('origin')&&r.getString('origin')!=='official')throw Error('Catalog ownership conflict');
   r.set('origin','official');r.set('label',n.label);r.set('outbound',n.outbound);r.set('enabled',true);r.set('approved',true);r.set('fresh_until',new Date(d.fresh_until*1000).toISOString());r.set('capability','general');tx.save(r);seen[r.id]=true;
  }
  for(const r of tx.findRecordsByFilter('official_nodes','origin="official"','',500,0)){if(!seen[r.id]){r.set('enabled',false);r.set('outbound',null);tx.save(r)}}
 });console.log('Official catalog updated: '+nodes.length+' nodes; credentials withheld.');
}}));
$app.rootCmd.addCommand(new Command({use:'enana-share-review',run:(cmd,args)=>{
 if(args.length!==2||!/^shared-[a-z0-9]{15}-[a-f0-9]{32}$/.test(args[0])||!['approve','reject'].includes(args[1]))throw Error('Share key and approve/reject required');
 $app.runInTransaction(tx=>{
  const r=tx.findFirstRecordByData('official_nodes','node_key',args[0]),u=tx.findRecordById('users',r.getString('owner'));
  if(r.getString('origin')!=='shared'||!r.getBool('consent')||r.getString('consent_revision')!=='server-sharing-v1'||u.getBool('disabled')||!u.getBool('verified')||r.getDateTime('fresh_until').unix()<=Math.floor(Date.now()/1000))throw Error('Share consent unavailable');
  nodeDomain.outbound(JSON.parse(toString(r.get('outbound'))));const approved=args[1]==='approve';r.set('approved',approved);r.set('enabled',approved);r.set('approved_at',new Date().toISOString());tx.save(r);
  const e=new Record(tx.findCollectionByNameOrId('server_share_events'));e.set('user',u.id);e.set('node_key',r.getString('node_key'));e.set('action',approved?'approve':'reject');e.set('revision','server-sharing-v1');tx.save(e);
 });console.log('Share review saved; credentials withheld.');
}}));
