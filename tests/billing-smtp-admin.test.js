'use strict';
// Exercise administrator CLI commands against a fresh database, never Gmail.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
test('SMTP administrator configuration is private, reversible and absent from HTTP hooks',()=>{
 const binary=process.env.PB_BIN;assert.ok(binary,'PB_BIN is required');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'enana-smtp-admin-')),hooks=path.join(dir,'hooks'),migrations=path.join(dir,'migrations'),input=path.join(dir,'input.json'),backup=path.join(dir,'backup.json');
 const oldPassword='previous-fixture-only',password='abcdefghijklmnop';
 try {
  fs.mkdirSync(hooks);fs.mkdirSync(migrations);
  fs.copyFileSync(path.resolve(__dirname,'../server/admin/smtp.pb.js'),path.join(hooks,'smtp.pb.js'));
  fs.writeFileSync(path.join(hooks,'fixture.pb.js'),`$app.rootCmd.addCommand(new Command({use:'fixture-settings',run:()=>{const s=$app.settings();s.smtp.enabled=false;s.smtp.host='smtp.example.invalid';s.smtp.port=587;s.smtp.password='${oldPassword}';s.meta.senderName='Previous sender';s.meta.senderAddress='previous@example.invalid';$app.save(s)}}));$app.rootCmd.addCommand(new Command({use:'fixture-check',run:()=>{const s=$app.settings();console.log(JSON.stringify({password_matches:s.smtp.password==='${password}',sender_name:s.meta.senderName}))}}));`);
  const args=['--dir='+path.join(dir,'data'),'--hooksDir='+hooks,'--migrationsDir='+migrations,'--automigrate=false','--hooksWatch=false'];
  function cli(cmd){const r=spawnSync(binary,[...args,...cmd],{encoding:'utf8',timeout:15000});assert.ok(!((r.stdout||'')+(r.stderr||'')).includes(password),'password never appears in output');return r}
  function status(){const r=cli(['enana-smtp-status']);assert.equal(r.status,0);return JSON.parse(r.stdout.slice(r.stdout.indexOf('{')).trim())}
  assert.equal(cli(['fixture-settings']).status,0);const before=status();
  fs.writeFileSync(input,JSON.stringify({sender:'gococms@gmail.com',password:'abcd efgh ijkl mnop'}),{mode:0o600});
  assert.equal(cli(['enana-smtp-configure',input,backup]).status,0);
  assert.deepEqual(status(),{enabled:true,host:'smtp.gmail.com',port:465,tls:true,sender:'gococms@gmail.com',password_present:true});
  assert.equal(fs.statSync(backup).mode&0o777,0o600);const saved=JSON.parse(fs.readFileSync(backup));assert.equal(saved.smtp.password,oldPassword);
  const check=cli(['fixture-check']);assert.equal(check.status,0);assert.ok(check.stdout.includes('"password_matches":true'));assert.ok(check.stdout.includes('"sender_name":"enana"'));
  assert.equal(cli(['enana-smtp-restore',backup]).status,0);assert.deepEqual(status(),before);
  fs.writeFileSync(input,JSON.stringify({sender:'other@example.invalid',password}));assert.notEqual(cli(['enana-smtp-configure',input,path.join(dir,'invalid-backup.json')]).status,0);assert.deepEqual(status(),before);assert.equal(fs.existsSync(path.join(dir,'invalid-backup.json')),false);
  assert.equal(fs.existsSync(path.resolve(__dirname,'../server/pb_hooks/smtp.pb.js')),false,'administrator commands are not loaded by HTTP daemon');
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
});
