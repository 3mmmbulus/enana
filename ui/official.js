/* Official-node delivery and independent server sharing. GETs only read state;
 * configuration changes start only after an explicit user action. */
(function () {
  'use strict';
  var TP=window.TP,ui=TP.ui,h=TP.h,t=window.I18N.t,L=window.I18N.L;
  var O=TP.official={},mounts=[],data=null,error=null,pending=null,epoch=0,busy=false,dialogs=[];
  function draw(root){
    TP.clear(root);
    var why=TP.why.helper(),reason=data&&data.reason;
    root.appendChild(h('div',{class:'card-h'},ui.icon('pro',20,'ci'),h('h3',null,L('servers.off.title')),ui.badge(data&&data.nodes?t('official.count',{n:data.nodes}):t('billing.none'),data&&data.nodes?'ok':'neutral')));
    root.appendChild(h('p',{class:'muted'},L('official.note')));
    if(error)root.appendChild(h('p',{role:'status',class:'hint warn'},TP.errMsg(error)));
    if(reason)root.appendChild(h('p',{role:'status',class:'hint warn'},t('official.reason.'+reason)));
    if(data&&data.pending)root.appendChild(h('p',{role:'status',class:'hint warn'},L('official.pending')));
    var refresh=ui.btn(L('official.refresh'),{kind:'primary',icon:'refresh'});
    ui.avail(refresh,why||'');if(busy)ui.actionBusy(refresh,true);
    ui.act(refresh,O.refresh);root.appendChild(refresh);
    root.appendChild(h('p',{class:'muted sm'},L('official.private')));
  }
  function redraw(){mounts.forEach(draw)}
  O.mount=function(){var root=h('section',{class:'card srv-off'});mounts.push(root);draw(root);return root};
  O.load=function(){
    if(TP.S.locked||TP.why.helper())return Promise.resolve(null);
    if(pending)return pending;var mine=epoch;
    pending=TP.helper('GET','/api/official/status').then(function(r){if(mine===epoch){data=r;error=null;redraw()}return r},function(e){if(mine===epoch){error=e;redraw()}return null}).finally(function(){if(mine===epoch)pending=null});return pending;
  };
  O.refresh=async function(){
    if(busy)return;var mine=epoch;var yes=await ui.confirmDialog({title:t('official.refresh'),message:t('official.applyNote'),confirmText:t('official.refresh')});if(!yes||mine!==epoch)return;
    busy=true;redraw();
    try{await TP.jobs.runInDock(t('official.refresh'),function(){return TP.helper('POST','/api/official/refresh')});if(mine!==epoch)return;await TP.loadState();await TP.plan.load(true);await O.load()}
    finally{if(mine===epoch){busy=false;redraw()}}
  };
  O.share=async function(s){
    if(s.official||s.sub||s.derived)return;
    var mine=epoch,r=await TP.helper('GET','/api/servers/shares'),old=(r.shares||[]).find(function(x){return x.label===s.tag&&x.status!=='revoked'});
    if(mine!==epoch)return;
    var body=h('div',null,h('p',null,t('sharing.note',{name:s.tag})),h('p',{class:'hint warn'},L('sharing.plaintext')),h('p',{class:'muted sm'},L('sharing.scope')),h('p',{role:'status'},t(old?'sharing.status.'+old.status:'sharing.off')));
    var dm=ui.modal({title:t('sharing.title'),icon:'server',size:'md',body:body,actions:[
      {label:t(old?'sharing.renew':'sharing.enable'),kind:'primary',keep:true,onClick:async function(){
        var yes=await ui.confirmDialog({title:t('sharing.consentTitle'),message:t('sharing.consent'),detail:[t('sharing.plaintext'),t('sharing.cost'),t('sharing.scope')],confirmText:t('sharing.accept')});if(!yes||mine!==epoch)return false;
        await TP.helper('POST','/api/servers/share',{body:JSON.stringify({tag:s.tag,consent:true,revision:'server-sharing-v1'}),sudoWhy:t('sharing.title'),timeout:18000});dm.close();ui.toast(t('sharing.submitted'),'ok');return false;
      }},
      {label:t('sharing.revoke'),kind:'danger',keep:true,unavail:old?null:{reason:t('sharing.off')},onClick:async function(){
        var yes=await ui.confirmDialog({title:t('sharing.revoke'),message:t('sharing.revokeNote'),confirmText:t('sharing.revoke'),danger:true});if(!yes||mine!==epoch)return false;
        await TP.helper('POST','/api/servers/share',{body:JSON.stringify({tag:s.tag,consent:false}),sudoWhy:t('sharing.title'),timeout:18000});dm.close();ui.toast(t('sharing.revoked'),'ok');return false;
      }}, {label:t('common.close'),cancel:true}
    ]});dialogs.push(dm);
  };
  TP.on('auth',function(){epoch++;dialogs.forEach(function(d){d.close()});dialogs=[];data=null;error=null;pending=null;busy=false;redraw()});
  TP.on('lang',redraw);
})();
