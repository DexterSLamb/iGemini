# iGemini Windows 网页层启动器（PowerShell 版 start-web.sh）。
# 放在与 claudecodeui\ 同一目录（部署机即 %USERPROFILE%\Documents\iGemini）。
# 由任务计划程序在登录时调用；也可手动 powershell -NoProfile -File start-web.ps1。
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$CC   = Join-Path $Here 'claudecodeui'

# 1) DeepSeek 环境（key 从文件读，绝不硬编码；与 mac 的 ds.sh 一致）
# base 地址【可配置】：.config\deepseek\base 存在则用它，否则缺省官方（为将来切换后端留位）。
$baseFile = Join-Path $env:USERPROFILE '.config\deepseek\base'
if (Test-Path $baseFile) {
  $env:ANTHROPIC_BASE_URL = (Get-Content $baseFile -Raw).Trim().TrimStart([char]0xFEFF)
} else {
  $env:ANTHROPIC_BASE_URL = 'https://api.deepseek.com/anthropic'
}
$keyFile = Join-Path $env:USERPROFILE '.config\deepseek\key'
if (Test-Path $keyFile) { $env:ANTHROPIC_AUTH_TOKEN = (Get-Content $keyFile -Raw).Trim() }
Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
$env:ANTHROPIC_MODEL                = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-pro[1m]'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'deepseek-v4-flash'
$env:CLAUDE_CODE_SUBAGENT_MODEL     = 'deepseek-v4-flash'
$env:CLAUDE_CODE_EFFORT_LEVEL       = 'max'
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:DISABLE_GROWTHBOOK             = '1'
$env:DISABLE_TELEMETRY              = '1'
$env:DISABLE_ERROR_REPORTING        = '1'
$env:DISABLE_INSTALLATION_CHECKS    = '1'
$env:DISABLE_AUTOUPDATER            = '1'
$env:DISABLE_UPDATES                = '1'
$env:CLAUDE_CODE_ATTRIBUTION_HEADER = '0'
$env:CLAUDE_CONFIG_DIR              = Join-Path $env:USERPROFILE '.claude-igemini'
$identityPrompt = Join-Path $Here '..\common\igemini-system-prompt.md'
if (-not (Test-Path $identityPrompt)) { $identityPrompt = Join-Path $Here 'igemini-system-prompt.md' }
if (-not (Test-Path $identityPrompt) -or (Get-Item $identityPrompt).Length -le 0) {
  throw "iGemini 产品身份 prompt 缺失：$identityPrompt"
}
$env:IGEMINI_SYSTEM_PROMPT_FILE     = $identityPrompt

# 2) PATH：node、claude(npm 全局)、能力工具；并显式给 CC 指 claude 路径
$npmGlobal = Join-Path $env:APPDATA 'npm'
$tools     = Join-Path $env:USERPROFILE 'iGemini-tools'
$env:Path  = "C:\Program Files\nodejs;$npmGlobal;$tools;" + $env:Path
$claudeCmd = Join-Path $npmGlobal 'claude.cmd'
if (Test-Path $claudeCmd) { $env:CLAUDE_CLI_PATH = $claudeCmd }
$sanitizer = Join-Path $Here '..\common\sanitize-claude-state.mjs'
if (-not (Test-Path $sanitizer)) { $sanitizer = Join-Path $Here 'sanitize-claude-state.mjs' }
if (-not (Test-Path $sanitizer)) { throw "安全清理器缺失：$sanitizer" }
& 'C:\Program Files\nodejs\node.exe' $sanitizer $env:CLAUDE_CONFIG_DIR
if ($LASTEXITCODE -ne 0) { throw 'Claude 状态安全清理失败，拒绝启动' }

# 3) 网页服务：默认只绑本机；端口默认 8888
$env:HOST = '127.0.0.1'
if (-not $env:SERVER_PORT) { $env:SERVER_PORT = '8888' }

Set-Location $CC
Write-Host ("backend: {0} | model: {1} | listen: {2}:{3} | claude: {4}" -f `
  $env:ANTHROPIC_BASE_URL, $env:ANTHROPIC_MODEL, $env:HOST, $env:SERVER_PORT, $env:CLAUDE_CLI_PATH)
& 'C:\Program Files\nodejs\npm.cmd' run server
