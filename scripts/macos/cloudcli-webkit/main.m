// iGemini —— 只跑 CloudCLI(localhost:8888)的原生 WebKit 专用浏览器。
// 用原生 WKWebView(= Safari 同款 CoreAnimation 合成)，规避 Chrome 在弱核显机器上的合成卡顿。
// 交叉编译(arm64 开发机 → x86_64 目标机):
//   xcrun clang -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc main.m \
//     -framework Cocoa -framework WebKit -o iGemini
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSURL *HomeURL(void) { return [NSURL URLWithString:@"http://localhost:8888"]; }

// 本地加载动画页（服务未就绪时显示）：暗底 + 旋转圈 + 本地化文案，纯前端、不联网。
// accent = 旋转圈颜色（正常=蓝；慢速/异常=琥珀）。
static NSString *LoaderHTMLWith(NSString *title, NSString *hint, NSString *accent) {
    NSString *tpl =
      @"<!doctype html><html><head><meta charset='utf-8'>"
      "<meta name='viewport' content='width=device-width,initial-scale=1'>"
      "<style>html,body{height:100%;margin:0}"
      "body{display:flex;flex-direction:column;align-items:center;justify-content:center;"
      "background:hsl(0,0%,8%);color:hsl(40,8%,93%);"
      "font:15px 'Encode Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;"
      "-webkit-user-select:none;user-select:none}"
      ".s{width:38px;height:38px;border-radius:50%;"
      "border:3px solid rgba(255,255,255,.15);border-top-color:__A__;"
      "animation:r .9s linear infinite;margin-bottom:18px}"
      "@keyframes r{to{transform:rotate(360deg)}}"
      ".t{opacity:.92}.h{opacity:.5;font-size:12px;margin-top:7px;max-width:22em;text-align:center;line-height:1.55}</style></head>"
      "<body><div class='s'></div><div class='t'>__T__</div><div class='h'>__H__</div></body></html>";
    tpl = [tpl stringByReplacingOccurrencesOfString:@"__A__" withString:accent];
    tpl = [tpl stringByReplacingOccurrencesOfString:@"__T__" withString:title];
    tpl = [tpl stringByReplacingOccurrencesOfString:@"__H__" withString:hint];
    return tpl;
}
static NSString *LoaderHTML(void) {
    return LoaderHTMLWith(NSLocalizedString(@"loading.title", nil), NSLocalizedString(@"loading.hint", nil), @"hsl(217.2,91.2%,59.8%)");
}
// 轮询超时后的"慢速/异常"提示页（琥珀色）——仍在后台轮询、后端就绪即自动进。
static NSString *SlowHTML(void) {
    return LoaderHTMLWith(NSLocalizedString(@"loading.slow.title", nil), NSLocalizedString(@"loading.slow.hint", nil), @"#e0a44a");
}

