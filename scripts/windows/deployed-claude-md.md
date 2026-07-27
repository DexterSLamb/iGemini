# 部署机 Claude Code 指引（Windows 版）

> ⚠️ **这是 Windows 专属的 CLAUDE.md**，与 mac/共享的 `config/deployed-claude-md.md` 各管各的（OS 隔离）。
> 安装包会把本文件部署到 Windows 部署机的 **`%USERPROFILE%\.claude\CLAUDE.md`**，
> 供网页层 claudecodeui spawn 出来的 `claude` 读取（该 CC 用 DeepSeek 作后端，
> 端点**只支持 text + tool_use**，不收图片/文件上传）。

---

本机已装好一批**全局命令**（已在 PATH 上，CC 在 Windows 经 **git-bash** 跑命令，直接按名字调用即可）。
把"看图 / 解析文件 / 导出文档 / 搜索"这类 DeepSeek 端点本身做不到的事，落到**工具层**完成。

## 🟢 可写、可联网、可装包（用户级）
**写代码、跑代码、装依赖都行**（用户级 `pip install --user` / `python -m venv` / npm；Windows 上 `pip --user` 直接可用，不用 sudo）。常用库已预装（pymupdf / pdfplumber / python-docx / openpyxl / markdown 等）——"看图/解析/导出/搜索"这类**优先用下面的现成命令**；预装栈里没有的库,按下面规则装。

> ## 🔴 装包前必做的安全检查（硬规则）
> ⚠️ **这是【真机/部署机】,不是一次性沙箱** —— 上面有明文密钥(`%USERPROFILE%\.config` 下 DeepSeek/Qwen/Serper key)、用户文件。**装包 = 安装那一刻就执行代码**(pip 的 `setup.py`、npm 的 `preinstall/postinstall` 在 install 时立即跑,不等 import)——坏包装的瞬间就能把这些发走。**官方源(PyPI/npm)也不等于安全。**
> **强制**:执行 `pip install` / `pip install -r` / `npm install` / `npm i -g` / `npx` / `uv pip install` 等任何装包命令**之前**,先输出一行评估(不输出不许装):
> `[装包评估] 包=<名> 源=<PyPI官方/npm官方/其他> 判断=<装/停> 理由=<一句话>`
> **判「停」**(拒绝,改为说出顾虑、等用户确认):源非官方(`git+https://`/本地路径/`-e .`/`curl…|bash`/下载的 .whl/非官方镜像);包名像仿冒或蹭名牌;陌生小包(月下载<1000/新注册);标准库或已装包就能做(先 `pip list`)。
> **判「装」**:官方源 + 公认常用包(requests/numpy/pandas/httpx/fastapi/flask/pytest、express/axios/react/typescript 等直接过),或月下载>10万。
> **残余风险**(诚实告知,挡不住):传递依赖里的坏包、维护者被盗号发的恶意版、二进制里的隐蔽代码。
**遇到下列场景，优先用对应命令，不要只靠模型臆测。**

## 网络搜索（带兜底）
- **优先**用自带 **WebSearch** 工具（由 DeepSeek 服务端执行）。
- **若 WebSearch 报错 / 被限流 / 返回空结果** → 改用 **`websearch "查询词" [结果数]`**
  （Serper(Google)→DuckDuckGo 兜底链，输出 标题/URL/摘要；拿到后可继续 `WebFetch` 抓正文、据此引用）。
- 例：`websearch "2026 AI 监管 最新进展" 8`

## 看图 / OCR（图片 → 文字）
- DeepSeek 端点**不收图片**。要"看图、读截图、把图里的表格/文字转出来" →
  **`describe-image <图片路径> [提示词]`**（阿里 Qwen3-VL，OCR + 图片理解）。
- 纯 OCR 重场景：`DESCRIBE_MODEL=qwen3.5-ocr describe-image <图片>`。

## 解析上传的文档（PDF / Word / Excel → 文字）
- 用户从网页上传的文件会落在**项目工作目录**。要读其内容 → **`parsedoc <文件>`**
  （按扩展名**自动分派**：PDF / .docx / .doc / .rtf / .odt / .xlsx / 纯文本；
  扫描件 PDF 无文字层会自动转图走 OCR）。**不要自己猜用哪个库，更不要 pip 装。**

## 导出文档（Markdown → PDF / Word）
- 先把内容写成 `.md`，再导出：
  - **`md2pdf 文档.md`** → `文档.pdf`（无头 Chrome/Edge 高保真，中文/表格/标题/代码/链接全对）。
  - **`md2docx 文档.md`** → `文档.docx`（可编辑 Word，经 pandoc）。

## 表格
- **CSV** 小表可直接读/算；**XLSX(Excel) 必须走代码**：用 Bash 调 python + **openpyxl** 读写（已装）。
- 复杂透视 / 多表合并：用 **openpyxl + python 自己算**即可（**本机未装 pandas，别 `import pandas`**）。**计算走代码，别靠模型心算。**

---
> 涉及的 key 文件（**都不在仓库里**，运行时本地读）：
> Serper `%USERPROFILE%\.config\deepseek\serper_key`；DeepSeek `%USERPROFILE%\.config\deepseek\key`；Qwen `%USERPROFILE%\.config\qwen\{key,base}`。
