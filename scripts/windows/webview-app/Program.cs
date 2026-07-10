// iGemini —— 只跑 CloudCLI(localhost:8888)的原生 WebView2 专用壳（Windows 版，等价 mac 的 WKWebView 壳）。
// 自带图标/AUMID → 任务栏/Alt-Tab 都是 iGemini；含就绪加载动画、外链用系统浏览器打开。
// WebView2 原生支持文件选择/下载/浏览器加速键(Ctrl +/-/0 缩放)，无需像 mac 壳那样手工补。
// v1.1.0 对齐 mac：自动登录固定账号 + 跳 CloudCLI 引导（直接进聊天）、缩放持久化、启动超时提示、关于/配置密钥。
//
// 【入口】窗口【系统菜单】(点标题栏左上角图标 / Alt+空格) 底部的「配置密钥…」「关于 iGemini」。
//   —— 窗口不加任何 chrome（不加菜单栏/工具条/顶栏），保住"只有网页"的极简。
//   托盘图标(NotifyIcon)方案已弃用：实测图标根本不出现(连 Win11 的 ^ 溢出区都没有)，
//   给了成本却没给到可发现性。配置密钥首次运行会自动弹，之后靠系统菜单。
// 【弹窗】AboutForm / KeyForm 均继承 ThemedForm，字体与间距对标 Inno 安装包的填 key 页（12pt 粗标题 /
//   9pt 正文 / 8pt 灰注释 / 24px 边距），字体用【微软雅黑 UI】（安装包的 MS Shell Dlg 在中文 Windows 上
//   就渲染成雅黑），密钥框保持【明文】（与安装包/mac 一致，且能一眼看出粘贴带进来的空格）。
// 【DPI】不用 AutoScaleMode.Font（它与自定义字体的 AutoScaleDimensions 基准会打架、结果难预测）：
//   改为 AutoScaleMode.None + 字体用磅值(自动随 DPI 变大) + 所有像素尺寸走 Px() 显式换算 + 容器 AutoSize。
//
// 编译（.NET Framework csc，免装 SDK；见 build.ps1，会顺带生成 Version.cs）：
//   csc /target:winexe /codepage:65001 /out:iGemini.exe /win32icon:igemini.ico ^
//       /reference:Microsoft.Web.WebView2.Core.dll /reference:Microsoft.Web.WebView2.WinForms.dll ^
//       /reference:System.Windows.Forms.dll /reference:System.Drawing.dll Program.cs Version.cs
// 运行依赖：WebView2 Runtime（Win11 自带）+ 同目录 WebView2Loader.dll(x64) + 两个托管 DLL。
// 注：源码存 UTF-8，靠 csc /codepage:65001 正确读中文。csc 是 C# 5：catch 里不能 await、无字符串内插。
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace iGemini
{
    static class Program
    {
        [DllImport("user32.dll")]
        static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        [STAThread]
        static void Main()
        {
            // 必须在创建任何窗口之前把进程设成 Per-Monitor V2 DPI 感知（否则 150% 缩放屏上网页模糊，root cause）。
            try { SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    // ---- 设计 token：一处定义，两个弹窗共用；数值对标 Inno 安装包的填 key 页 ----
    static class Ui
    {
        public const string FontName = "Microsoft YaHei UI";   // 与安装包 MS Shell Dlg 在中文 Windows 上的实际渲染一致
        public static Font Title()    { return new Font(FontName, 12f, FontStyle.Bold); }
        public static Font Body()     { return new Font(FontName, 9f); }
        public static Font BodyBold() { return new Font(FontName, 9f, FontStyle.Bold); }
        public static Font Note()     { return new Font(FontName, 8f); }
        public static readonly Color NoteColor  = Color.FromArgb(0x70, 0x70, 0x70);
        public static readonly Color ErrorColor = Color.FromArgb(0xC0, 0x39, 0x2B);
        // 逻辑像素(96 DPI 基准)，运行时经 ThemedForm.Px() 换算
        public const int PadX = 24, PadTop = 20, PadBottom = 16;
        public const int GapTitle = 8, GapSection = 16, GapLabel = 4;
        public const int FieldWidth = 420, ButtonW = 96, ButtonH = 28;
    }

    // ---- 弹窗统一底座：雅黑基准字体、白底、固定对话框、DPI 换算 ----
    public class ThemedForm : Form
    {
        readonly float scale;

        public ThemedForm()
        {
            AutoScaleMode = AutoScaleMode.None;   // 见文件头注释：自己算，别让 WinForms 拿错基准
            AutoSize = false;
            Font = Ui.Body();
            BackColor = Color.White;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterScreen;   // 托盘唤起时主窗可能不可见，CenterScreen 永远合理
            Icon = AppIcon();
            using (Graphics g = CreateGraphics()) scale = g.DpiX / 96f;
        }

        /// 逻辑像素(96 DPI) → 当前 DPI 的设备像素。字体走磅值自动放大，像素尺寸靠这个跟上。
        protected int Px(int logical) { return (int)Math.Round(logical * scale); }

        /// app 图标；size>0 时取该尺寸的位图（关于窗的大图标用）
        public static Icon AppIcon()
        {
            try
            {
                string p = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "igemini.ico");
                if (File.Exists(p)) return new Icon(p);
            }
            catch { }
            return null;
        }
        /// 取 app 图标并【按目标像素高质量绘好】返回（调用方 PictureBox 用 Normal 模式贴，别再缩一次）。
        public static Image AppImage(int targetPx)
        {
            Bitmap src = LoadBestIcoFrame();
            if (src == null) return null;
            Bitmap dst = new Bitmap(targetPx, targetPx, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(dst))
            {
                g.Clear(Color.Transparent);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, targetPx, targetPx));
            }
            src.Dispose();
            return dst;
        }

        // 我们的 .ico 是 build.ps1 手工拼的【32bpp PNG-in-ICO】。.NET 的 Icon.ToBitmap() 处理 PNG 帧
        // 会出花屏 / 丢 alpha —— 所以自己解析 ICONDIR，取【最大】那帧的 PNG 字节直接 Image.FromStream。
        static Bitmap LoadBestIcoFrame()
        {
            try
            {
                string p = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "igemini.ico");
                if (!File.Exists(p)) return null;
                byte[] b = File.ReadAllBytes(p);
                if (b.Length < 6) return null;
                int count = BitConverter.ToUInt16(b, 4);
                int best = -1, bestOff = 0, bestLen = 0;
                for (int i = 0; i < count; i++)
                {
                    int e = 6 + i * 16;
                    if (e + 16 > b.Length) break;
                    int w = b[e]; if (w == 0) w = 256;          // ICONDIRENTRY: 宽=0 表示 256
                    int len = BitConverter.ToInt32(b, e + 8);
                    int off = BitConverter.ToInt32(b, e + 12);
                    if (off < 0 || len <= 0 || off + len > b.Length) continue;
                    if (w > best) { best = w; bestOff = off; bestLen = len; }
                }
                if (best <= 0) return null;
                using (MemoryStream ms = new MemoryStream(b, bestOff, bestLen))
                using (Image img = Image.FromStream(ms))
                    return new Bitmap(img);                      // 复制一份，脱离 stream 生命周期
            }
            catch { return null; }
        }

        /// 容器算完自身首选尺寸后，把窗口客户区收紧到它 —— 比给 Form 设 AutoSize 稳（不会循环布局）
        protected void FitTo(Control root)
        {
            root.PerformLayout();
            ClientSize = root.PreferredSize;
        }
    }

    // ---- 关于 iGemini：app 图标 + 名字 + 版本 + 署名 + 确定 ----
    public class AboutForm : ThemedForm
    {
        public AboutForm()
        {
            Text = "关于 iGemini";

            TableLayoutPanel root = new TableLayoutPanel();
            root.ColumnCount = 1; root.AutoSize = true;
            root.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            root.BackColor = Color.White;
            root.Padding = new Padding(Px(Ui.PadX), Px(Ui.PadTop), Px(Ui.PadX), Px(Ui.PadBottom));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

            int isz = Px(48);
            PictureBox pic = new PictureBox();
            pic.Size = new Size(isz, isz);
            pic.SizeMode = PictureBoxSizeMode.Normal;     // 图已按目标尺寸高质量绘好，别让 PictureBox 再低质量缩一次
            pic.BackColor = Color.Transparent;
            pic.Image = AppImage(isz);                    // 从 .ico 的最大 PNG 帧(256)双三次缩下来，任何 DPI 都清晰
            pic.Anchor = AnchorStyles.None;               // 在单元格内居中
            pic.Margin = new Padding(0, 0, 0, Px(12));

            Label name = new Label();
            name.Text = "iGemini"; name.Font = Ui.Title(); name.AutoSize = true;
            name.Anchor = AnchorStyles.None; name.Margin = new Padding(0, 0, 0, Px(2));

            Label ver = new Label();
            ver.Text = "版本 " + Ver.V; ver.Font = Ui.Body(); ver.ForeColor = Ui.NoteColor;
            ver.AutoSize = true; ver.Anchor = AnchorStyles.None; ver.Margin = new Padding(0, 0, 0, Px(14));

            Label copy = new Label();
            copy.Text = "© 2026 iGemini · CloudCLI (AGPL-3.0)";
            copy.Font = Ui.Note(); copy.ForeColor = Ui.NoteColor; copy.AutoSize = true;
            copy.Anchor = AnchorStyles.None; copy.Margin = new Padding(0, 0, 0, Px(16));

            Button ok = new Button();
            ok.Text = "确定"; ok.Font = Ui.Body();
            ok.Size = new Size(Px(Ui.ButtonW), Px(Ui.ButtonH));
            ok.Anchor = AnchorStyles.None; ok.DialogResult = DialogResult.OK;

            root.Controls.Add(pic); root.Controls.Add(name); root.Controls.Add(ver);
            root.Controls.Add(copy); root.Controls.Add(ok);
            Controls.Add(root);
            AcceptButton = ok; CancelButton = ok;    // Enter / Esc 都关掉
            FitTo(root);
        }
    }

    // ---- 配置密钥：4 字段【明文】+ 保存时联网实测 DeepSeek key ----
    // 字号/间距/灰注释对标 Inno 安装包的填 key 页；不用 PasswordChar（与安装包、mac 一致，且能看出多余空格）。
    public class KeyForm : ThemedForm
    {
        readonly TextBox tDs, tSp, tQk, tQb;
        readonly Label msg;
        readonly Button btnSave, btnCancel;
        public bool Saved = false;

        public KeyForm()
        {
            Text = "iGemini · 配置密钥";

            TableLayoutPanel root = new TableLayoutPanel();
            root.ColumnCount = 1; root.AutoSize = true;
            root.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            root.BackColor = Color.White;
            root.Padding = new Padding(Px(Ui.PadX), Px(Ui.PadTop), Px(Ui.PadX), Px(Ui.PadBottom));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

            Label title = new Label();
            title.Text = "配置 API 密钥"; title.Font = Ui.Title(); title.AutoSize = true;
            title.Margin = new Padding(0, 0, 0, Px(Ui.GapTitle));

            Label sub = new Label();
            sub.Text = "DeepSeek 必填，其余可选；密钥只保存在你本机，不会上传。";
            sub.Font = Ui.Body(); sub.ForeColor = Ui.NoteColor; sub.AutoSize = true;
            sub.Margin = new Padding(0, 0, 0, Px(Ui.GapSection));

            root.Controls.Add(title); root.Controls.Add(sub);

            tDs = AddField(root, "DeepSeek API Key *", "AI 的大脑：对话、推理、写代码都靠它。去 platform.deepseek.com 申请");
            tSp = AddField(root, "Serper API Key（选填）", "增强联网搜索；不填也能搜（用内置兜底）。去 serper.dev 申请");
            tQk = AddField(root, "Qwen API Key（选填）", "让 AI 看懂图片、认出图中的字（OCR）。去阿里云百炼 / DashScope 申请");
            tQb = AddField(root, "Qwen Base URL（选填）", "阿里给你的接入地址，和上面的 Qwen Key 配对使用。");

            Label note = new Label();
            note.Text = "密钥明文写入本机 " + Cfg.Root();
            note.Font = Ui.Note(); note.ForeColor = Ui.NoteColor; note.AutoSize = true;
            note.Margin = new Padding(0, 0, 0, Px(10));
            root.Controls.Add(note);

            msg = new Label();
            msg.Text = ""; msg.Font = Ui.Body(); msg.ForeColor = Ui.ErrorColor;
            msg.AutoSize = false; msg.Width = Px(Ui.FieldWidth); msg.Height = Px(20);
            msg.Margin = new Padding(0, 0, 0, Px(8));
            root.Controls.Add(msg);

            // 按钮行：右对齐，读序为 [保存][取消]（RightToLeft 流 → 先加的在最右）
            FlowLayoutPanel bar = new FlowLayoutPanel();
            bar.FlowDirection = FlowDirection.RightToLeft;
            bar.AutoSize = true; bar.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            bar.Width = Px(Ui.FieldWidth); bar.Margin = new Padding(0);

            btnCancel = new Button();
            btnCancel.Text = "取消"; btnCancel.Font = Ui.Body();
            btnCancel.Size = new Size(Px(Ui.ButtonW), Px(Ui.ButtonH));
            btnCancel.DialogResult = DialogResult.Cancel;

            btnSave = new Button();
            btnSave.Text = "保存"; btnSave.Font = Ui.Body();
            btnSave.Size = new Size(Px(Ui.ButtonW), Px(Ui.ButtonH));
            btnSave.Margin = new Padding(Px(8), 0, Px(8), 0);
            btnSave.Click += OnSave;

            bar.Controls.Add(btnCancel); bar.Controls.Add(btnSave);
            root.Controls.Add(bar);

            Controls.Add(root);
            AcceptButton = btnSave; CancelButton = btnCancel;   // Enter 保存 / Esc 取消
            FitTo(root);

            // 预填现有值 + Tab 顺序（TableLayoutPanel 里 Tab 走 TabIndex，不走视觉顺序）
            tDs.Text = Cfg.Read("deepseek\\key");
            tSp.Text = Cfg.Read("deepseek\\serper_key");
            tQk.Text = Cfg.Read("qwen\\key");
            tQb.Text = Cfg.Read("qwen\\base");
            tDs.TabIndex = 0; tSp.TabIndex = 1; tQk.TabIndex = 2; tQb.TabIndex = 3;
            btnSave.TabIndex = 4; btnCancel.TabIndex = 5;
        }

        // 一个字段 = 粗体标签 + 明文输入框 + 8pt 灰说明（与安装包同构）
        TextBox AddField(TableLayoutPanel root, string label, string desc)
        {
            Label l = new Label();
            l.Text = label; l.Font = Ui.BodyBold(); l.AutoSize = true;
            l.Margin = new Padding(0, 0, 0, Px(Ui.GapLabel));

            TextBox box = new TextBox();
            box.Font = Ui.Body(); box.Width = Px(Ui.FieldWidth);
            box.Margin = new Padding(0, 0, 0, Px(Ui.GapLabel));
            // 明文：不设 PasswordChar。也不关 IME —— 强行关会让用户切输入法时困惑。
            HookNoWhitespace(box);   // 但空白必须挡：见下

            Label d = new Label();
            d.Text = desc; d.Font = Ui.Note(); d.ForeColor = Ui.NoteColor;
            d.AutoSize = false; d.Width = Px(Ui.FieldWidth); d.Height = Px(17);
            d.Margin = new Padding(0, 0, 0, Px(Ui.GapSection));

            root.Controls.Add(l); root.Controls.Add(box); root.Controls.Add(d);
            return box;
        }

        // 与 mac 表单一致：4 个框【即时剔除所有空白】（打字和粘贴都覆盖，光标位置保住）。
        // key / URL 里永远不该有空白，而"粘贴带进尾随空格 → key 明明对却鉴权失败"是最经典的坑。
        // 保存时的 Trim() 只作兜底。（DS 主张别实时改用户的字；此处按产品决定推翻——空白在这里 100% 是错的。）
        static void HookNoWhitespace(TextBox box)
        {
            box.TextChanged += delegate
            {
                string t = box.Text;
                string clean = StripWhitespace(t);
                if (clean == t) return;          // 无空白 → 直接返回；也终结下面赋值再次触发本事件的递归
                int caret = box.SelectionStart, removed = 0;
                for (int i = 0; i < caret && i < t.Length; i++) if (char.IsWhiteSpace(t[i])) removed++;
                box.Text = clean;
                box.SelectionStart = Math.Max(0, Math.Min(clean.Length, caret - removed));
            };
        }
        static string StripWhitespace(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length);
            for (int i = 0; i < s.Length; i++) if (!char.IsWhiteSpace(s[i])) sb.Append(s[i]);
            return sb.ToString();
        }

        void Say(string text, Color color) { msg.ForeColor = color; msg.Text = text; }

        void SetBusy(bool busy)
        {
            btnSave.Enabled = !busy; btnCancel.Enabled = !busy;
            tDs.Enabled = tSp.Enabled = tQk.Enabled = tQb.Enabled = !busy;
            Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
            if (busy) Say("验证中…", Ui.NoteColor);
        }

        // 只在【保存时】Trim —— 输入过程中别动用户的字（粘贴后当场少了空格会让人困惑）
        async void OnSave(object sender, EventArgs e)
        {
            string ds = tDs.Text.Trim();
            if (ds.Length == 0) { Say("请填写 DeepSeek 密钥。", Ui.ErrorColor); tDs.Focus(); return; }
            if (!ds.StartsWith("sk-")) { Say("密钥格式不对，应以 sk- 开头。", Ui.ErrorColor); tDs.Focus(); return; }

            SetBusy(true);
            bool ok = await ValidateDeepSeek(ds);
            SetBusy(false);
            if (!ok) { Say("密钥无效，请核对。", Ui.ErrorColor); tDs.Focus(); return; }

            Cfg.Write("deepseek\\key", ds);
            Cfg.Write("deepseek\\serper_key", tSp.Text.Trim());
            Cfg.Write("qwen\\key", tQk.Text.Trim());
            Cfg.Write("qwen\\base", tQb.Text.Trim());
            Saved = true; DialogResult = DialogResult.OK; Close();
        }

        // 联网实测：GET api.deepseek.com/user/balance 带 Bearer。
        // 200=有效；401/403=无效；其它(超时/断网)=无法判断 → 不阻断保存（与 mac 一致）。
        static async Task<bool> ValidateDeepSeek(string key)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.deepseek.com/user/balance");
                req.Method = "GET"; req.Timeout = 10000; req.Proxy = null;
                req.Headers["Authorization"] = "Bearer " + key;
                using (HttpWebResponse resp = (HttpWebResponse)await req.GetResponseAsync())
                    return resp.StatusCode == HttpStatusCode.OK;
            }
            catch (WebException we)
            {
                HttpWebResponse r = we.Response as HttpWebResponse;
                if (r != null && (r.StatusCode == HttpStatusCode.Unauthorized || r.StatusCode == HttpStatusCode.Forbidden)) return false;
                return true;
            }
            catch { return true; }
        }
    }

    // ---- 配置文件读写（%USERPROFILE%\.config\...，等价 mac 的 ~/.config；空值=删文件）----
    static class Cfg
    {
        public static string Root()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        }
        static string PathOf(string rel) { return Path.Combine(Root(), rel); }

        public static string Read(string rel)
        {
            try { string p = PathOf(rel); return File.Exists(p) ? File.ReadAllText(p).Trim() : ""; }
            catch { return ""; }
        }
        public static void Write(string rel, string val)
        {
            try
            {
                string p = PathOf(rel);
                if (string.IsNullOrEmpty(val)) { if (File.Exists(p)) File.Delete(p); return; }
                Directory.CreateDirectory(Path.GetDirectoryName(p));
                File.WriteAllText(p, val.Trim() + "\r\n");
            }
            catch { }
        }
    }

    public class MainForm : Form
    {
        const string Url = "http://localhost:8888";
        const string Api = "http://localhost:8888/api";
        readonly WebView2 web = new WebView2();
        bool pageReady = false;
        bool authDone = false;      // 自动登录只做一次（token 已注入 localStorage）
        int  pollCount = 0;         // 轮询次数：到阈值仍没起来 → 换"仍在启动"提示
        string zoomFile;            // 缩放持久化文件

        // 唯一入口：往窗口【系统菜单】(点标题栏左上角图标 / Alt+空格)追加两项。
        // 自定义命令 ID 低 4 位必须为 0（WM_SYSCOMMAND 低 4 位系统内部占用，判定要 & 0xFFF0）。
        const int SC_ABOUT = 0x9010;
        const int SC_KEYS  = 0x9020;
        const int WM_SYSCOMMAND = 0x112;
        const int MF_STRING = 0x0, MF_SEPARATOR = 0x800;
        [DllImport("user32.dll")] static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(IntPtr hMenu, int uFlags, int uIDNewItem, string lpNewItem);

        public MainForm()
        {
            Text = "iGemini";
            Width = 1280; Height = 820;
            StartPosition = FormStartPosition.CenterScreen;
            Icon = ThemedForm.AppIcon();
            zoomFile = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iGemini-shell", "zoom.txt");
            web.Dock = DockStyle.Fill;
            Controls.Add(web);
            Load += async (s, e) => await InitAsync();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            IntPtr h = GetSystemMenu(this.Handle, false);
            AppendMenu(h, MF_SEPARATOR, 0, null);
            AppendMenu(h, MF_STRING, SC_KEYS, "配置密钥…");
            AppendMenu(h, MF_STRING, SC_ABOUT, "关于 iGemini");
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_SYSCOMMAND)
            {
                int c = m.WParam.ToInt32() & 0xFFF0;
                if (c == SC_ABOUT) { ShowAbout(); return; }
                if (c == SC_KEYS)  { ShowKeyForm(false); return; }
            }
            base.WndProc(ref m);
        }

        async Task InitAsync()
        {
            string udf = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iGemini-shell");
            CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, udf, null);
            await web.EnsureCoreWebView2Async(env);
            CoreWebView2 cw = web.CoreWebView2;

            // 浏览器加速键（Ctrl +/-/0 缩放、Ctrl+滚轮）保持开启（WebView2 默认即支持，无需手工加）
            try { cw.Settings.AreBrowserAcceleratorKeysEnabled = true; } catch { }
            RestoreZoom();
            web.ZoomFactorChanged += (s, e) => SaveZoom();

            // 外链(非 localhost) → 系统默认浏览器
            cw.NewWindowRequested += (s, e) => { e.Handled = true; OpenExternal(e.Uri); };
            cw.NavigationStarting += (s, e) =>
            {
                try
                {
                    Uri u = new Uri(e.Uri);
                    if ((u.Scheme == "http" || u.Scheme == "https")
                        && u.Host != "localhost" && u.Host != "127.0.0.1")
                    {
                        e.Cancel = true; OpenExternal(e.Uri);
                    }
                }
                catch { }
            };
            // 真正页面加载失败(服务中途不可用) → 回到加载动画并重新轮询
            cw.NavigationCompleted += (s, e) =>
            {
                if (pageReady && !e.IsSuccess) { pageReady = false; ShowLoaderAndConnect(); }
            };

            // 首次无 DeepSeek key → 先弹配置密钥窗（等价 mac 首次自动弹表单）；有 key 直接连。
            // 注：Windows 安装器一般已在装时收了 key，此路径主要是"漏了/被清空"的兜底。
            if (string.IsNullOrEmpty(Cfg.Read("deepseek\\key")))
                ShowKeyForm(true);
            else
                ShowLoaderAndConnect();
        }

        static void OpenExternal(string uri)
        {
            try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); } catch { }
        }

        // ---- 缩放持久化（对齐 mac 的 pageZoom 记忆）----
        void RestoreZoom()
        {
            try
            {
                if (!File.Exists(zoomFile)) return;
                double z;
                if (double.TryParse(File.ReadAllText(zoomFile).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out z)
                    && z >= 0.25 && z <= 5.0)
                    web.ZoomFactor = z;
            }
            catch { }
        }
        void SaveZoom()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(zoomFile));
                File.WriteAllText(zoomFile, web.ZoomFactor.ToString(CultureInfo.InvariantCulture));
            }
            catch { }
        }

        // 显示加载动画并轮询 8888 就绪；就绪后【自动登录 + 跳引导】再载入聊天页。
        void ShowLoaderAndConnect()
        {
            pageReady = false; pollCount = 0;
            web.CoreWebView2.NavigateToString(LoaderHtml);
            Task.Run(async () =>
            {
                while (!pageReady)
                {
                    pollCount++;
                    if (pollCount == 25 && !IsDisposed)   // ~20s 仍没起来 → 换"仍在启动"提示（仍继续轮询）
                    {
                        try { BeginInvoke((Action)(() => { if (!pageReady) web.CoreWebView2.NavigateToString(SlowHtml); })); }
                        catch { }
                    }
                    if (await IsServerUp())
                    {
                        string token = await GetAuthTokenAsync();   // 后台线程只做 HTTP，安全
                        if (IsDisposed) return;
                        try
                        {
                            BeginInvoke((Action)(async () =>
                            {
                                if (!authDone && !string.IsNullOrEmpty(token))
                                {
                                    string js = "try{localStorage.setItem('auth-token','" + JsEscape(token) + "')}catch(e){}";
                                    try { await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(js); } catch { }
                                    authDone = true;
                                }
                                pageReady = true;
                                web.CoreWebView2.Navigate(Url);   // 有 token→免登录进聊天；无 token→回退(前端显示登录页)
                            }));
                        }
                        catch { }
                        break;
                    }
                    await Task.Delay(800);
                }
            });
        }

        static async Task<bool> IsServerUp()
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Url);
                req.Method = "GET"; req.Timeout = 2500; req.Proxy = null; req.AllowAutoRedirect = false;
                Task<WebResponse> task = req.GetResponseAsync();
                if (await Task.WhenAny(task, Task.Delay(3000)) != task) { req.Abort(); return false; }
                using (WebResponse resp = await task) return true;
            }
            catch (WebException we) { return we.Response != null; }
            catch { return false; }
        }

        // ---- 自动登录固定账号 iGemini/iGemini + 标记 CloudCLI 首次引导完成（等价 mac 的 ensureAuthThenLoad）----
        // GET /api/auth/status → needsSetup ? register : login → 拿 JWT → POST /complete-onboarding → 返回 token。
        // 全程只 HTTP（后台线程安全）；token 的注入/导航在 UI 线程做。失败则返回 null → 回退手动登录。
        async Task<string> GetAuthTokenAsync()
        {
            if (authDone) return null;
            try
            {
                string status = await HttpSend("GET", Api + "/auth/status", null, null);
                bool needsSetup = status != null &&
                    status.Replace(" ", "").IndexOf("\"needsSetup\":true", StringComparison.OrdinalIgnoreCase) >= 0;
                string ep = needsSetup ? "register" : "login";
                string resp = await HttpSend("POST", Api + "/auth/" + ep,
                    "{\"username\":\"iGemini\",\"password\":\"iGemini\"}", null);
                string token = ExtractJsonString(resp, "token");
                if (!string.IsNullOrEmpty(token))
                {
                    try { await HttpSend("POST", Api + "/user/complete-onboarding", "", token); } catch { }
                }
                return token;
            }
            catch { return null; }
        }

        // 通用 HTTP：method + 可选 JSON body + 可选 Bearer；返回响应体（含错误体，便于判 401/403）。
        static async Task<string> HttpSend(string method, string url, string jsonBody, string bearer)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method; req.Timeout = 8000; req.Proxy = null; req.AllowAutoRedirect = false;
            if (bearer != null) req.Headers["Authorization"] = "Bearer " + bearer;
            if (jsonBody != null)
            {
                req.ContentType = "application/json";
                byte[] bytes = Encoding.UTF8.GetBytes(jsonBody);
                using (Stream rs = await req.GetRequestStreamAsync()) rs.Write(bytes, 0, bytes.Length);
            }
            try
            {
                using (HttpWebResponse resp = (HttpWebResponse)await req.GetResponseAsync())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                    return await sr.ReadToEndAsync();
            }
            catch (WebException we)
            {
                // C# 5 的 csc 不允许 catch 里 await（CS1985）→ 错误体很小，同步读即可
                if (we.Response != null)
                    using (StreamReader sr = new StreamReader(we.Response.GetResponseStream())) return sr.ReadToEnd();
                return null;
            }
        }

        // 从简单 JSON 里抽取字符串值（"key":"value"）——响应结构已知、稳定，够用；token 是 JWT 无引号/转义。
        static string ExtractJsonString(string json, string key)
        {
            if (string.IsNullOrEmpty(json)) return null;
            string pat = "\"" + key + "\"";
            int i = json.IndexOf(pat, StringComparison.Ordinal);
            if (i < 0) return null;
            i = json.IndexOf(':', i + pat.Length);
            if (i < 0) return null;
            i++;
            while (i < json.Length && (json[i] == ' ' || json[i] == '\t')) i++;
            if (i >= json.Length || json[i] != '"') return null;
            i++;
            StringBuilder sb = new StringBuilder();
            while (i < json.Length && json[i] != '"')
            {
                if (json[i] == '\\' && i + 1 < json.Length) { sb.Append(json[i + 1]); i += 2; }
                else { sb.Append(json[i]); i++; }
            }
            return sb.ToString();
        }

        static string JsEscape(string s) { return s.Replace("\\", "\\\\").Replace("'", "\\'"); }

        // ---- 关于 iGemini ----
        void ShowAbout()
        {
            using (AboutForm f = new AboutForm()) f.ShowDialog(this);
        }

        // ---- 配置密钥（系统菜单 或 首次无 key 时弹）。保存后重启后端让新 key 生效、再重连。----
        void ShowKeyForm(bool firstRun)
        {
            using (KeyForm f = new KeyForm())
            {
                f.ShowDialog(this);
                if (f.Saved)
                {
                    RestartBackend();
                    authDone = false;         // 后端重启 → 重新走一次自动登录/重连
                    ShowLoaderAndConnect();
                }
                else if (firstRun)
                {
                    ShowLoaderAndConnect();    // 首次取消也照常连（后端 keyless；用户可再从系统菜单配置）
                }
            }
        }

        // 重启网页后端：杀掉本 app 自带 node 起的服务（按主模块路径匹配，避免误杀用户别的 node），再经 launcher.vbs 隐藏重启。
        static void RestartBackend()
        {
            try
            {
                string shellDir = AppDomain.CurrentDomain.BaseDirectory;                    // ...\shell\
                string appDir = Directory.GetParent(shellDir.TrimEnd('\\', '/')).FullName;   // {app}
                foreach (Process p in Process.GetProcessesByName("node"))
                {
                    try
                    {
                        if (p.MainModule != null &&
                            p.MainModule.FileName.StartsWith(appDir, StringComparison.OrdinalIgnoreCase))
                            p.Kill();
                    }
                    catch { }
                }
                string vbs = Path.Combine(appDir, "launcher.vbs");
                if (File.Exists(vbs))
                    Process.Start(new ProcessStartInfo("wscript.exe", "\"" + vbs + "\"")
                    { UseShellExecute = true, WindowStyle = ProcessWindowStyle.Hidden });
            }
            catch { }
        }

        // 正在启动 iGemini… 加载动画
        const string LoaderHtml =
            "<!doctype html><html><head><meta charset='utf-8'><style>" +
            "html,body{height:100%;margin:0}" +
            "body{display:flex;flex-direction:column;align-items:center;justify-content:center;" +
            "background:#0b0f17;color:#cfd6e4;font:15px 'Segoe UI','Microsoft YaHei',sans-serif;-webkit-user-select:none;user-select:none}" +
            ".s{width:38px;height:38px;border-radius:50%;border:3px solid rgba(255,255,255,.15);" +
            "border-top-color:#6aa3ff;animation:r .9s linear infinite;margin-bottom:18px}" +
            "@keyframes r{to{transform:rotate(360deg)}}.h{opacity:.55;font-size:12px;margin-top:7px}</style></head>" +
            "<body><div class='s'></div><div>正在启动 iGemini…</div>" +
            "<div class='h'>正在等待本地服务就绪</div></body></html>";

        // 启动偏慢时的提示（对齐 mac 的 SlowHTML）——只是慢，不是报错，别写吓人的排查话
        const string SlowHtml =
            "<!doctype html><html><head><meta charset='utf-8'><style>" +
            "html,body{height:100%;margin:0}" +
            "body{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:0 32px;text-align:center;" +
            "background:#0b0f17;color:#cfd6e4;font:15px 'Segoe UI','Microsoft YaHei',sans-serif;-webkit-user-select:none;user-select:none}" +
            ".s{width:38px;height:38px;border-radius:50%;border:3px solid rgba(255,255,255,.15);" +
            "border-top-color:#e0a35a;animation:r .9s linear infinite;margin-bottom:18px}" +
            "@keyframes r{to{transform:rotate(360deg)}}.h{opacity:.55;font-size:12px;margin-top:9px}</style></head>" +
            "<body><div class='s'></div><div>仍在启动…</div>" +
            "<div class='h'>比平时慢一些，仍在重试…</div></body></html>";
    }
}