// ============ 填 key 表单（壳内 HTML 页；提交经消息回调、由壳【原生】写 ~/.config 的 key 文件）============
static NSString *CfgPath(NSString *rel) {   // rel 形如 @"deepseek/key"
    return [NSHomeDirectory() stringByAppendingPathComponent:[@".config" stringByAppendingPathComponent:rel]];
}
static NSString *ReadCfg(NSString *rel) {
    NSString *s = [NSString stringWithContentsOfFile:CfgPath(rel) encoding:NSUTF8StringEncoding error:nil];
    return s ? [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
}
static void WriteCfg(NSString *rel, NSString *val) {
    NSString *path = CfgPath(rel);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil];       // 目录 0700
    val = val ? [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (val.length == 0) { [fm removeItemAtPath:path error:nil]; return; }  // 选填留空 → 删文件
    [val writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];  // key 文件 0600
}
static NSString *AttrEsc(NSString *s) {   // 注入 value='...' 前转义
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"&#39;"];
    return s;
}
static NSString *KeyFormHTML(NSString *ds, NSString *sp, NSString *qk, NSString *qb) {
    NSString *h =
      @"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
      "<style>*{box-sizing:border-box}html,body{margin:0;height:100%}"
      "body{background:hsl(0,0%,8%);color:hsl(40,8%,93%);"
      "font:14px 'Encode Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;"
      "-webkit-user-select:none;user-select:none;display:flex;justify-content:center;padding:34px 20px;overflow-y:auto}"
      ".card{width:100%;max-width:440px}h1{font-size:19px;font-weight:600;margin:0 0 5px}"
      ".sub{color:hsl(0,0%,60%);font-size:12.5px;margin:0 0 24px}"
      ".f{margin-bottom:18px}.lab{font-weight:600;font-size:13px;margin-bottom:6px}"
      ".tag{font-weight:500;font-size:10.5px;padding:1.5px 8px;border-radius:6px;margin-left:8px;vertical-align:1px}"
      ".req{background:rgba(224,164,74,.16);color:#e0a44a}.opt{background:hsl(0,0%,17%);color:hsl(0,0%,60%)}"
      "input{width:100%;padding:9px 11px;border-radius:8px;border:1px solid hsl(0,0%,23%);background:hsl(0,0%,12%);color:hsl(40,8%,93%);"
      "font:13px ui-monospace,'SF Mono',Menlo,monospace;-webkit-user-select:text;user-select:text}"
      "input:focus{outline:none;border-color:hsl(217.2,91.2%,59.8%)}"
      ".desc{color:hsl(0,0%,55%);font-size:11.5px;margin-top:6px;line-height:1.55}"
      ".desc a{color:hsl(217.2,91.2%,59.8%);text-decoration:none;cursor:pointer}"
      ".bar{display:flex;justify-content:flex-end;gap:10px;margin-top:26px}"
      ".err{display:none;color:#e5484d;font-size:12px;margin-bottom:10px;text-align:right}"
      "button{padding:8px 20px;border-radius:8px;border:1px solid hsl(217.2,91.2%,59.8%);background:hsl(217.2,91.2%,59.8%);color:#fff;font-size:13px;font-weight:500;cursor:pointer}"
      "button.sec{background:hsl(0,0%,17%);border-color:hsl(0,0%,23%);color:hsl(40,8%,93%)}"
      "button:disabled{opacity:.45;cursor:not-allowed}</style></head><body><div class='card'>"
      "<h1>__TITLE__</h1><div class='sub'>__SUB__</div>"
      "<div class='f'><div class='lab'>DeepSeek API Key<span class='tag req'>__REQ__</span></div>"
        "<input id='ds' autocapitalize='off' autocorrect='off' spellcheck='false' value='__DSV__' placeholder='sk-...'>"
        "<div class='desc'>__DSD__ · <a class='ap' data-u='https://platform.deepseek.com/api_keys'>__DSA__</a></div></div>"
      "<div class='f'><div class='lab'>Serper API Key<span class='tag opt'>__OPT__</span></div>"
        "<input id='sp' autocapitalize='off' autocorrect='off' spellcheck='false' value='__SPV__'>"
        "<div class='desc'>__SPD__ · <a class='ap' data-u='https://serper.dev'>__SPA__</a></div></div>"
      "<div class='f'><div class='lab'>Qwen API Key<span class='tag opt'>__OPT__</span></div>"
        "<input id='qk' autocapitalize='off' autocorrect='off' spellcheck='false' value='__QKV__'>"
        "<div class='desc'>__QKD__ · <a class='ap' data-u='https://bailian.console.aliyun.com'>__QKA__</a></div></div>"
      "<div class='f'><div class='lab'>Qwen Base URL<span class='tag opt'>__OPT__</span></div>"
        "<input id='qb' autocapitalize='off' autocorrect='off' spellcheck='false' value='__QBV__' placeholder='https://...'>"
        "<div class='desc'>__QBD__</div></div>"
      "<div id='err' class='err' data-fmt='__ERRMSG__' data-inv='__ERRINV__' data-ver='__VER__' data-sav='__SAVE__'></div>"
      "<div class='bar'><button id='cancel' class='sec'>__CANCEL__</button><button id='save'>__SAVE__</button></div></div>"
      "<script>function O(u){window.webkit.messageHandlers.igopen.postMessage(u)}"
      "document.querySelectorAll('.ap').forEach(function(a){a.onclick=function(){O(a.getAttribute('data-u'))}});"
      "var ds=document.getElementById('ds'),sv=document.getElementById('save');"
      "['ds','sp','qk','qb'].forEach(function(id){var inp=document.getElementById(id);inp.addEventListener('input',function(){var v=inp.value,c=v.replace(/\\s/g,'');if(c!==v){var p=inp.selectionStart-(v.length-c.length);inp.value=c;try{inp.setSelectionRange(p,p)}catch(e){}}});});"
      "function chk(){sv.disabled=ds.value.length===0}ds.addEventListener('input',chk);chk();"
      "var eb=document.getElementById('err'),cb=document.getElementById('cancel');"
      "function D(k){return eb.getAttribute(k)}"
      "function busy(on){sv.disabled=on;cb.disabled=on;sv.textContent=on?D('data-ver'):D('data-sav')}"
      "window.igInvalid=function(){busy(false);eb.textContent=D('data-inv');eb.style.display='block'};"
      "sv.onclick=function(){var k=ds.value.trim();if(k.indexOf('sk-')!==0){eb.textContent=D('data-fmt');eb.style.display='block';ds.focus();return;}eb.style.display='none';busy(true);"
      "window.webkit.messageHandlers.igkeys.postMessage({ds:k,sp:document.getElementById('sp').value.trim(),qk:document.getElementById('qk').value.trim(),qb:document.getElementById('qb').value.trim()})};"
      "document.getElementById('cancel').onclick=function(){window.webkit.messageHandlers.igkeys.postMessage({cancel:1})};"
      "ds.focus()</script></body></html>";
    NSDictionary *r = @{@"__TITLE__":NSLocalizedString(@"keyform.title",nil), @"__SUB__":NSLocalizedString(@"keyform.sub",nil),
      @"__REQ__":NSLocalizedString(@"keyform.required",nil), @"__OPT__":NSLocalizedString(@"keyform.optional",nil), @"__SAVE__":NSLocalizedString(@"keyform.save",nil),
      @"__DSD__":NSLocalizedString(@"keyform.ds.desc",nil), @"__DSA__":NSLocalizedString(@"keyform.ds.apply",nil),
      @"__SPD__":NSLocalizedString(@"keyform.sp.desc",nil), @"__SPA__":NSLocalizedString(@"keyform.sp.apply",nil),
      @"__QKD__":NSLocalizedString(@"keyform.qk.desc",nil), @"__QKA__":NSLocalizedString(@"keyform.qk.apply",nil),
      @"__QBD__":NSLocalizedString(@"keyform.qb.desc",nil), @"__CANCEL__":NSLocalizedString(@"keyform.cancel",nil),
      @"__ERRMSG__":AttrEsc(NSLocalizedString(@"keyform.err.ds",nil)), @"__ERRINV__":AttrEsc(NSLocalizedString(@"keyform.err.invalid",nil)), @"__VER__":AttrEsc(NSLocalizedString(@"keyform.verifying",nil)),
      @"__DSV__":AttrEsc(ds), @"__SPV__":AttrEsc(sp), @"__QKV__":AttrEsc(qk), @"__QBV__":AttrEsc(qb)};
    for (NSString *k in r) h = [h stringByReplacingOccurrencesOfString:k withString:r[k]];
    return h;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler>
@property (strong) NSWindow *window;
@property (strong) WKWebView *webView;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMutableSet *downloads;
@property (assign) BOOL pageReady;    // 真正页面是否已就绪载入（用于加载动画/轮询状态机）
@property (assign) int  pollCount;    // 轮询累计次数（超时后切"慢速/异常"提示页）
@property (assign) BOOL formShowing;  // 正在显示填 key 表单（抑制轮询/失败页覆盖）
@property (strong) WKUserContentController *ucc;  // 保留引用，用于注入登录 token 脚本
@property (assign) BOOL authDone;     // 已自动登录并注入 token（本次进程内只做一次）
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.downloads = [NSMutableSet set];
    NSRect frame = NSMakeRect(0, 0, 1280, 820);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    [self.window setTitle:@"iGemini"];
    [self.window center];
    [self.window setFrameAutosaveName:@"iGeminiMain"];
    self.window.delegate = self;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];

    // 兼容垫片：Monterey 上 WKWebView 用的系统 WebKit(17613,~Safari16.3)比 Safari 自带的(17618)旧，
    // 不支持正则 lookbehind。CloudCLI 的 GFM 邮箱自动链接在运行时构造 new RegExp("(?<=...)...") 会抛 SyntaxError，
    // 导致聊天界面崩。这里包装 RegExp：正常用原生行为，仅当构造失败时去掉 lookbehind 重试(捕获组序号不变)。
    NSString *shim =
      @"(function(){var O=window.RegExp;"
      "function strip(p){return p.replace(/\\(\\?<[=!](?:[^()\\\\]|\\\\.|\\([^()]*\\))*\\)/g,'');}"
      "function R(p,f){if(p instanceof O&&f===undefined){return new O(p);}"
      "try{return f===undefined?new O(p):new O(p,f);}catch(e){"
      "try{var q=(typeof p==='string')?strip(p):p;return f===undefined?new O(q):new O(q,f);}"
      "catch(e2){return f===undefined?new O('(?!)'):new O('(?!)',f);}}}"
      "R.prototype=O.prototype;"
      "try{Object.getOwnPropertyNames(O).forEach(function(k){try{if(!(k in R))R[k]=O[k];}catch(_){}});}catch(_){}"
      "window.RegExp=R;})();";
    WKUserScript *u1 = [[WKUserScript alloc] initWithSource:shim injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [ucc addUserScript:u1];

    // IME 守卫：WebKit(Safari/WKWebView)用回车“确认合成”时，事件顺序与 Chrome 相反——先 compositionend
    // (isComposing 已变 false)、再 keydown，但该 keydown 的 keyCode 仍是 229(IME 处理码)。页面(CloudCLI)
    // 只判 isComposing 会漏过 → 首次回车就误提交。这里在捕获阶段拦下这种回车、阻止其冒泡到页面的提交处理，
    // 但不 preventDefault(合成照常确认)。效果：首次回车只确认合成、再次回车才提交，对齐 Chrome。
    // 纯 app 侧注入，不改 CloudCLI 源码。
    NSString *imeGuard =
      @"(function(){window.addEventListener('keydown',function(e){"
      "if(e.key==='Enter'&&(e.isComposing||e.keyCode===229||e.which===229)){e.stopImmediatePropagation();}"
      "},true);})();";
    WKUserScript *u2 = [[WKUserScript alloc] initWithSource:imeGuard injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [ucc addUserScript:u2];

    // 填 key 表单的消息回调：igkeys=提交 key（壳原生写文件）、igopen=打开"去申请"链接
    [ucc addScriptMessageHandler:self name:@"igkeys"];
    [ucc addScriptMessageHandler:self name:@"igopen"];
    self.ucc = ucc;   // 保留引用：自动登录拿到 token 后往里加注入脚本

    cfg.userContentController = ucc;

    self.webView = [[WKWebView alloc] initWithFrame:[self.window.contentView bounds] configuration:cfg];
    [self.webView setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    [self.window.contentView addSubview:self.webView];
    if (ReadCfg(@"deepseek/key").length == 0)
        [self showKeyForm:nil];        // 首次无 key → 直接弹填 key 窗（顶替旧的 tkinter 首运行表单）
    else
        [self showLoaderAndConnect];   // 有 key → 显示加载动画并轮询，服务就绪后自动载入
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // 顶部菜单栏右侧常驻入口图标(Siri 风格)
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *appIcon = [NSApp applicationIconImage];
    if (appIcon) {
        NSImage *small = [appIcon copy];
        [small setSize:NSMakeSize(18, 18)];
        [small setTemplate:NO];
        self.statusItem.button.image = small;
    } else {
        self.statusItem.button.title = @"iG";
    }
    self.statusItem.button.toolTip = @"iGemini";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusClicked:);
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp)];
}

