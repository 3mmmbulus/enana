routerAdd('GET','/api/enana/v1/billing',(e)=>require(`${__hooks}/enana_billing.js`).status(e));
routerAdd('POST','/api/enana/v1/billing/checkout',(e)=>require(`${__hooks}/enana_billing.js`).checkout(e),$apis.bodyLimit(16384));
routerAdd('GET','/api/enana/v1/billing/order',(e)=>require(`${__hooks}/enana_billing.js`).order(e));
routerAdd('POST','/api/enana/v1/billing/cancel',(e)=>require(`${__hooks}/enana_billing.js`).cancel(e),$apis.bodyLimit(16384));
routerAdd('POST','/api/enana/v1/billing/order/recheck',(e)=>require(`${__hooks}/enana_billing.js`).recheck(e),$apis.bodyLimit(16384));
routerAdd('POST','/api/enana/v1/billing/purchase',(e)=>require(`${__hooks}/enana_billing.js`).purchase(e),$apis.bodyLimit(16384));
routerAdd('POST','/api/enana/v1/billing/auto-renew',(e)=>require(`${__hooks}/enana_billing.js`).autoRenew(e),$apis.bodyLimit(16384));
routerAdd('GET','/api/enana/v1/email/status',(e)=>require(`${__hooks}/enana_billing.js`).emailStatus(e));
routerAdd('POST','/api/enana/v1/email/send',(e)=>require(`${__hooks}/enana_billing.js`).emailSend(e),$apis.bodyLimit(16384));
// These paths are not whitelisted by public nginx and also require a private
// scanner key and a loopback socket. A user token can never confirm a payment.
routerAdd('GET','/api/enana/internal/billing/work',(e)=>require(`${__hooks}/enana_billing.js`).work(e));
routerAdd('POST','/api/enana/internal/billing/event',(e)=>require(`${__hooks}/enana_billing.js`).events(e),$apis.bodyLimit(16384));
routerAdd('POST','/api/enana/internal/billing/health',(e)=>require(`${__hooks}/enana_billing.js`).health(e),$apis.bodyLimit(16384));
// Operator queue (superuser only; not in the public nginx allow-list).
routerAdd('GET','/api/enana/admin/billing/manual',(e)=>require(`${__hooks}/enana_billing.js`).manualList(e),$apis.requireSuperuserAuth());
routerAdd('POST','/api/enana/admin/billing/manual/resolve',(e)=>require(`${__hooks}/enana_billing.js`).manualResolve(e),$apis.bodyLimit(16384),$apis.requireSuperuserAuth());
cronAdd('enana_wallet_renewal','* * * * *',()=>require(`${__hooks}/enana_billing.js`).renewAll());
onRecordAfterCreateSuccess((e)=>{e.next();require(`${__hooks}/enana_billing.js`).registrationMail(e.record)},'users');
