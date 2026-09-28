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
#import "fishhook.h"

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

// 读取 JS 探针（gnm_probe.txt / gnm_js.log），并回灌到 native 日志
//   v2：JS 侧写入的目录不可预知 → 用 -[conchRuntime getRootCachePath] 反查 + 多候选目录扫描
static NSString *g_jsLogCache = nil;
static NSString *g_lastJsLog = nil;

static NSArray *gnm_probe_dirs(void);

static NSArray *gnm_probe_dirs(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    [a addObject:[home stringByAppendingPathComponent:@"Documents"]];
    if (g_jsLogCache) {
        [a addObject:g_jsLogCache];
        [a addObject:[g_jsLogCache stringByAppendingPathComponent:@"stand.alone.version"]];
        [a addObject:[g_jsLogCache stringByAppendingPathComponent:@"appCache/stand.alone.version"]];
    }
    // conchRuntime.getRootCachePath() → .../Library/Caches/LayaCache/appCache
    Class cc = NSClassFromString(@"conchRuntime");
    if (cc) {
        id inst = nil;
        SEL gs = @selector(GetIOSConchRuntime);
        if ([cc respondsToSelector:gs]) { inst = ((id (*)(id, SEL))objc_msgSend)(cc, gs); }
        SEL rg = @selector(getRootCachePath);
        if (inst && [inst respondsToSelector:rg]) {
            NSString *rp = ((id (*)(id, SEL))objc_msgSend)(inst, rg);
            if (rp.length) {
                [a addObject:rp];
                [a addObject:[rp stringByAppendingPathComponent:@"stand.alone.version"]];
                // .../Library/Caches/LayaCache/appCache → 上两级 + Documents
                [a addObject:[[rp stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]];
                mlog(@"getRootCachePath=%@", rp);
            }
        }
    }
    [a addObject:@"/tmp"];
    [a addObject:home];
    return a;
}

// 读取缓存目录下所有文件的【大小】，用于确认 DCC 资源位置（不解码，只探测）
static void gnm_probe_dcc(const char *why) {
    NSArray *dirs = gnm_probe_dirs();
    for (NSString *d in dirs) {
        for (NSString *sub in @[@"", @"stand.alone.version", @"appCache", @"LayaCache"]) {
            NSString *p = sub.length ? [d stringByAppendingPathComponent:sub] : d;
            NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:nil];
            if (!items.count) { continue; }
            NSUInteger big = 0; NSString *bigN = nil;
            for (NSString *f in items) {
                NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:
                                    [p stringByAppendingPathComponent:f] error:nil];
                unsigned long long sz = [at fileSize];
                if (sz > big) { big = (NSUInteger)sz; bigN = f; }
            }
            mlog(@"dccprobe(%s) %@ : %lu files, biggest=%@ (%lu B)",
                 why, p, (unsigned long)items.count, bigN, (unsigned long)big);
        }
    }
}

static void gnm_scan_probe(void) {
    NSArray *dirs = gnm_probe_dirs();
    // 1) 探针
    if (!g_probeSeen) {
        for (NSString *d in dirs) {
            NSString *p = [d stringByAppendingPathComponent:@"gnm_probe.txt"];
            NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (!s) { continue; }
            mlog(@"probe found at %@", p);
            for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"cachePath="]) {
                    NSString *cp = [line substringFromIndex:10];
                    if (cp.length) { g_jsCachePath = cp; g_jsLogCache = cp; }
                }
                mlog(@"  probe| %@", line);
            }
            g_probeSeen = YES;
            gnm_sync_flags();
            break;
        }
    }
    // 2) JS 日志回灌（每 2s 一次，读到多少写多少）
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:@"gnm_js.log"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            g_jsLogCache = d;
            NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (s.length && ![s isEqualToString:g_lastJsLog]) {
                g_lastJsLog = s;
                mlog(@"=== JS LOG (%@) ===", p);
                for (NSString *ln in [s componentsSeparatedByString:@"\n"]) {
                    if (ln.length) { mlog(@"  JS| %@", ln); }
                }
                mlog(@"=== JS LOG END ===");
            }
            break;
        }
    }
}

#pragma mark - JS→native 日志通道：给 JSBridge 动态加 +gnmLog:
// JS 侧 PlatformClass.createClass("JSBridge").call("gnmLog:", msg) → conch.callMethod
//   → native Reflection → [JSBridge gnmLog:msg] → 本函数 → gnm.log
// 这条通道不依赖文件系统，是判断 JS 层是否真的跑起来的【唯一可靠依据】。
static void gnm_log_from_js(id self, SEL _cmd, id msg) {
    NSString *s = nil;
    if ([msg isKindOfClass:NSClassFromString(@"NSString")]) { s = (NSString *)msg; }
    else if (msg) { s = [msg description]; }
    if (s.length) { mlog(@"JSB| %@", s); }
}

static void gnm_install_js_bridge(void) {
    Class c = NSClassFromString(@"JSBridge");
    if (!c) { mlog(@"JSBridge NOT FOUND (js log channel off)"); return; }
    Class meta = object_getClass(c);
    BOOL ok = class_addMethod(meta, @selector(gnmLog:), (IMP)gnm_log_from_js, "v@:@");
    mlog(@"JSBridge gnmLog: added=%d", ok);
}

static void gnm_run_js(id rt, NSString *js);
static void gnm_probe_dcc(const char *why);
static NSString *gnm_instrument_bundle(void);
static void gnm_push_bundle_to_js(id rt);

