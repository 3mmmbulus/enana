// 提取应用图标 (macOS): osascript -l JavaScript appicon.js <输出目录> <清单文件>
// 清单每行: <文件名(不含扩展名)><TAB><应用路径>。对每一行把系统给这个应用的图标 (NSWorkspace, 和 Finder 里看到的一样, 含 Assets.car 里的新式图标)
// 渲染成 96×96 的 PNG 写到 <输出目录>/<文件名>.png。只读本机应用文件, 不执行任何程序, 不联网。取不到图标的应用直接跳过 (前端用字母头像兜底)。
ObjC.import('AppKit');
ObjC.import('Foundation');
var SIZE = 96;
function render(img, outPath) {
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, SIZE, SIZE, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  if (!rep) return false;
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
  img.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, SIZE, SIZE), $.NSZeroRect, 2, 1.0);   // 2 = NSCompositingOperationSourceOver
  $.NSGraphicsContext.restoreGraphicsState;
  var png = rep.representationUsingTypeProperties(4, $.NSDictionary.dictionary);                    // 4 = NSBitmapImageFileTypePNG
  return !!(png && png.writeToFileAtomically($(outPath), true));
}
function run(argv) {
  var out = argv[0], list = $.NSString.stringWithContentsOfFileEncodingError(argv[1], $.NSUTF8StringEncoding, null);
  if (!list) return '0';
  var ws = $.NSWorkspace.sharedWorkspace, lines = ObjC.unwrap(list).split('\n'), n = 0, i, t, img;
  for (i = 0; i < lines.length; i++) {
    t = lines[i].split('\t');
    if (t.length < 2 || !t[0] || !t[1]) continue;
    try {
      img = ws.iconForFile($(t[1]).stringByResolvingSymlinksInPath);       // 先解析符号链接, 否则系统会给图标加上「替身」小箭头
      if (img && render(img, out + '/' + t[0] + '.png')) n++;
    } catch (e) { /* 这个应用取不到图标就跳过 */ }
  }
  return String(n);
}
