/* 图标: Lucide (https://lucide.dev), ISC 许可证, 允许商用; 部分图标源自 Feather (MIT)。
 * 版权与许可声明见仓库根目录 THIRD_PARTY_NOTICES.md (分发时需保留)。
 * 本文件由 tools/make-icons.py 生成 (只含形状数据, 不含脚本); 想换图标: 改 ALIAS 后重新生成。
 *
 *   Icons.el('nav-servers', {size: 18, cls: 'icon'})  -> <svg> 元素 (stroke=currentColor, 跟随文字颜色, aria-hidden)
 *   Icons.has(name) / Icons.names()
 */
(function (root) {
  'use strict';
  var NS = 'http://www.w3.org/2000/svg';
  var SHAPES = __SHAPES__;
  var ALIAS = __ALIAS__;
  function resolve(n) { return SHAPES[n] ? n : (ALIAS[n] && SHAPES[ALIAS[n]] ? ALIAS[n] : null); }
  function el(name, o) {
    o = o || {};
    var key = resolve(name) || resolve('help'), svg = document.createElementNS(NS, 'svg'), size = o.size || 18;
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('width', size); svg.setAttribute('height', size);
    svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', o.stroke || 2);
    svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round'); svg.setAttribute('aria-hidden', 'true'); svg.setAttribute('focusable', 'false');
    if (o.cls) svg.setAttribute('class', o.cls);
    SHAPES[key].forEach(function (s) { var e = document.createElementNS(NS, s[0]); for (var k in s[1]) e.setAttribute(k, s[1][k]); svg.appendChild(e); });
    return svg;
  }
  root.Icons = { el: el, has: function (n) { return !!resolve(n); }, names: function () { return Object.keys(SHAPES).concat(Object.keys(ALIAS)); } };
})(typeof window !== 'undefined' ? window : this);