#pragma mark - JS 源码（由 gen.py 注入，JSON/ObjC 双重转义已校验）
static NSString *const kBootJS =
    @"/*\n * boot.js  -- injected via [conchRuntime runJS:] (LayaAir Conch)\n * Goal: obtain js/bundle.js source, splice hook.js inside the IIFE, evaluate.\n * All strings are ASCII to avoid any encoding hazard across runJS.\n */\n(function () {\n    'use strict';\n\n    /* ---- resolve global object (runJS eval ctx may lack `window`) ---- */\n    var G = null;\n    try { if (typeof window !=="
    @" 'undefined' && window) { G = window; } } catch (e) { }\n    if (!G) { try { if (typeof globalThis !== 'undefined' && globalThis) { G = globalThis; } } catch (e) { } }\n    if (!G) { try { if (typeof self !== 'undefined' && self) { G = self; } } catch (e) { } }\n    if (!G) { try { if (typeof global !== 'undefined' && global) { G = global; } } catch (e) { } }\n    if (!G) { return;"
    @" }\n    if (G.__GNM_BOOT) { return; }\n    G.__GNM_BOOT = true;\n    G.__GNM_BOOT_V = 2;\n\n    /* ---- native-instrumented bundle loader (called by native via runJS) ----\n     * native instruments the bundle and writes Documents/gnm_bundle.js (plus a copy in the cache dir).\n     * Probe each API with typeof: referencing a missing variable throws ReferenceError and kills the whole b"
    @"lock.\n     * Every attempt reports its failure reason instead of failing silently. */\n    G.__GNM_LOAD_NATIVE = function (arg) {\n        var cands = [];\n        if (typeof arg === 'string' && arg) { cands.push(arg); }\n        else if (arg && arg.length) { for (var z = 0; z < arg.length; z++) { if (arg[z]) { cands.push(arg[z]); } } }\n        /* ???? fishhook ??? */\n        cands"
    @".push('gnm_bundle.js');\n        if (CP) { cands.push(CP + '/gnm_bundle.js'); }\n        cands.push('/tmp/gnm_bundle.js');\n\n        var fns = [];\n        try { if (typeof fs_readFileSync === 'function') { fns.push(['fs_readFileSync(a)', function (p) { return fs_readFileSync(p); }]); } } catch (e) { }\n        try { if (typeof fs_readFileSync === 'function') { fns.push(['fs_readFil"
    @"eSync(a,utf8)', function (p) { return fs_readFileSync(p, 'utf8'); }]); } } catch (e) { }\n        try { if (typeof readFileSync === 'function') { fns.push(['readFileSync(a)', function (p) { return readFileSync(p); }]); } } catch (e) { }\n        try { if (typeof readFileSync === 'function') { fns.push(['readFileSync(a,utf8)', function (p) { return readFileSync(p, 'utf8'); }]); } "
    @"} catch (e) { }\n        try { if (typeof readText === 'function') { fns.push(['readText(a)', function (p) { return readText(p); }]); } } catch (e) { }\n\n        function conv(r) {\n            if (r == null) { return null; }\n            if (typeof r === 'string') { return r.length > 100000 ? r : null; }\n            try {\n                var u = new Uint8Array(r);\n                "
    @"if (u.length < 100000) { return null; }\n                var o = '';\n                for (var k = 0; k < u.length; k += 8192) {\n                    o += String.fromCharCode.apply(null, u.subarray(k, k + 8192));\n                }\n                return o;\n            } catch (e) { return null; }\n        }\n\n        var s = null, how = '';\n        for (var ci = 0; ci < cands.length"
    @" && !s; ci++) {\n            for (var fi = 0; fi < fns.length && !s; fi++) {\n                try {\n                    s = conv(fns[fi][1](cands[ci]));\n                    if (s) { how = fns[fi][0] + ' @ ' + cands[ci]; }\n                } catch (e) { L('read err ' + fns[fi][0] + ' @ ' + cands[ci] + ' : ' + e); }\n            }\n        }\n        if (!s) {\n            L('native rea"
    @"d FAILED (tried ' + cands.length + ' paths x ' + fns.length + ' apis)');\n            return 0;\n        }\n        L('native source via ' + how + ' len=' + s.length);\n        G.__GNM_BUNDLE_LEN = s.length;\n        try { G.eval(s); } catch (e) {\n            L('native eval err ' + e);\n            return -1;\n        }\n        L('native eval OK, hook installed=' + (G.__GNM_HOOK_INSTA"
    @"LLED || 0) + ' alive=' + (G.__GNM_ALIVE || 0));\n        return 1;\n    };\n\n    /* ---- cache path ---- */\n    var CP = '';\n    try { if (typeof conch !== 'undefined' && conch.getCachePath) { CP = '' + conch.getCachePath(); } } catch (e) { }\n    if (!CP) { try { CP = '' + conchConfig.getCachePath(); } catch (e) { } }\n    G.__GNM_CACHE = CP;\n\n    function paths(name) {\n        var"
    @" out = [], seen = {};\n        function add(p) { if (p && !seen[p]) { seen[p] = 1; out.push(p); } }\n        if (CP) {\n            add(CP + '/' + name);\n            add(CP + '/LayaCache/appCache/' + name);\n        }\n        add(name);\n        add('/tmp/' + name);\n        add('/var/mobile/Documents/' + name);\n        return out;\n    }\n    function writeFile(name, text) {\n        v"
    @"ar ps = paths(name), fns = [], i, j, ok = 0;\n        try { if (typeof fs_writeFileSync === 'function') { fns.push(fs_writeFileSync); } } catch (e) { }\n        try { if (typeof writeFile === 'function') { fns.push(writeFile); } } catch (e) { }\n        try { if (typeof writeFileSync === 'function') { fns.push(writeFileSync); } } catch (e) { }\n        for (i = 0; i < ps.length; i+"
    @"+) {\n            for (j = 0; j < fns.length; j++) {\n                try { fns[j](ps[i], text); ok++; break; } catch (e) { }\n            }\n        }\n        return ok;\n    }\n\n    /* ---- JS -> native channel (no filesystem needed) ---- */\n    var bridge = null, bridgeOK = 0;\n    function toNative(msg) {\n        if (bridgeOK === -1) { return; }\n        try {\n            if (!brid"
    @"ge) {\n                if (typeof PlatformClass === 'undefined') { bridgeOK = -1; return; }\n                bridge = PlatformClass.createClass('JSBridge');\n            }\n            if (!bridge || typeof bridge.call !== 'function') { bridgeOK = -1; return; }\n            bridge.call('gnmLog:', '' + msg);\n            bridgeOK = 1;\n        } catch (e) { bridgeOK = -1; }\n    }\n\n    "
    @"/* ---- log ring + flush ---- */\n    var LINES = [];\n    G.__GNM_LOG = function (m) {\n        try {\n            LINES.push('[' + Date.now() + '] ' + m);\n            if (LINES.length > 500) { LINES.splice(0, LINES.length - 500); }\n            writeFile('gnm_js.log', LINES.join('\\n'));\n            toNative(m);\n        } catch (e) { }\n    };\n    function L(m) { try { G.__GNM_LOG('"
    @"[boot] ' + m); } catch (e) { } }\n\n    /* ---- probe: report env back to native ---- */\n    function probe(extra) {\n        var s = [\n            'v=2',\n            'alive=' + (G.__GNM_ALIVE || 0),\n            'cachePath=' + CP,\n            'fs_write=' + (typeof fs_writeFileSync),\n            'fs_read=' + (typeof fs_readFileSync),\n            'readFileSync=' + (typeof readFileSy"
    @"nc),\n            'loadLib=' + (typeof G.loadLib),\n            'appcache=' + (typeof G.appcache),\n            'conch=' + (typeof conch),\n            'bundle=' + (G.__GNM_BUNDLE_LEN || 0),\n            'extra=' + (extra || '')\n        ].join('\\n');\n        writeFile('gnm_probe.txt', s);\n        return s;\n    }\n    probe('boot start');\n    L('BRIDGE-PROOF');   /* first line: proves"
    @" runJS really executed */\n    try { if (typeof conch !== 'undefined' && conch.log) { conch.log('GNM boot v2 cp=' + CP); } } catch (e) { }\n\n    /* ---- read helpers ---- */\n    function toStr(buf) {\n        if (buf == null) { return null; }\n        if (typeof buf === 'string') { return buf; }\n        try {\n            var u8 = new Uint8Array(buf);\n            if (u8.length < 100"
    @") { return null; }\n            var out = '';\n            for (var i = 0; i < u8.length; i += 8192) {\n                out += String.fromCharCode.apply(null, u8.subarray(i, i + 8192));\n            }\n            return out;\n        } catch (e) { return null; }\n    }\n    var CRC_T = (function () {\n        var t = [], c, n, k;\n        for (n = 0; n < 256; n++) {\n            c = n;\n "
    @"           for (k = 0; k < 8; k++) { c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); }\n            t[n] = c >>> 0;\n        }\n        return t;\n    })();\n    function crc32(str) {\n        var c = 0xFFFFFFFF;\n        for (var i = 0; i < str.length; i++) { c = CRC_T[(c ^ str.charCodeAt(i)) & 0xFF] ^ (c >>> 8); }\n        return ((c ^ 0xFFFFFFFF) >>> 0);\n    }\n    function hex8("
    @"n) { var s = (n >>> 0).toString(16); while (s.length < 8) { s = '0' + s; } return s; }\n    function readRaw(path) {\n        var fns = [];\n        try { if (typeof fs_readFileSync === 'function') { fns.push(fs_readFileSync); } } catch (e) { }\n        try { if (typeof readFileSync === 'function') { fns.push(readFileSync); } } catch (e) { }\n        try { if (typeof readFile === 'f"
    @"unction') { fns.push(readFile); } } catch (e) { }\n        for (var i = 0; i < fns.length; i++) {\n            for (var k = 0; k < 2; k++) {\n                try {\n                    var s = toStr(k === 0 ? fns[i](path, 'utf8') : fns[i](path));\n                    if (s) { return s; }\n                } catch (e) { }\n            }\n        }\n        return null;\n    }\n    function "
    @"dccRoots() {\n        var r = [], seen = {};\n        function add(p) { if (p && !seen[p]) { seen[p] = 1; r.push(p); } }\n        if (CP) {\n            add(CP + '/stand.alone.version');\n            add(CP + '/appCache/stand.alone.version');\n            add(CP + '/LayaCache/appCache/stand.alone.version');\n            add(CP + '/../stand.alone.version');\n            add(CP);\n       "
    @" }\n        add('/var/mobile/Library/Caches/LayaCache/appCache/stand.alone.version');\n        return r;\n    }\n    function READ(url) {\n        var u = '' + url;\n        var base = u.substring(u.lastIndexOf('/') + 1);\n        var cands = [u, '/' + base, base], i, s;\n\n        try {\n            var ac = G.appcache;\n            if (ac && typeof ac.loadCachedURL === 'function') {\n   "
    @"             for (i = 0; i < cands.length; i++) {\n                    s = toStr(ac.loadCachedURL(cands[i]));\n                    if (s && s.length > 100000) { L('via appcache ' + cands[i]); return s; }\n                }\n            }\n        } catch (e) { L('appcache err ' + e); }\n\n        for (i = 0; i < cands.length; i++) {\n            s = readRaw(cands[i]);\n            if (s"
    @" && s.length > 100000) { L('via file ' + cands[i]); return s; }\n        }\n\n        var roots = dccRoots(), fid = hex8(crc32(u));\n        for (i = 0; i < roots.length; i++) {\n            s = readRaw(roots[i] + '/' + fid);\n            if (s && s.length > 100000 && s.indexOf('}());') > 0) { L('via dcc ' + roots[i] + '/' + fid); return s; }\n        }\n\n        try {\n            if ("
    @"typeof fs_readdirSync === 'function') {\n                for (i = 0; i < roots.length; i++) {\n                    var list = null;\n                    try { list = fs_readdirSync(roots[i]); } catch (e) { }\n                    if (!list) { continue; }\n                    for (var j = 0; j < list.length; j++) {\n                        var nm = '' + list[j];\n                       "
    @" if (!/^[0-9a-f]{8}$/.test(nm)) { continue; }\n                        var t = readRaw(roots[i] + '/' + nm);\n                        if (t && t.length > 100000 && t.indexOf('}());') > 0) {\n                            L('via dirscan ' + roots[i] + '/' + nm);\n                            return t;\n                        }\n                    }\n                }\n            }\n     "
    @"   } catch (e) { }\n        return null;\n    }\n\n    /* ---- instrument + evaluate ---- */\n    var HOOK = G.__GNM_HOOK_SRC || '';\n    function instrument(src) {\n        if (!src || src.length < 100000) { return null; }\n        var idx = src.lastIndexOf('}());');\n        if (idx < 0) { idx = src.lastIndexOf('})();'); }\n        if (idx < 0) { idx = src.length; }\n        G.__GNM_BUN"
    @"DLE_LEN = src.length;\n        return src.substring(0, idx) + '\\n' + HOOK + '\\n' + src.substring(idx);\n    }\n    var done = false;\n    function tryBundle(url, tag) {\n        if (done) { return true; }\n        try {\n            var src = READ(url);\n            if (!src) { L('bundle read FAILED (' + tag + ')'); return false; }\n            var out = instrument(src);\n            if "
    @"(!out) { return false; }\n            done = true;\n            probe('instrumented len=' + src.length + ' tag=' + tag);\n            try { G.eval(out + '\\n//@ sourceURL=' + url); }\n            catch (e1) {\n                L('G.eval err ' + e1);\n                try { (0, eval)(out); } catch (e2) { L('indirect eval err ' + e2); }\n            }\n            probe('hook evaluated aliv"
    @"e=' + (G.__GNM_ALIVE || 0));\n            return true;\n        } catch (e) { L('tryBundle err ' + e); return false; }\n    }\n\n    /* ---- three interception paths ---- */\n    function wrapLoadLib() {\n        if (G.__GNM_LIBW) { return true; }\n        var f = G.loadLib;\n        if (typeof f !== 'function') { return false; }\n        G.__GNM_LIBW = true;\n        G.loadLib = function"
    @" (url) {\n            try {\n                if (url && ('' + url).indexOf('bundle.js') >= 0 && tryBundle(url, 'loadLib')) { return; }\n            } catch (e) { L('loadLib wrap err ' + e); }\n            return f.apply(this, arguments);\n        };\n        L('loadLib wrapped');\n        return true;\n    }\n    function wrapEval() {\n        if (G.__GNM_EVALW) { return true; }\n        "
    @"var f = G.eval;\n        if (typeof f !== 'function') { return false; }\n        G.__GNM_EVALW = true;\n        G.eval = function (code) {\n            try {\n                if (!done && typeof code === 'string' && code.length > 100000 &&\n                    code.indexOf('}());') > 0 && code.indexOf('__GNM_HOOK_INSTALLED') < 0) {\n                    var out = instrument(code);\n    "
    @"                if (out) { done = true; probe('instrumented len=' + code.length + ' tag=eval'); return f.call(G, out); }\n                }\n            } catch (e) { L('eval wrap err ' + e); }\n            return f.apply(this, arguments);\n        };\n        L('eval wrapped');\n        return true;\n    }\n    function wrapRequire() {\n        if (G.__GNM_REQW) { return true; }\n      "
    @"  var f = G.require;\n        if (typeof f !== 'function') { return false; }\n        G.__GNM_REQW = true;\n        G.require = function (n) {\n            try {\n                if (n && ('' + n).indexOf('bundle.js') >= 0 && tryBundle(n, 'require')) { return; }\n            } catch (e) { }\n            return f.apply(this, arguments);\n        };\n        L('require wrapped');\n        "
    @"return true;\n    }\n\n    L('wraps loadLib=' + wrapLoadLib() + ' eval=' + wrapEval() + ' require=' + wrapRequire());\n\n    /* ---- load the native-prepared instrumented copy immediately ----\n     * A second runJS is unreliable (its evaluation is unobservable), so the read\n     * must be issued inside THIS injection. */\n    try {\n        if (typeof G.__GNM_LOAD_NATIVE === 'function"
    @"' && G.__GNM_NATIVE_PREP) {\n            L('loading native-prepared bundle: ' + G.__GNM_NATIVE_PREP);\n            var rv = G.__GNM_LOAD_NATIVE(G.__GNM_NATIVE_PREP);\n            L('native-prepared load rv=' + rv);\n        }\n    } catch (e) { L('native-prepared load threw ' + e); }\n\n    /* ---- retry / fallback ---- */\n    var n = 0;\n    var t = setInterval(function () {\n        n"
    @"++;\n        if (done) { probe('done'); clearInterval(t); return; }\n        wrapLoadLib(); wrapEval(); wrapRequire();\n        if (n === 25) { tryBundle('js/bundle.js', 'poll'); }\n        if (n === 60) { tryBundle('/js/bundle.js', 'poll2'); tryBundle('index.js', 'poll3'); }\n        if (n === 120) { probe('giveup loadLib=' + (typeof G.loadLib)); clearInterval(t); }\n    }, 200);\n\n "
    @"   setInterval(function () { probe(G.__GNM_ALIVE ? 'alive' : 'waiting'); }, 5000);\n\n    L('boot v2 ready hookLen=' + HOOK.length);\n\n    /* ================= Plan G: bundle-free ESP =================\n     * Everything below uses window.Laya globals ONLY.\n     * It does NOT depend on reading bundle.js.\n     *\n     * CRITICAL: enemy names must be matched EXACTLY.\n     * A substrin"
    @"g test on \"kbnn\" also hits ~51 level-geometry nodes\n     * (KBNN_4_4 / KBNN_mishi_1_1 / KBNN_-1_2_1 ...), and painting those with\n     * DEPTHTEST_ALWAYS + red albedo makes the whole level turn red and\n     * see-through (doors and floors vanish). Same for \"zhizhu\" which also\n     * matches \"zhizhuwang\" (spider web prop).\n     */\n    function gnmRend(n) {\n        if (!n) { retu"
    @"rn null; }\n        try { if (n.skinnedMeshRenderer) { return n.skinnedMeshRenderer; } } catch (e) { }\n        try { if (n.meshRenderer) { return n.meshRenderer; } } catch (e) { }\n        return null;\n    }\n    function gnmSetP(o, k, v) { try { o[k] = v; return 1; } catch (e) { return 0; } }\n    function gnmCollectRend(root) {\n        var out = [], st = [root], g = 0;\n        wh"
    @"ile (st.length && g++ < 3000) {\n            var c = st.pop();\n            if (gnmRend(c)) { out.push(c); }\n            try {\n                var n = c.numChildren | 0;\n                for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\n            } catch (e) { }\n        }\n        return out;\n    }\n    /* exact-name enemy table (lowercased) -> {la"
    @"bel, color} */\n    var G_ENEMY = {\n        'kbnn_nainai': { label: 'GRANNY', color: '#FF2020' },\n        'kbnn_zhizhu': { label: 'SPIDER', color: '#FFD000' },\n        'kbnn_wuya': { label: 'CROW', color: '#FF8000' }\n    };\n    function gnmEnemyOf(nm) {\n        if (!nm) { return null; }\n        var s = ('' + nm).toLowerCase();\n        if (s.length > 24) { return null; }         "
    @"            /* level nodes have longer names */\n        return G_ENEMY[s] || null;\n    }\n    var g_cesp = null;\n    /* remember modified materials so we can restore them */\n    function gnmInstallPlanG() {\n        var La = G.Laya;\n        if (!La || !La.stage || !La.Sprite || !La.Vector3) { return false; }\n        /* idempotent: use Laya itself as registry (shared across every "
    @"JS context).\n         * Re-injected boot used to spawn several timers that each cleared and redrew\n         * the same layer -> visible flicker. */\n        if (La.__GNM_ESP) { return true; }\n        La.__GNM_ESP = { units: [], sig: '', ticks: 0, cache: [], dirty: [], nrend: 0 };\n\n        /* Pre-built pool of {box sprite, label text}. Nothing is ever cleared or\n         * redraw"
    @"n; only x/y/scale/visible change, so the overlay cannot flicker. */\n        function makeUnit(La2, color) {\n            var sp = new La2.Sprite();\n            sp.mouseEnabled = false;\n            /* fgui.GRoot (the whole game UI) sits at zOrder=5, so anything with the\n             * default zOrder=0 gets drawn underneath it and is invisible. */\n            sp.zOrder = 90000;\n  "
    @"          sp.graphics.drawRect(-27, -100, 54, 100, null, color, 3);\n            La2.stage.addChild(sp);\n            var txt = new La2.Text();\n            txt.fontSize = 16;\n            txt.color = color;\n            txt.text = '';\n            txt.mouseEnabled = false;\n            txt.zOrder = 90001;\n            La2.stage.addChild(txt);\n            return { box: sp, txt: txt };\n"
    @"        }\n        var COLORS = ['#FF2020', '#FFD000', '#FF8000', '#FF3030', '#FFC000', '#FF9020', '#FF1010', '#FFE000'];\n        for (var pi = 0; pi < COLORS.length; pi++) { La.__GNM_ESP.units.push(makeUnit(La, COLORS[pi])); }\n        L('planG INSTALL v3 (pool=' + COLORS.length + ', registry=Laya)');\n\n        var S = La.__GNM_ESP;\n        function hideAll() {\n            for (v"
    @"ar u = 0; u < S.units.length; u++) {\n                if (S.units[u].box.visible) { S.units[u].box.visible = false; S.units[u].txt.visible = false; }\n            }\n        }\n        /* restore modified materials back to their original state */\n        function restoreAll() {\n            for (var i = 0; i < S.dirty.length; i++) {\n                var d = S.dirty[i];\n              "
    @"  gnmSetP(d.m, 'depthTest', d.t);\n                gnmSetP(d.m, 'depthWrite', d.w);\n                gnmSetP(d.m, 'renderQueue', d.q);\n                if (d.c != null) { try { d.m.albedoColor = d.c; } catch (e) { } }\n                try { d.m.__gnmDirty = 0; } catch (e) { }\n            }\n            S.dirty = [];\n        }\n\n        /* 1) scene scan + material pass: low frequency "
    @"(scene tree is large) */\n        setInterval(function () {\n            S.ticks++;\n            var cfg = G.__GNM_CFG || { esp: 0, bright: 0, ad: 1 };\n            /* esp < 2 means \"no material see-through\": restore anything we changed.\n             * Must also reset the per-material flag, otherwise a later enable is\n             * skipped by the __gnmDirty guard and appears to do"
    @" nothing. */\n            if (cfg.esp < 2 && S.dirty.length) {\n                var nrst = S.dirty.length;\n                restoreAll();\n                L('planG materials restored (n=' + nrst + ')');\n            }\n            if (!cfg.esp) {\n                S.cache = []; S.cam = null;\n                hideAll();\n                return;\n            }\n            var hits = [], sce"
    @"ne = null, st = [La.stage], g = 0;\n            while (st.length && g++ < 60000) {\n                var c = st.pop();\n                try {\n                    if (!scene && c._cameraPool) { scene = c; }\n                    var info = gnmEnemyOf(c.name);\n                    if (info) { hits.push({ n: c, i: info }); }\n                    var n = c.numChildren | 0;\n                "
    @"    for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\n                } catch (e) { }\n            }\n            var sig = hits.length + ':';\n            for (var q = 0; q < hits.length; q++) { sig += hits[q].n.name + ','; }\n            if (sig !== S.sig) {\n                S.sig = sig;\n                L('planG enemies=' + sig + ' scene=' + (scene"
    @" ? 'y' : 'n') +\n                  ' stage=' + La.stage.width + 'x' + La.stage.height);\n            }\n            var cam = null;\n            try { cam = (scene && scene._cameraPool && scene._cameraPool[0]) || null; } catch (e) { }\n            S.cam = cam;\n            if (cam) {\n                var camPos = null;\n                try { camPos = cam.transform.position; } catch (e)"
    @" { }\n                if (!camPos) { try { camPos = cam.owner.transform.position; } catch (e) { } }\n                S.camPos = camPos;\n                try { S.vw = cam.viewport.width; } catch (e) { S.vw = 0; }\n            }\n            S.cache = hits;\n\n            /* material see-through: exact enemy nodes only, esp>=2 */\n            var nrend = 0;\n            if (cfg.esp >= 2) "
    @"{\n                for (var ii = 0; ii < hits.length; ii++) {\n                    var nd = gnmCollectRend(hits[ii].n);\n                    for (var kk = 0; kk < nd.length; kk++) {\n                        var r = gnmRend(nd[kk]), m = null;\n                        try { m = r.material; } catch (e) { }\n                        if (!m) { continue; }\n                        if (m.__gn"
    @"mDirty) { nrend++; continue; }\n                        if (!g_cesp) { try { g_cesp = new La.Vector4(1.0, 0.15, 0.15, 1.0); } catch (e) { } }\n                        var oT = null, oW = null, oQ = null, oC = null;\n                        try { oT = m.depthTest; oW = m.depthWrite; oQ = m.renderQueue; } catch (e) { }\n                        try { oC = m.albedoColor; } catch (e) { "
    @"}\n                        S.dirty.push({ m: m, t: oT, w: oW, q: oQ, c: oC });\n                        m.__gnmDirty = 1;\n                        gnmSetP(m, 'depthTest', 0x0207);\n                        gnmSetP(m, 'depthWrite', false);\n                        gnmSetP(m, 'renderQueue', 3000);\n                        gnmSetP(m, 'cull', 0);\n                        try { if (m.albedo"
    @"Color && g_cesp) { m.albedoColor = g_cesp; } } catch (e) { }\n                        nrend++;\n                    }\n                }\n            }\n            S.nrend = nrend;\n        }, 200);\n\n        /* 2) per-frame positional update: smooth, never clear/redraw */\n        La.timer.frameLoop(1, null, function () {\n            var cfg = G.__GNM_CFG || { esp: 0, bright: 0, ad: "
    @"1 };\n            var cam = S.cam, hits = S.cache;\n            /* mode 1 = box + name + distance, mode 2 = material see-through only */\n            if (cfg.esp !== 1 || !cam || !hits || !hits.length) { hideAll(); return; }\n            var kx = S.vw ? La.stage.width / S.vw : 1;\n            var drew = 0, first = '';\n            for (var jj = 0; jj < hits.length && jj < S.units.len"
    @"gth; jj++) {\n                try {\n                    var ep = hits[jj].n.transform.position;\n                    var pf = new La.Vector3(), ph = new La.Vector3();\n                    cam.worldToViewportPoint(ep, pf);\n                    cam.worldToViewportPoint(new La.Vector3(ep.x, ep.y + 1.8, ep.z), ph);\n                    if (!isFinite(pf.x) || !isFinite(pf.y)) { continue;"
    @" }\n                    var x = pf.x * kx, yf = pf.y * kx, yh = ph.y * kx;\n                    var bh = Math.abs(yf - yh);\n                    if (!(bh > 8)) { bh = 140; }\n                    if (bh > 420) { bh = 420; }\n                    if (bh < 40) { bh = 40; }\n                    var un = S.units[jj];\n                    un.box.visible = true;\n                    un.box.x ="
    @" x;\n                    un.box.y = yf;\n                    un.box.scaleY = bh / 100;\n                    un.box.scaleX = (bh * 0.55) / 54;\n                    var dist = 0;\n                    if (S.camPos) {\n                        var dx = ep.x - S.camPos.x, dy = ep.y - S.camPos.y, dz = ep.z - S.camPos.z;\n                        dist = Math.sqrt(dx * dx + dy * dy + dz * dz);\n"
    @"                    }\n                    un.txt.visible = true;\n                    un.txt.x = x - 60;\n                    un.txt.y = yh - 22;\n                    var label = hits[jj].i.label + ' ' + dist.toFixed(1) + 'm';\n                    if (un.txt.text !== label) { un.txt.text = label; }\n                    if (!first) { first = hits[jj].n.name; }\n                    dre"
    @"w++;\n                } catch (e) { }\n            }\n            for (var r2 = drew; r2 < S.units.length; r2++) {\n                if (S.units[r2].box.visible) { S.units[r2].box.visible = false; S.units[r2].txt.visible = false; }\n            }\n            S.drew = drew; S.first = first;\n            if (S.ticks && S.logged !== S.ticks) {\n                S.logged = S.ticks;\n        "
    @"        L('planG draw=' + drew + '/' + hits.length + ' mat=' + S.nrend +\n                  ' first=' + first + ' scaleY=' + S.units[0].box.scaleY.toFixed(2) +\n                  ' stage=' + La.stage.width + 'x' + La.stage.height);\n            }\n        });\n        return true;\n    }\n    var planGTries = 0;\n    var planGT = setInterval(function () {\n        planGTries++;\n        "
    @"if (gnmInstallPlanG() || planGTries > 200) {\n            clearInterval(planGT);\n            if (planGTries > 200) { L('planG giveup: no Laya.stage'); }\n        }\n    }, 150);\n})();\n";