- (void)statusClicked:(id)sender {
    NSEvent *e = [NSApp currentEvent];
    BOOL rightish = e && (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl));
    if (rightish) {
        NSMenu *m = [[NSMenu alloc] init];
        [[m addItemWithTitle:NSLocalizedString(@"menu.show", nil) action:@selector(showMain:) keyEquivalent:@""] setTarget:self];
        [[m addItemWithTitle:NSLocalizedString(@"menu.reload", nil) action:@selector(reloadWeb:) keyEquivalent:@""] setTarget:self];
        [m addItem:[NSMenuItem separatorItem]];
        [m addItemWithTitle:NSLocalizedString(@"menu.quit", nil) action:@selector(terminate:) keyEquivalent:@"q"];
        self.statusItem.menu = m;
        [self.statusItem.button performClick:nil];
        self.statusItem.menu = nil;
    } else {
        [self showMain:sender];
    }
}
- (void)showMain:(id)sender { [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)reloadWeb:(id)sender { if (self.pageReady) [self.webView reload]; else [self showLoaderAndConnect]; }

// —— 缩放（⌘+ / ⌘- / ⌘0，浏览器风格；比例记入 UserDefaults，下次启动保持）——
- (void)applyZoom:(CGFloat)z {
    if (z < 0.5) z = 0.5;
    if (z > 3.0) z = 3.0;
    self.webView.pageZoom = z;
    [[NSUserDefaults standardUserDefaults] setDouble:z forKey:@"pageZoom"];
}
- (void)zoomIn:(id)sender    { [self applyZoom:self.webView.pageZoom * 1.1]; }
- (void)zoomOut:(id)sender   { [self applyZoom:self.webView.pageZoom / 1.1]; }
- (void)zoomReset:(id)sender { [self applyZoom:1.0]; }

// —— 填 key 表单：显示（各框预填当前值）——
- (void)showKeyForm:(id)sender {
    self.formShowing = YES;
    NSString *html = KeyFormHTML(ReadCfg(@"deepseek/key"), ReadCfg(@"deepseek/serper_key"),
                                 ReadCfg(@"qwen/key"), ReadCfg(@"qwen/base"));
    [self.webView loadHTMLString:html baseURL:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
// 写完 key 后重启后端（让 start-web.sh 重读 ~/.config/deepseek/*）
- (void)restartBackend {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/launchctl";
    t.arguments = @[@"kickstart", @"-k", [NSString stringWithFormat:@"gui/%u/com.igemini.web", getuid()]];
    @try { [t launch]; } @catch (NSException *e) {}
}
// 联网实测 DeepSeek key：GET /user/balance —— 401/403=key 无效(打回)，200/网络错/其它=放行(best-effort)。
// 用便宜的只读端点、不跑 completion；只验必填的 DeepSeek，Serper/Qwen 不拦。
- (void)validateThenSave:(NSDictionary *)b {
    NSString *key = [b[@"ds"] isKindOfClass:[NSString class]] ? b[@"ds"] : @"";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.deepseek.com/user/balance"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    __weak typeof(self) ws = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self = ws; if (!self) return;
            NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            if (code == 401 || code == 403) {   // 明确的鉴权失败 → key 无效，通知表单、不写
                [self.webView evaluateJavaScript:@"window.igInvalid&&window.igInvalid()" completionHandler:nil];
                return;
            }
            [self writeKeysAndEnter:b];          // 200 或 网络错/超时/其它 → 放行
        });
    }] resume];
}
- (void)writeKeysAndEnter:(NSDictionary *)b {
    WriteCfg(@"deepseek/key",        b[@"ds"]);   // 必填
    WriteCfg(@"deepseek/serper_key", b[@"sp"]);   // 选填留空即删
    WriteCfg(@"qwen/key",            b[@"qk"]);
    WriteCfg(@"qwen/base",           b[@"qb"]);
    [self restartBackend];
    self.formShowing = NO;
    [self showLoaderAndConnect];   // 回加载页轮询 → 后端重启就绪后自动进聊天
}
// 表单提交(igkeys) / 去申请链接(igopen) 的消息回调
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    if ([msg.name isEqualToString:@"igopen"]) {
        NSString *u = [msg.body isKindOfClass:[NSString class]] ? msg.body : nil;
        if (u.length) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
        return;
    }
    if ([msg.name isEqualToString:@"igkeys"]) {
        NSDictionary *b = [msg.body isKindOfClass:[NSDictionary class]] ? msg.body : nil;
        if (!b) return;
        if (b[@"cancel"]) { self.formShowing = NO; [self showLoaderAndConnect]; return; }  // 取消：不写、回聊天
        [self validateThenSave:b];    // 先联网验 DeepSeek key（401 打回、其它放行）→ 通过才写
    }
}

