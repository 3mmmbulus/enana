// SystemConfiguration preferences, not UI automation. Only proxy dictionaries
// are read/changed; DNS, interfaces, Keychain credentials and other apps remain
// outside this receipt. Invoked with administrator authorization for restore.
ObjC.import('SystemConfiguration');
ObjC.import('Foundation');
function unwrap(ref) { return ref ? ObjC.deepUnwrap(ObjC.castRefToObject(ref)) : null; }
// The receipt is data written by an unprivileged process, and restore runs as
// root. Accept the shape `snapshot` writes ({schema:1, services:{id: Proxies}})
// and check, before any change, every value restore can copy back: the
// HTTP/HTTPS/SOCKS fields and ExceptionsList. Other keys are never restored.
function plain(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { // at most 255 UTF-16 units, no control characters, no unpaired surrogates
    return typeof value === 'string' && value.length <= 255 && !/[\u0000-\u001f\u007f-\u009f]/.test(value)
        && !/[\ud800-\udbff](?![\udc00-\udfff])|(?:^|[^\ud800-\udbff])[\udc00-\udfff]/.test(value);
}
function field(key, value) {
    if (key === 'ExceptionsList') return Array.isArray(value) && value.length <= 1024 && value.every(text);
    if (!/^(HTTP|SOCKS)/.test(key)) return true;
    // Other tools sometimes store ports and flags as digit strings: those are restored as they were. A refusal here
    // stops uninstall, so only shapes restore must not write back (objects, lists, out-of-range numbers) are refused.
    if (/(Enable|ProxyAuthenticated)$/.test(key)) return value === 0 || value === 1 || value === true || value === false || value === '0' || value === '1';
    if (/Port$/.test(key)) return (Number.isInteger(value) || (typeof value === 'string' && /^[0-9]{1,5}$/.test(value))) && Number(value) >= 0 && Number(value) <= 65535;
    return text(value) || typeof value === 'boolean' || (typeof value === 'number' && isFinite(value));
}
function receipt(file) {
    var saved = null;
    try { saved = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(file), $.NSUTF8StringEncoding, null))); } catch (e) { saved = null; }
    if (!plain(saved) || saved.schema !== 1 || !plain(saved.services)) throw Error('Invalid proxy receipt');
    Object.keys(saved.services).forEach(function(id) {
        var proxies = saved.services[id];
        if (!plain(proxies) || !Object.keys(proxies).every(function(key) { return field(key, proxies[key]); })) throw Error('Invalid proxy receipt');
    });
    return saved;
}
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
    // No receipt argument (or no such file): restore only clears enana's own fields.
    var saved = {services:{}};
    if (file && $.NSFileManager.defaultManager.fileExistsAtPath($(file))) saved = receipt(file);
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