static NSString *const kHookJSON =
    @"window.__GNM_HOOK_SRC = \"/*\\n * hook.js -- spliced into js/bundle.js IIFE (evaluated in global scope by boot.js)\\n * Available: SceneMgr / PropMgr / MainRoleMgr / Role / iOSDeal / SDK / SDK_ORDER / Laya\\n * Switch: G.__GNM_CFG pushed by native via [conchRuntime runJS:]\\n *\\n * Features:\\n *   1) ad skip  2) see-through (depthTest=ALWAYS)  3) draw enemies on screen  4) bright\\n "
    @"* ASCII-only on purpose: runJS must not carry non-ASCII bytes.\\n */\\n(function () {\\n    'use strict';\\n    var G = null;\\n    try { if (typeof window !== 'undefined' && window) { G = window; } } catch (e) { }\\n    if (!G) { try { G = globalThis; } catch (e) { } }\\n    if (!G) { G = this; }\\n    var CFG = G.__GNM_CFG = G.__GNM_CFG || { esp: 0, bright: 0, ad: 1 };\\n    function "
    @"LOG(m) { try { if (G.__GNM_LOG) { G.__GNM_LOG('[hook] ' + m); } } catch (e) { } }\\n    var L = (typeof Laya !== 'undefined' && Laya) ? Laya : G.Laya;\\n    if (!L) { LOG('Laya missing abort'); return; }\\n    G.__GNM_HOOK_INSTALLED = 1;\\n    LOG('hook v2 enter');\\n\\n    /* ---------- 1. ad skip (JS layer; native has fallback) ---------- */\\n    try {\\n        if (typeof iOSDeal !"
    @"== 'undefined' && iOSDeal && iOSDeal.prototype) {\\n            var _video = iOSDeal.prototype.videoChange;\\n            iOSDeal.prototype.videoChange = function () {\\n                if (!CFG.ad) { return _video ? _video.apply(this, arguments) : undefined; }\\n                LOG('reward skipped -> auto ok');\\n                try { SDK.ins_.send(SDK_ORDER.AD_VIDEO_CLOSE, { name:"
    @" 'iOS', info: 'ok' }); } catch (e) { }\\n            };\\n            iOSDeal.prototype.insertChange = function () { if (CFG.ad) { return; } };\\n            iOSDeal.prototype.bannerChange = function () { if (CFG.ad) { return; } };\\n            iOSDeal.prototype.impactionChange = function () { if (CFG.ad) { return; } };\\n            iOSDeal.prototype.nativeSmallChange = function ("
    @") { if (CFG.ad) { return; } };\\n            LOG('iOSDeal ad hooks ok');\\n        } else { LOG('iOSDeal missing'); }\\n    } catch (e) { LOG('ad hook err ' + e); }\\n\\n    /* ---------- 2. 3D helpers ---------- */\\n    function rend(n) {\\n        if (!n) { return null; }\\n        try { if (n.skinnedMeshRenderer) { return n.skinnedMeshRenderer; } } catch (e) { }\\n        try { if ("
    @"n.meshRenderer) { return n.meshRenderer; } } catch (e) { }\\n        return null;\\n    }\\n    function setP(o, k, v) { try { o[k] = v; return 1; } catch (e) { return 0; } }\\n    function collect(root, cap) {\\n        var out = [], st = [], g = 0;\\n        if (!root) { return out; }\\n        st.push(root);\\n        while (st.length && g++ < (cap || 30000)) {\\n            var c = "
    @"st.pop();\\n            if (rend(c)) { out.push(c); }\\n            try {\\n                var n = c.numChildren | 0;\\n                for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\\n            } catch (e) { }\\n        }\\n        return out;\\n    }\\n\\n    /* ---------- 3. enemy detection ---------- */\\n    var KEYS = ['nainai', 'kbnn', 'zhizhu"
    @"', 'wuya', 'ying_er', 'yinger', 'monster', 'enemy'];\\n    function isEnemy(nm) {\\n        if (!nm) { return false; }\\n        var s = ('' + nm).toLowerCase();\\n        for (var i = 0; i < KEYS.length; i++) { if (s.indexOf(KEYS[i]) >= 0) { return true; } }\\n        return false;\\n    }\\n    var sSig = '';\\n    function scanEnemies() {\\n        var sc = null;\\n        try { sc = "
    @"SceneMgr.Inst.getScene(); } catch (e) { }\\n        if (!sc) { return null; }\\n        var found = [], st = [sc], g = 0;\\n        while (st.length && g++ < 30000) {\\n            var c = st.pop();\\n            try {\\n                if (rend(c) && isEnemy(c.name)) { found.push(c); }\\n                var n = c.numChildren | 0;\\n                for (var i = 0; i < n; i++) { var ch "
    @"= c.getChildAt(i); if (ch) { st.push(ch); } }\\n            } catch (e) { }\\n        }\\n        try {\\n            var k = SceneMgr.Inst.GetKbnnScript();\\n            if (k && k.owner) { found.push(k.owner); }\\n        } catch (e) { }\\n        return found;\\n    }\\n\\n    /* ---------- 4. see-through ---------- */\\n    var C_ESP = null, C_WHITE = null;\\n    function espNode(n, on"
    @") {\\n        var r = rend(n); if (!r) { return; }\\n        var m = null;\\n        try { m = r.material; } catch (e) { }\\n        if (!m) { return; }\\n        if (!C_ESP) { C_ESP = new L.Vector4(1.0, 0.15, 0.15, 1.0); C_WHITE = new L.Vector4(1, 1, 1, 1); }\\n        if (on) {\\n            setP(m, 'depthTest', 0x0207);\\n            setP(m, 'depthWrite', false);\\n            setP(m"
    @", 'renderQueue', 3000);\\n            setP(m, 'cull', 0);\\n            try { if (m.albedoColor) { m.albedoColor = C_ESP; } } catch (e) { }\\n        } else {\\n            setP(m, 'depthTest', 0x0201);\\n            setP(m, 'depthWrite', true);\\n            setP(m, 'renderQueue', 2000);\\n            try { if (m.albedoColor) { m.albedoColor = C_WHITE; } } catch (e) { }\\n        }\\n "
    @"   }\\n\\n    /* ---------- 5. bright ---------- */\\n    function brightNode(n) {\\n        var r = rend(n); if (!r) { return; }\\n        var m = null;\\n        try { m = r.sharedMaterial; } catch (e) { }\\n        if (!m) { return; }\\n        try { if (m.albedoColor) { m.albedoColor = new L.Vector4(1, 1, 1, 1); } } catch (e) { }\\n        setP(m, 'enableLighting', false);\\n        "
    @"setP(r, 'lightmapIndex', -1);\\n        setP(r, 'lightmapScaleOffset', null);\\n    }\\n\\n    /* ---------- 6. screen overlay (enemy box) ---------- */\\n    var gSp = null;\\n    function getLayer() {\\n        if (gSp && gSp.parent) { return gSp; }\\n        try {\\n            gSp = new L.Sprite();\\n            gSp.mouseEnabled = false;\\n            gSp.zOrder = 100000;\\n           "
    @" L.stage.addChild(gSp);\\n            LOG('esp layer added');\\n        } catch (e) { LOG('layer err ' + e); }\\n        return gSp;\\n    }\\n    function drawBoxes(list) {\\n        var sp = getLayer();\\n        if (!sp) { return -1; }\\n        try { sp.graphics.clear(); } catch (e) { }\\n        var cam = null;\\n        try { cam = SceneMgr.Inst.GetCamera(); } catch (e) { }\\n      "
    @"  if (!cam) { return -2; }\\n        var n = 0;\\n        for (var i = 0; i < list.length; i++) {\\n            var e = list[i], tp;\\n            try {\\n                tp = new L.Vector3();\\n                var t = e.transform.position;\\n                cam.worldToViewportPoint(t, tp);\\n            } catch (err) { continue; }\\n            var x = tp.x, y = tp.y;\\n            if ("
    @"!isFinite(x) || !isFinite(y)) { continue; }\\n            if (x < -200 || x > 3000 || y < -200 || y > 3000) { continue; }\\n            try {\\n                sp.graphics.drawRect(x - 30, y - 70, 60, 140, null, '#FF3030', 3);\\n                n++;\\n            } catch (err) { }\\n        }\\n        return n;\\n    }\\n\\n    /* ---------- 7. main loop ---------- */\\n    var sScene = "
    @"null, sSceneNodes = null, sSceneDone = 0, sTicks = 0;\\n\\n    function tick() {\\n        sTicks++;\\n        try {\\n            var sc = null;\\n            try { sc = SceneMgr.Inst.getScene(); } catch (e) { }\\n            if (sc !== sScene) {\\n                sScene = sc; sSceneNodes = sc ? collect(sc) : null; sSceneDone = 0;\\n                LOG('scene nodes=' + (sSceneNodes ? s"
    @"SceneNodes.length : 0));\\n            }\\n            if (CFG.bright && sSceneNodes && !sSceneDone) {\\n                sSceneDone = 1;\\n                setP(sScene, 'enableFog', false);\\n                try { sScene.ambientColor = new L.Vector3(1, 1, 1); } catch (e) { }\\n                for (var i = 0; i < sSceneNodes.length; i++) { brightNode(sSceneNodes[i]); }\\n               "
    @" var cm = null;\\n                try { cm = SceneMgr.Inst.GetCamera(); } catch (e) { }\\n                if (cm) { setP(cm, 'nearPlane', 0.02); setP(cm, 'farPlane', 5000); }\\n                LOG('bright applied n=' + sSceneNodes.length);\\n            }\\n\\n            var en = scanEnemies();\\n            if (en) {\\n                var sig = en.length + ':';\\n                for ("
    @"var q = 0; q < en.length; q++) { sig += (en[q].name || '?') + ','; }\\n                if (sig !== sSig) { sSig = sig; LOG('enemies=' + sig); }\\n                var nd, ii, kk;\\n                if (CFG.esp >= 1) {\\n                    for (ii = 0; ii < en.length; ii++) {\\n                        nd = collect(en[ii], 2000);\\n                        for (kk = 0; kk < nd.length; kk"
    @"++) { espNode(nd[kk], true); }\\n                    }\\n                    var d = drawBoxes(en);\\n                    if (sTicks % 10 === 0) { LOG('draw=' + d + ' of ' + en.length); }\\n                } else {\\n                    for (ii = 0; ii < en.length; ii++) {\\n                        nd = collect(en[ii], 2000);\\n                        for (kk = 0; kk < nd.length; kk++"
    @") { espNode(nd[kk], false); }\\n                    }\\n                    if (gSp) { try { gSp.graphics.clear(); } catch (e) { } }\\n                }\\n            }\\n\\n            G.__GNM_ALIVE = 1;\\n            if (sTicks % 20 === 0) {\\n                LOG('tick ' + sTicks + ' esp=' + CFG.esp + ' bright=' + CFG.bright +\\n                    ' ad=' + CFG.ad + ' enemy=' + (en ? "
    @"en.length : -1));\\n            }\\n        } catch (e) { LOG('tick err ' + e); }\\n    }\\n\\n    try { setInterval(tick, 200); LOG('timer ok'); } catch (e) { LOG('timer fail ' + e); }\\n    tick();\\n    LOG('hook v2 installed esp=' + CFG.esp + ' bright=' + CFG.bright + ' ad=' + CFG.ad);\\n})();\\n\";";
