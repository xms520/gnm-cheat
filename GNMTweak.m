// GNMTweak.m — 恐怖奶奶迷雾 1.0.10 (com.muwu.nainai) 悬浮助手
// 引擎：LayaAir Native（Conch 2.1.3.1）+ WebGL，游戏逻辑在 DCC 缓存里的 js/bundle.js（明文）
//
// 逆向实证：
//   主二进制 Granny 18.6MB arm64，ObjC 类 conchRuntime 提供 JS 求值入口
//     -[conchRuntime runJS:]        0x10014493c  （NSString → JS 全局上下文求值）
//     -[conchRuntime renderFrame]   0x10014239c  （每帧渲染）
//     -[conchRuntime runJsLoop]     0x100143924  （JS 每帧泵）
//     -[conchRuntime onVsync:]      0x1001423c4
//   广告（穿山甲 CSJ + 优量汇）native 侧：AppDelegate.showKaiping/showHenfu/showInter/
//     loadReward/loadAndShowReward；JS 桥 JSBridge.showInter: / initThirdSDK:
//   DCC 缓存：Library/Caches/LayaCache/appCache/stand.alone.version/，文件名 = crc32(路径)
//     索引 cache/stand.alone.version/{allfiles.txt,filetable.txt}
//   游戏逻辑：js/bundle.js（IIFE，1.02MB 明文）内含 SceneMgr / PropMgr / MainRoleMgr / iOSDeal / SDK
//   奶奶节点：SceneMgr.GetKbnnScript().owner（kbnn_nainai，SkinnedMeshSprite3D ×3）
//   透视原理：Laya 材质 depthTest = RenderState.DEPTHTEST_ALWAYS(0x207) 关闭深度裁剪 → 穿墙可见
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

#pragma mark - 日志
static FILE *g_log = NULL;
static void mlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void mlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GNM] %@", s);
    if (!g_log) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gnm.log"];
        g_log = fopen(p.UTF8String, "a");
    }
    if (g_log) { fprintf(g_log, "[GNM] %s\n", s.UTF8String); fflush(g_log); }
}

#pragma mark - 状态
static int g_esp = 0;       // 0=关 1=透视奶奶 2=+道具
static int g_bright = 0;    // 亮度/去黑
static int g_ad = 1;        // 1=免广告
static NSString *g_jsCachePath = nil;
static BOOL g_probeSeen = NO;
static int g_frame = 0;
static BOOL g_bootPushed = NO;

static void gnm_sync_flags(void) {
    NSString *json = [NSString stringWithFormat:
        @"{\"esp\":%d,\"bright\":%d,\"ad\":%d}", g_esp, g_bright, g_ad];
    NSString *home = NSHomeDirectory();
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:
        [home stringByAppendingPathComponent:@"Documents"], nil];
    if (g_jsCachePath) { [dirs addObject:g_jsCachePath]; }
    for (NSString *d in dirs) {
        [json writeToFile:[d stringByAppendingPathComponent:@"gnm_flags.json"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 读取 JS 探针（gnm_probe.txt），拿到真实 cachePath（供日志/配置落盘）
static void gnm_scan_probe(void) {
    if (g_probeSeen) { return; }
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]];
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:@"gnm_probe.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!s) { continue; }
        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"cachePath="]) {
                NSString *cp = [line substringFromIndex:10];
                if (cp.length) { g_jsCachePath = cp; mlog(@"js probe cachePath=%@", cp); }
            }
        }
        g_probeSeen = YES;
        gnm_sync_flags();
        return;
    }
}

