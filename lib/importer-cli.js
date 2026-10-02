// 用 macOS 自带的 JavaScript (JXA) 运行与仪表盘相同的 ui/importer.js, 在后台刷新订阅时使用 (无需安装 node)。
// 用法: osascript -l JavaScript importer-cli.js <importer.js 路径> <订阅内容文件> <role> <订阅名>
// 输出: JSONL (每行一个服务器); 若一个都没识别出来则输出空。
ObjC.import('Foundation');
function readFile(p) {
  var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null);
  return s.isNil() ? '' : s.js;
}
function run(argv) {
  var src = readFile(argv[0]), text = readFile(argv[1]), role = argv[2] || 'auto', sub = argv[3] || '';
  eval(src); // 定义全局 TPImporter
  var r = TPImporter.parse(text, { role: role });
  return r.servers.length ? TPImporter.toJSONL(r.servers, sub).replace(/\n$/, '') : '';
}