static NSString *const kHookJS =
    @"/*\n * hook.js -- spliced into js/bundle.js IIFE (evaluated in global scope by boot.js)\n * Available: SceneMgr / PropMgr / MainRoleMgr / Role / iOSDeal / SDK / SDK_ORDER / Laya\n * Switch: G.__GNM_CFG pushed by native via [conchRuntime runJS:]\n *\n * Features:\n *   1) ad skip  2) see-through (depthTest=ALWAYS)  3) draw enemies on screen  4) bright\n * ASCII-only on purpose: runJS m"
    @"ust not carry non-ASCII bytes.\n */\n(function () {\n    'use strict';\n    var G = null;\n    try { if (typeof window !== 'undefined' && window) { G = window; } } catch (e) { }\n    if (!G) { try { G = globalThis; } catch (e) { } }\n    if (!G) { G = this; }\n    var CFG = G.__GNM_CFG = G.__GNM_CFG || { esp: 0, bright: 0, ad: 1 };\n    function LOG(m) { try { if (G.__GNM_LOG) { G.__GNM"
    @"_LOG('[hook] ' + m); } } catch (e) { } }\n    var L = (typeof Laya !== 'undefined' && Laya) ? Laya : G.Laya;\n    if (!L) { LOG('Laya missing abort'); return; }\n    G.__GNM_HOOK_INSTALLED = 1;\n    LOG('hook v2 enter');\n\n    /* ---------- 1. ad skip (JS layer; native has fallback) ---------- */\n    try {\n        if (typeof iOSDeal !== 'undefined' && iOSDeal && iOSDeal.prototype) {"
    @"\n            var _video = iOSDeal.prototype.videoChange;\n            iOSDeal.prototype.videoChange = function () {\n                if (!CFG.ad) { return _video ? _video.apply(this, arguments) : undefined; }\n                LOG('reward skipped -> auto ok');\n                try { SDK.ins_.send(SDK_ORDER.AD_VIDEO_CLOSE, { name: 'iOS', info: 'ok' }); } catch (e) { }\n            };\n"
    @"            iOSDeal.prototype.insertChange = function () { if (CFG.ad) { return; } };\n            iOSDeal.prototype.bannerChange = function () { if (CFG.ad) { return; } };\n            iOSDeal.prototype.impactionChange = function () { if (CFG.ad) { return; } };\n            iOSDeal.prototype.nativeSmallChange = function () { if (CFG.ad) { return; } };\n            LOG('iOSDeal ad "
    @"hooks ok');\n        } else { LOG('iOSDeal missing'); }\n    } catch (e) { LOG('ad hook err ' + e); }\n\n    /* ---------- 2. 3D helpers ---------- */\n    function rend(n) {\n        if (!n) { return null; }\n        try { if (n.skinnedMeshRenderer) { return n.skinnedMeshRenderer; } } catch (e) { }\n        try { if (n.meshRenderer) { return n.meshRenderer; } } catch (e) { }\n        r"
    @"eturn null;\n    }\n    function setP(o, k, v) { try { o[k] = v; return 1; } catch (e) { return 0; } }\n    function collect(root, cap) {\n        var out = [], st = [], g = 0;\n        if (!root) { return out; }\n        st.push(root);\n        while (st.length && g++ < (cap || 30000)) {\n            var c = st.pop();\n            if (rend(c)) { out.push(c); }\n            try {\n       "
    @"         var n = c.numChildren | 0;\n                for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\n            } catch (e) { }\n        }\n        return out;\n    }\n\n    /* ---------- 3. enemy detection ---------- */\n    var KEYS = ['nainai', 'kbnn', 'zhizhu', 'wuya', 'ying_er', 'yinger', 'monster', 'enemy'];\n    function isEnemy(nm) {\n        "
    @"if (!nm) { return false; }\n        var s = ('' + nm).toLowerCase();\n        for (var i = 0; i < KEYS.length; i++) { if (s.indexOf(KEYS[i]) >= 0) { return true; } }\n        return false;\n    }\n    var sSig = '';\n    function scanEnemies() {\n        var sc = null;\n        try { sc = SceneMgr.Inst.getScene(); } catch (e) { }\n        if (!sc) { return null; }\n        var found = []"
    @", st = [sc], g = 0;\n        while (st.length && g++ < 30000) {\n            var c = st.pop();\n            try {\n                if (rend(c) && isEnemy(c.name)) { found.push(c); }\n                var n = c.numChildren | 0;\n                for (var i = 0; i < n; i++) { var ch = c.getChildAt(i); if (ch) { st.push(ch); } }\n            } catch (e) { }\n        }\n        try {\n        "
    @"    var k = SceneMgr.Inst.GetKbnnScript();\n            if (k && k.owner) { found.push(k.owner); }\n        } catch (e) { }\n        return found;\n    }\n\n    /* ---------- 4. see-through ---------- */\n    var C_ESP = null, C_WHITE = null;\n    function espNode(n, on) {\n        var r = rend(n); if (!r) { return; }\n        var m = null;\n        try { m = r.material; } catch (e) { }\n "
    @"       if (!m) { return; }\n        if (!C_ESP) { C_ESP = new L.Vector4(1.0, 0.15, 0.15, 1.0); C_WHITE = new L.Vector4(1, 1, 1, 1); }\n        if (on) {\n            setP(m, 'depthTest', 0x0207);\n            setP(m, 'depthWrite', false);\n            setP(m, 'renderQueue', 3000);\n            setP(m, 'cull', 0);\n            try { if (m.albedoColor) { m.albedoColor = C_ESP; } } catch"
    @" (e) { }\n        } else {\n            setP(m, 'depthTest', 0x0201);\n            setP(m, 'depthWrite', true);\n            setP(m, 'renderQueue', 2000);\n            try { if (m.albedoColor) { m.albedoColor = C_WHITE; } } catch (e) { }\n        }\n    }\n\n    /* ---------- 5. bright ---------- */\n    function brightNode(n) {\n        var r = rend(n); if (!r) { return; }\n        var m "
    @"= null;\n        try { m = r.sharedMaterial; } catch (e) { }\n        if (!m) { return; }\n        try { if (m.albedoColor) { m.albedoColor = new L.Vector4(1, 1, 1, 1); } } catch (e) { }\n        setP(m, 'enableLighting', false);\n        setP(r, 'lightmapIndex', -1);\n        setP(r, 'lightmapScaleOffset', null);\n    }\n\n    /* ---------- 6. screen overlay (enemy box) ---------- */\n "
    @"   var gSp = null;\n    function getLayer() {\n        if (gSp && gSp.parent) { return gSp; }\n        try {\n            gSp = new L.Sprite();\n            gSp.mouseEnabled = false;\n            gSp.zOrder = 100000;\n            L.stage.addChild(gSp);\n            LOG('esp layer added');\n        } catch (e) { LOG('layer err ' + e); }\n        return gSp;\n    }\n    function drawBoxes(li"
    @"st) {\n        var sp = getLayer();\n        if (!sp) { return -1; }\n        try { sp.graphics.clear(); } catch (e) { }\n        var cam = null;\n        try { cam = SceneMgr.Inst.GetCamera(); } catch (e) { }\n        if (!cam) { return -2; }\n        var n = 0;\n        for (var i = 0; i < list.length; i++) {\n            var e = list[i], tp;\n            try {\n                tp = new"
    @" L.Vector3();\n                var t = e.transform.position;\n                cam.worldToViewportPoint(t, tp);\n            } catch (err) { continue; }\n            var x = tp.x, y = tp.y;\n            if (!isFinite(x) || !isFinite(y)) { continue; }\n            if (x < -200 || x > 3000 || y < -200 || y > 3000) { continue; }\n            try {\n                sp.graphics.drawRect(x - "
    @"30, y - 70, 60, 140, null, '#FF3030', 3);\n                n++;\n            } catch (err) { }\n        }\n        return n;\n    }\n\n    /* ---------- 7. main loop ---------- */\n    var sScene = null, sSceneNodes = null, sSceneDone = 0, sTicks = 0;\n\n    function tick() {\n        sTicks++;\n        try {\n            var sc = null;\n            try { sc = SceneMgr.Inst.getScene(); } cat"
    @"ch (e) { }\n            if (sc !== sScene) {\n                sScene = sc; sSceneNodes = sc ? collect(sc) : null; sSceneDone = 0;\n                LOG('scene nodes=' + (sSceneNodes ? sSceneNodes.length : 0));\n            }\n            if (CFG.bright && sSceneNodes && !sSceneDone) {\n                sSceneDone = 1;\n                setP(sScene, 'enableFog', false);\n                tr"
    @"y { sScene.ambientColor = new L.Vector3(1, 1, 1); } catch (e) { }\n                for (var i = 0; i < sSceneNodes.length; i++) { brightNode(sSceneNodes[i]); }\n                var cm = null;\n                try { cm = SceneMgr.Inst.GetCamera(); } catch (e) { }\n                if (cm) { setP(cm, 'nearPlane', 0.02); setP(cm, 'farPlane', 5000); }\n                LOG('bright applied"
    @" n=' + sSceneNodes.length);\n            }\n\n            var en = scanEnemies();\n            if (en) {\n                var sig = en.length + ':';\n                for (var q = 0; q < en.length; q++) { sig += (en[q].name || '?') + ','; }\n                if (sig !== sSig) { sSig = sig; LOG('enemies=' + sig); }\n                var nd, ii, kk;\n                if (CFG.esp >= 1) {\n     "
    @"               for (ii = 0; ii < en.length; ii++) {\n                        nd = collect(en[ii], 2000);\n                        for (kk = 0; kk < nd.length; kk++) { espNode(nd[kk], true); }\n                    }\n                    var d = drawBoxes(en);\n                    if (sTicks % 10 === 0) { LOG('draw=' + d + ' of ' + en.length); }\n                } else {\n              "
    @"      for (ii = 0; ii < en.length; ii++) {\n                        nd = collect(en[ii], 2000);\n                        for (kk = 0; kk < nd.length; kk++) { espNode(nd[kk], false); }\n                    }\n                    if (gSp) { try { gSp.graphics.clear(); } catch (e) { } }\n                }\n            }\n\n            G.__GNM_ALIVE = 1;\n            if (sTicks % 20 === 0) "
    @"{\n                LOG('tick ' + sTicks + ' esp=' + CFG.esp + ' bright=' + CFG.bright +\n                    ' ad=' + CFG.ad + ' enemy=' + (en ? en.length : -1));\n            }\n        } catch (e) { LOG('tick err ' + e); }\n    }\n\n    try { setInterval(tick, 200); LOG('timer ok'); } catch (e) { LOG('timer fail ' + e); }\n    tick();\n    LOG('hook v2 installed esp=' + CFG.esp + ' br"
    @"ight=' + CFG.bright + ' ad=' + CFG.ad);\n})();\n";
