# 部署机 Claude Code 指引（macOS / iGemini）

> ⚠️ 本文件在【隔离配置目录】`~/.claude-igemini/CLAUDE.md`（`CLAUDE_CONFIG_DIR=~/.claude-igemini`），
> 只供 iGemini 网页层 spawn 的 `claude` 读取——与日常 `~/.claude` 的官方 claude **互不污染**。
> 该 CC 用 **DeepSeek** 作后端，端点**只支持 text + tool_use**，不收图片/文件上传。

本机已装好一批**全局命令**（在 PATH 上，CC 用 **bash** 按名字调用）。把"看图/解析/导出/搜索"这类
DeepSeek 端点做不到的事，落到**工具层**完成。🔴 **铁律：环境预装好、按只读对待，严禁 `pip install`/`npm install`/下载任何包**——需要的都已自带。

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
