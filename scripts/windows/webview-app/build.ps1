# 构建 iGemini.exe —— 原生 WebView2 专用壳（Windows）。
# 在 Windows 上跑：powershell -ExecutionPolicy Bypass -File build.ps1
# 依赖：.NET Framework(自带 csc) + WebView2 Runtime(Win11 自带；缺则 winget install Microsoft.EdgeWebView2Runtime)。
# 产物：本目录下 iGemini.exe + 3 个 WebView2 DLL + igemini.ico（一起拷到目标机即可运行）。
# 国内下 nupkg 慢时，先设代理：$env:HTTPS_PROXY='http://127.0.0.1:7897'；并把 DefaultWebProxy 指过去。
param(
  [string]$IconPng = (Join-Path $PSScriptRoot '..\..\..\assets\igemini-icon.png'),
  [string]$Version = ''   # 用户可见版本；空则读 ..\installer\VERSION（build-installer.ps1 会显式传进来）
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Version) {
  $vf = Join-Path $here '..\installer\VERSION'
  $Version = if (Test-Path $vf) { (Get-Content $vf -Raw).Trim() } else { '1.1.0' }
}
if ($env:HTTPS_PROXY) { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($env:HTTPS_PROXY) }

# 1) 取 WebView2 SDK（nupkg=zip），抽出 Core/WinForms(net4*) + 原生 Loader(x64)
if (-not (Test-Path (Join-Path $here 'WebView2Loader.dll'))) {
  $nupkg = Join-Path $env:TEMP 'wv2.zip'
  Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile $nupkg -TimeoutSec 180
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
  $map = @(
    @('lib/net4.*/Microsoft\.Web\.WebView2\.Core\.dll$',     'Microsoft.Web.WebView2.Core.dll'),
    @('lib/net4.*/Microsoft\.Web\.WebView2\.WinForms\.dll$', 'Microsoft.Web.WebView2.WinForms.dll'),
    @('runtimes/win-x64/native/WebView2Loader\.dll$',        'WebView2Loader.dll'))
  foreach ($m in $map) {
    $e = $zip.Entries | Where-Object { $_.FullName -match $m[0] } | Select-Object -First 1
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $here $m[1]), $true)
  }
  $zip.Dispose()
}

# 2) 生成多尺寸 32bpp PNG-in-ICO（手工拼，绕开 .NET Icon.Save 会降成 16 色的坑）
Add-Type -AssemblyName System.Drawing
$srcBmp = New-Object System.Drawing.Bitmap($IconPng)
function ResizePng([int]$s) {
  $b = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($srcBmp, (New-Object System.Drawing.Rectangle(0, 0, $s, $s))); $g.Dispose()
  $ms = New-Object System.IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); return $ms.ToArray()
}
$sizes = 16, 24, 32, 48, 64, 128, 256
# ⚠️ 必须用 List[byte[]]，不能 $sizes | ForEach-Object { ResizePng $_ } —— 管道会把每个 byte[] 摊平成单字节流，
# 于是 $frames[$i] 变成单个字节、.Length=1，ICONDIR 目录写成 size=1/偏移逐字节 → .ico 损坏（只 16x16 凑巧能渲染）。
$frames = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($s in $sizes) { $frames.Add((ResizePng $s)) }
$out = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$off = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $d = $frames[$i]
  $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s })); $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
  $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$d.Length); $bw.Write([UInt32]$off); $off += $d.Length
}
foreach ($f in $frames) { $bw.Write($f) }; $bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $here 'igemini.ico'), $out.ToArray())

# 3) 编译（csc 自带于 .NET Framework；/codepage:65001 让源码里的中文正确）
# 必须预拼成【带引号的字符串】传参：/out:(Join-Path ...) 这种「裸词紧跟子表达式」
# 在某些 PS 环境会被拆成两个参数 → csc 收到空 /out: 和无源文件（CS2005/CS2008）。
$csc  = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe  = Join-Path $here 'iGemini.exe'
$ico  = Join-Path $here 'igemini.ico'
$core = Join-Path $here 'Microsoft.Web.WebView2.Core.dll'
$wf   = Join-Path $here 'Microsoft.Web.WebView2.WinForms.dll'
$prog = Join-Path $here 'Program.cs'
# 生成 Version.cs：把版本号编进壳（关于面板读 Ver.V）+ 写进 exe 文件属性（AssemblyFileVersion 需 4 段数字）
$verFull = (@($Version -split '\.') + @('0','0','0','0'))[0..3] -join '.'
$verCs = Join-Path $here 'Version.cs'
@"
using System.Reflection;
[assembly: AssemblyFileVersion("$verFull")]
[assembly: AssemblyVersion("$verFull")]
namespace iGemini { static class Ver { public const string V = "$Version"; } }
"@ | Set-Content $verCs -Encoding UTF8
& $csc /nologo /target:winexe /codepage:65001 "/out:$exe" "/win32icon:$ico" `
  "/reference:$core" "/reference:$wf" `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "$prog" "$verCs"
if ($LASTEXITCODE -eq 0) { Write-Host ('OK -> ' + $exe) } else { throw 'csc failed' }
