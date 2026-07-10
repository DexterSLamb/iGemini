# 部署机 Claude Code 指引（Linux / iGemini）

> ⚠️ 本文件在【隔离配置目录】`~/.claude-igemini/CLAUDE.md`（`CLAUDE_CONFIG_DIR=~/.claude-igemini`），
> 只供 iGemini 网页层 spawn 的 `claude` 读取——与你日常 `~/.claude` 的官方 claude **互不污染**。
> 该 CC 用 **DeepSeek** 作后端，端点**只支持 text + tool_use**，不收图片/文件上传。

---

本机已装好一批**全局命令**（在 PATH 上，CC 直接用 **bash** 按名字调用即可）。
把"看图 / 解析文件 / 导出文档 / 搜索"这类 DeepSeek 端点本身做不到的事，落到**工具层**完成。

🔴 **铁律：本机环境预先装好，按只读对待。** 解析/看图/导出/搜索一律用下面的现成命令；
**严禁 `pip install` / `npm install` / 下载安装任何包**——需要的库都已装好
（pymupdf / pdfplumber / python-docx / openpyxl / pandas / markdown 等）。
某命令"找不到"是用法/环境问题，**重看本文、用现成命令**，绝不自己装依赖绕过。

## 网络搜索（带兜底）
- **优先**用自带 **WebSearch**（DeepSeek 服务端执行）。
- 若**报错 / 限流 / 返空** → **`websearch "查询词" [结果数]`**（Serper(Google)→DuckDuckGo 兜底，输出 标题/URL/摘要，可继续 `WebFetch` 抓正文据此引用）。

## 看图 / OCR（图片 → 文字）
- DeepSeek 端点**不收图片**。看图/读截图/把图里表格文字转出来 → **`describe-image <图片> [提示词]`**（阿里 Qwen3-VL）。
- 纯 OCR：`DESCRIBE_MODEL=qwen3.5-ocr describe-image <图片>`。

## 解析上传的文档（PDF / Word / Excel → 文字）
- 上传文件落在**项目工作目录**。读内容 → **`parsedoc <文件>`**（按扩展名自动分派 PDF/.docx/.doc/.rtf/.odt/.xlsx/纯文本；扫描件无文字层自动 OCR）。

## 导出文档（Markdown → PDF / Word）
- 写成 `.md` 再导出：
  - **`md2pdf 文档.md`** → `文档.pdf`（无头 **Chromium** 高保真，中文/表格/标题/代码/链接全对）。
  - **`md2docx 文档.md`** → `文档.docx`（pandoc）。

## 表格
- **CSV / XLSX 一律走代码**：用 bash 调 `python3` + **openpyxl / pandas**（都已装）读写、透视、合并。**计算走代码，别靠模型心算。**

---
> key 文件（**都不在仓库**，运行时本地读）：
> DeepSeek `~/.config/deepseek/key`；Serper `~/.config/deepseek/serper_key`；Qwen `~/.config/qwen/{key,base}`。