#pragma mark - JS 源码（由 gen.py 注入，JSON/ObjC 双重转义已校验）
static NSString *const kBootJS =
    @"/*\n * boot.js —— 在 LayaNative Conch 全局上下文中执行（由 dylib 经 [conchRuntime runJS:] 注入）\n * 职责：\n *   1) 建立日志/探针文件通道（写 conch.getCachePath()）\n *   2) wrap window.loadLib —— 当加载 js/bundle.js 时读出源码，在 IIFE 内部插入 hook 源码后 eval\n *   3) 兜底：若 wrap 失败，记录原因\n */\n(function () {\n    var W = window;\n    if (W.__GNM_BOOT) { return; }\n    W.__GNM_BOOT = true;\n\n    /* ---------------- 日志（内存环形 + 落盘） -----"
    @"----------- */\n    var LINES = [];\n    function cachePath() {\n        var c = null;\n        try { c = conch.getCachePath(); } catch (e) { }\n        if (!c) { try { c = conchConfig.getCachePath(); } catch (e) { } }\n        return c;\n    }\n    function writeAll() {\n        var txt = LINES.join('\\u000A');\n        var cps = [];\n        try { var c = cachePath(); if (c) { cps.push(c"
    @"); } } catch (e) { }\n        cps.push('');                                   /* cwd 相对路径 */\n        var ok = 0;\n        for (var i = 0; i < cps.length; i++) {\n            var p = cps[i] ? (cps[i] + '/gnm_js.log') : 'gnm_js.log';\n            try { fs_writeFileSync(p, txt); ok++; } catch (e) { }\n        }\n        return ok;\n    }\n    W.__GNM_LOG = function (m) {\n        try {\n   "
    @"         LINES.push('[' + (new Date()).getTime() + '] ' + m);\n            if (LINES.length > 400) { LINES.splice(0, LINES.length - 400); }\n            writeAll();\n        } catch (e) { }\n    };\n    function L(m) { try { W.__GNM_LOG(m); } catch (e) { } }\n\n    /* ---------------- 探针（把 cache 路径告诉 native） ---------------- */\n    function probe() {\n        try {\n            var c = "
    @"cachePath() || '';\n            var s = 'cachePath=' + c + '\\u000A' +\n                'exePath=' + (function () { try { return getExePath(); } catch (e) { return '?'; } })() + '\\u000A' +\n                'fs_readFileSync=' + (typeof fs_readFileSync) + '\\u000A' +\n                'fs_writeFileSync=' + (typeof fs_writeFileSync) + '\\u000A' +\n                'readFileSync=' + (typeof "
    @"readFileSync) + '\\u000A' +\n                'appcache=' + (typeof W.appcache) + '\\u000A' +\n                'conch=' + (typeof conch);\n            var paths = [];\n            if (c) { paths.push(c + '/gnm_probe.txt'); }\n            paths.push('gnm_probe.txt');\n            for (var i = 0; i < paths.length; i++) {\n                try { fs_writeFileSync(paths[i], s); } catch (e) { }"
    @"\n            }\n            return c;\n        } catch (e) { return ''; }\n    }\n\n    /* ---------------- 读取 DCC 资源 ---------------- */\n    function toStr(buf) {\n        if (buf == null) { return null; }\n        if (typeof buf === 'string') { return buf; }\n        try {\n            var u8 = new Uint8Array(buf);\n            var out = '';\n            for (var i = 0; i < u8.length; i"
    @" += 8192) {\n                out += String.fromCharCode.apply(null, u8.subarray(i, i + 8192));\n            }\n            return out;\n        } catch (e) { return null; }\n    }\n    function READ(url) {\n        var u = '' + url;\n        var base = u.substring(u.lastIndexOf('/') + 1);\n        var cands = [u, '/' + base, base];\n        var i, s;\n        /* 1) AppCache（native DCC 虚拟路"
    @"径，最正确） */\n        try {\n            var ac = W.appcache;\n            if (ac && typeof ac.loadCachedURL === 'function') {\n                for (i = 0; i < cands.length; i++) {\n                    s = toStr(ac.loadCachedURL(cands[i]));\n                    if (s && s.length > 10000) { L('read via appcache ' + cands[i]); return s; }\n                }\n            }\n        } catch (e"
    @") { }\n        /* 2) readFileSync / fs_readFileSync / readFile */\n        var fns = [];\n        try { if (typeof readFileSync === 'function') { fns.push(readFileSync); } } catch (e) { }\n        try { if (typeof fs_readFileSync === 'function') { fns.push(fs_readFileSync); } } catch (e) { }\n        try { if (typeof readFile === 'function') { fns.push(readFile); } } catch (e) { }\n "
    @"       for (var k = 0; k < fns.length; k++) {\n            for (i = 0; i < cands.length; i++) {\n                try {\n                    s = k === 0 ? toStr(fns[k](cands[i], 'utf8')) : toStr(fns[k](cands[i]));\n                    if (s && s.length > 10000) { L('read via fn#' + k + ' ' + cands[i]); return s; }\n                } catch (e) { }\n            }\n        }\n        retur"
    @"n null;\n    }\n\n    /* ---------------- wrap loadLib ---------------- */\n    function install() {\n        var _loadLib = W.loadLib;\n        if (typeof _loadLib !== 'function') { return false; }\n        if (W.__GNM_LIBW) { return true; }\n        W.__GNM_LIBW = true;\n        W.loadLib = function (url) {\n            try {\n                if (url && ('' + url).indexOf('bundle.js') >"
    @"= 0) {\n                    var src = READ(url);\n                    if (src && src.length > 100000) {\n                        var idx = src.lastIndexOf('}());');\n                        if (idx < 0) { idx = src.length; }\n                        var out = src.substring(0, idx) + '\\u000A' + W.__GNM_HOOK_SRC + '\\u000A' + src.substring(idx);\n                        L('bundle instru"
    @"mented len=' + src.length);\n                        W.eval(out + '\\u000A//@ sourceURL=' + url);\n                        return;\n                    }\n                    L('bundle read FAILED url=' + url);\n                }\n            } catch (e) {\n                L('loadLib wrap err ' + e);\n            }\n            return _loadLib.apply(this, arguments);\n        };\n        L"
    @"('loadLib wrapped');\n        return true;\n    }\n\n    var cp = probe();\n    L('boot v1 cachePath=' + cp);\n    if (!install()) {\n        L('loadLib missing -> retry');\n        var n = 0;\n        var t = setInterval(function () {\n            n++;\n            if (install() || n > 60) { clearInterval(t); if (n > 60) { L('loadLib never appeared'); } }\n        }, 100);\n    }\n\n    /* 定"
    @"时刷新探针（cachePath 可能晚一点才可用） */\n    setInterval(function () { probe(); writeAll(); }, 5000);\n})();\n";