static NSString *const kAvatarB64 =
    @"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"
    @"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"
    @"vDDWM4G3lQ10caRFvhM26OkreWrjfdxupR5n9gKvvTFnZgQ0NoSAQNz313zmKXWY6kjbIqGGEoSMAUDdIfR8i7awgathECUwwY0lrH8VORwrB70jIPeMd1WQhISMVqrBojAYxFEYq2RGdrzBZDZH2XM/yn/FSBcSoZSoEGkcAU1fjLAK4boaXzKFDKD/AI9PhRq79gweoF6txzHq1Ab5pJTgHbUPJnXGMD7Tb3yB+NkdYn5b/EVHPakYScHrUnuLK8/pRTqqx7yF0rnoQgfeAzvUVOmpQlR4gMDJJ5CotVynzBwwLXNkE8lKR1SPUqx+lYTp96YoL1BKStAORCjE8H96uavkKQ1HkAoyP1PUeq0QHLn/ADIoNydTy+qj8QtqF/au/wDWI7E/y+PbRgxBRGYS2gBKUjApVtYYYSzFZRHaSMAJFM5LijnJJPiaw7fLInKgsf0jYpNhwOBMPgcWM/Osm6lnCJfugnAc7D59xqMkuL3waaqmuJQpCkpdbIwpCxkEVGl84pbkYl7PH5H1hEqYhYyFg+tIuPpI55oTEdLzh+q56obvP2d4caD/AEnmPj6VspWo2Nlwo8gfmbkYz6EV6WnXK4zMq3RlTgQgdezsKayHGWGVvyXUNtp3UpRwBUG5M1GoFLdujMfzLdK/kAKj3rVcJbgduUpTygcgckp8hyFGbVqPl5gRpT/EYhfbou7OpZZSpuGhWUpIwXD+Y+HcPWmaooW2RiphNvQ0MYrVTISeVJsxY5MbUBRgSstc6PXemXERU/6pKSpnxUBkD15etAN0tTk/oXmTFNKC4t2aUARuMcKFD/z3rpSGw31gWUDPfURr2xtztG3iDGjoCnWeJKEJAy4XEHO3aTRa1xOa3PEG4XRz9b/RElMojlVx9ocvUXb3ste7gf1NpWPUUAfRik56UNOqBPvOFB/7FCuzLDa2LPYYFnbSFNQ4yGMHkrCcH4nPxrlXo70uvSf0pRp1KFJYjXJb0bxYWhS0H4HHpTrpgqYrVZuVx+c6zX92sA7c62VyrUDINMRGMtdMdfYVoxnCwarXpotgh9EsfhGCic2tX9yVCrfujIfhrQeWQaCOmyJ7T0VXVIGeoS28P7VDPyJpDVDn8o9pGwVH3nGGqXVqww0CpxZwlI7SdgKu7oZ0oI0ODbwnJ2W8rvPNR+NVvoHTj2oNRTLotBMK1lCSewurzwj0AUr0FdOdFtsDTS5RTj8KfSkuzial7bVlH/SfX7Jrh2O2klRixkISkZJ93YAetZ0BoJ2xhD1zZ/8AmHwOsQd+oB5N+ff47dlXpcejqFcelxrXVycbkMxIbaYkUpziQnI6xXYQkY4R379gpKy2oSL9LnPpJw8rgz586hgehKDUDYB9BHejrAiBHC3Eguq3UaLmkhKaSYQEJxtW6lY7aIOIkxLHJiqiMYpNRrTjNaKWc1xM4TcnJwOZNOnoaERus41lXyprG959GR25p084T9nnbhJqFwc5ksCMYkc1KC+LhVkpOD4GtlPE8yTQvKn/AFfqBfGcNPJwrwI5GnVwu7cSMJZyWkn3yN+EHtpG/VGqtm9xHU0xZhj3k06XFDAJApMM47BTW3XmNKaS424hxCuSknINS8dcd7GFpz41i1ldU24tk/eEcNVwRI91JAO1R8lJGaKFRG1IyCKirlGShJ5VGr0DquZNF6k4g0+OdR0lJ3NSUshKyM1GS3QAa8+QQZsJGEltKk77Ebgjsp1aryULEaYvOThLh/eo2ZLQkElQqOLzEgnKio9ya2PHai1WwDBailWXkQ+WUlOdqaPEb1A6bvJdaVGcXxhCsIXnmKmVr4gSDXrK23KDMKxCrFTGz2N6ZO86dPqO9NVbmriUxFoh3FEGmYyJN3aS6gLQPeIPLbcfMCoOIgE0XaKYPtjjuPuN/rTVAywi9xwphKsnOSaFp2i4EvpPtuvOuUiVCgORFNBGzpOeBZPYUhSx45HdRUsVpitEjMQBI6mSqsDJr361sBUiRHzoBBHfUVf7e3d7BcLS6QETI62So9nEkgH0ODUqsb02d91WKX1C5GYalsGVNoLQT+kuiT2C4NoF2flqmzOAhWFE8KU5HPCAPiaPdMRxGtjTYGNsmpKalLzC21bhQ3pvHHVN8I5Cs8rgx4uWHMeLI4T5VHtMIacUUjGTmnBcpNah31xlJuSANjWpV30l1nPetCvxqDJi2axkUgXPGsdZ41UmXVY/hBReUQCeFJO1KuJUkLeWkp93hSCNz3msWY5Lyx3AVm5rPVmpX5cyGPqxK01yrilKxkHhPKojSl7cda9lfWQrHuqNSOr18UtzJ5CgW3OKbUlxJwQazLly5H1m3pxmmGj9ujTluSbbNfsV0Cj1imEhbLiu9xk7HPekpPnTB++a8sW9w081fIqf/tWZ3iVjvUyvCh6E0opL81hMyCsCY2MFJOA6n8p8e40lC1Clay24VMvoOFNr2KTXntTU+nbDruX2Pv8AqJoUkWDjn7H/ALmYhdMunQvqZk6RbXgcKamNKZUD/cMVNs69s1xQDGu0Z8HlwOpV+hqKuLltubRRcIseUk8+tbCv1oPuuh9DSFKWbPHZWe1r3aALkYYyw/PP+IUUUE524MPZd6ZXuhXF5VAXe9NtNlbsuNGQOannQkfOgJ/Qmngs9QZIT3B1WP1pWJozT7Cgv2NC1D8TnvH51K0Vd5J/L/mF+HWvRjqbqu1uKKIi5N5ezsiKnDefFZ2+GaWgxrtdMPXdSIcEEFFvjEgO9wcXzUPDYeFOmGoUMBEdlPEdgEp51PQIjmA8/svGyfyj/Naejq3thBxFdVctS5xMQWVNAEbHOdqnosglIyd6YpbxSzY4a9GoxxPOO2TmO3VZpNKSTWUgqNLtN5NEAgyY4iIwBRzpZgtQFPEYLitvIUK22MXnUtpGSogCj1ppLEdthHJCQKe0y85iWobjE8s7bVoayusDBNOxSercCta3FdidHqxjnSEhBW3kcxvThY3pJ55qMyp99wNtpGSTVWAI5llzkY7kQ69gkE0iXRnnQVqjX9jj31MZD/Uh08KesIAUvuHdnurZvU0dYyHR8axnuQMQDN4+M1CKGZSMwwLw76TW+O+hVWoGcZ6wfGkHdRsJG7qfjQzcs5dBYfaFapCQSM0muUnvoMd1PHB/ij0ps5qmOD99R/tNUN6xpPE3n+E/pDdUkZ+9XhJT30Aq1Uxz4l/9prw1XH71/wDaaG14jC+H1H8h/SXBpw8UBxzvcI+AFJ3ZeEKrGi1h3ScGTv8AboLvoonHyxSN8XhpeKb6rEwmXFrD6GVlqtf2klZPIH9KCIbgCRvRLr6YiHY7jMcVwpQgkn5fvVWQtSxF4AfSfI1nsMvN3ToTSZZtlm9U4BxbGpC/WiDemg9/ClJHuuo2Pr31X0G+NFQKXB8aLLXd0qSPfHxqzKrjaw4g8Ojbk4MHZsK+W9woz16ByIODTQ3CQg4ejvpPig0eyH2X0HODUatptKiUms5/F1McrxH08i2MOuYLtzHnDhqO+s9wbNSEW3XOSQXEiMg9q+fwFTjRA7actqT31erxVYPqJMFd5JsehQInbLZHiDiSC452rVz9O6pBKaTQtPfSwWmtWutUXaowJj2O9h3MczYJrdKN616xPfWDIQntoogdpjtpNPGUZqEcuTTYJKxSVq1XYv8AiKLbrneIsBDvvKU6vGw7B4nlnlREwTiQa2IyBLQ0lA4UmY4nYbN+faanV16I7EfhtrgutOx+EBCmlBSceYrKgc1rIoQYmS7FjkxMjNa8O+1bkYOK9jtq8pNcVuAMVrWw5Vw7nR+vASVEgAbkmgjVMmRdULbjEhsZDYzjPjUv0gXFdtsBWgHLqw2SOwYyf0qpJmqXEgpC1D1pDV3hfQZ6XwXjXu/8y+x4gjrvou1BfnClFxtkRlRypchxRI8QEg5PwrNl0k1p+EmNctYS7u6jZIbZDaQO7JJUfM04ul9lSSR1ignzqJEshRUSSc1jFkAwon0JdNfaAbm69gIQ"
    @"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"
    @"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";

