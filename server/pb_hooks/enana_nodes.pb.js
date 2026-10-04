routerAdd('GET','/api/enana/v1/servers/shares',e=>require(`${__hooks}/enana_nodes.js`).shares(e));
routerAdd('POST','/api/enana/v1/servers/share',e=>require(`${__hooks}/enana_nodes.js`).share(e),$apis.bodyLimit(16384));