static NSString *const kHookJSON =
    @"window.__GNM_HOOK_SRC = \"/*\\n * hook.js —— 注入 js/bundle.js 的 IIFE 内部执行\\n * 可访问 bundle 内 SceneMgr / PropMgr / MainRoleMgr / Role / iOSDeal / SDK / SDK_ORDER / Laya\\n * 开关由 native 经 [conchRuntime runJS:] 推送到 window.__GNM_CFG\\n */\\n(function () {\\n    var W = window;\\n    var CFG = W.__GNM_CFG = W.__GNM_CFG || { esp: 0, bright: 0, ad: 1 };\\n    function log(m) { try { if (W.__GNM_"
    @"LOG) { W.__GNM_LOG('[hook] ' + m); } } catch (e) { } }\\n    var L = (typeof Laya !== 'undefined' && Laya) ? Laya : W.Laya;\\n    if (!L) { log('Laya missing, hook abort'); return; }\\n    if (W.__GNM_HOOK_INSTALLED) { log('hook re-entered (cfg esp=' + CFG.esp + ' bright=' + CFG.bright + ')'); return; }\\n    W.__GNM_HOOK_INSTALLED = 1;\\n    log('hook v1 enter');\\n\\n    /* ========"
    @"========= 广告拦截（JS 层，游戏 SDK 分发的唯一入口） ================= */\\n    try {\\n        if (typeof iOSDeal !== 'undefined' && iOSDeal) {\\n            var _video = iOSDeal.prototype.videoChange;\\n            /* 看视频得奖励：不弹广告，但仍走正规回调链发奖（HANDLER_RUN type=true） */\\n            iOSDeal.prototype.videoChange = function (data) {\\n                if (!CFG.ad) { return _video.apply(this, arguments);"
    @" }\\n                log('reward video skipped -> auto ok');\\n                setTimeout(function () {\\n                    try { SDK.ins_.send(SDK_ORDER.AD_VIDEO_CLOSE, { name: 'iOS', info: 'ok' }); } catch (e) { log('ad cb err ' + e); }\\n                }, 60);\\n            };\\n            var _noop = function () { };\\n            iOSDeal.prototype.insertChange = function (d) "
    @"{ if (CFG.ad) { log('insert ad blocked'); return; } return Object.getPrototypeOf(this).insertChange; };\\n            iOSDeal.prototype.bannerChange = function (d) { if (CFG.ad) { return; } };\\n            iOSDeal.prototype.impactionChange = function (d) { if (CFG.ad) { return; } };\\n            iOSDeal.prototype.nativeSmallChange = function (d) { if (CFG.ad) { return; } };\\n   "
    @"         iOSDeal.prototype.changeFoundAward = function (d) { if (CFG.ad) { return; } };\\n            log('iOSDeal ad hooks installed');\\n        } else {\\n            log('iOSDeal not found');\\n        }\\n    } catch (e) { log('ad hook err ' + e); }\\n\\n    /* ================= 3D 节点工具 ================= */\\n    function rend(n) {\\n        if (!n) { return null; }\\n        try { "
    @"if (n.skinnedMeshRenderer) { return n.skinnedMeshRenderer; } } catch (e) { }\\n        try { if (n.meshRenderer) { return n.meshRenderer; } } catch (e) { }\\n        return null;\\n    }\\n    function setP(o, k, v) { try { o[k] = v; return 1; } catch (e) { return 0; } }\\n    function collect(root, cap) {\\n        var out = [];\\n        if (!root) { return out; }\\n        var st = "
    @"[root], g = 0;\\n        while (st.length && g++ < (cap || 40000)) {\\n            var c = st.pop();\\n            if (rend(c)) { out.push(c); }\\n            try {\\n                var n = c.numChildren | 0;\\n                for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\\n            } catch (e) { }\\n        }\\n        return out;\\n    }\\n\\n    "
    @"/* 全亮：关光照 / 去 lightmap / 白化 */\\n    function brightNode(n) {\\n        var r = rend(n); if (!r) { return; }\\n        var m = null;\\n        try { m = r.sharedMaterial; } catch (e) { }\\n        if (!m) { return; }\\n        try { if (m.albedoColor) { m.albedoColor = new L.Vector4(1, 1, 1, 1); } } catch (e) { }\\n        setP(m, 'enableLighting', false);\\n        setP(r, 'lightmapIn"
    @"dex', -1);\\n        setP(r, 'lightmapScaleOffset', null);\\n    }\\n\\n    /* 透视：depthTest=ALWAYS + 淡红染色（实例材质，不污染共享材质） */\\n    var C_ESP = null, C_WHITE = null;\\n    function espNode(n, on) {\\n        var r = rend(n); if (!r) { return; }\\n        var m = null;\\n        try { m = r.material; } catch (e) { }\\n        if (!m) { return; }\\n        if (!C_ESP) { C_ESP = new L.Vector4(1"
    @".0, 0.25, 0.25, 1.0); C_WHITE = new L.Vector4(1, 1, 1, 1); }\\n        if (on) {\\n            setP(m, 'depthTest', 0x0207);   /* DEPTHTEST_ALWAYS */\\n            setP(m, 'depthWrite', false);\\n            setP(m, 'renderQueue', 3000);   /* TRANSPARENT */\\n            try { m.enableLighting = false; } catch (e) { }\\n            try { if (m.albedoColor) { m.albedoColor = C_ESP; } "
    @"} catch (e) { }\\n        } else {\\n            setP(m, 'depthTest', 0x0201);   /* DEPTHTEST_LESS */\\n            setP(m, 'depthWrite', true);\\n            setP(m, 'renderQueue', 2000);   /* OPAQUE */\\n            try { if (m.albedoColor) { m.albedoColor = C_WHITE; } } catch (e) { }\\n        }\\n    }\\n\\n    /* ================= 状态机 ================= */\\n    var sScene = null, sS"
    @"ceneNodes = null, sSceneDone = 0;\\n    var sOwner = null, sOwnerNodes = null;\\n    var sPropNodes = null, sPropSig = '';\\n    var sTicks = 0, sLastProp = 0;\\n\\n    function propNodes() {\\n        var out = [];\\n        try {\\n            var vals = PropMgr.Inst.dic_Prop.values;\\n            for (var i = 0; vals && i < vals.length; i++) {\\n                var p = vals[i];\\n     "
    @"           if (!p || !p.propArr) { continue; }\\n                for (var j = 0; j < p.propArr.length; j++) { if (p.propArr[j]) { out.push(p.propArr[j]); } }\\n            }\\n        } catch (e) { }\\n        return out;\\n    }\\n\\n    function tick() {\\n        sTicks++;\\n        try {\\n            /* --- 场景（全亮） --- */\\n            var sc = null;\\n            try { sc = SceneMgr.I"
    @"nst.getScene(); } catch (e) { }\\n            if (sc !== sScene) {\\n                sScene = sc; sSceneNodes = sc ? collect(sc) : null; sSceneDone = 0;\\n                log('scene ' + (sc ? ('nodes=' + (sSceneNodes ? sSceneNodes.length : 0)) : 'null'));\\n            }\\n            if (CFG.bright && sSceneNodes && !sSceneDone) {\\n                sSceneDone = 1;\\n                s"
    @"etP(sScene, 'enableFog', false);\\n                try { sScene.ambientColor = new L.Vector3(1, 1, 1); } catch (e) { }\\n                for (var i = 0; i < sSceneNodes.length; i++) { brightNode(sSceneNodes[i]); }\\n                var cam = null;\\n                try { cam = SceneMgr.Inst.GetCamera(); } catch (e) { }\\n                if (cam) { setP(cam, 'nearPlane', 0.02); setP("
    @"cam, 'farPlane', 5000); }\\n                log('bright applied n=' + sSceneNodes.length);\\n            }\\n\\n            /* --- 奶奶（透视档 1/2） --- */\\n            var k = null;\\n            try { k = SceneMgr.Inst.GetKbnnScript(); } catch (e) { }\\n            var owner = (k && k.owner) ? k.owner : null;\\n            if (owner !== sOwner) {\\n                sOwner = owner; sOwnerNod"
    @"es = owner ? collect(owner, 5000) : null;\\n                log('nainai ' + (owner ? ('nodes=' + sOwnerNodes.length) : 'null'));\\n            }\\n            var espN = CFG.esp >= 1 ? 1 : 0;\\n            if (sOwnerNodes) { for (var j = 0; j < sOwnerNodes.length; j++) { espNode(sOwnerNodes[j], !!espN); } }\\n\\n            /* --- 道具（透视档 2） --- */\\n            var espP = CFG.esp >= 2"
    @" ? 1 : 0;\\n            if (espP && (sTicks - sLastProp > 10 || !sPropNodes)) {\\n                sLastProp = sTicks; sPropNodes = propNodes();\\n            }\\n            if (sPropNodes) { for (var q = 0; q < sPropNodes.length; q++) { espNode(sPropNodes[q], !!espP); } }\\n\\n            if (sTicks % 20 === 0) {\\n                log('tick ' + sTicks + ' esp=' + CFG.esp + ' bright='"
    @" + CFG.bright + ' ad=' + CFG.ad +\\n                    ' nainai=' + (sOwner ? 'y' : 'n') + ' prop=' + (sPropNodes ? sPropNodes.length : 0));\\n            }\\n        } catch (e) { log('tick err ' + e); }\\n    }\\n\\n    try { setInterval(tick, 500); log('timer installed'); }\\n    catch (e) { log('timer fail ' + e); }\\n    log('hook installed (esp=' + CFG.esp + ' bright=' + CFG.bri"
    @"ght + ' ad=' + CFG.ad + ')');\\n})();\\n\";";
