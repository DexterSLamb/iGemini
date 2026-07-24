#!/usr/bin/env python3
# ============================================================================
# igemini-shell.py —— iGemini 的 Linux 原生桌面壳（GTK3 + WebKit2GTK）
#
# 与 macOS 的 WKWebView 壳（scripts/macos/cloudcli-webkit/main.m）功能对齐。
# 两边同为 WebKit，API 几乎一一对应，所以「壳内 HTML 填 key 表单 + 注入 localStorage
# 做自动登录」这套是原样搬过来的：
#     WKUserScript              ←→  WebKit2.UserScript / UserContentManager.add_script
#     WKScriptMessageHandler    ←→  ucm.register_script_message_handler + script-message-received
#     pageZoom                  ←→  webview.set_zoom_level
#
# 它做什么：
#   1) 只加载本机 localhost:8888（CloudCLI）；外链交给系统浏览器
#   2) 起动时轮询后端就绪；~20s 还没起来就换一句温和的「仍在启动…」（不是报错）
#   3) 【自动登录】固定账号 iGemini/iGemini + 标记 CloudCLI 引导完成 → 直接进聊天
#   4) 【配置密钥…】壳内 HTML 表单（4 字段、即时剔空白、保存时联网实测 DeepSeek key）
#      首次没有 key 时自动弹出；保存后重启后端服务再重连
#   5) 【关于 iGemini】原生 GTK AboutDialog（图标 + 版本 + AGPL 署名）
#   6) 缩放 Ctrl + / − / 0，记忆缩放级别
#
# 入口放在 GTK HeaderBar 右上角的 ☰ —— 这是 GNOME/Deepin 的原生惯例，用户天然认得
# （不像 Windows 那边只能退回系统菜单）。
#
# 依赖（Deepin 25 实测）：python3-gi、gir1.2-webkit2-4.1、libwebkit2gtk-4.1-0、GTK3
#   sudo apt install -y gir1.2-webkit2-4.1 libwebkit2gtk-4.1-0
#
# 运行：python3 igemini-shell.py
# ============================================================================
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2, GLib, Gdk, Gio, GdkPixbuf   # noqa: E402

import html
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


def log(*a):
    """诊断日志走 stderr（systemd/nohup 会收进日志文件）。壳里静默失败最难查。"""
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)

URL = "http://localhost:8888"
API = URL + "/api"
HERE = os.path.dirname(os.path.abspath(__file__))
CFG_ROOT = os.path.expanduser("~/.config")
ZOOM_FILE = os.path.join(CFG_ROOT, "igemini", "zoom")
SLOW_AFTER_POLLS = 25          # ×800ms ≈ 20s


def read_version():
    """版本号单一真源：scripts/linux/VERSION（部署时随壳一起拷过去）。"""
    for p in (os.path.join(HERE, "VERSION"), os.path.join(HERE, "..", "VERSION")):
        try:
            with open(p) as f:
                v = f.read().strip()
                if v:
                    return v
        except OSError:
            pass
    return "1.1.0"


VERSION = read_version()


def app_icon_path():
    for name in ("igemini.png", "icon.png"):
        p = os.path.join(HERE, name)
        if os.path.exists(p):
            return p
    return None


# ---------------------------------------------------------------- 配置读写
def cfg_path(rel):
    return os.path.join(CFG_ROOT, rel)


def cfg_read(rel):
    try:
        with open(cfg_path(rel)) as f:
            return f.read().strip()
    except OSError:
        return ""


def cfg_write(rel, val):
    """空值 = 删文件（与 mac/win 一致）。目录 0700、文件 0600。"""
    p = cfg_path(rel)
    try:
        if not val:
            if os.path.exists(p):
                os.remove(p)
            return
        d = os.path.dirname(p)
        os.makedirs(d, mode=0o700, exist_ok=True)
        with open(p, "w") as f:
            f.write(val.strip() + "\n")
        os.chmod(p, 0o600)
    except OSError:
        pass