#pragma mark - native 侧 bundle 定位 + 插桩（JS 读不到文件时的权威通道）
// bundle 缓存文件 = 明文 JS（1022195B，无额外头）。文件名 = crc32(路径) 的 %08x。
// 搜索顺序：getRootCachePath/LayaCache/appCache/stand.alone.version → 各候选目录 → bundle 内 cache/
static NSString *g_bundlePath = nil;

static NSString *gnm_find_bundle(void) {
    if (g_bundlePath) { return g_bundlePath; }
    NSString *home = NSHomeDirectory();
    NSMutableArray *roots = [NSMutableArray array];
    // 1) getRootCachePath 衍生
    Class cc = NSClassFromString(@"conchRuntime");
    id inst = nil;
    if (cc && [cc respondsToSelector:@selector(GetIOSConchRuntime)]) {
        inst = ((id (*)(id, SEL))objc_msgSend)(cc, @selector(GetIOSConchRuntime));
    }
    if (inst && [inst respondsToSelector:@selector(getRootCachePath)]) {
        NSString *rp = ((id (*)(id, SEL))objc_msgSend)(inst, @selector(getRootCachePath));
        if (rp.length) {
            [roots addObject:rp];
            [roots addObject:[rp stringByAppendingPathComponent:@"stand.alone.version"]];
            [roots addObject:[rp stringByAppendingPathComponent:@"appCache/stand.alone.version"]];
            [roots addObject:[rp stringByAppendingPathComponent:@"LayaCache/appCache/stand.alone.version"]];
        }
    }
    [roots addObject:[home stringByAppendingPathComponent:@"Library/Caches/LayaCache/appCache/stand.alone.version"]];
    [roots addObject:[home stringByAppendingPathComponent:@"Library/Caches/stand.alone.version"]];
    // 2) bundle 内 cache（只读，standalone 模式可能直接读这里）
    NSString *bp = [NSBundle mainBundle].bundlePath;
    [roots addObject:[bp stringByAppendingPathComponent:@"cache/stand.alone.version"]];
    [roots addObject:[bp stringByAppendingPathComponent:@"cache"]];

    NSFileManager *fm = [NSFileManager defaultManager];
    // 2a) 首选：crc32("/js/bundle.js") = 6ab7299a
    for (NSString *r in roots) {
        NSString *p = [r stringByAppendingPathComponent:@"6ab7299a"];
        NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
        if ([at fileSize] > 500000) {
            g_bundlePath = p;
            mlog(@"bundle FOUND %@ (%llu B)", p, [at fileSize]);
            return g_bundlePath;
        }
    }
    // 2b) 兜底：扫 >= 600KB 且含 "}());" 的文件
    for (NSString *r in roots) {
        NSArray *items = [fm contentsOfDirectoryAtPath:r error:nil];
        if (!items.count) { continue; }
        for (NSString *f in items) {
            NSString *p = [r stringByAppendingPathComponent:f];
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            if ([at fileSize] < 600000) { continue; }
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
            NSData *head = [fh readDataOfLength:64];
            NSData *tail = nil;
            unsigned long long sz = [at fileSize];
            [fh seekToFileOffset:(sz > 64 ? sz - 64 : 0)];
            tail = [fh readDataToEndOfFile];
            [fh closeFile];
            NSString *hs = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
            NSString *ts = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
            if (hs && ts && [ts rangeOfString:@"}());"].location != NSNotFound) {
                g_bundlePath = p;
                mlog(@"bundle FOUND by scan %@ (%llu B)", p, sz);
                return g_bundlePath;
            }
        }
        mlog(@"bundle scan miss %@", r);
    }
    return nil;
}

