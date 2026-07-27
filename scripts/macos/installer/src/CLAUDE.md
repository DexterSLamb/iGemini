# 部署机 Claude Code 指引（macOS / iGemini）

> ⚠️ 本文件在【隔离配置目录】`~/.claude-igemini/CLAUDE.md`（`CLAUDE_CONFIG_DIR=~/.claude-igemini`），
> 只供 iGemini 网页层 spawn 的 `claude` 读取——与日常 `~/.claude` 的官方 claude **互不污染**。
> 该 CC 用 **DeepSeek** 作后端，端点**只支持 text + tool_use**，不收图片/文件上传。

本机已装好一批**全局命令**（在 PATH 上，CC 用 **bash** 按名字调用）。把"看图/解析/导出/搜索"这类
DeepSeek 端点做不到的事，落到**工具层**完成。常用库已自带(看图/解析/导出/搜索**优先用下面现成命令**)。

## 🟢 可写、可联网、可装包（用户级）
**写代码、跑代码、装依赖都行**(用户级 `pip install --user` / `python3 -m venv` / npm;**别用 sudo/系统级**)。预装栈里没有的库,按下面规则装。

> ## 🔴 装包前必做的安全检查（硬规则）
> ⚠️ **这是【真机/部署机】,不是一次性沙箱** —— 上面有明文密钥(`~/.config` 下 DeepSeek/Qwen/Serper key)、用户文件、可能还有 SSH key。**装包 = 安装那一刻就执行代码**(pip 的 `setup.py`、npm 的 `preinstall/postinstall` 在 install 时立即跑,不等 import)——坏包装的瞬间就能把这些发走。**官方源(PyPI/npm)也不等于安全。**
> **强制**:执行 `pip install` / `npm install` / `npm i -g` / `npx` / `uv pip install` 等任何装包命令**之前**,先输出一行评估(不输出不许装):
> `[装包评估] 包=<名> 源=<PyPI官方/npm官方/其他> 判断=<装/停> 理由=<一句话>`
> **判「停」**:源非官方(`git+https://`/本地路径/`-e .`/`curl…|bash`/下载的 .whl/非官方镜像);包名仿冒或蹭名牌;陌生小包(月下载<1000/新注册);标准库或已装包就能做(先 `pip list`)。
> **判「装」**:官方源 + 公认常用包(requests/numpy/pandas/httpx/fastapi/flask/pytest、express/axios/react/typescript),或月下载>10万。
> **残余风险**(挡不住):传递依赖里的坏包、维护者被盗号发的恶意版、二进制隐蔽代码。

## 网络搜索（带兜底）
- 优先用自带 **WebSearch**（DeepSeek 服务端执行，**无需翻墙**）。报错/限流/返空 → **`websearch "查询词" [数]`**（Serper→DDG，需联网/翻墙）。
## 看图 / OCR
- DeepSeek 不收图片 → **`describe-image <图片> [提示词]`**（阿里 Qwen3-VL）。纯 OCR：`DESCRIBE_MODEL=qwen3.5-ocr describe-image <图>`。
## 解析文档（PDF/Word/Excel→文字）
- **`parsedoc <文件>`**（按扩展名自动分派；扫描件无文字层自动 OCR）。
## 导出文档（Markdown→PDF/Word）
- **`md2pdf 文档.md`** → PDF（无头 chrome-headless-shell 高保真）；**`md2docx 文档.md`** → Word（pandoc）。
## 表格
- CSV/XLSX 走代码：bash 调 `python3` + **openpyxl/pandas**（自带）读写/透视/合并。

---
> key 文件（运行时本地读）：DeepSeek `~/.config/deepseek/key`；Serper `~/.config/deepseek/serper_key`；Qwen `~/.config/qwen/{key,base}`。