// 显示加载动画并开始轮询本地服务（8888）是否就绪。
- (void)showLoaderAndConnect {
    self.pageReady = NO;
    self.pollCount = 0;
    [self.webView loadHTMLString:LoaderHTML() baseURL:nil];
    [self pollServer];
}

// 轻量探测：GET http://localhost:8888。拿到任意 HTTP 响应=服务在听→载入真正页面；
// 连接被拒/超时→0.8s 后再探，直到就绪。纯本地、不影响别处。
- (void)pollServer {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:HomeURL()
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    req.HTTPMethod = @"GET";
    __weak typeof(self) ws = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self = ws; if (!self || self.pageReady) return;
            if (resp && !err) {
                self.pageReady = YES;
                [self ensureAuthThenLoad];   // 先自动登录（注入 token）再加载聊天页 —— 免掉 claudecodeui 登录页
            } else {
                self.pollCount++;
                if (self.pollCount == 25) [self.webView loadHTMLString:SlowHTML() baseURL:nil]; // ~20s 仍未就绪 → 切慢速提示页（后台继续轮询、后端一起来就进）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        __strong typeof(ws) s2 = ws; if (s2 && !s2.pageReady) [s2 pollServer];
                    });
            }
        });
    }];
    [task resume];
}

// 拿到 token 后：注入 localStorage(前端认为已登录) + 加载聊天页。token 为空则直接加载(回退到手动登录)。
- (void)finishAuthWithToken:(NSString *)token {
    if (token.length) {
        NSString *js = [NSString stringWithFormat:@"try{localStorage.setItem('auth-token','%@')}catch(e){}", token];
        [self.ucc addUserScript:[[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        self.authDone = YES;
    }
    [self.webView loadRequest:[NSURLRequest requestWithURL:HomeURL()]];
}

// 自动登录固定账号 iGemini/iGemini（用 claudecodeui 自带 register/login 接口）→ 拿 token 注入 localStorage →
// 前端认为已登录、免掉登录/注册页；顺手标记首次引导(Git 配置/Connect Agents)完成，直接进聊天。
// 整进程只做一次；登录失败(如机器上已有别的账号)则直接加载、回退到手动登录。
- (void)ensureAuthThenLoad {
    if (self.authDone) { [self.webView loadRequest:[NSURLRequest requestWithURL:HomeURL()]]; return; }
    NSString *base = @"http://localhost:8888/api/auth";
    __weak typeof(self) ws = self;
    NSMutableURLRequest *sreq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/status"]]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:sreq completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        BOOL needsSetup = NO;
        if (d) { id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                 if ([j isKindOfClass:[NSDictionary class]]) needsSetup = [j[@"needsSetup"] boolValue]; }
        NSString *path = needsSetup ? @"/register" : @"/login";
        NSMutableURLRequest *areq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
        areq.HTTPMethod = @"POST";
        [areq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        areq.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"username":@"iGemini",@"password":@"iGemini"} options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:areq completionHandler:^(NSData *d2, NSURLResponse *resp2, NSError *err2) {
            NSString *token = nil;
            if (d2) { id j2 = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
                      if ([j2 isKindOfClass:[NSDictionary class]] && [j2[@"token"] isKindOfClass:[NSString class]]) token = j2[@"token"]; }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ws) self = ws; if (!self) return;
                if (!token.length) { [self finishAuthWithToken:nil]; return; }   // 登录失败 → 回退加载(前端可能显示登录页)
                // 已登录 → 顺手标记首次引导(Git 配置/Connect Agents)完成，再进聊天
                NSMutableURLRequest *oreq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost:8888/api/user/complete-onboarding"]
                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
                oreq.HTTPMethod = @"POST";
                [oreq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
                [[[NSURLSession sharedSession] dataTaskWithRequest:oreq completionHandler:^(NSData *d3, NSURLResponse *r3, NSError *e3) {
                    dispatch_async(dispatch_get_main_queue(), ^{ __strong typeof(ws) s2 = ws; if (s2) [s2 finishAuthWithToken:token]; });
                }] resume];
            });
        }] resume];
    }] resume];
}