static NSString *g_instrumentedPath = nil;
static BOOL g_instrumented = NO;

// 把 hook 源码写进 bundle 缓存文件副本，返回该副本路径（推给 JS 用 eval 执行）
static NSString *gnm_instrument_bundle(void) {
    if (g_instrumented) { return g_instrumentedPath; }
    NSString *src = gnm_find_bundle();
    if (!src) { mlog(@"instrument: bundle not found"); return nil; }
    NSData *data = [NSData dataWithContentsOfFile:src];
    if (data.length < 500000) { mlog(@"instrument: read fail %lu", (unsigned long)data.length); return nil; }
    NSString *code = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!code.length) { mlog(@"instrument: decode fail"); return nil; }

    NSRange r = [code rangeOfString:@"}());" options:NSBackwardsSearch];
    NSUInteger idx = (r.location == NSNotFound) ? code.length : r.location;
    NSString *out = [NSString stringWithFormat:@"%@\n%@\n%@",
                     [code substringToIndex:idx], kHookJS, [code substringFromIndex:idx]];

    NSString *dst = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                     stringByAppendingPathComponent:@"gnm_bundle.js"];
    NSError *err = nil;
    if (![out writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        mlog(@"instrument: write fail %@", err);
        return nil;
    }
    g_instrumentedPath = dst;
    g_instrumented = YES;
    mlog(@"instrument OK src=%lu out=%lu -> %@", (unsigned long)code.length, (unsigned long)out.length, dst);
    return dst;
}

