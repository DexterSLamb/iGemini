# ============================================================================
# run-server.ps1 —— 安装后【目标机】上的网页服务启动器（自包含版 start-web.ps1）
# 与仓库根 scripts\windows\start-web.ps1 的区别：运行时全部指向【安装目录内自带】的
# node/python/pandoc/claude，不依赖系统级安装。由 build-installer.ps1 拷进 staging 根，
# 安装后位于 {app}\run-server.ps1，被任务计划「iGemini-Web」登录时隐藏窗口调用。
# ============================================================================
$ErrorActionPreference = 'Continue'
# 任务计划用 -WindowStyle Hidden 调用 → Write-Host 看不见。把诊断落到日志，出问题能查。
$Log = Join-Path $env:TEMP 'iGemini-web.log'
function Note($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Tee-Object -FilePath $Log -Append | Out-Null }
Note "[计时] ===== run-server 启动 ====="   # 诊断启动耗时：本行→[计时]环境就绪=env+chmod；→backend=其余；backend→CloudCLI Ready=node 服务本体
$App     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Node    = Join-Path $App 'runtime\node'
$Python  = Join-Path $App 'runtime\python'
$Pandoc  = Join-Path $App 'runtime\pandoc'
$Tools   = Join-Path $App 'tools'
$ClaudeBin = Join-Path $App 'claude\bin'
$CC      = Join-Path $App 'claudecodeui'

# 1) DeepSeek 环境（key 从 %USERPROFILE%\.config 读，绝不硬编码；与 mac ds.sh 一致）
# base 地址【可配置】：.config\deepseek\base 存在则用它，否则缺省 DeepSeek 官方。
# 为未来「切换后端」留位——届时只改这个文件（地址指向新端点），代码不动、包不重出。
# 与 macOS start-web.sh 一致。
$baseFile = Join-Path $env:USERPROFILE '.config\deepseek\base'
if (Test-Path $baseFile) {
  $env:ANTHROPIC_BASE_URL = (Get-Content $baseFile -Raw).Trim().TrimStart([char]0xFEFF)
} else {
  $env:ANTHROPIC_BASE_URL = 'https://api.deepseek.com/anthropic'
}
$keyFile = Join-Path $env:USERPROFILE '.config\deepseek\key'
if (Test-Path $keyFile) {
  # .Trim() 去首尾空白/换行；再 TrimStart BOM —— UTF-8 BOM 开头的 key 会让 DeepSeek 鉴权失败
  $env:ANTHROPIC_AUTH_TOKEN = (Get-Content $keyFile -Raw).Trim().TrimStart([char]0xFEFF)
}
if (-not $env:ANTHROPIC_AUTH_TOKEN) {
  Note "警告：未找到 DeepSeek key（$keyFile 缺失或为空）。AI 功能不可用 —— 请把 key 写进该文件后重登录。"
}
Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
$env:ANTHROPIC_MODEL                = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'deepseek-v4-flash'
# [iGemini] 隔离：iGemini 的 claude 会话/配置写进独立目录，不污染用户日常 Claude Code 的 ~/.claude（与 mac/Linux 一致）。
$env:CLAUDE_CONFIG_DIR              = Join-Path $env:USERPROFILE '.claude-igemini'
$env:CLAUDE_CODE_SUBAGENT_MODEL     = 'deepseek-v4-flash'
$env:CLAUDE_CODE_EFFORT_LEVEL       = 'max'
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
# 自带 claude.exe 从 {app}\claude\bin 跑（不是 claude 原生安装位 ~\.local\bin\claude.exe）→ 关掉
# 它的「安装完整性自检」，否则终端/聊天启动时会刷红字：
#   claude command at C:\Users\<user>\.local\bin\claude.exe missing or broken · run claude install to repair
# A/B 实测确认：DISABLE_INSTALLATION_CHECKS=1 才压得住这条（DISABLE_AUTOUPDATER 不管它；
# NONESSENTIAL_TRAFFIC 只连带设了 AUTOUPDATER）。两个都设：不自检、也不后台自更新（我们用固定离线版）。
$env:DISABLE_INSTALLATION_CHECKS = '1'
$env:DISABLE_AUTOUPDATER         = '1'

# 2) PATH：自带 node、claude、能力工具(.cmd)、pandoc、python；并把 claude.exe 显式喂给 CC
$env:Path = "$Node;$ClaudeBin;$Tools;$Pandoc;$Python;" + $env:Path
$claudeExe = Join-Path $ClaudeBin 'claude.exe'
if (Test-Path $claudeExe) { $env:CLAUDE_CLI_PATH = $claudeExe }

# 2.5) 让无扩展名 bash 包装可执行：CC 在 Windows 经 git-bash 调 parsedoc 等命令需要 +x；
#      Inno 解压不保留 Unix 执行位，故每次启动自愈（git-bash 缺失则跳过，不影响服务）。
$gitBash = @("$env:ProgramFiles\Git\bin\bash.exe","${env:ProgramFiles(x86)}\Git\bin\bash.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
if ($gitBash) {
  try {
    $tb = '/' + $Tools.Substring(0,1).ToLower() + ($Tools.Substring(2) -replace '\\','/')
    & $gitBash -lc "chmod +x '$tb'/* 2>/dev/null" 2>$null
  } catch { Note "chmod 工具包装失败(忽略): $_" }
}
Note "[计时] 环境+chmod 就绪（此行与上面'启动'行的时间差≈run-server自身开销，主要看 chmod 起 git-bash 慢不慢）"

# 3) 只绑本机；端口默认 8888
$env:HOST = '127.0.0.1'
if (-not $env:SERVER_PORT) { $env:SERVER_PORT = '8888' }

if (-not (Test-Path (Join-Path $CC 'package.json'))) { Note "致命：claudecodeui 缺失（$CC）"; exit 1 }
Set-Location $CC
Note ("backend: {0} | model: {1} | listen: {2}:{3} | claude: {4}" -f `
  $env:ANTHROPIC_BASE_URL, $env:ANTHROPIC_MODEL, $env:HOST, $env:SERVER_PORT, $env:CLAUDE_CLI_PATH)
# 直接 node 起服务，不经 npm.cmd —— 省掉 cmd→node(npm)→cmd→node 一长串：启动更快、进程更少，
# 且 node 直接继承 powershell 的隐藏控制台、不再像 cmd 链那样冒出 `npm run server` 控制台窗。
# （server 脚本实测就是 `node dist-server/server/index.js`，cwd 已 Set-Location 到 $CC。）
& (Join-Path $Node 'node.exe') 'dist-server/server/index.js' *>> $Log   # 服务输出并入日志，便于排查
