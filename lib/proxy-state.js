// SystemConfiguration preferences, not UI automation. Only proxy dictionaries
// are read/changed; DNS, interfaces, Keychain credentials and other apps remain
// outside this receipt. Invoked with administrator authorization for restore.
ObjC.import('SystemConfiguration');
ObjC.import('Foundation');
function unwrap(ref) { return ref ? ObjC.deepUnwrap(ObjC.castRefToObject(ref)) : null; }
function run(args) {
    var action = args[0], port = Number(args[1]), file = args[2];
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('Invalid proxy port');
    var preferencesID = $.nil;
    var prefs = $.SCPreferencesCreate($.kCFAllocatorDefault, $('enana proxy receipt'), preferencesID);
    if (!prefs) throw Error('Cannot open network preferences');
    if (action === 'snapshot') {
        var services = unwrap($.SCPreferencesGetValue(prefs, $('NetworkServices'))) || {};
        var saved = {};
        Object.keys(services).forEach(function(id) { saved[id] = services[id].Proxies || {}; });
        return JSON.stringify({schema:1, services:saved});
    }
    if (action !== 'restore' && action !== 'check') throw Error('Invalid proxy receipt operation');
    var saved = {services:{}};
    if (file && $.NSFileManager.defaultManager.fileExistsAtPath($(file))) {
        saved = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(file), $.NSUTF8StringEncoding, null)));
        if (saved.schema !== 1 || !saved.services || Array.isArray(saved.services)) throw Error('Invalid proxy receipt');
    }
    var locked = action === 'restore';
    if (locked && !$.SCPreferencesLock(prefs, true)) throw Error('Cannot lock network preferences');
    try {
        var services = unwrap($.SCPreferencesGetValue(prefs, $('NetworkServices'))) || {}, changed = false;
        var bypass = ['localhost','127.0.0.1','*.local','169.254/16','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16'];
        Object.keys(services).forEach(function(id) {
            var current = services[id].Proxies || {}, original = saved.services[id] || {};
            var next = JSON.parse(JSON.stringify(current)), owns = false;
            ['HTTP','HTTPS','SOCKS'].forEach(function(kind) {
                if (current[kind+'Proxy'] !== '127.0.0.1' || Number(current[kind+'Port']) !== port) return;
                owns = true;
                function group(key) { return kind === 'HTTP' ? /^HTTP(?!S)/.test(key) : key.indexOf(kind) === 0; }
                Object.keys(next).filter(group).forEach(function(key) { delete next[key]; });
                // Older installs may have captured enana itself as the backup.
                // Clear those stale local endpoints rather than restoring them.
                if (original[kind+'Proxy'] !== '127.0.0.1' || Number(original[kind+'Port']) !== port) {
                    Object.keys(original).filter(group).forEach(function(key) { next[key] = original[key]; });
                }
            });
            if (owns && JSON.stringify(current.ExceptionsList) === JSON.stringify(bypass)) {
                if (original.ExceptionsList && JSON.stringify(original.ExceptionsList) !== JSON.stringify(bypass)) next.ExceptionsList = original.ExceptionsList;
                else delete next.ExceptionsList;
            }
            // Preserve foreign endpoints and every key enana did not change,
            // including PAC, auto discovery and edits made after installation.
            if (JSON.stringify(next) !== JSON.stringify(current)) {
                if (action === 'restore' && !$.SCPreferencesPathSetValue(prefs, $('/NetworkServices/'+id+'/Proxies'), $(next))) throw Error('Cannot restore proxy preferences');
                changed = true;
            }
        });
        if (action === 'check') return changed ? 'changed' : 'clean';
        if (changed && (!$.SCPreferencesCommitChanges(prefs) || !$.SCPreferencesApplyChanges(prefs))) throw Error('Cannot apply restored proxy preferences');
        return 'Proxy preferences restored';
    } finally { if (locked) $.SCPreferencesUnlock(prefs); }
}