static NSString *const kAvatarB64 =
    @"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"
    @"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"
    @"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"
    @"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"
    @"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";

#pragma mark - conchRuntime 帧回调 hook（多个入口，任一命中即可）
static void (*orig_renderFrame)(id, SEL);
static void (*orig_runJsLoop)(id, SEL);
static void (*orig_onVsync)(id, SEL, id);
static void gnm_on_frame(id self);

static void hook_renderFrame(id s, SEL c) { if (orig_renderFrame) { orig_renderFrame(s, c); } gnm_on_frame(s); }
static void hook_runJsLoop(id s, SEL c)   { if (orig_runJsLoop)   { orig_runJsLoop(s, c);   } gnm_on_frame(s); }
static void hook_onVsync(id s, SEL c, id o) {
    if (orig_onVsync) { orig_onVsync(s, c, o); }
    gnm_on_frame(s);
}

static void gnm_run_js(id rt, NSString *js) {
    SEL sel = @selector(runJS:);
    if (!rt || ![rt respondsToSelector:sel]) { return; }
    ((void (*)(id, SEL, id))objc_msgSend)(rt, sel, js);
}

static void gnm_push_cfg(id rt) {
    NSString *js = [NSString stringWithFormat:
        @"try{window.__GNM_CFG={esp:%d,bright:%d,ad:%d};}catch(e){}", g_esp, g_bright, g_ad];
    gnm_run_js(rt, js);
}

