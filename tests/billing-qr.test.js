// 收款地址二维码 (ui/billing.js 的 qrBlock 用的 vendor/qrcode.js): 库能在页面里加载, 并对 TRON 地址生成正确的 SVG.
// 只检查版本和模块数 (不解码; 解码要用真机扫码). 34 位 TRON 地址按字节模式、纠错等级 M 需要 3 号版本 = 29×29 模块.
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
const src = fs.readFileSync(path.join(__dirname, '..', 'ui', 'vendor', 'qrcode.js'), 'utf8');
const ctx = {}; ctx.window = ctx; vm.createContext(ctx); vm.runInContext(src, ctx);
assert.strictEqual(typeof ctx.qrcode, 'function', 'qrcode 应该是全局函数');
const addr = 'TRXk1Lx9m3H8dA1P7LXGQ6EjVDSvNSJZkp';
assert.ok(/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(addr), '测试地址格式应与 billing.js 的校验一致');
const q = ctx.qrcode(0, 'M'); q.addData(addr); q.make();
assert.strictEqual(q.getModuleCount(), 29, '34 位地址应使用 3 号版本 (29 模块)');
const svg = q.createSvgTag(4, 4, 'label', '');
assert.ok(svg.startsWith('<svg'), 'createSvgTag 应返回 SVG 标记');
assert.ok(svg.includes('viewBox'), 'SVG 应带 viewBox');
const other = ctx.qrcode(0, 'M'); other.addData('T' + '1'.repeat(33)); other.make();
assert.notStrictEqual(other.createSvgTag(4, 4, 'label', ''), svg, '不同地址应生成不同的二维码');
console.log('ok billing-qr: 3号版本 29 模块, SVG 正常');
