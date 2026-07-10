# 部署机 Claude Code 指引（模板）

> 本文件的内容要放到**部署机**的 **`~/.claude/CLAUDE.md`**，
> 供网页层 claudecodeui spawn 出来的 `claude` 读取（该 CC 用 DeepSeek 作后端，
> 端点**只支持 text + tool_use**，不收图片/文件上传）。
> 部署机是专用机、无"日常 CC"要隔离，故用全局 `~/.claude/CLAUDE.md`。
> 安装：`cp config/deployed-claude-md.md ~/.claude/CLAUDE.md`（按需合并已有内容）。

---

本机已装好一批**全局命令**(都在 `/usr/local/bin`，任何项目可直接 Bash 调用)，
把"看图 / 解析文件 / 导出文档 / 搜索"这类 DeepSeek 端点本身做不到的事，落到**工具层**完成。
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
  扫描件 PDF 无文字层会自动转图走 OCR）。**不要自己猜用哪个库。**

## 导出文档（Markdown → PDF / Word）
- 先把内容写成 `.md`，再导出：
  - **`md2pdf 文档.md`** → `文档.pdf`（无头 Chrome 高保真，中文/表格/标题/代码/链接全对）。
  - **`md2docx 文档.md`** → `文档.docx`（可编辑 Word）。

## 表格
- **CSV** 小表可直接读/算；**XLSX(Excel) 必须走代码**：用 Bash 调 python + **openpyxl** 读写。
- 复杂透视 / 多表合并 / 大数据：用 **pandas**（已装）。**计算尽量走代码，别靠模型心算。**

---
> 涉及的 key 文件（**都不在仓库里**，运行时本地读）：
> Serper `~/.config/deepseek/serper_key`；DeepSeek `~/.config/deepseek/key`；Qwen `~/.config/qwen/{key,base}`。