static BOOL g_hookDumped = NO;
static void gnm_on_frame(id rt) {
    g_frame++;
    if (g_frame % 30 == 0) { gnm_push_cfg(rt); }

    if (!g_bootPushed && g_frame >= 15) {
        g_bootPushed = YES;
        if (!g_hookDumped) {
            Method m = class_getInstanceMethod(object_getClass(rt), @selector(runJS:));
            mlog(@"frame hook alive (tick=%d) runJS: %s", g_frame, m ? "ok" : "MISSING");
            g_hookDumped = YES;
        }
        gnm_push_cfg(rt);                       // 先放配置
        gnm_run_js(rt, kHookJSON);              // 注册 hook 源码字符串
        gnm_run_js(rt, kBootJS);                // 注入 bootstrap（wrap loadLib）
        mlog(@"boot injected at tick %d", g_frame);
    }
    if (g_bootPushed && g_frame % 100 == 0) {
        gnm_scan_probe();
        if (!g_probeSeen && g_frame < 3000) {   // 探针一直没出现 → 重注入
            gnm_run_js(rt, kHookJSON);
            gnm_run_js(rt, kBootJS);
            mlog(@"boot RE-injected at tick %d", g_frame);
        }
    }
}

static void gnm_install_frame_hooks(void) {
    Class c = NSClassFromString(@"conchRuntime");
    if (!c) { mlog(@"conchRuntime NOT FOUND"); return; }
    Method m;
    m = class_getInstanceMethod(c, @selector(renderFrame));
    if (m) { orig_renderFrame = (void (*)(id, SEL))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_renderFrame); mlog(@"hooked renderFrame"); }
    m = class_getInstanceMethod(c, @selector(runJsLoop));
    if (m) { orig_runJsLoop = (void (*)(id, SEL))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_runJsLoop); mlog(@"hooked runJsLoop"); }
    m = class_getInstanceMethod(c, @selector(onVsync:));
    if (m) { orig_onVsync = (void (*)(id, SEL, id))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_onVsync); mlog(@"hooked onVsync:"); }
}

