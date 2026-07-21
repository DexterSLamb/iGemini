# iGemini

<p align="right"><a href="README.en.md">English</a> · <b>简体中文</b></p>

这个项目，源自于一个恶搞想法 —— 在 Google Pixelbook Go 笔记本上安装 macOS，开发 AVS 声卡和 IPU3 摄像头驱动，补齐 Apple 残废的 AI 能力，然后在 YouTube 上一本正经地胡说八道 —— 声称 Google 和 Apple 已经秘密合作一款笔记本。

![iGemini 截图](assets/screenshot.png)

> **说明**：iGemini 是个人 / 教育性质的玩具项目，与 Google（Gemini）、Anthropic（Claude）、Apple（Siri）**没有任何**隶属、背书或合作关系。

---

## 这是什么

iGemini 是一款**开箱即用、在本机运行**的 AI 助手。打开它，用浏览器就能：和 AI 对话、让它联网查资料、看图识图、读写文档、跑代码、用命令行。**所有运行所需（运行时、模型工具链、能力依赖）都已打进安装包 —— 离线胖包，装完即用，无需再装任何东西。**

只有一样要你提供：**一把 AI 服务密钥**（见下文「填写密钥」）。密钥只保存在你本机、绝不上传。

底层，它把三样东西编排到一起：**claudecodeui** 网页界面（[siteboon](https://github.com/siteboon/claudecodeui)，AGPL-3.0，白标成 iGemini）＋ **Claude Code** 智能体引擎 ＋ **DeepSeek** 模型后端。

---

## 能用来做什么

| 能力 | 说明 |
|---|---|
| 🧠 **分析解答** | 理清需求、给方案、写文案、做推理（背后是推理型大模型） |
| 🌐 **联网搜索** | 让 AI 自己上网查最新资料再回答 |
| 👁️ **看图识图 / OCR** | 理解图片内容、提取图中文字（截图、扫描件、照片都行） |
| 📄 **处理文档** | 读 PDF / Word / Excel 提取文字（扫描件自动 OCR）；导出 PDF / Word |
| 📊 **表格计算** | CSV / Excel 的读写、透视、合并、统计 |
| 💻 **编程开发** | 写代码、改 Bug、跑命令、做小工具 |
| 🖥️ **集成终端** | 内置 Shell，直接在网页里敲命令 / 跑 AI 会话 |
| 📁 **文件 & 源码管理** | 浏览项目文件、查看 git 改动 |

---

## 安装

下载对应平台的安装包，双击安装即可（普通用户权限，无需管理员；装前会自动停掉旧版本）。

| 平台 | 下载（v1.1.0） |
|---|---|
| **macOS（Apple Silicon / M 系列）** | [iGemini-Installer-arm64-v1.1.0.pkg](https://github.com/DexterSLamb/iGemini/releases/download/v1.1.0/iGemini-Installer-arm64-v1.1.0.pkg) |
| **macOS（Intel）** | [iGemini-Installer-x64-v1.1.0.pkg](https://github.com/DexterSLamb/iGemini/releases/download/v1.1.0/iGemini-Installer-x64-v1.1.0.pkg) |
| **Windows 64 位** | [iGemini-Setup-x64-v1.1.0.exe](https://github.com/DexterSLamb/iGemini/releases/download/v1.1.0/iGemini-Setup-x64-v1.1.0.exe) |
| **Linux（Debian / Deepin 系）** | 后端 + WebKitGTK 原生壳已完成；一键 installer 尚未做，见下方「从源码构建」 |

装完会自动启动后台服务并打开 iGemini 窗口；之后**开机自启**，随时打开即用。

> 不确定自己的 Mac 是哪种芯片？左上角  → 「关于本机」，写「Apple M…」选 arm64，写「Intel」选 x64。

---

## 填写密钥（首次使用必做）

iGemini 自己不带 AI 算力，需要你填一把**模型服务密钥**才能开始。密钥**仅明文保存在你本机**，不会进安装包、不会上传到任何 iGemini 的服务器。

| 密钥 | 必填？ | 作用 | 去哪申请 |
|---|---|---|---|
| **DeepSeek API Key** | ✅ **必填** | AI 模型后端（对话 / 推理 / 写代码的大脑） | platform.deepseek.com |
| **Serper API Key** | 选填 | 增强联网搜索（不填也有内置兜底搜索） | serper.dev（免费额度够用） |
| **Qwen API Key + Base URL** | 选填 | 看图识图 / OCR（用阿里 Qwen 视觉模型） | 阿里云百炼 / DashScope |

### 怎么填

- **Windows**：安装过程中会有一个「填写 API 密钥」页，DeepSeek 必填、其余可留空。**如果机器上已经有 DeepSeek 密钥，安装时会自动跳过这一页。**
- **macOS**：首次启动时，若还没有 DeepSeek 密钥，会弹出一个小窗口让你填。
- **随时修改（推荐）**：在 iGemini 里打开「**配置密钥…**」，填完点保存即可 —— 保存时会**联网校验 DeepSeek 密钥是否有效**，通过后自动重启后台服务生效，不用你操心。
  - **macOS**：菜单栏 `iGemini` → `配置密钥…`
  - **Windows**：按 `Alt + 空格`（或点窗口标题栏左上角的图标）→ `配置密钥…`
- **高级：直接改文件**（改完需重启 iGemini 服务生效）：
  - DeepSeek：`~/.config/deepseek/key`
  - Serper：`~/.config/deepseek/serper_key`
  - Qwen：`~/.config/qwen/key`、`~/.config/qwen/base`
  - （Windows 路径同理，在 `%USERPROFILE%\.config\` 下）

---

## 隐私 & 说明

- **本地优先**：iGemini 本体、会话记录、密钥都在你自己电脑上，不经过任何中转服务器。
- **AI 请求去向**：你提的问题会发给你配置的模型服务（DeepSeek / Qwen / Serper）做处理 —— 这是用 AI 的必然，敏感内容请自行斟酌。
- **绿点小知识**：聊天回复结束后，左侧会话的绿点可能还会脉动一会儿才熄灭 —— 这是模型连接收尾的正常现象，回复内容其实早就给你了，不影响使用。
- **不联苹果不联谷歌**：名字是玩笑，底层用的是 Claude Code 引擎 ＋ DeepSeek / Qwen 模型，跟 Apple、Google 没有任何关系。

---

## 从源码构建

这是一个**源码仓**（AGPL-3.0，欢迎自行构建 / 审计）。每个平台产出一个自包含的离线安装包，请在**目标 OS**上构建：

- **macOS**（在 Apple Silicon 上，会交叉编译出 Intel 壳）：
  ```sh
  bash scripts/macos/installer/build-pkg.sh arm64   # → iGemini-Installer-arm64-vX.Y.Z.pkg
  bash scripts/macos/installer/build-pkg.sh x64      # → Intel
  ```
- **Windows**（原生 x64）：
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\windows\installer\build-installer.ps1
  iscc scripts\windows\installer\iGemini.iss          # → iGemini-Setup-x64-vX.Y.Z.exe
  ```
  也可参考 `.github/workflows/` 里的 GitHub Actions 构建。
- **Linux**（Debian / Deepin 系）：
  ```sh
  bash scripts/linux/setup.sh                          # 后端 + 工具 + 服务
  # 原生壳：scripts/linux/shell-app/igemini-shell.py（GTK3 + WebKitGTK）
  ```

> 国内网络下二进制源慢时，可传代理：`PROXY=http://127.0.0.1:7897 bash …`（或 PowerShell 的 `-Proxy …`）；否则直连。

**数据流**：`浏览器 ⇄ claudecodeui(iGemini) ──spawn──▶ claude CLI ──env──▶ api.deepseek.com/anthropic`。子进程继承父进程环境变量，启动时注入 DeepSeek 配置即可把整条链路指向 DeepSeek；服务只绑 `127.0.0.1:8888`（仅本机）。密钥运行时从 `~/.config/deepseek/key` 注入，绝不硬编码、绝不入库。

本仓**不含** Claude Code 或 claudecodeui 的源码 —— claudecodeui 在固定上游 commit 上拉取，再套 [`vendor/igemini-claudecodeui.patch`](vendor/igemini-claudecodeui.patch) 白标（**只应用、不分叉**）。版本号单一真源：`scripts/<os>/installer/VERSION`。

---

## 许可

本仓采用 **AGPL-3.0**（见 [`LICENSE`](LICENSE)）。内含一份从 claudecodeui（© [siteboon](https://github.com/siteboon/claudecodeui)，AGPL-3.0）派生的白标 patch；完整的第三方署名与对应源码声明见 [`NOTICE`](NOTICE)。

*开箱即用。填一把 Key，剩下的交给它。*