// 关窗口=隐藏而非退出，菜单栏图标随时唤回(保留登录/页面)
- (BOOL)windowShouldClose:(NSWindow *)sender { [sender orderOut:nil]; return NO; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return NO; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag { [self showMain:nil]; return YES; }

// 外部链接(非 localhost)用系统默认浏览器打开
- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (action.shouldPerformDownload) { decisionHandler(WKNavigationActionPolicyDownload); return; }
    NSURL *url = action.request.URL; NSString *host = url.host;
    if (host && ![host isEqualToString:@"localhost"] && ![host isEqualToString:@"127.0.0.1"]) {
        [[NSWorkspace sharedWorkspace] openURL:url]; decisionHandler(WKNavigationActionPolicyCancel); return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

// 真正页面加载失败（如服务中途不可用）→ 回到加载动画并重新轮询，绝不露出 WebKit 的连接失败页。
- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    if (self.formShowing) return;
    if (self.pageReady) { self.pageReady = NO; [self showLoaderAndConnect]; }
}
- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    if (self.formShowing) return;
    if (self.pageReady) { self.pageReady = NO; [self showLoaderAndConnect]; }
}
// 页面载入完成后恢复上次缩放比例（pageZoom 是 webView 级属性，跨导航本应保留，这里兜底确保生效）
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
    double z = [[NSUserDefaults standardUserDefaults] doubleForKey:@"pageZoom"];
    if (z > 0.01 && wv.pageZoom != (CGFloat)z) wv.pageZoom = (CGFloat)z;
}