#pragma mark - 广告：native 侧短路
static void (*orig_showInter)(id, SEL);
static void (*orig_showHenfu)(id, SEL);
static void (*orig_showKaiping)(id, SEL);
static void (*orig_loadReward)(id, SEL);
static void (*orig_loadAndShowReward)(id, SEL);

static void hook_showInter(id s, SEL c)          { if (g_ad) { mlog(@"ad: showInter blocked"); return; } if (orig_showInter) { orig_showInter(s, c); } }
static void hook_showHenfu(id s, SEL c)          { if (g_ad) { mlog(@"ad: showHenfu blocked");  return; } if (orig_showHenfu) { orig_showHenfu(s, c); } }
static void hook_showKaiping(id s, SEL c)        { if (g_ad) { mlog(@"ad: showKaiping blocked");return; } if (orig_showKaiping) { orig_showKaiping(s, c); } }
static void hook_loadReward(id s, SEL c)         { if (g_ad) { return; } if (orig_loadReward) { orig_loadReward(s, c); } }
static void hook_loadAndShowReward(id s, SEL c)  { if (g_ad) { return; } if (orig_loadAndShowReward) { orig_loadAndShowReward(s, c); } }

static void gnm_hook_one(Class c, SEL sel, IMP imp, void **orig, const char *name) {
    if (!c) { return; }
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { return; }
    *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, imp);
    mlog(@"ad hook %s", name);
}

static void gnm_install_ad_hooks(void) {
    Class ad = NSClassFromString(@"AppDelegate");
    gnm_hook_one(ad, @selector(showInter),          (IMP)hook_showInter,          (void **)&orig_showInter,          "AppDelegate.showInter");
    gnm_hook_one(ad, @selector(showHenfu),          (IMP)hook_showHenfu,          (void **)&orig_showHenfu,          "AppDelegate.showHenfu");
    gnm_hook_one(ad, @selector(showKaiping),        (IMP)hook_showKaiping,        (void **)&orig_showKaiping,        "AppDelegate.showKaiping");
    gnm_hook_one(ad, @selector(loadReward),         (IMP)hook_loadReward,         (void **)&orig_loadReward,         "AppDelegate.loadReward");
    gnm_hook_one(ad, @selector(loadAndShowReward),  (IMP)hook_loadAndShowReward,  (void **)&orig_loadAndShowReward,  "AppDelegate.loadAndShowReward");
}

