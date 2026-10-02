# enana 一键安装 (Windows PowerShell)  ·  One-line installer for Windows
#   在 PowerShell 里执行:  irm https://install.enana.cc | iex
#
# Windows 版正在适配中 (安装器、系统代理、开机自启、仪表盘都要按 Windows 重做并在真机上测试), 还没有发布。
# 现在这个脚本只做环境检查并告诉你状态, 不会改动你的系统。macOS 已经可用: curl -fsSL https://install.enana.cc | bash
# The Windows edition is still being adapted and tested on real machines; this script only checks the environment and does not change your system.
$ErrorActionPreference = 'Stop'
$zh = (Get-Culture).Name -like 'zh*'
function T($zhText, $enText) { if ($zh) { $zhText } else { $enText } }
Write-Host ''
Write-Host (T 'enana · Windows 版即将推出' 'enana · the Windows edition is coming soon') -ForegroundColor Cyan
Write-Host (T '这台电脑暂时还不能安装 enana。我们会在 Windows 版经过真机测试后发布, 到时同一条命令就能安装。' 'enana cannot be installed on this PC yet. The same command will install it once the Windows edition has been tested on real machines.')
Write-Host (T 'macOS 用户现在就可以用:  curl -fsSL https://install.enana.cc | bash' 'On macOS you can already use:  curl -fsSL https://install.enana.cc | bash')
Write-Host ''