# ---------------------------------------------------------------- HTTP 小工具
def http_send(method, url, body=None, bearer=None, timeout=8):
    """返回 (status, text)。网络失败返回 (None, "")。错误体也读出来，便于判 401/403。"""
    req = urllib.request.Request(url, method=method)
    if bearer:
        req.add_header("Authorization", "Bearer " + bearer)
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = body.encode("utf-8")
    try:
        with urllib.request.urlopen(req, data=data, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception:
            return e.code, ""
    except Exception:
        return None, ""


def server_up():
    st, _ = http_send("GET", URL, timeout=2)
    return st is not None


def get_auth_token():
    """等价 mac 的 ensureAuthThenLoad 的 HTTP 部分：
    GET /auth/status → needsSetup ? register : login → 拿 JWT → POST /user/complete-onboarding。
    失败返回 None → 回退到手动登录页。

    ⚠️ 踩过的坑：早先版本只按 needsSetup 选一个端点，一旦 /auth/status 查询失败（返回空串），
    json 解析异常被吞掉 → needsSetup 默认 False → 去调 login → 401 → 静默落回注册页。
    现在 needsSetup 只当【提示】，两个端点都会试一遍，任一拿到 token 就算成功（自愈）。
    """
    st, status = http_send("GET", API + "/auth/status")
    log("auth/status →", st, repr(status[:60]))
    needs = None
    try:
        needs = bool(json.loads(status).get("needsSetup"))
    except Exception as e:
        log("  ! /auth/status 解析失败(%s) —— 两个端点都试" % e)

    order = ["register", "login"] if needs else ["login", "register"]
    creds = json.dumps({"username": "iGemini", "password": "iGemini"})
    token = None
    for ep in order:
        _, resp = http_send("POST", API + "/auth/" + ep, creds)
        try:
            token = json.loads(resp).get("token")
        except Exception:
            token = None
        log("  POST /auth/%s → %s" % (ep, ("token(%d)" % len(token)) if token else "无 token"))
        if token:
            break
    if not token:
        log("  ✗ 两个端点都没拿到 token → 回退到手动登录页")
        return None

    # 顺手把 CloudCLI 的首次引导（Git 配置 / Connect Agents）标记完成
    st3, _ = http_send("POST", API + "/user/complete-onboarding", "", token)
    log("  complete-onboarding →", st3)
    return token


def validate_deepseek(key):
    """联网实测：200=有效；401/403=无效；其它(超时/断网)=无法判断 → 不阻断保存（与 mac/win 一致）。"""
    st, _ = http_send("GET", "https://api.deepseek.com/user/balance", bearer=key, timeout=10)
    if st in (401, 403):
        return False
    return True


def restart_backend():
    """保存新 key 后让后端重新读它。Linux 用 systemd 用户服务。"""
    try:
        subprocess.Popen(["systemctl", "--user", "restart", "igemini-web"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


# ---------------------------------------------------------------- 页面
_CSS_BASE = (
    "html,body{height:100%;margin:0}"
    "body{display:flex;flex-direction:column;align-items:center;justify-content:center;"
    "background:#0b0f17;color:#cfd6e4;font:15px 'Noto Sans CJK SC','Source Han Sans SC',sans-serif;"
    "-webkit-user-select:none;user-select:none}"
    ".s{width:38px;height:38px;border-radius:50%;border:3px solid rgba(255,255,255,.15);"
    "animation:r .9s linear infinite;margin-bottom:18px}"
    "@keyframes r{to{transform:rotate(360deg)}}"
    ".h{opacity:.55;font-size:12px;margin-top:7px}"
)

LOADER_HTML = (
    "<!doctype html><meta charset='utf-8'><style>" + _CSS_BASE +
    ".s{border-top-color:#6aa3ff}</style>"
    "<div class='s'></div><div>正在启动 iGemini…</div>"
    "<div class='h'>正在等待本地服务就绪</div>"
)

# 只是慢，不是报错 —— 别写吓人的排查话
SLOW_HTML = (
    "<!doctype html><meta charset='utf-8'><style>" + _CSS_BASE +
    ".s{border-top-color:#e0a35a}</style>"
    "<div class='s'></div><div>仍在启动…</div>"
    "<div class='h'>比平时慢一些，仍在重试…</div>"
)


def keyform_html(ds, sp, qk, qb):
    """壳内填 key 表单。配色对齐 CloudCLI 暗色主题；4 字段全部【明文】
    （与安装器/mac 一致，且明文能一眼看出粘贴带进来的空格）。"""
    e = html.escape
    return f"""<!doctype html><meta charset='utf-8'><style>
:root{{--bg:hsl(0,0%,8%);--fg:hsl(40,8%,93%);--card:hsl(0,0%,12%);--pri:hsl(217,91%,60%);
--sec:hsl(0,0%,17%);--mut:hsl(0,0%,60%);--bd:hsl(0,0%,17%);--in:hsl(0,0%,23%);--err:hsl(0,72%,62%)}}
*{{box-sizing:border-box}}
body{{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:var(--bg);color:var(--fg);font:14px 'Noto Sans CJK SC','Source Han Sans SC',sans-serif}}
.card{{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:28px 30px;width:520px}}
h1{{margin:0 0 6px;font-size:19px;font-weight:600}}
.sub{{color:var(--mut);font-size:13px;margin:0 0 22px}}
label{{display:block;font-weight:600;font-size:13px;margin:0 0 6px}}
.tag{{font-weight:400;color:var(--mut);font-size:12px}}
input{{width:100%;padding:9px 11px;border-radius:7px;border:1px solid var(--in);
background:var(--bg);color:var(--fg);font:13px monospace;outline:none}}
input:focus{{border-color:var(--pri)}}
.desc{{color:var(--mut);font-size:12px;margin:6px 0 18px;line-height:1.5}}
.desc a{{color:var(--pri);text-decoration:none;cursor:pointer}}
.err{{color:var(--err);font-size:13px;min-height:20px;margin:2px 0 12px}}
.err.info{{color:var(--mut)}}
.row{{display:flex;gap:10px;justify-content:flex-end}}
button{{padding:9px 20px;border-radius:7px;border:none;font-size:13px;cursor:pointer}}
#cancel{{background:var(--sec);color:var(--fg)}}
#save{{background:var(--pri);color:#fff}}
#save:disabled{{opacity:.45;cursor:not-allowed}}
.note{{color:var(--mut);font-size:11px;margin-top:14px;text-align:center}}
</style>
<div class='card'>
<h1>配置 API 密钥</h1>
<p class='sub'>DeepSeek 必填，其余可选；密钥只保存在你本机，不会上传。</p>

<label>DeepSeek API Key <span class='tag'>必填</span></label>
<input id='ds' value="{e(ds)}" spellcheck='false' autocapitalize='off' autocorrect='off'>
<div class='desc'>AI 的大脑：对话、推理、写代码都靠它。<a data-u='https://platform.deepseek.com'>去 platform.deepseek.com 申请</a></div>

<label>Serper API Key <span class='tag'>选填</span></label>
<input id='sp' value="{e(sp)}" spellcheck='false' autocapitalize='off' autocorrect='off'>
<div class='desc'>增强联网搜索；不填也能搜（用内置兜底）。<a data-u='https://serper.dev'>去 serper.dev 申请</a></div>

<label>Qwen API Key <span class='tag'>选填</span></label>
<input id='qk' value="{e(qk)}" spellcheck='false' autocapitalize='off' autocorrect='off'>
<div class='desc'>让 AI 看懂图片、认出图中的字（OCR）。<a data-u='https://bailian.console.aliyun.com'>去阿里云百炼 / DashScope 申请</a></div>

<label>Qwen Base URL <span class='tag'>选填</span></label>
<input id='qb' value="{e(qb)}" spellcheck='false' autocapitalize='off' autocorrect='off'>
<div class='desc'>阿里给你的接入地址，和上面的 Qwen Key 配对使用。</div>

<div class='err' id='err'></div>
<div class='row'><button id='cancel'>取消</button><button id='save'>保存</button></div>
<div class='note'>密钥明文写入本机 ~/.config</div>
</div>
<script>
const $=i=>document.getElementById(i), err=$('err'), save=$('save');
const boxes=['ds','sp','qk','qb'].map($);
// 打字和粘贴都即时剔除所有空白 —— key/URL 里空白 100% 是错的，
// 而"粘贴带进尾随空格 → key 明明对却鉴权失败"是最经典的坑。
boxes.forEach(b=>b.addEventListener('input',()=>{{
  const c=b.value.replace(/\\s+/g,'');
  if(c!==b.value){{const p=b.selectionStart; b.value=c; b.selectionStart=b.selectionEnd=Math.max(0,p-1);}}
  save.disabled = $('ds').value.trim()==='';
}}));
save.disabled = $('ds').value.trim()==='';
// 「去申请」链接交给系统浏览器
document.querySelectorAll('a[data-u]').forEach(a=>a.onclick=()=>
  window.webkit.messageHandlers.igopen.postMessage(a.dataset.u));
function say(t,info){{err.textContent=t; err.className = info?'err info':'err';}}
$('cancel').onclick=()=>window.webkit.messageHandlers.igkeys.postMessage(JSON.stringify({{cancel:true}}));
save.onclick=()=>{{
  const k=$('ds').value.trim();
  if(k.indexOf('sk-')!==0){{ say('密钥格式不对，应以 sk- 开头'); return; }}
  save.disabled=true; boxes.forEach(b=>b.disabled=true); say('验证中…',1);
  window.webkit.messageHandlers.igkeys.postMessage(JSON.stringify(
    {{ds:k, sp:$('sp').value.trim(), qk:$('qk').value.trim(), qb:$('qb').value.trim()}}));
}};
// 原生端判定 key 无效时回调
window.igInvalid=()=>{{ save.disabled=false; boxes.forEach(b=>b.disabled=false); say('密钥无效，请核对'); }};
</script>"""


# ---------------------------------------------------------------- 主窗口
class Shell(Gtk.Window):
    def __init__(self):
        super().__init__(title="iGemini")
        self.set_default_size(1280, 820)
        self.set_position(Gtk.WindowPosition.CENTER)
        ico = app_icon_path()
        if ico:
            try:
                self.set_icon(GdkPixbuf.Pixbuf.new_from_file(ico))
            except Exception:
                pass

        self.page_ready = False
        self.auth_done = False
        self.poll_count = 0
        self.form_showing = False

        # HeaderBar + 右上角 ☰ —— GNOME/Deepin 的原生入口惯例
        hb = Gtk.HeaderBar(title="iGemini", show_close_button=True)
        menu = Gio.Menu()
        menu.append("配置密钥…", "win.keys")
        menu.append("关于 iGemini", "win.about")
        btn = Gtk.MenuButton()
        btn.set_menu_model(menu)
        btn.set_tooltip_text("菜单")
        # Deepin 的图标主题不一定带 open-menu-symbolic；缺了的话 Gtk.Image 会渲染成空白，
        # 按钮就成了「看不见的空壳」（实测踩过）。所以逐个探测，全都没有就退回纯文字 ☰。
        child = None
        try:
            theme = Gtk.IconTheme.get_default()
            for name in ("open-menu-symbolic", "open-menu", "view-more-symbolic", "format-justify-fill"):
                if theme is not None and theme.has_icon(name):
                    child = Gtk.Image.new_from_icon_name(name, Gtk.IconSize.BUTTON)
                    log("菜单图标:", name)
                    break
        except Exception as e:
            log("图标主题探测失败:", e)
        if child is None:
            log("菜单图标: 主题里都没有 → 退回文字 ☰")
            child = Gtk.Label(label="☰")
        btn.add(child)
        hb.pack_end(btn)
        self.set_titlebar(hb)
        hb.show_all()

        # ⚠️ GTK3 里只有 Gtk.ApplicationWindow 实现了 GActionMap；普通 Gtk.Window 没有 add_action()，
        # 直接调会 AttributeError 把 __init__ 整个炸掉（踩过）。用 SimpleActionGroup 挂到 "win" 前缀。
        group = Gio.SimpleActionGroup()
        for name, cb in (("keys", lambda *_: self.show_key_form(False)),
                         ("about", lambda *_: self.show_about())):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", cb)
            group.add_action(act)
        self.insert_action_group("win", group)

        # WebView + user content manager（注入 user script / 接 JS 消息）
        self.ucm = WebKit2.UserContentManager()
        for h in ("igkeys", "igopen"):
            self.ucm.register_script_message_handler(h)
        self.ucm.connect("script-message-received::igkeys", self.on_keys_msg)
        self.ucm.connect("script-message-received::igopen", self.on_open_msg)

        self.web = WebKit2.WebView.new_with_user_content_manager(self.ucm)
        self.web.connect("decide-policy", self.on_policy)
        self.web.connect("load-failed", self.on_load_failed)
        self.add(self.web)

        self.restore_zoom()
        self.connect("key-press-event", self.on_key)
        self.connect("destroy", Gtk.main_quit)

        # 首次没有 DeepSeek key → 先弹配置窗；有 key 直接连（等价 mac）
        if not cfg_read("deepseek/key"):
            self.show_key_form(True)
        else:
            self.show_loader_and_connect()

    # ---- 缩放（Ctrl +/−/0，记忆级别）----
    def restore_zoom(self):
        try:
            with open(ZOOM_FILE) as f:
                z = float(f.read().strip())
            if 0.25 <= z <= 5.0:
                self.web.set_zoom_level(z)
        except Exception:
            pass

    def save_zoom(self):
        try:
            os.makedirs(os.path.dirname(ZOOM_FILE), exist_ok=True)
            with open(ZOOM_FILE, "w") as f:
                f.write("%.3f" % self.web.get_zoom_level())
        except OSError:
            pass

    def on_key(self, _w, ev):
        if not (ev.state & Gdk.ModifierType.CONTROL_MASK):
            return False
        k = ev.keyval
        z = self.web.get_zoom_level()
        if k in (Gdk.KEY_plus, Gdk.KEY_equal, Gdk.KEY_KP_Add):
            self.web.set_zoom_level(min(3.0, z + 0.1))
        elif k in (Gdk.KEY_minus, Gdk.KEY_KP_Subtract):
            self.web.set_zoom_level(max(0.5, z - 0.1))
        elif k in (Gdk.KEY_0, Gdk.KEY_KP_0):
            self.web.set_zoom_level(1.0)
        else:
            return False
        self.save_zoom()
        return True

    # ---- 外链 → 系统浏览器 ----
    def on_policy(self, _w, decision, dtype):
        if dtype != WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            return False
        try:
            uri = decision.get_navigation_action().get_request().get_uri()
        except Exception:
            return False
        if uri.startswith(("http://localhost", "http://127.0.0.1", "about:", "data:")):
            return False
        if uri.startswith(("http://", "https://")):
            decision.ignore()
            self.open_external(uri)
            return True
        return False

    @staticmethod
    def open_external(uri):
        try:
            Gio.AppInfo.launch_default_for_uri(uri, None)
        except Exception:
            subprocess.Popen(["xdg-open", uri],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def on_load_failed(self, *_a):
        # 页面中途失败（服务重启等）→ 回加载动画重新轮询
        if self.page_ready and not self.form_showing:
            self.page_ready = False
            self.show_loader_and_connect()
        return False

    # ---- 加载动画 + 轮询 + 自动登录 ----
    def show_loader_and_connect(self):
        self.form_showing = False
        self.page_ready = False
        self.poll_count = 0
        self.web.load_html(LOADER_HTML, URL)
        threading.Thread(target=self._poll, daemon=True).start()

    def _poll(self):
        while not self.page_ready:
            self.poll_count += 1
            if self.poll_count == SLOW_AFTER_POLLS:
                GLib.idle_add(self._show_slow)
            if server_up():
                token = get_auth_token()          # 后台线程只做 HTTP
                GLib.idle_add(self._enter_chat, token)
                return
            GLib.usleep(800 * 1000)

    def _show_slow(self):
        if not self.page_ready and not self.form_showing:
            self.web.load_html(SLOW_HTML, URL)
        return False

    def _enter_chat(self, token):
        if token and not self.auth_done:
            js = "try{localStorage.setItem('auth-token','%s')}catch(e){}" % token.replace("\\", "\\\\").replace("'", "\\'")
            self.ucm.add_script(WebKit2.UserScript.new(
                js, WebKit2.UserContentInjectedFrames.ALL_FRAMES,
                WebKit2.UserScriptInjectionTime.START, None, None))
            self.auth_done = True
        self.page_ready = True
        self.web.load_uri(URL)   # 有 token→免登录直接聊天；无 token→回退到登录页
        return False

    # ---- 配置密钥 ----
    def show_key_form(self, first_run):
        self.first_run = first_run
        self.form_showing = True
        self.page_ready = False
        self.web.load_html(keyform_html(
            cfg_read("deepseek/key"), cfg_read("deepseek/serper_key"),
            cfg_read("qwen/key"), cfg_read("qwen/base")), URL)

    def on_open_msg(self, _ucm, result):
        self.open_external(result.get_js_value().to_string())

    def on_keys_msg(self, _ucm, result):
        try:
            d = json.loads(result.get_js_value().to_string())
        except Exception:
            return
        if d.get("cancel"):
            # 首次取消也照常连（后端 keyless；之后可从 ☰ 再配）
            self.show_loader_and_connect()
            return
        threading.Thread(target=self._validate_then_save, args=(d,), daemon=True).start()

    def _validate_then_save(self, d):
        ok = validate_deepseek(d["ds"])
        if not ok:
            GLib.idle_add(lambda: (self.web.run_javascript("window.igInvalid()", None, None, None), False)[1])
            return
        cfg_write("deepseek/key", d["ds"])
        cfg_write("deepseek/serper_key", d.get("sp", ""))
        cfg_write("qwen/key", d.get("qk", ""))
        cfg_write("qwen/base", d.get("qb", ""))
        restart_backend()
        self.auth_done = False          # 后端重启 → 重走一次自动登录
        GLib.idle_add(lambda: (self.show_loader_and_connect(), False)[1])

    # ---- 关于（极简窗口，对齐 mac：只显 图标/名字/版本/署名，无正文按钮，Esc 或标题栏 × 关闭）----
    def show_about(self):
        w = Gtk.Window(title="关于 iGemini")
        w.set_transient_for(self)
        w.set_modal(True)
        w.set_resizable(False)
        w.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
        w.set_border_width(28)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        w.add(box)
        ico = app_icon_path()
        if ico:
            try:
                box.pack_start(Gtk.Image.new_from_pixbuf(
                    GdkPixbuf.Pixbuf.new_from_file_at_size(ico, 96, 96)), False, False, 0)
            except Exception:
                pass
        name = Gtk.Label()
        name.set_markup('<span size="x-large" weight="bold">iGemini</span>')
        ver = Gtk.Label(label="版本 " + VERSION)
        cr = Gtk.Label()
        cr.set_markup('<span size="small">© 2026 iGemini · CloudCLI（AGPL-3.0）</span>')
        for lbl in (name, ver, cr):
            box.pack_start(lbl, False, False, 0)
        w.connect("key-press-event",
                  lambda _w, e: w.destroy() if e.keyval == Gdk.KEY_Escape else False)
        w.show_all()


if __name__ == "__main__":
    GLib.set_prgname("iGemini")
    GLib.set_application_name("iGemini")
    Shell().show_all()
    Gtk.main()