#pragma mark - 悬浮球 / 面板（直接挂游戏 window 顶层，不建独立 UIWindow）
@class GNMBox;
static UIView *g_ball = nil;
static GNMBox *g_panel = nil;
static UILabel *g_btnEsp = nil, *g_btnBright = nil, *g_btnAd = nil;

static UIImage *gnm_avatar(void) {
    static UIImage *img = nil;
    if (!img) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:kAvatarB64
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d) { img = [UIImage imageWithData:d]; }
    }
    return img;
}

static void gnm_add_rainbow(UIView *v, CGFloat inner) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = v.bounds;
    g.type = kCAGradientLayerConic;
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(0.5, 0);
    g.colors = @[(id)[UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.5 green:0.3 blue:1.0 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1.0 green:0.2 blue:0.5 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1.0 green:0.7 blue:0.1 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:1].CGColor];
    CAShapeLayer *mask = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:v.bounds];
    CGFloat inset = v.bounds.size.width * (1.0 - inner) / 2.0;
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(v.bounds, inset, inset)]];
    mask.path = p.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    g.mask = mask;
    [v.layer addSublayer:g];
}

static void gnm_refresh_buttons(void) {
    g_btnEsp.text = g_esp == 0 ? @"👁 透视  OFF" : (g_esp == 1 ? @"👁 透视  奶奶" : @"👁 透视  奶奶+道具");
    g_btnEsp.textColor = g_esp ? [UIColor colorWithRed:0.3 green:1 blue:0.45 alpha:1] : UIColor.lightGrayColor;
    g_btnBright.text = g_bright ? @"💡 亮度  ON" : @"💡 亮度  OFF";
    g_btnBright.textColor = g_bright ? [UIColor colorWithRed:0.3 green:1 blue:0.45 alpha:1] : UIColor.lightGrayColor;
    g_btnAd.text = g_ad ? @"🚫 免广告  ON" : @"🚫 免广告  OFF";
    g_btnAd.textColor = g_ad ? [UIColor colorWithRed:1 green:0.8 blue:0.2 alpha:1] : UIColor.lightGrayColor;
}

@interface GNMBox : UIView
@end

@implementation GNMBox
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.96];
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 12;
        self.userInteractionEnabled = YES;

        UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(14, 14, 40, 40)];
        av.image = gnm_avatar();
        av.layer.cornerRadius = 20;
        av.layer.masksToBounds = YES;
        av.layer.borderWidth = 2.5;
        av.layer.borderColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1].CGColor;
        [self addSubview:av];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(62, 14, 170, 22)];
        title.text = @"✦ 昆哥儿科技 ✦";
        title.textColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1];
        title.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:title];

        UILabel *sub = [UILabel alloc] initWithFrame:CGRectMake(62, 35, 170, 16)];
        sub.text = @"恐怖奶奶迷雾 · 助手";
        sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        sub.font = [UIFont systemFontOfSize:10];
        [self addSubview:sub];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        x.frame = CGRectMake(f.size.width - 42, 12, 30, 30);
        [x setTitle:@"✕" forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [x setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:x];

        CGFloat y = 66;
        for (int i = 0; i < 3; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(16, y, f.size.width - 32, 42);
            b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
            b.layer.cornerRadius = 10;
            b.tag = i;
            [b addTarget:self action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
            UILabel *lb = [[UILabel alloc] initWithFrame:b.bounds];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.font = [UIFont boldSystemFontOfSize:14];
            [b addSubview:lb];
            if (i == 0) { g_btnEsp = lb; }
            if (i == 1) { g_btnBright = lb; }
            if (i == 2) { g_btnAd = lb; }
            [self addSubview:b];
            y += 50;
        }
        gnm_refresh_buttons();

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)closeTap { [g_panel removeFromSuperview]; g_panel = nil; }
- (void)btnTap:(UIButton *)b {
    if (b.tag == 0) { g_esp = (g_esp + 1) % 3; }
    if (b.tag == 1) { g_bright = !g_bright; }
    if (b.tag == 2) { g_ad = !g_ad; }
    gnm_refresh_buttons();
    gnm_sync_flags();
    mlog(@"btn tag=%ld -> esp=%d bright=%d ad=%d", (long)b.tag, g_esp, g_bright, g_ad);
}
- (void)drag:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    CGPoint c = self.center; c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:self.superview];
    CGRect scr = self.superview.bounds;
    c.x = MAX(self.bounds.size.width / 2, MIN(scr.size.width - self.bounds.size.width / 2, c.x));
    c.y = MAX(self.bounds.size.height / 2, MIN(scr.size.height - self.bounds.size.height / 2, c.y));
    self.center = c;
}
@end

