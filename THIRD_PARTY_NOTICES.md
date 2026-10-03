# 第三方声明 (Third-party notices)

## 运行时下载的第三方软件 (不包含在本仓库里)

- **sing-box** (<https://github.com/SagerNet/sing-box>): 代理核心。安装器在你的电脑上从它的官方发布页下载并校验 SHA-256, 作为独立进程运行; 它采用 GPL-3.0 (附加条款见其仓库的 LICENSE)。本仓库不分发它的二进制。
- **社区规则集** (如 SagerNet 的 sing-geosite / sing-geoip 等): 在安装时从各自的发布渠道 (GitHub / jsDelivr 镜像) 下载, 不属于本仓库; 请参阅各自的许可证。
- **云端下发的内容** (服务目录、规则库清单、服务器部署脚本等) 属于 enana 云端服务, 登录后下发并验签, 不属于本仓库。
- **Git for Windows PortableGit** (<https://gitforwindows.org/>): Windows 安装器从官方发布下载并校验 SHA-256, 安装在 enana 私有目录。Git、Bash、Perl、OpenSSL、OpenSSH 等组件各有自己的许可证; 保留完整上游包中的 LICENSE 与声明, 不裁剪许可证。
- **Node.js** (<https://nodejs.org/>): Windows 本机 HTTP 桥与辅助程序的私有运行时, 从官方分发下载并校验 SHA-256, 保留上游 LICENSE (Node.js MIT 及依赖声明)。
- 本机使用的系统自带工具 (`curl`、`openssl` (LibreSSL)、`ssh` / `ssh-keyscan`、`perl`、`dig` 等) 来自 macOS, 不随本仓库分发。


## 图标 — Lucide

仪表盘使用的图标来自 [Lucide](https://lucide.dev) (<https://github.com/lucide-icons/lucide>),
采用 **ISC 许可证**,允许个人与**商业**使用、复制、修改与分发,只要求在副本中保留下面的版权与许可声明。
其中部分图标源自 Feather 项目 (MIT 许可证),其声明也包含在下面。

`ui/icons.js` 只包含这些图标的形状数据 (SVG 路径),由 `tools/make-icons.py` 生成。

```
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The following Lucide icons are derived from the Feather project:

airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out

The MIT License (MIT) (for the icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