// 推给 JS：让 JS 侧函数自己读回插桩副本（避免 ObjC 内联 JS 转义 + 未定义变量问题）
// 同时在 Documents 与 cache 目录各存一份，提高被 fishhook / cachePath 命中的概率
static void gnm_push_bundle_to_js(id rt) {
    NSString *path = gnm_instrument_bundle();
    if (!path) { mlog(@"push: no instrumented bundle"); return; }
    // 额外副本：cachePath 目录（JS 侧 fs 绝对路径可能只允许该目录）
    if (g_jsCachePath.length) {
        NSString *alt = [g_jsCachePath stringByAppendingPathComponent:@"gnm_bundle.js"];
        [[NSFileManager defaultManager] removeItemAtPath:alt error:nil];
        NSError *e = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:alt error:&e]) {
            mlog(@"push: copy -> %@", alt);
        } else {
            mlog(@"push: copy fail %@", e);
        }
    }
    NSString *esc = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"try{var G=(typeof window!=='undefined')?window:((typeof globalThis!=='undefined')?globalThis:this);"
        @"if(G.__GNM_LOAD_NATIVE){G.__GNM_LOAD_NATIVE('%@');}"
        @"else{try{G.eval(\"try{G.__GNM_LOG('no loader')\"});}catch(e){}}}catch(e){}", esc];
    gnm_run_js(rt, js);
    mlog(@"native bundle push sent (%@)", path.lastPathComponent);
}

#pragma mark - fishhook：把 JS 侧的 gnm_* 相对路径重定向到 Documents
// LayaNative 的 fs_writeFileSync/fs_readFileSync 底层是纯 fopen，相对路径基于进程 cwd。
// JS 侧 getCachePath() 实测返回 <home>/Library/Caches/，写成相对名就落到不可预期的位置。
// 这里把三个固定文件名的【非绝对路径】读写一律改写到 Documents —— native 必能扫到。
static FILE *(*orig_fopen)(const char *, const char *);
static const char *gnm_redirect_name(const char *path) {
    if (!path || path[0] == '/') { return NULL; }
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    if (!strcmp(base, "gnm_js.log") || !strcmp(base, "gnm_probe.txt") || !strcmp(base, "gnm_flags.json")
        || !strcmp(base, "gnm_bundle.js")) {
        return base;
    }
    return NULL;
}
static FILE *my_fopen(const char *path, const char *mode) {
    const char *base = gnm_redirect_name(path);
    if (base) {
        static char s_doc[512];
        if (!s_doc[0]) { snprintf(s_doc, sizeof(s_doc), "%s/Documents", NSHomeDirectory().UTF8String); }
        char np[768];
        snprintf(np, sizeof(np), "%s/%s", s_doc, base);
        return orig_fopen(np, mode);
    }
    return orig_fopen(path, mode);
}
static void gnm_install_fopen_hook(void) {
    rebind_symbols((struct rebinding[1]){{"fopen", (void *)my_fopen, (void **)&orig_fopen}}, 1);
    mlog(@"fopen redirect installed (gnm_* -> Documents)");
}

#pragma mark - conchRuntime 帧回调 hook（多个入口，任一命中即可）
static void (*orig_renderFrame)(id, SEL);
static void (*orig_runJsLoop)(id, SEL);
static void (*orig_onVsync)(id, SEL, id);
static void (*orig_onGLReady)(id, SEL, int, int, int);
static void gnm_on_frame(id self);
static void gnm_inject(id rt, const char *why);

static void hook_renderFrame(id s, SEL c) { if (orig_renderFrame) { orig_renderFrame(s, c); } gnm_on_frame(s); }
static void hook_runJsLoop(id s, SEL c)   { if (orig_runJsLoop)   { orig_runJsLoop(s, c);   } gnm_on_frame(s); }
static void hook_onVsync(id s, SEL c, id o) {
    if (orig_onVsync) { orig_onVsync(s, c, o); }
    gnm_on_frame(s);
}
// onGLReady 是最早的稳定时机（GL 就绪 + JS 引擎已建），优先在此注入
static void hook_onGLReady(id s, SEL c, int w, int h, int n) {
    if (orig_onGLReady) { orig_onGLReady(s, c, w, h, n); }
    mlog(@"onGLReady w=%d h=%d n=%d -> inject", w, h, n);
    gnm_inject(s, "onGLReady");
    gnm_on_frame(s);
}

static void gnm_run_js(id rt, NSString *js) {
    SEL sel = @selector(runJS:);
    if (!rt || ![rt respondsToSelector:sel]) { return; }
    ((void (*)(id, SEL, id))objc_msgSend)(rt, sel, js);
}

static void gnm_push_cfg(id rt) {
    // 兼容 runJS 的 eval 作用域里可能没有 window 的情况
    NSString *js = [NSString stringWithFormat:
        @"try{var G=(typeof window!=='undefined')?window:((typeof globalThis!=='undefined')?globalThis:this);"
        @"G.__GNM_CFG={esp:%d,bright:%d,ad:%d};}catch(e){}",
        g_esp, g_bright, g_ad];
    gnm_run_js(rt, js);
}

static BOOL g_hookDumped = NO;
static BOOL g_injected = NO;
static BOOL g_nativeEvalPushed = NO;
static int g_bundleRetry = 0;

// 一次性注入：配置 + hook 源码字符串 + bootstrap
// ⚠️ 关键：注入前先把插桩副本准备好，并把路径通过 __GNM_NATIVE_PREP 一起下发。
//    实测第二次 [conchRuntime runJS:] 的求值结果观察不到（JS 侧无任何日志），
//    因此「读回插桩 bundle」必须由本段 boot 自己发起，路径必须随本次注入一起送进去。
static void gnm_inject(id rt, const char *why) {
    if (!rt) { return; }
    NSString *bpath = gnm_instrument_bundle();      // 先准备文件
    g_injected = YES;
    gnm_push_cfg(rt);
    gnm_run_js(rt, kHookJSON);
    gnm_run_js(rt, kBootJS);
    if (bpath.length) {
        NSString *esc = [bpath stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        NSString *pre = [NSString stringWithFormat:
            @"try{var G=(typeof window!=='undefined')?window:((typeof globalThis!=='undefined')?globalThis:this);"
            @"G.__GNM_NATIVE_PREP='%@';}catch(e){}", esc];
        gnm_run_js(rt, pre);
    }
    mlog(@"boot injected (%s) tick=%d hookLen=%lu bootLen=%lu prep=%s",
         why, g_frame, (unsigned long)kHookJSON.length, (unsigned long)kBootJS.length,
         bpath ? bpath.lastPathComponent.UTF8String : "none");
}

static void gnm_on_frame(id rt) {
    g_frame++;

    if (!g_injected && g_frame >= 3) {
        if (!g_hookDumped) {
            Method m = class_getInstanceMethod(object_getClass(rt), @selector(runJS:));
            mlog(@"frame hook alive (tick=%d) runJS: %s", g_frame, m ? "ok" : "MISSING");
            g_hookDumped = YES;
        }
        gnm_inject(rt, "frame3");
    }
    if (g_injected && g_frame % 30 == 0) { gnm_push_cfg(rt); }

    // 注入后 ~tick 60（约 1s）native 侧插桩 bundle 并推给 JS（权威通道）
    if (g_injected && !g_nativeEvalPushed && g_frame >= 60) {
        g_nativeEvalPushed = YES;
        gnm_push_bundle_to_js(rt);
        gnm_probe_dcc("bundle-push");
    }
    // 若 JS 侧读回失败（native eval 没成功），每 300 帧补推一次（最多 5 次）
    if (g_injected && g_nativeEvalPushed && g_bundleRetry < 5 && g_frame % 300 == 0 && g_frame > 300) {
        g_bundleRetry++;
        NSString *cp = g_jsLogCache;
        NSString *flag = cp ? [cp stringByAppendingPathComponent:@"gnm_js.log"] : nil;
        NSString *js2 = [cp stringByAppendingPathComponent:@"gnm_js.log"];
        NSArray *cands = @[ js2 ?: @"/tmp/gnm_js.log",
                            [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gnm_js.log"] ];
        for (NSString *p in cands) {
            NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (!s) { continue; }
            if ([s rangeOfString:@"native eval OK"].location != NSNotFound) { g_bundleRetry = 99; break; }
            if ([s rangeOfString:@"native read FAILED"].location != NSNotFound ||
                [s rangeOfString:@"native eval err"].location != NSNotFound) {
                mlog(@"bundle load failed in JS -> re-push #%d", g_bundleRetry);
                gnm_push_bundle_to_js(rt);
            }
            break;
        }
        (void)flag;
    }

    // 探针/JS 日志：只在注入后前 30s 高频轮询，之后降频
    if (g_injected && (g_frame < 1800 ? (g_frame % 60 == 0) : (g_frame % 600 == 0))) {
        gnm_scan_probe();
        if (g_frame == 120) { gnm_probe_dcc("t120"); }
        // 真·未跑起来才重注入
        if (!g_probeSeen && g_frame < 1200 && g_frame % 300 == 0) {
            mlog(@"probe still missing -> re-inject at tick %d", g_frame);
            gnm_inject(rt, "retry");
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
    m = class_getInstanceMethod(c, @selector(onGLReady:height:downloadThreadNum:));
    if (m) { orig_onGLReady = (void (*)(id, SEL, int, int, int))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_onGLReady); mlog(@"hooked onGLReady"); }
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
    g_btnEsp.text = g_esp == 0 ? @"👁 透视  OFF" : (g_esp == 1 ? @"👁 1 方框+距离" : @"👁 2 奶奶穿墙");
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

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(62, 35, 170, 16)];
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
    mlog(@"ctor: GNMTweak v2 (pid=%d)", getpid());
    gnm_install_js_bridge();
    gnm_install_fopen_hook();     // 必须在任何 JS 写文件之前
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