static UIWindow *gnm_game_window(void) {
    UIWindow *w = [UIApplication sharedApplication].delegate.window;
    if (w) { return w; }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *ww in ws.windows) { if (ww.isKeyWindow) { return ww; } }
        if (ws.windows.count) { return ws.windows.firstObject; }
    }
    return nil;
}

@implementation UIView (GNMGestures)
- (void)gnm_ballDrag:(UIPanGestureRecognizer *)p {
    UIView *b = self;
    CGPoint t = [p translationInView:b.superview];
    CGPoint c = b.center; c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:b.superview];
    CGRect scr = b.superview.bounds;
    c.x = MAX(b.bounds.size.width / 2, MIN(scr.size.width - b.bounds.size.width / 2, c.x));
    c.y = MAX(b.bounds.size.height / 2, MIN(scr.size.height - b.bounds.size.height / 2, c.y));
    b.center = c;
}
- (void)gnm_ballTap:(UITapGestureRecognizer *)p {
    UIWindow *w = self.window;
    if (!w) { return; }
    if (g_panel) { [g_panel removeFromSuperview]; g_panel = nil; return; }
    CGFloat pw = 250, ph = 232;
    CGRect scr = w.bounds;
    CGFloat px = self.center.x - pw / 2;
    px = MAX(10, MIN(scr.size.width - pw - 10, px));
    CGFloat py = self.center.y + 70;
    py = MAX(10, MIN(scr.size.height - ph - 10, py));
    g_panel = [[GNMBox alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    [w addSubview:g_panel];
    [w bringSubviewToFront:g_panel];
    mlog(@"panel opened %.0f,%.0f", px, py);
}
@end

static UIView *gnm_build_ball(void) {
    CGFloat bs = 58;
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bs, bs)];
    ball.layer.cornerRadius = bs / 2;
    ball.layer.masksToBounds = NO;
    ball.layer.shadowColor = UIColor.blackColor.CGColor;
    ball.layer.shadowOpacity = 0.6;
    ball.layer.shadowRadius = 6;
    ball.layer.shadowOffset = CGSizeMake(0, 2);
    gnm_add_rainbow(ball, 0.88);
    UIImageView *ava = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, bs - 6, bs - 6)];
    ava.image = gnm_avatar();
    ava.layer.cornerRadius = (bs - 6) / 2;
    ava.layer.masksToBounds = YES;
    [ball addSubview:ava];
    [ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:ball action:@selector(gnm_ballTap:)]];
    [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:ball action:@selector(gnm_ballDrag:)]];
    return ball;
}

static void gnm_ensure_overlay(void) {
    UIWindow *w = gnm_game_window();
    if (!w) { static int s = 0; if (++s <= 5) { mlog(@"window not ready #%d", s); } return; }
    BOOL need = NO;
    if (!g_ball) { g_ball = gnm_build_ball(); need = YES; }
    else if (g_ball.superview != w) { need = YES; }
    else if (w.subviews.lastObject != g_ball) { [w bringSubviewToFront:g_ball]; }
    if (need) {
        CGPoint old = g_ball.center;
        CGRect scr = w.bounds;
        if (old.x < 1 && old.y < 1) { g_ball.center = CGPointMake(scr.size.width - 57, scr.size.height * 0.42); }
        [w addSubview:g_ball];
        [w bringSubviewToFront:g_ball];
        mlog(@"ball attached (%.0fx%.0f) subviews=%lu", scr.size.width, scr.size.height,
             (unsigned long)w.subviews.count);
    }
    if (g_panel && g_panel.superview == w && w.subviews.lastObject != g_panel) { [w bringSubviewToFront:g_panel]; }
}

#pragma mark - ctor
__attribute__((constructor))
static void gnm_ctor(void) {
    mlog(@"ctor: GNMTweak v1 (pid=%d)", getpid());
    gnm_install_frame_hooks();
    gnm_install_ad_hooks();
    gnm_sync_flags();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gnm_ensure_overlay();
    });
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            gnm_scan_probe();
            gnm_ensure_overlay();
            static int n = 0;
            if (++n % 10 == 0) { gnm_sync_flags(); }
        });
    });
    dispatch_resume(t);
}
