# ============================================================================
# build-installer.ps1 —— iGemini Windows 安装包「出厂打包」脚本
# ----------------------------------------------------------------------------
# 在一台【Windows x64 构建机】上跑一次。把整套栈的
# 所有零件【预先备齐、摆成 staging\ 目录树】，目标机安装时纯解压、零网络、零编译。
#
#   powershell -ExecutionPolicy Bypass -File build-installer.ps1
#   # 国内走代理： -Proxy http://127.0.0.1:7897   （node/python/pandoc 从官方源下，慢则用代理）
#
# 产物： scripts\windows\installer\staging\   （喂给 iGemini.iss 打成 setup.exe）
# 之后： iscc iGemini.iss      （装了 Inno Setup 6 才有 iscc；本脚本末尾会自动尝试）
#
# 前置：构建机已装 git（winget Git.Git）。其余 node/python/pandoc 本脚本自带下载。
# ⚠️ 本脚本为【已撰写、尚未在构建机实跑】；带 VERIFY 标记处需首次构建时确认。
# ============================================================================
param(
  [string]$Proxy        = $env:HTTPS_PROXY,
  [string]$NodeVersion  = 'v24.17.0',     # 便携 node；构建用同一个 node 做 npm ci/build → 原生模块 ABI 自洽（与 实测可用版本一致）
  [string]$PyVersion    = '3.12.7',       # 嵌入式 Python
  [string]$PandocVersion= '3.10',         # 与 实测一致
  [string]$Commit       = '4712431be81718dfb559ef43d7d7d5315bf4e01a',  # claudecodeui 上游基线（勿改，patch 基于它）
  [string]$UpstreamUrl  = 'https://github.com/siteboon/claudecodeui',
  [string]$PyIndex      = 'https://pypi.tuna.tsinghua.edu.cn/simple',   # pip 主索引；CI/海外传 https://pypi.org/simple
  [switch]$SkipDownloads                  # 调试：复用已下好的零件
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # 关掉 Invoke-WebRequest 的进度条（在 CI/SSH 里拖慢）
if ($Proxy) {
  [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($Proxy)
  $env:HTTPS_PROXY = $Proxy; $env:HTTP_PROXY = $Proxy
}

$Installer = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Version   = (Get-Content (Join-Path $Installer 'VERSION') -Raw).Trim()   # 用户可见版本单一真源 → 进包名 / AppVersion / exe 文件属性 / 壳关于
$Patch     = Join-Path $RepoRoot 'vendor\igemini-claudecodeui.patch'
$IconPng   = Join-Path $RepoRoot 'assets\igemini-icon.png'
$ToolsSrc  = Join-Path $RepoRoot 'scripts\windows\tools'
$ClaudeMd  = Join-Path $RepoRoot 'scripts\windows\deployed-claude-md.md'   # Windows 专属，不用 mac/共享的 config\ 那份（OS 隔离）
$Cache     = Join-Path $Installer 'cache'      # 下载缓存（可复用，已 gitignore）
$Stage     = Join-Path $Installer 'staging'    # 产物（每次重建，已 gitignore）

function Say($m){ Write-Host "==> $m" -ForegroundColor Cyan }
# 下到 .part 再 rename：断网留下的半截文件不会被下次误当成「已下好」；-UseBasicParsing 免 PS5.1 加载 IE DOM
function Get-File($url,$out){
  if((Test-Path $out) -and (Get-Item $out).Length -gt 0){ return }
  Say "下载 $url"; $tmp = "$out.part"
  Invoke-WebRequest $url -OutFile $tmp -TimeoutSec 600 -UseBasicParsing
  if((Get-Item $tmp).Length -le 0){ throw "下载为空: $url" }
  Move-Item $tmp $out -Force }
function Unzip($zip,$dest){ Add-Type -AssemblyName System.IO.Compression.FileSystem -EA SilentlyContinue
  if(Test-Path $dest){ Remove-Item $dest -Recurse -Force }; [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,$dest) }
# robocopy 比 Copy-Item 快很多（node_modules 十万小文件）；/NFL /NDL /NJH /NJS 静音，/E 含空目录
# 注意：变量名别用 $args（PowerShell 函数自动变量）。robocopy 返回码 <8 都算成功
function Mirror($src,$dst,[string[]]$xd=@(),[string[]]$xf=@()){
  $rc=@($src,$dst,'/E','/NFL','/NDL','/NJH','/NJS','/NP','/R:1','/W:1')
  if($xd){ $rc+='/XD'; $rc+=$xd }; if($xf){ $rc+='/XF'; $rc+=$xf }
  # 用重定向而非管道：管道到 Out-Null 时 $LASTEXITCODE 可能丢失 → robocopy 失败被静默吞掉
  robocopy @rc *> $null; if($LASTEXITCODE -ge 8){ throw "robocopy 失败($LASTEXITCODE): $src -> $dst" } }
# 跑原生命令(git/npm/pip/csc/iscc)：把 stderr 并进 stdout，避免 EAP=Stop 把 npm/pip 往 stderr 打的【弃用警告】误当致命错；
# 真失败靠【退出码】判定（PS5.1 下原生命令非零退出本身不会抛，必须显式查）。
function Native([scriptblock]$sb,[string]$what){
  $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try { & $sb 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference=$old }
  if($LASTEXITCODE -ne 0){ throw "$what 失败 (exit=$LASTEXITCODE)" } }

New-Item -ItemType Directory -Force -Path $Cache,$Stage | Out-Null
Get-ChildItem $Stage -Force | Remove-Item -Recurse -Force   # 清空 staging
foreach($d in 'runtime\node','runtime\python','runtime\pandoc','claudecodeui','claude\bin','tools','shell','legal'){
  New-Item -ItemType Directory -Force -Path (Join-Path $Stage $d) | Out-Null }

# ---------------------------------------------------------------------------
# 1) 便携 Node.js（x64 zip：含 node.exe + npm）
# ---------------------------------------------------------------------------
Say "[1/7] Node.js $NodeVersion"
$nodeZip = Join-Path $Cache "node-$NodeVersion-win-x64.zip"
if(-not $SkipDownloads){ Get-File "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip" $nodeZip }
Unzip $nodeZip (Join-Path $Cache 'node')
Mirror (Join-Path $Cache "node\node-$NodeVersion-win-x64") (Join-Path $Stage 'runtime\node')
$NodeExe = Join-Path $Stage 'runtime\node\node.exe'
$NpmCmd  = Join-Path $Stage 'runtime\node\npm.cmd'

# ---------------------------------------------------------------------------
# 2) 嵌入式 Python + 预装 wheels（含 pandas，与 macOS 对齐 —— 5 个固定工具不 import 它，但供 agent 临场用 python 做 CSV/XLSX 透视/合并）
# ---------------------------------------------------------------------------
Say "[2/7] Python embed $PyVersion + wheels"
$pyZip = Join-Path $Cache "python-$PyVersion-embed-amd64.zip"
if(-not $SkipDownloads){ Get-File "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip" $pyZip }
$PyDir = Join-Path $Stage 'runtime\python'
Unzip $pyZip $PyDir
# 嵌入式 python 默认 ._pth 关掉了 site → 解开，并把 Lib\site-packages 加进路径，否则 pip 装的包 import 不到
$pth = Get-ChildItem $PyDir -Filter 'python*._pth' | Select-Object -First 1
$lines = (Get-Content $pth.FullName) -replace '^#\s*import site','import site'
if((($lines) -join "`n") -notmatch 'Lib\\site-packages'){ $lines += 'Lib\site-packages' }
Set-Content $pth.FullName $lines -Encoding ascii
$PyExe = Join-Path $PyDir 'python.exe'
$getpip = Join-Path $Cache 'get-pip.py'
if(-not $SkipDownloads){ Get-File 'https://bootstrap.pypa.io/get-pip.py' $getpip }
Native { & $PyExe $getpip --no-warn-script-location } 'get-pip'
$pipArgs = @('-m','pip','install','--no-warn-script-location','--no-compile','--retries','5','--timeout','60')
if($Proxy){ $pipArgs += @('--proxy',$Proxy) }
# -i 主索引（默认清华更快；CI/海外用 -PyIndex https://pypi.org/simple）；pymupdf 带自己的 mupdf dll 在 wheel 里
$pipArgs += @('-i',$PyIndex,'--extra-index-url','https://pypi.org/simple','pymupdf','pdfplumber','python-docx','openpyxl','markdown','pandas')
Native { & $PyExe @pipArgs } 'pip install wheels'
# 干净机确认 import 全过（fitz 原生 dll、pdfplumber 依赖的 Pillow/cffi、pandas/numpy）。
# 【不用 Native】——它合并 stderr 不按退出码中止；这里要【硬中止】，否则 pandas 等 pip 网络失败会静默产出残缺包。
& $PyExe -c "import fitz, pdfplumber, docx, openpyxl, markdown, pandas; print('py-deps OK')"
if($LASTEXITCODE -ne 0){ throw 'python 依赖 import 失败（pandas/numpy 等可能因 pip 网络失败未装上）—— 终止构建，避免产出不含 pandas 的残缺安装包' }

# ---------------------------------------------------------------------------
# 3) pandoc.exe（md2docx 核心依赖 + parsedoc 的 rtf/odt）
# ---------------------------------------------------------------------------
Say "[3/7] pandoc $PandocVersion"
$pdZip = Join-Path $Cache "pandoc-$PandocVersion-windows-x86_64.zip"
if(-not $SkipDownloads){ Get-File "https://github.com/jgm/pandoc/releases/download/$PandocVersion/pandoc-$PandocVersion-windows-x86_64.zip" $pdZip }
Unzip $pdZip (Join-Path $Cache 'pandoc')
Copy-Item (Join-Path $Cache "pandoc\pandoc-$PandocVersion\pandoc.exe") (Join-Path $Stage 'runtime\pandoc\pandoc.exe') -Force

# ---------------------------------------------------------------------------
# 4) claudecodeui：clone@commit → 打白标 patch → 用便携 node 的 npm ci+build → prod 裁剪
# ---------------------------------------------------------------------------
Say "[4/7] claudecodeui (build@$($Commit.Substring(0,7)))"
$ccBuild = Join-Path $Cache 'claudecodeui'
if(Test-Path $ccBuild){ Remove-Item $ccBuild -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ccBuild | Out-Null
$env:Path = "$(Split-Path $NodeExe);$env:Path"   # 让 npm/git 调到便携 node
Push-Location $ccBuild
try {
  Native { git init -q } 'git init'
  git remote add origin $UpstreamUrl
  Native { git fetch --depth 1 origin $Commit -q } 'git fetch'
  Native { git checkout -q FETCH_HEAD } 'git checkout'
  Native { git apply --binary --check $Patch } 'git apply --check'   # dry-run：patch 冲突/空/格式错立刻暴露
  Native { git apply --binary $Patch } 'git apply'                   # 81 文件白标；冲突即上游漂移 → 见 vendor/README.md
  Native { & $NpmCmd ci } 'npm ci'                                   # 严格按 lockfile，比 npm install 可靠
  Native { & $NpmCmd run build } 'npm run build'                    # 出 dist\ + dist-server\
  Native { & $NpmCmd prune --production } 'npm prune'               # 砍掉 devDependencies（646MB→~200MB）
} finally { Pop-Location }                # 任一步挂掉也把工作目录弹回来，别污染交互 shell
# [iGemini · Windows 专属] 强制 bypassPermissions：CC 在网页里要跑 bash 命令时不再被权限拦（= --dangerously-skip-permissions）。
# ⚠️ 只在 Windows 出厂构建里改【编译产物 dist-server】，绝不进共享白标 patch、不碰 mac —— OS 隔离。
$sdk = Join-Path $ccBuild 'dist-server\server\claude-sdk.js'
if(Test-Path $sdk){
  $sdkTxt = [IO.File]::ReadAllText($sdk)
  $sdkOld = "if (settings.skipPermissions && permissionMode !== 'plan') {"
  $sdkNew = "if (permissionMode !== 'plan') { // [iGemini] always bypass permissions (Windows build only)"
  if($sdkTxt.Contains($sdkOld)){ [IO.File]::WriteAllText($sdk, $sdkTxt.Replace($sdkOld,$sdkNew)); Say 'claude-sdk.js → 强制 bypass(仅Win)' }
  else { Write-Host 'WARN: claude-sdk.js 的 skipPermissions 模式没找到（上游可能变了），跳过 patch' -ForegroundColor Yellow }
}
# [iGemini · Windows 专属] Shell 终端也免权限：Chat(claude-sdk)已 bypass，但 claudecodeui 的 Shell 集成
# 终端走 buildShellCommand 直接拼 `claude --resume`、没带 --dangerously-skip-permissions → Shell 里 claude
# 不停问权限（与 mac 同一漏网，全库审计确认 claude 仅经 SDK 与此 pty-shell 两路，故只需改这 3 条命令）。
$shellsvc = Join-Path $ccBuild 'dist-server\server\modules\websocket\services\shell-websocket.service.js'
if(Test-Path $shellsvc){
  $svc = [IO.File]::ReadAllText($shellsvc)
  if(-not $svc.Contains('[iGemini] shell bypass')){
    $svc = $svc.Replace('const command = initialCommand || ''claude'';', 'const command = initialCommand || ''claude --dangerously-skip-permissions'';')
    $svc = $svc.Replace('claude --resume "${resumeSessionId}"; if ($LASTEXITCODE -ne 0) { claude }', 'claude --dangerously-skip-permissions --resume "${resumeSessionId}"; if ($LASTEXITCODE -ne 0) { claude --dangerously-skip-permissions }')
    $svc = $svc.Replace('claude --resume "${resumeSessionId}" || claude', 'claude --dangerously-skip-permissions --resume "${resumeSessionId}" || claude --dangerously-skip-permissions')
    $svc = $svc.Replace('function buildShellCommand', "// [iGemini] shell bypass`r`nfunction buildShellCommand")
    [IO.File]::WriteAllText($shellsvc, $svc); Say 'shell-websocket.service.js → Shell 终端也免权限(仅Win)'
  } else { Write-Host 'shell-websocket 已含 shell bypass，跳过' -ForegroundColor DarkGray }
} else { Write-Host 'WARN: shell-websocket.service.js 没找到，跳过 Shell bypass patch' -ForegroundColor Yellow }
# 搬到 staging。⚠️ 只用【绝对路径】剔顶层 .git —— 绝不能按名字 /XD src，那会把 node_modules 里
# 各个包自己的 src\ 也一并删掉（web-push 等的入口就在 src\index.js），弄坏运行期依赖 → 服务起不来。
Mirror $ccBuild (Join-Path $Stage 'claudecodeui') -xd @((Join-Path $ccBuild '.git')) -xf @('*.map')
# VERIFY: 用便携 node 起服务能 200： node runtime\node\node.exe + `npm run server`（见 run-server.ps1）

# ---------------------------------------------------------------------------
# 5) claude CLI：装到临时 prefix → 只取单份 claude.exe（去掉 node_modules 里那份重复，省 215MB）
# ---------------------------------------------------------------------------
Say "[5/7] claude CLI (dedup → single claude.exe)"
$claudePrefix = Join-Path $Cache 'claude-npm'
if(Test-Path $claudePrefix){ Remove-Item $claudePrefix -Recurse -Force }
New-Item -ItemType Directory -Force -Path $claudePrefix | Out-Null
Native { & $NpmCmd install '@anthropic-ai/claude-code' --prefix $claudePrefix --no-fund --no-audit } 'npm install claude'
$pkg = Join-Path $claudePrefix 'node_modules\@anthropic-ai\claude-code'
Copy-Item (Join-Path $pkg 'bin\claude.exe') (Join-Path $Stage 'claude\bin\claude.exe') -Force
# 随手把包根的小支撑文件也带上（*.cjs/*.d.ts/package.json/LICENSE，几百 KB），不带那份 214MB 重复二进制
Get-ChildItem $pkg -File | Where-Object { $_.Name -match '\.(cjs|d\.ts|json|md)$' } |
  ForEach-Object { Copy-Item $_.FullName (Join-Path $Stage 'claude') -Force }
# 冒烟测试：去重后的单份 claude.exe 必须能独立跑（自带 node 的 SEA，理应不依赖被删的那份）。挂了立刻 throw，别等装到目标机才发现
Native { & (Join-Path $Stage 'claude\bin\claude.exe') --version } '去重后 claude.exe 冒烟测试'

# ---------------------------------------------------------------------------
# 6) 能力工具：5 个 .py + 生成调用包装 .cmd（指向【自带】python，放 PATH 即可 `parsedoc x.pdf`）
# ---------------------------------------------------------------------------
Say "[6/7] capability tools + .cmd wrappers"
Copy-Item (Join-Path $ToolsSrc '*.py') (Join-Path $Stage 'tools') -Force
$shEnc = New-Object System.Text.UTF8Encoding($false)   # 无 BOM
foreach($py in Get-ChildItem (Join-Path $Stage 'tools') -Filter *.py){
  $name = $py.BaseName
  # ① .cmd 包装：给 cmd.exe / powershell 用；%~dp0 末尾自带反斜杠
  $cmd  = "@echo off`r`n`"%~dp0..\runtime\python\python.exe`" `"%~dp0$($py.Name)`" %*`r`n"
  Set-Content (Join-Path $Stage "tools\$name.cmd") $cmd -Encoding ascii -NoNewline
  # ② 无扩展名 bash 包装：CC 在 Windows 经 git-bash 跑命令，bash 不认 .cmd 规则、裸名解析不到 → 必须有这个。
  #    LF 换行 + 无 BOM（否则 git-bash 不认 shebang）。运行期 run-server.ps1 会 chmod +x。
  $sh = @('#!/bin/sh','here="$(dirname "$0")"',('exec "$here/../runtime/python/python.exe" "$here/'+$py.Name+'" "$@"'))
  [IO.File]::WriteAllText((Join-Path $Stage "tools\$name"), (($sh -join "`n")+"`n"), $shEnc)
}

# ---------------------------------------------------------------------------
# 7) 原生壳 iGemini.exe（调现成 build.ps1）+ 启动器 + 法务（AGPL）+ 部署版 CLAUDE.md
# ---------------------------------------------------------------------------
Say "[7/7] iGemini.exe shell + launcher + legal"
& (Join-Path $RepoRoot 'scripts\windows\webview-app\build.ps1') -Version $Version   # 产出 iGemini.exe + 3 个 DLL + igemini.ico（版本编进壳）
$wv = Join-Path $RepoRoot 'scripts\windows\webview-app'
foreach($f in 'iGemini.exe','igemini.ico','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll','WebView2Loader.dll'){
  Copy-Item (Join-Path $wv $f) (Join-Path $Stage 'shell') -Force }
# 安装界面品牌图。large.bmp = 欢迎/完成页左侧【全幅渐变侧栏】(WizardImageFile)：紫→青渐变铺满 +
# orb 居上 + off-white "iGemini" 字样(按 Wizard97/Inno 规范，watermark 应铺满整栏、避免白底飘球)。
# 出 492×941(3x 于 164:314，HiDPI 缩放仍清晰)。small/orb.bmp 现已不被 iss 引用，留作备用。
Say "  branding BMP (gradient sidebar large.bmp + small/orb)"
Add-Type -AssemblyName System.Drawing
$brand = Join-Path $Stage 'branding'; New-Item -ItemType Directory -Force -Path $brand | Out-Null
function MakeBmp($outBmp,$w,$h){
  $b=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g=[System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::White)
  $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $s=New-Object System.Drawing.Bitmap($IconPng)
  $k=[Math]::Min($w/$s.Width,$h/$s.Height); $dw=[int]($s.Width*$k); $dh=[int]($s.Height*$k)
  $g.DrawImage($s,[int](($w-$dw)/2),[int](($h-$dh)/2),$dw,$dh)
  $g.Dispose(); $s.Dispose(); $b.Save($outBmp,[System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
}
# 全幅渐变侧栏(欢迎/完成页 WizardImageFile)：紫→青竖向渐变铺满 + orb 居上 + off-white 字样
function MakeSidebar($outBmp,$w,$h){
  $b=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g=[System.Drawing.Graphics]::FromImage($b)
  $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.TextRenderingHint=[System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $rect=New-Object System.Drawing.Rectangle(0,0,$w,$h)
  $c1=[System.Drawing.Color]::FromArgb(0x53,0x26,0xA8)   # 紫(顶)
  $c2=[System.Drawing.Color]::FromArgb(0x14,0xA6,0xB0)   # 青(底)
  $grad=New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,$c1,$c2,90)
  $g.FillRectangle($grad,$rect)
  $s=New-Object System.Drawing.Bitmap($IconPng)
  $ow=[int]($w*0.60); $oh=$ow; $ox=[int](($w-$ow)/2); $oy=[int]($h*0.16)
  $g.DrawImage($s,$ox,$oy,$ow,$oh)
  $font=New-Object System.Drawing.Font('Segoe UI',[float]($w*0.115),[System.Drawing.FontStyle]::Bold,[System.Drawing.GraphicsUnit]::Pixel)
  $sf=New-Object System.Drawing.StringFormat; $sf.Alignment=[System.Drawing.StringAlignment]::Center
  $offwhite=New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xF0,0xF0,0xF0))   # off-white 防高分屏眩光
  $ty=$oy+$oh+[int]($h*0.025)
  $g.DrawString('iGemini',$font,$offwhite,(New-Object System.Drawing.RectangleF(0,$ty,$w,60)),$sf)
  $g.Dispose(); $s.Dispose(); $b.Save($outBmp,[System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
}
MakeBmp     (Join-Path $brand 'small.bmp') 138 140
MakeSidebar (Join-Path $brand 'large.bmp') 492 941
MakeBmp     (Join-Path $brand 'orb.bmp')   220 220
Copy-Item (Join-Path $Installer 'run-server.ps1') (Join-Path $Stage 'run-server.ps1') -Force
# launcher.vbs：登录启动项用 wscript 跑它 → 以隐藏窗口起 run-server.ps1，根治 powershell -WindowStyle Hidden
# 藏不住主控制台窗的问题（iGemini.iss 的 [Icons]/[Run] 都指向它）。纯 ASCII，wscript 直接读。
Copy-Item (Join-Path $Installer 'launcher.vbs') (Join-Path $Stage 'launcher.vbs') -Force
Copy-Item $ClaudeMd (Join-Path $Stage 'deployed-claude-md.md') -Force
# 法务：AGPL 要求随二进制提供对应源码 → 带上 patch + 来源说明（大陆访问不了 GitHub，patch 必须随包）
Copy-Item $Patch (Join-Path $Stage 'legal\igemini-claudecodeui.patch') -Force
# AGPL 全文：用【仓库内置】的（gnu.org 大陆不可达；URL 占位不满足 AGPL「随附完整许可证正文」要求）
Copy-Item (Join-Path $Installer 'LICENSE-AGPL-3.0.txt') (Join-Path $Stage 'legal\LICENSE-AGPL-3.0.txt') -Force
@"
iGemini 内含第三方开源组件 claudecodeui（作者 siteboon），许可证 AGPL-3.0。
按 AGPL 要求，随二进制提供对应完整源码的获取方式：

  上游仓库    : $UpstreamUrl
  基线 commit : $Commit
  白标改动    : 见同目录 igemini-claudecodeui.patch
                （克隆上游后 git checkout $Commit，再 git apply --binary <该 patch>，
                  即可逐字节重建本包内的 claudecodeui）

注：本 Windows 版在出厂构建时另有两处平台特有改动（作用于编译产物 dist-server）：
    claude-sdk.js 强制 bypass 权限确认；shell-websocket.service.js 让集成终端里的 claude 也免权限。
    这两处不在上面的共享 patch 内。索取完整对应源码请访问项目主页：
      https://github.com/DexterSLamb/iGemini

本目录另含 LICENSE-AGPL-3.0.txt（AGPL-3.0 许可证全文）。
"@ | Set-Content (Join-Path $Stage 'legal\SOURCE.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# 汇总 + 可选直接打 setup.exe
# ---------------------------------------------------------------------------
$mb = [math]::Round(((Get-ChildItem $Stage -Recurse -Force | Measure-Object Length -Sum).Sum/1MB),0)
Say "staging 就绪：$Stage  (落盘 ${mb} MB)"
$iscc = @((Get-Command iscc -EA SilentlyContinue).Source,
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",          # winget 常装到这里
          "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe","$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if($iscc){ Say "Inno Setup → setup.exe (v$Version)"; Native { & $iscc "/DAppVersion=$Version" (Join-Path $Installer 'iGemini.iss') } 'iscc' }
else { Write-Host "未找到 ISCC.exe（装 Inno Setup 6 后跑： iscc iGemini.iss）。" -ForegroundColor Yellow }
