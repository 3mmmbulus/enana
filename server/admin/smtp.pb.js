// Load only for a local administrator command with --hooksDir=server/admin.
// These commands are never added to the production HTTP service or client.
// Secrets enter through a private file, never process arguments or stdout.
$app.rootCmd.addCommand(new Command({
 use:'enana-smtp-configure',
 run:(cmd,args)=>{
  if(args.length!==2)throw Error('Private input and backup paths required');
  const c=JSON.parse(toString($os.readFile(args[0])));
  if(c.sender!=='gococms@gmail.com'||typeof c.password!=='string'||!/^[a-z]{16}$/.test(c.password.replace(/ /g,'')))throw Error('Invalid official Gmail configuration');
  const s=$app.settings();
  $os.writeFile(args[1],JSON.stringify({smtp:s.smtp,senderName:s.meta.senderName,senderAddress:s.meta.senderAddress}),0o600);
  s.smtp.enabled=true;s.smtp.host='smtp.gmail.com';s.smtp.port=465;s.smtp.tls=true;s.smtp.authMethod='PLAIN';s.smtp.username=c.sender;s.smtp.password=c.password.replace(/ /g,'');
  s.meta.senderName='enana';s.meta.senderAddress=c.sender;
  try{$app.save(s)}catch(_){throw Error('SMTP configuration could not be saved')}
  console.log('SMTP configuration saved; credentials withheld.');
 }
}));
$app.rootCmd.addCommand(new Command({
 use:'enana-smtp-status',
 run:()=>{const s=$app.settings();console.log(JSON.stringify({enabled:s.smtp.enabled,host:s.smtp.host,port:s.smtp.port,tls:s.smtp.tls,sender:s.meta.senderAddress,password_present:!!s.smtp.password}));}
}));
$app.rootCmd.addCommand(new Command({
 use:'enana-smtp-restore',
 run:(cmd,args)=>{
  if(args.length!==1)throw Error('Private backup path required');
  const c=JSON.parse(toString($os.readFile(args[0]))),s=$app.settings();
  if(!c.smtp||typeof c.senderName!=='string'||typeof c.senderAddress!=='string')throw Error('Invalid settings backup');
  for(const k of ['enabled','host','port','tls','authMethod','username','password','localName'])s.smtp[k]=c.smtp[k];
  s.meta.senderName=c.senderName;s.meta.senderAddress=c.senderAddress;$app.save(s);
  console.log('Previous SMTP configuration restored.');
 }
}));
