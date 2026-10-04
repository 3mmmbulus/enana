migrate((app)=>{
 const c=app.findCollectionByNameOrId('official_nodes');
 c.fields.add(new TextField({name:'consent_revision',max:40}));
 c.fields.add(new DateField({name:'approved_at'}));app.save(c);
 const users=app.findCollectionByNameOrId('users');
 const events=new Collection({name:'server_share_events',type:'base',fields:[
  {name:'user',type:'relation',required:true,collectionId:users.id,maxSelect:1,cascadeDelete:false},
  {name:'node_key',type:'text',required:true,max:64},
  {name:'action',type:'select',required:true,values:['consent','renew','change','revoke','approve','reject'],maxSelect:1},
  {name:'revision',type:'text',max:40},
  {name:'created',type:'autodate',onCreate:true}
 ]});events.addIndex('idx_share_events_user',false,'user, created','');app.save(events);
},()=>{/* Preserve consent history and user data during rollback. */});
