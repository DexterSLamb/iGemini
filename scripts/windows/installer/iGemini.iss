; ============================================================================
; iGemini.iss —— Inno Setup 6：把 build-installer.ps1 产出的 staging\ 打成单个 setup.exe
;   编译： iscc iGemini.iss        产物： Output\iGemini-Setup-x64.exe
; 设计：装到 %LocalAppData%\iGemini（免管理员）；装【前】终止占用进程；装中收 key；
;       品牌化界面 + 填白；建快捷方式 + 登录自启；把 {app}\claude\bin 等加进用户 PATH。
; ⚠️ Inno Pascal 易错；[Code] 一律用 // 注释（{ } 注释里嵌 {常量} 会提前闭合）。
; ============================================================================
#define AppName    "iGemini"
; 版本号单一真源 = 同目录 VERSION 文件；build-installer.ps1 读它、以 /DAppVersion=<ver> 传进来。
; 直接 iscc（不经 build 脚本）时用下面 fallback（与 VERSION 保持一致）。
#ifndef AppVersion
  #define AppVersion "1.1.0"
#endif
#define StageDir   "staging"

[Setup]
AppId={{A7F3C2E1-9B4D-4C8A-B6E5-2D1F8C3A9E70}
AppName={#AppName}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=iGemini
DefaultDirName={localappdata}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=iGemini-Setup-x64-v{#AppVersion}
; 正式交付：lzma2/ultra64 出 ~250MB 小包（iscc ~20 分钟）。迭代调试时可临时改 Compression=none（~1-2 分钟、临时 ~1.3GB）
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; 宽度 100%；高度 110% —— 容下填 key 页的 4 个字段 + 底部 .config 灰注释，不溢出（IS6 默认 120 过高显空）
WizardSizePercent=100,110
; 角标(右上角小图)按用户要求去掉、恢复默认；仅保留欢迎/完成页的标准左 banner
WizardImageFile={#StageDir}\branding\large.bmp
SetupIconFile={#StageDir}\shell\igemini.ico
UninstallDisplayIcon={app}\shell\iGemini.exe
LicenseFile={#StageDir}\legal\LICENSE-AGPL-3.0.txt
; #3：要改用户 PATH，声明环境变更（装完广播 WM_SETTINGCHANGE）
ChangesEnvironment=yes

[Languages]
; 简中用【仓库内置】的 .isl（winget 装的 Inno 默认不带简中）；相对路径 = iss 同目录
Name: "cn"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Messages]
; 许可页去重：默认说明行("继续安装前阅读重要信息")与正文("仔细阅读…继续安装前必须同意")都在说"继续安装前阅读"。
; 拆成不同意思：说明行=请阅读，正文=必须同意才能继续。
cn.LicenseLabel=请阅读以下软件许可协议。
cn.LicenseLabel3=您必须同意本协议条款，才能继续安装。

[Files]
; 主体：装 staging\* 到 {app}，但排除 branding\（那是装界面用的图，不进安装目录）
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: "branding\*"; Flags: recursesubdirs createallsubdirs ignoreversion
; #1：装前停进程脚本，dontcopy，PrepareToInstall 里取出来跑
Source: "preinstall-stop.ps1"; Flags: dontcopy

[Registry]
; #3：把 {app}\claude\bin 等加进【用户 PATH】，让任何 shell/终端的裸 `claude`、能力工具都能解析。
;     {olddata} 保留原 PATH 追加；NeedsAddPath 防重复（重装不会越加越长）。
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}\claude\bin;{app}\tools;{app}\runtime\node;{app}\runtime\python;{app}\runtime\pandoc"; \
  Check: NeedsAddPath('{app}\claude\bin')

[Icons]
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\shell\iGemini.exe"; IconFilename: "{app}\shell\igemini.ico"
Name: "{group}\{#AppName}";       Filename: "{app}\shell\iGemini.exe"; IconFilename: "{app}\shell\igemini.ico"
; 登录自启：启动文件夹快捷方式 → wscript 跑 launcher.vbs（VBS 以隐藏窗口起 powershell→run-server）。
; 为什么不直接 powershell -WindowStyle Hidden：它藏不住 powershell 自己的主控制台窗（先建窗再隐藏的老毛病），
; 用户会看到一个常驻命令窗；wscript + VBS 的 Run(cmd,0,False) 从一开始就真隐藏、连子进程一起隐。卸载随 [Icons] 清除。
Name: "{userstartup}\iGemini-Web"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launcher.vbs"""; IconFilename: "{app}\shell\igemini.ico"; Comment: "iGemini 网页服务登录自启"

[Run]
; key 在【安装前】的填 key 页已写入 .config，所以这里起服务即带着 key。
; 去掉 postinstall → 安装末尾【自动静默】起服务，不在 Finish 页弹「运行 powershell」勾选项
Filename: "{sys}\wscript.exe"; Parameters: """{app}\launcher.vbs"""; Flags: nowait
Filename: "{app}\shell\iGemini.exe"; Description: "{cm:LaunchProgram,iGemini}"; Flags: nowait postinstall skipifsilent

[Code]
var
  KeyPage: TInputQueryWizardPage;
  ConfigNote: TNewStaticText;   // 填 key 页底部的 8pt 灰色 .config 路径注释

// 用户 PATH 里是否还没有这个目录（防重复追加）。Param 是带 {app} 的常量串，内部展开。
function NeedsAddPath(Param: String): Boolean;
var OrigPath, P: String;
begin
  P := ExpandConstant(Param);
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then begin
    Result := True; exit;
  end;
  Result := Pos(';' + Lowercase(P) + ';', ';' + Lowercase(OrigPath) + ';') = 0;
end;

// 设计规范（基于 Wizard97 / Inno modern + 4px 栅格，CurPageChanged 单入口全局强制）：
//   内部页标题 12pt 粗体（默认 9pt 粗体太弱、被正文淹没）；标题↔说明行 8px（默认仅 2px，显挤）。
//   欢迎/完成页用的是另一组 14pt 标签（WelcomeLabel/FinishedHeadingLabel），跳过标题改动。
procedure ApplySpec(PageID: Integer);
begin
  if (PageID <> wpWelcome) and (PageID <> wpFinished) then begin
    WizardForm.PageNameLabel.AutoSize := True;       // 让标签随字号长高，12pt 不被 16px 旧高度裁切
    WizardForm.PageNameLabel.Font.Size := 12;
    WizardForm.PageNameLabel.Font.Style := [fsBold];
  end;
  WizardForm.PageDescriptionLabel.Top :=
    WizardForm.PageNameLabel.Top + WizardForm.PageNameLabel.Height + ScaleY(8);
end;

procedure InitializeWizard;
var cfg: String;
begin
  cfg := ExpandConstant('{%USERPROFILE}') + '\.config';   // 真实路径，不显示变量名
  // 填 key 页（选目录后、安装前）。说明放【页眉描述行】(第 3 参数，与其它内置页同槽位)；
  // 必填/可选 写进说明，字段标签保持精简（不加括号注释）；正文用默认布局，不手动挪控件。
  KeyPage := CreateInputQueryPage(wpSelectDir,
    '填写 API 密钥',
    '请填写 API 密钥（DeepSeek 必填，其余可选）',
    '');
  // 第 2 个参数 False = 明文显示（不是 •••），方便核对有没有多余空格；保存时 WriteKey 会自动去首尾空格
  KeyPage.Add('DeepSeek API Key:', False);
  KeyPage.Add('Serper API Key:', False);
  KeyPage.Add('Qwen API Key:', False);
  KeyPage.Add('Qwen Base URL:', False);
  // .config 真实路径作 8pt 灰色辅助注释，放最后一个输入框下方 8px（信息层级降一级，不抢正文）
  ConfigNote := TNewStaticText.Create(WizardForm);
  ConfigNote.Parent := KeyPage.Surface;
  ConfigNote.AutoSize := True;
  ConfigNote.Font.Size := 8;
  ConfigNote.Font.Color := clGray;
  ConfigNote.Caption := '密钥明文写入本机 ' + cfg;
  ConfigNote.Left := KeyPage.Edits[3].Left;
  ConfigNote.Top := KeyPage.Edits[3].Top + KeyPage.Edits[3].Height + ScaleY(8);
end;

// 每页切换时套用设计规范（内置页 + 自定义页一并生效）
procedure CurPageChanged(CurPageID: Integer);
begin
  ApplySpec(CurPageID);
end;

procedure WriteKey(Rel, Val: String);
var P: String;
begin
  if Trim(Val) = '' then exit;
  P := GetEnv('USERPROFILE') + '\.config\' + Rel;
  ForceDirectories(ExtractFileDir(P));
  SaveStringToFile(P, Trim(Val) + #13#10, False);
end;

// 填 key 页在安装前，离开该页（点下一步）时写入 .config；DeepSeek 必填。
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = KeyPage.ID then begin
    if Trim(KeyPage.Values[0]) = '' then begin
      MsgBox('请填写 DeepSeek API Key（模型后端必需）。留空的话装完无法使用 AI。', mbError, MB_OK);
      Result := False; exit;
    end;
    WriteKey('deepseek\key',        KeyPage.Values[0]);
    WriteKey('deepseek\serper_key', KeyPage.Values[1]);
    WriteKey('qwen\key',            KeyPage.Values[2]);
    WriteKey('qwen\base',           KeyPage.Values[3]);
  end;
end;

// 已有 DeepSeek key（.config\deepseek\key 非空）则跳过填 key 页 —— 与 macOS 一致：有 key 不再问。
// 要改 key：直接编辑 %USERPROFILE%\.config\deepseek\key。
function HasDeepSeekKey(): Boolean;
begin
  // 文件存在即视为已配（WriteKey 只写非空 key，故存在即非空）
  Result := FileExists(GetEnv('USERPROFILE') + '\.config\deepseek\key');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = KeyPage.ID then Result := HasDeepSeekKey();
end;

// #1：点「安装」后、拷文件前，先终止占用 {app} 文件的进程（解决 bcrypt.node 覆盖失败）
function PrepareToInstall(var NeedsRestart: Boolean): String;
var RC: Integer;
begin
  try
    ExtractTemporaryFile('preinstall-stop.ps1');
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\preinstall-stop.ps1') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, RC);
  except
  end;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ClaudeMd: String;
begin
  if CurStep <> ssPostInstall then exit;
  // 部署版 CLAUDE.md（让 spawn 出的 CC 知道能力命令 + 严禁 pip）——总是部署，已有的先备份成 .bak
  ClaudeMd := GetEnv('USERPROFILE') + '\.claude\CLAUDE.md';
  ForceDirectories(ExtractFileDir(ClaudeMd));
  if FileExists(ClaudeMd) then begin
    DeleteFile(ClaudeMd + '.bak');
    RenameFile(ClaudeMd, ClaudeMd + '.bak');
  end;
  FileCopy(ExpandConstant('{app}\deployed-claude-md.md'), ClaudeMd, False);
end;