// 下载（如「文件」标签的 Download 按钮触发的 blob <a download>）→ 转成 WKDownload，弹「另存为」选目录。
- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download {
    download.delegate = self; [self.downloads addObject:download];
}
- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download {
    download.delegate = self; [self.downloads addObject:download];
}
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response
    suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL *destination))completionHandler {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = suggestedFilename.length ? suggestedFilename : @"download";
    panel.canCreateDirectories = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [[NSFileManager defaultManager] removeItemAtURL:panel.URL error:nil]; // NSSavePanel 已确认覆盖
            completionHandler(panel.URL);
        } else {
            completionHandler(nil);
        }
    }];
}
- (void)downloadDidFinish:(WKDownload *)download { [self.downloads removeObject:download]; }
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData { [self.downloads removeObject:download]; }

// 网页 <input type="file">（如附加图片）→ 弹出 Finder 选择框。极简壳默认没实现此 WKUIDelegate 方法，
// 导致点“附加”无反应；这里用 NSOpenPanel 补上（Safari 内置了等价逻辑）。
- (void)webView:(WKWebView *)wv runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
   initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = parameters.allowsDirectories;
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : nil);
    }];
}

// 关于 iGemini：原生标准“关于”面板，只显 图标/名字/版本/署名——不放副标题标语(废话)。
// 版本号从 Info.plist(CFBundleShortVersionString) 读 → 与 VERSION 文件 / 包名同源；
// "Version"=@"" 去掉版本号后那对"(构建号)"括号；署名走 Info.plist 的 NSHumanReadableCopyright。
- (void)showAbout:(id)sender {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{ @"ApplicationVersion": ver, @"Version": @"" }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *appItem = [[NSMenuItem alloc] init]; [mainMenu addItem:appItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        NSMenuItem *ab = [appMenu addItemWithTitle:NSLocalizedString(@"menu.about", nil) action:@selector(showAbout:) keyEquivalent:@""]; [ab setTarget:delegate];
        [appMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *r = [appMenu addItemWithTitle:NSLocalizedString(@"menu.reload", nil) action:@selector(reloadWeb:) keyEquivalent:@"r"]; [r setTarget:delegate];
        NSMenuItem *ek = [appMenu addItemWithTitle:NSLocalizedString(@"menu.editKey", nil) action:@selector(showKeyForm:) keyEquivalent:@""]; [ek setTarget:delegate];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:NSLocalizedString(@"menu.quit", nil) action:@selector(terminate:) keyEquivalent:@"q"];
        [appItem setSubmenu:appMenu];

        // 编辑菜单：标准“第一响应者动作”(剪切/复制/粘贴/纯文本粘贴/全选/撤销/重做)。
        // macOS 的 ⌘C/⌘V 不是 WebView 自己监听键盘，而是靠编辑菜单项的快捷键触发 copy:/paste:
        // 等动作、经响应链送到聚焦的 WKWebView。极简壳缺了这个菜单 → 之前 ⌘C/⌘V 全部失效。
        // 这些项 target=nil(默认)→ 走第一响应者；WKWebView 不响应的项会自动置灰，无害。
        NSMenuItem *editItem = [[NSMenuItem alloc] init]; [mainMenu addItem:editItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.edit", nil)];
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.undo", nil) action:@selector(undo:) keyEquivalent:@"z"];
        NSMenuItem *redo = [editMenu addItemWithTitle:NSLocalizedString(@"menu.redo", nil) action:@selector(redo:) keyEquivalent:@"z"];
        redo.keyEquivalentModifierMask = (NSEventModifierFlagCommand|NSEventModifierFlagShift);
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.cut", nil) action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.copy", nil) action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.paste", nil) action:@selector(paste:) keyEquivalent:@"v"];
        NSMenuItem *pasteMatch = [editMenu addItemWithTitle:NSLocalizedString(@"menu.pasteMatch", nil) action:@selector(pasteAsPlainText:) keyEquivalent:@"v"];
        pasteMatch.keyEquivalentModifierMask = (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagShift);
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.delete", nil) action:@selector(delete:) keyEquivalent:@""];
        [editMenu addItemWithTitle:NSLocalizedString(@"menu.selectAll", nil) action:@selector(selectAll:) keyEquivalent:@"a"];
        [editItem setSubmenu:editMenu];

        // 视图菜单：缩放（⌘+ / ⌘- / ⌘0，浏览器风格）。target=delegate。
        NSMenuItem *viewItem = [[NSMenuItem alloc] init]; [mainMenu addItem:viewItem];
        NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.view", nil)];
        NSMenuItem *zi = [viewMenu addItemWithTitle:NSLocalizedString(@"menu.zoomIn", nil) action:@selector(zoomIn:) keyEquivalent:@"+"]; [zi setTarget:delegate];
        NSMenuItem *zo = [viewMenu addItemWithTitle:NSLocalizedString(@"menu.zoomOut", nil) action:@selector(zoomOut:) keyEquivalent:@"-"]; [zo setTarget:delegate];
        NSMenuItem *za = [viewMenu addItemWithTitle:NSLocalizedString(@"menu.zoomReset", nil) action:@selector(zoomReset:) keyEquivalent:@"0"]; [za setTarget:delegate];
        [viewItem setSubmenu:viewMenu];

        [app setMainMenu:mainMenu];
        [app run];
    }
    return 0;
}
