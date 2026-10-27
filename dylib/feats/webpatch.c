// Enables Steam Play in the UI, and shows the game properties tab Steam calls Compatibility
// as Bridgeplay, since on a Mac every setting on it is Bridgeplay's
#include "webpatch.h"
#include "nativeplatform.h"
#include "../util/log.h"
#include "../util/file.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NP_C1 "\001"
#define NP_C2 "\002"
#define NP_C3 "\003"
#define NP_C4 "\004"
#define NP_C5 "\005"
#define NP_C6 "\006"
#define NP_C7 "\007"
#define NP_C8 "\010"
// 9-12 sit past whitespace and the \021/\022 markers.
#define NP_C9 "\023"
#define NP_C10 "\024"
#define NP_C11 "\025"
#define NP_C12 "\026"
#define NP_CAP_MAX 12

// Stands for the name set by np_webpatch_set_fallback_tool.
#define NP_FALLBACK_TOOL "\021"
// Stands for the JS array set by np_webpatch_set_fex_tools.
#define NP_FEX_TOOLS "\022"

#define NP_TOOL_NAME_MAX 128

static _Thread_local char g_fallback_tool[NP_TOOL_NAME_MAX];
static _Thread_local char g_fex_tools[NP_WEBPATCH_FEX_TOOLS_MAX * (NP_TOOL_NAME_MAX + 3) + 3] = "[]";

typedef struct {
    const char *find;
    const char *replace;
    int         expect;   // exact occurrence count, else abort
    int         optional; // skipped in the event that it doesn't match the current Steam client
} np_gate_t;

#define NP_GATE_MAX 32

typedef struct { const char *at; size_t len; } np_cap_t;

static int is_ident_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '$';
}

static int cap_index(unsigned char c) {
    if (c >= (unsigned char)NP_C1[0] && c <= (unsigned char)NP_C8[0]) return c - NP_C1[0];
    if (c >= (unsigned char)NP_C9[0] && c <= (unsigned char)NP_C12[0]) return c - NP_C9[0] + 8;
    return -1;
}

static int is_tool_name(const char *name) {
    size_t n = strlen(name);
    if (n >= NP_TOOL_NAME_MAX) return 0;
    for (size_t i = 0; i < n; i++)
        if (!is_ident_char((unsigned char)name[i]) && name[i] != '.' && name[i] != '-')
            return 0;
    return 1;
}

void np_webpatch_set_fallback_tool(const char *name) {
    g_fallback_tool[0] = '\0';
    if (name && is_tool_name(name))
        memcpy(g_fallback_tool, name, strlen(name) + 1);
}

void np_webpatch_set_fex_tools(const char *const *names, size_t count) {
    size_t n = 0;
    g_fex_tools[n++] = '[';
    for (size_t i = 0; i < count && i < NP_WEBPATCH_FEX_TOOLS_MAX; i++) {
        if (!names[i] || !*names[i] || !is_tool_name(names[i])) continue;
        size_t len = strlen(names[i]);
        if (n > 1) g_fex_tools[n++] = ',';
        g_fex_tools[n++] = '"';
        memcpy(g_fex_tools + n, names[i], len);
        n += len;
        g_fex_tools[n++] = '"';
    }
    g_fex_tools[n++] = ']';
    g_fex_tools[n] = '\0';
}

static const char *marker_text(char c) {
    if (c == NP_FALLBACK_TOOL[0]) return g_fallback_tool;
    if (c == NP_FEX_TOOLS[0]) return g_fex_tools;
    return NULL;
}

static size_t match_at(const char *src, size_t len, size_t pos,
                       const char *find, np_cap_t *caps) {
    if (cap_index((unsigned char)find[0]) < 0 && !marker_text(find[0]) && src[pos] != find[0])
        return 0;
    for (int i = 0; i < NP_CAP_MAX; i++) { caps[i].at = NULL; caps[i].len = 0; }

    if (cap_index((unsigned char)find[0]) >= 0 && pos &&
        (is_ident_char((unsigned char)src[pos - 1]) || src[pos - 1] == '.')) return 0;

    size_t s = pos;
    for (const char *f = find; *f; f++) {
        const char *text = marker_text(*f);
        if (text) {
            size_t n = strlen(text);
            if (s + n > len || memcmp(src + s, text, n) != 0) return 0;
            s += n;
            continue;
        }
        int ci = cap_index((unsigned char)*f);
        if (ci < 0) {
            if (s >= len || src[s] != *f) return 0;
            s++;
            continue;
        }

        if (s >= len || (src[s] >= '0' && src[s] <= '9')) return 0;
        size_t run = 0;
        while (s + run < len && is_ident_char((unsigned char)src[s + run])) run++;
        if (run == 0) return 0;

        if (caps[ci].at) {
            if (run != caps[ci].len || memcmp(src + s, caps[ci].at, run) != 0)
                return 0;
        } else {
            caps[ci].at = src + s;
            caps[ci].len = run;
        }
        s += run;
    }
    return s - pos;
}

static void mark_start(unsigned char *can_start, const char *find) {
    if (marker_text(find[0])) {
        memset(can_start, 1, 256);
    } else if (cap_index((unsigned char)find[0]) >= 0) {
        for (int c = 0; c < 256; c++)
            if (is_ident_char((unsigned char)c) && !(c >= '0' && c <= '9')) can_start[c] = 1;
    } else {
        can_start[(unsigned char)find[0]] = 1;
    }
}

static size_t count_matches(const char *src, size_t len, const char *find) {
    np_cap_t caps[NP_CAP_MAX];
    size_t n = 0, lit = 0;
    while (find[lit] && cap_index((unsigned char)find[lit]) < 0 && !marker_text(find[lit])) lit++;
    for (size_t i = 0; i < len; ) {
        if (lit) {
            const char *at = memmem(src + i, len - i, find, lit);
            if (!at) break;
            i = (size_t)(at - src);
        }
        size_t used = match_at(src, len, i, find, caps);
        if (used) { n++; i += used; } else i++;
    }
    return n;
}

typedef struct { char *buf; size_t len, cap; } np_out_t;

static int out_reserve(np_out_t *o, size_t extra) {
    if (o->len + extra + 1 <= o->cap) return 1;
    size_t want = o->cap ? o->cap : 1024;
    while (want < o->len + extra + 1) want *= 2;
    char *grown = realloc(o->buf, want);
    if (!grown) return 0;
    o->buf = grown;
    o->cap = want;
    return 1;
}

static int out_put(np_out_t *o, const char *p, size_t n) {
    if (!out_reserve(o, n)) return 0;
    memcpy(o->buf + o->len, p, n);
    o->len += n;
    return 1;
}

static int out_expand(np_out_t *o, const char *replace, const np_cap_t *caps) {
    for (const char *r = replace; *r; r++) {
        const char *text = marker_text(*r);
        if (text) {
            if (!out_put(o, text, strlen(text))) return 0;
            continue;
        }
        int ci = cap_index((unsigned char)*r);
        if (ci < 0) {
            if (!out_put(o, r, 1)) return 0;
        } else {
            if (!caps[ci].at) return 0;
            if (!out_put(o, caps[ci].at, caps[ci].len)) return 0;
        }
    }
    return 1;
}

// Finds the launch options set before %command%.
#define NP_CX_LAUNCH_PARSE \
    "E=(()=>{let i=0,c=[];const cs=[c]," \
    "qs=x=>{while(i<o.length&&o[i]!==x)i+=x!==\"'\"&&o[i]==='\\\\'?2:1;i++}," \
    "nest=(a,b)=>{for(let d=1;i<o.length&&d;){const x=o[i++];" \
    "if(x==='\\\\')i++;else if(\"'\\\"`\".includes(x))qs(x);else if(x===a)d++;else if(x===b)d--}}," \
    "wd=()=>{const s=i;let v=\"\",q=0,l=1;while(i<o.length){const x=o[i];" \
    "if(q===39){if(x===\"'\")q=0;else v+=x;i++;continue}" \
    "if(x==='\\\\'){const n=o[i+1]||\"\";if(q&&!'\"\\\\$`\\n'.includes(n)){v+=x;i++;continue}" \
    "if(n!=='\\n')v+=n;i+=2;continue}" \
    "if(x==='\"'){q=q?0:34;i++;continue}" \
    "if(!q&&' \\t\\n;&|<>()'.includes(x))break;" \
    "if(!q&&x===\"'\"){q=39;i++;continue}" \
    "if(x==='`'){l=0;i++;qs(x);continue}" \
    "if(x==='$'){l=0;const n=o[i+1];if(n==='('||n==='{'){i+=2;nest(n,n==='('?')':'}');continue}}" \
    "v+=x;i++}return{start:s,end:i,value:l?v:null}};" \
    "while(i<o.length){const x=o[i],r=/^(<<-|<<|>>|<&|>&|<>|>\\||&>>|&>|<|>)/.exec(o.slice(i));" \
    "if(x===' '||x==='\\t')i++;" \
    "else if(x==='\\\\'&&o[i+1]==='\\n')i+=2;" \
    "else if(x==='#')while(i<o.length&&o[i]!=='\\n')i++;" \
    "else if(r)i+=r[0].length;" \
    "else if(';&|\\n()'.includes(x)){i++;cs.push(c=[])}" \
    "else{const w=wd();if(!c.length&&/^(if|then|else|elif|do|while|until|!|\\{)$/" \
    ".test(o.slice(w.start,w.end)))cs.push(c=[]);else c.push(w)}}" \
    "const m=w=>/%command%/i.test(o.slice(w.start,w.end)),G=cs.find(c=>c.some(m));" \
    "if(!G)return{p:0,e:[],G:[],c:-1};" \
    "const n=G.findIndex(w=>m(w)||!/^[A-Za-z_]\\w*=/.test(o.slice(w.start,w.end)));" \
    "return{p:G[0].start,e:G.slice(0,n<0?G.length:n),G:G,c:G.findIndex(m)}})(),"

// Rewrites KEY=value entries before %command% and leaves the rest of the text byte for byte.
#define NP_CX_LAUNCH \
    "(o,id)=>{const " NP_CX_LAUNCH_PARSE \
    "g=k=>{const p=E.e.filter(w=>o.startsWith(k+\"=\",w.start)).pop();" \
    "return p?(p.value===null?o.slice(p.start+k.length+1,p.end):p.value.slice(k.length+1)):\"\"}," \
    "qv=v=>/^[\\w.,:=\\/+@%-]*$/.test(v)?v:\"'\"+v.replace(/'/g,\"'\\\\''\")+\"'\"," \
    "s=ps=>{const add=ps.filter(p=>p[1]).map(p=>p[0]+\"=\"+qv(p[1])).join(\" \");let r;" \
    "if(!/%command%/i.test(o)){if(!add)return;r=add+\" %command%\"+(o.trim()?\" \"+o:\"\")}" \
    "else{let at=E.p;r=o.slice(0,at)+(add?add+\" \":\"\");" \
    "E.e.forEach(w=>{if(ps.some(p=>o.startsWith(p[0]+\"=\",w.start))){" \
    "r+=o.slice(at,w.start);at=w.end;while(o[at]===\" \"||o[at]===\"\\t\")at++}});r+=o.slice(at)}" \
    "SteamClient.Apps.SetAppLaunchOptions(id,r.trim()===\"%command%\"?\"\":r)};" \
    "return{g,s,k:E.e.map(w=>o.slice(w.start,w.end).split(\"=\")[0])}}"

#define NP_CX_PICK \
    "(t,n)=>{const o=t.strLaunchOptions||\"\";" \
    "if(" NP_FEX_TOOLS ".indexOf(n)<0||/[<>\\n]|\\$'/.test(o))return;" \
    "const L=MSCXLaunch(o,t.unAppID)," \
    "ks=L.k.filter(k=>/^D3DM_[A-Z0-9_]*$/.test(k)||k===\"ROSETTA_ADVERTISE_AVX\"" \
    "||k===\"CX_GRAPHICS_BACKEND\"&&L.g(k)===\"d3dmetal\");" \
    "ks.length&&L.s(ks.map(k=>[k,\"\"]))}"

// The picker refetches after the client's state notification, by which point the mapping
// has changed, so a new selection here is when the prefix row asks again.
#define NP_CX_TOOL_QUERY \
    "(r,id)=>{const q=r[0].data;if(id&&q){const k=q.selected_tool_identifier+\"|\"+q.default_tool_identifier," \
    "M=globalThis.MSCXSeen||(globalThis.MSCXSeen=new Map);" \
    "M.has(id)&&M.get(id)!==k&&queueMicrotask(()=>globalThis.dispatchEvent?.(new CustomEvent(\"mscxstate\",{detail:id})));" \
    "M.set(id,k)}return[r[0],v=>{r[1](v);const d=r[0].data;if(!id||!d)return;" \
    "const n=v||d.default_tool_identifier||\"" NP_FALLBACK_TOOL "\",a=(d.aliases||[]).find(x=>x.alias===n)," \
    "t=globalThis.appDetailsStore?.GetAppDetails(id);t&&MSCXPick(t,a?a.current_tool_name:n)}]}"

// CrossOver options panel. Not in great shape, but it'll do
#define NP_WEB_IS_ZH \
    "(()=>{const l=(globalThis.document?.documentElement?.lang||" \
    "globalThis.navigator?.language||\"\").toLowerCase().replace(/_/g,\"-\");" \
    "return /^(zh(-hans(-[a-z0-9]+)*|-cn|-sg)?|schinese)$/.test(l)})()"

#define NP_WEB_IS_IT \
    "(()=>{const l=(globalThis.document?.documentElement?.lang||" \
    "globalThis.navigator?.language||\"\").toLowerCase().replace(/_/g,\"-\");" \
    "return /^(it(-[a-z0-9]+)*|italian)$/.test(l)})()"

#define NP_WEB_TEXT(EN, ZH, IT) \
    "(" NP_WEB_IS_ZH "?\"" ZH "\":" NP_WEB_IS_IT "?\"" IT "\":\"" EN "\")"

#define NP_COMPAT_HINT NP_WEB_TEXT( \
    "Enable CrossOver under Properties > Bridgeplay to install and run the Windows version.", \
    "请在“属性 > Bridgeplay”中启用 CrossOver，以安装并运行 Windows 版本。", \
    "Abilita CrossOver in Propriet\\u00e0 > Bridgeplay per installare e avviare la versione Windows.")

#define NP_IMAGE_FILES_LABEL NP_WEB_TEXT( \
    "Image Files (*.tga,*.png,*.exe)", "图像文件 (*.tga,*.png,*.exe)", "File immagine (*.tga,*.png,*.exe)")

#define NP_LIBRARY_WINDOWS_HINT NP_WEB_TEXT( \
    "Show only games that run on Windows and do not have a macOS version", \
    "Show only games that run on Windows and do not have a macOS version", \
    "Mostra solo i giochi che funzionano su Windows e non hanno una versione macOS")

#define NP_LIBRARY_WINDOWS_SUMMARY NP_WEB_TEXT( \
    "Runs on Windows, no Mac OS version", \
    "Runs on Windows, no Mac OS version", \
    "Funziona su Windows, nessuna versione macOS")

// Rebuild row in the CrossOver panel.
// The row is redrawn on every poll, so the bar keeps its phase from when the rebuild started
// instead of restarting on each redraw.
#define NP_PREFIX_NEED NP_WEB_TEXT("Switching to this compatibility tool requires a prefix rebuild. Rebuild now?", "切换到此兼容性工具需要重建游戏容器。现在重建吗？", "Per passare a questo strumento di compatibilità serve ricostruire il prefisso. Ricostruirlo ora?")
#define NP_PREFIX_BACKUP NP_WEB_TEXT("Backup & Rebuild Prefix", "备份并重建游戏容器", "Backup e ricostruisci prefisso")
#define NP_PREFIX_REBUILD NP_WEB_TEXT("Rebuild Prefix", "重建游戏容器", "Ricostruisci prefisso")
#define NP_PREFIX_RUNNING NP_WEB_TEXT("Quit the game to rebuild.", "请先退出游戏再重建。", "Chiudi il gioco per ricostruire.")
#define NP_PREFIX_SETUP NP_WEB_TEXT("Rebuilding prefix\\u2026", "正在重建游戏容器\\u2026", "Ricostruzione del prefisso\\u2026")
#define NP_PREFIX_COPY NP_WEB_TEXT("Copying your files\\u2026", "正在复制你的文件\\u2026", "Copia dei tuoi file\\u2026")
#define NP_PREFIX_FINISH NP_WEB_TEXT("Finishing\\u2026", "正在完成\\u2026", "Completamento\\u2026")
#define NP_PREFIX_DONE NP_WEB_TEXT("Prefix rebuilt.", "游戏容器已重建。", "Prefisso ricostruito.")
#define NP_PREFIX_DONE_BACKUP NP_WEB_TEXT("Prefix rebuilt. A backup of the original is in Bridgeplay's Prefixes view.", "游戏容器已重建。原容器的备份在 Bridgeplay 的“游戏容器”视图中。", "Prefisso ricostruito. Un backup dell'originale è nella vista Prefissi di Bridgeplay.")
#define NP_PREFIX_FAILED NP_WEB_TEXT("Prefix rebuild failed!", "游戏容器重建失败！", "Ricostruzione del prefisso non riuscita!")
#define NP_PREFIX_LOG NP_WEB_TEXT("Open Log", "打开日志", "Apri il log")
#define NP_PREFIX_APP NP_WEB_TEXT("Couldn't find the Bridgeplay app. Move Bridgeplay to Applications, open it and click Install again.", "找不到 Bridgeplay 应用。请将 Bridgeplay 移到“应用程序”文件夹，打开它并再次点击“安装”。", "Impossibile trovare l'app Bridgeplay. Sposta Bridgeplay in Applicazioni, aprila e fai di nuovo clic su Installa.")

#define NP_CX_PREFIX_ROW \
    "globalThis.MSCXPrefixRow=(e,id)=>{if(e.npApp===id)return;e.npStop&&e.npStop();e.npApp=id;let ter" \
    "m='',busy=0,timer=0,t0=0,stopped=0,live=0;const T={need:" \
    NP_PREFIX_NEED \
    ",backup:" \
    NP_PREFIX_BACKUP \
    ",rebuild:" \
    NP_PREFIX_REBUILD \
    ",running:" \
    NP_PREFIX_RUNNING \
    ",setup:" \
    NP_PREFIX_SETUP \
    ",copy:" \
    NP_PREFIX_COPY \
    ",finish:" \
    NP_PREFIX_FINISH \
    ",done:" \
    NP_PREFIX_DONE \
    ",doneBackup:" \
    NP_PREFIX_DONE_BACKUP \
    ",failed:" \
    NP_PREFIX_FAILED \
    ",log:" \
    NP_PREFIX_LOG \
    ",app:" \
    NP_PREFIX_APP \
    "},el=(tag,cls,txt)=>{const n=e.ownerDocument.createElement(tag);if(cls)n.className=cls;if(txt!=n" \
    "ull)n.textContent=txt;return n},btn=(txt,main,off,on)=>{const b=el('button','MSCXBtn'+(main?' MS" \
    "CXMain':''),txt);b.disabled=!!off;b.onclick=on;return b},call=r=>MSCXRoute(r,id).then(j=>JSON.pa" \
    "rse(j||'{}')),refresh=()=>{if(stopped)return;if(!e.isConnected||e.npApp!==id)return stop();return MSCXRoute('NotProton.PrefixState#1',id).t" \
    "hen(j=>draw(JSON.parse(j))).catch(()=>{if(stopped||!e.isConnected||e.npApp!==id)return;clearTimeout(timer);if(busy||live)timer=setTimeout(refresh,500);else e.style.display='none'})},start=r=>{term='';busy=1;t0=Date.now();draw(null);cal" \
    "l(r).then(j=>{j.error==='spawn'&&(term='failed')},()=>0).finally(()=>{busy=0;refresh()})},pair=off=>{const r=el('div','MSCXBtns');r.app" \
    "end(btn(T.backup,1,off,()=>start('NotProton.BackupAndRebuildPrefix#1')),btn(T.rebuild,0,off,()=>" \
    "start('NotProton.RebuildPrefix#1')));return r},draw=s=>{if(stopped||!e.isConnected||e.npApp!==id)return;clearTimeout(timer);live=0;const ph=s?s.rebuild" \
    ":'',k=[];if(ph==='done'||ph==='done-backup'||ph==='failed')term=ph;s&&s.needsRebuild&&term!=='failed'&&(term='');if(busy||ph==='setup'||ph==='" \
    "copy'||ph==='finish'){k.push(el('div','',ph==='copy'?T.copy:ph==='finish'?T.finish:T.setup));con" \
    "st b=el('div','MSCXBar');t0||(t0=Date.now());const m=el('div','');m.style.animationDelay=-((Date.now()-t0)%1200)+'ms';b.append(m);k.push(b);live=1;timer=setTimeout(refresh,500)}else if((t0=0)||" \
    "term==='failed'){k.push(el('div','',T.failed));const r=el('div','MSCXBtns');r.append(btn(T.log,0" \
    ",0,()=>call('NotProton.OpenPrefixLog#1').catch(()=>0)));k.push(r);s&&s.needsRebuild&&s.app&&!s.r" \
    "unning&&k.push(pair(0))}else if(term)k.push(el('div','',term==='done-backup'?T.doneBackup:T.done" \
    "));else if(s&&s.needsRebuild){if(!s.app)k.push(el('div','',T.app));else{k.push(el('div','',s.run" \
    "ning?T.running:T.need),pair(s.running));s.running&&(timer=setTimeout(refresh,3e3))}}e.replaceChi" \
    "ldren(...k);e.style.display=k.length?'':'none'};e.style.flexDirection='column';e.style.gap='8px'" \
    ";e.style.display='none';const on=v=>{if(!e.isConnected)return e.npStop();v.detail===id&&!busy&&(" \
    "term='',refresh())};const stop=e.npStop=()=>{stopped=1;clearTimeout(timer);observer?.disconnect();globalThis.removeEventListener?.('mscxstat" \
    "e',on)};const observer=globalThis.MutationObserver?new globalThis.MutationObserver(()=>{if(!e.isConnected)stop()}):null;observer?.observe(e.ownerDocument,{childList:true,subtree:true});globalThis.addEventListener?.('mscxstate',on);refresh()};"

#define NP_CX_OPTIONS_CSS \
    "\".MSCXPanel{margin-top:10px}" \
    ".MSCXPanel .MSCXRow{display:flex;flex-direction:row;padding:9px;margin:0;" \
    "color:#dfe3e6;background:rgba(59,63,72,.5);border-radius:3px}" \
    ".MSCXPanel .MSCXRow:hover{box-shadow:0 6px 8px 0 rgba(0,0,0,.16)}" \
    ".MSCXPanel .MSCXDrop{display:flex;flex-direction:column;align-items:stretch;gap:6px;" \
    "padding:0;margin:10px 0;background:none}" \
    ".MSCXPanel .MSCXDrop>*{width:100%;max-width:none;margin:0}" \
    ".MSCXNoBottomGap{margin-bottom:0}" \
    ".MSCXBtns{display:flex;gap:8px}" \
    ".MSCXBtn{background:#3d4450;color:#fff;border:none;border-radius:2px;padding:6px 14px;" \
    "font-size:14px;cursor:pointer}.MSCXBtn:hover{background:#4c5361}" \
    ".MSCXBtn.MSCXMain{background:#1a9fff}.MSCXBtn.MSCXMain:hover{background:#47b4ff}" \
    ".MSCXBtn:disabled{opacity:.5;cursor:default}" \
    ".MSCXBtn:focus-visible{outline:2px solid #fff;outline-offset:1px}" \
    ".MSCXBar{position:relative;align-self:stretch;width:100%;height:4px;overflow:hidden;" \
    "border-radius:2px;background:rgba(255,255,255,.12)}" \
    ".MSCXBar>div{position:absolute;top:0;bottom:0;left:-30%;width:30%;background:#1a9fff;" \
    "animation:MSCXSlide 1.2s linear infinite}" \
    "@keyframes MSCXSlide{from{left:-30%}to{left:100%}}\""

// FEX runs arm64 Wine, which has no D3DMetal and never runs under Rosetta.
#define NP_CX_OPTIONS_BODY(ARG, RT, BARREL) \
    ARG "=>{" \
    "const t=" ARG ".details,o=t.strLaunchOptions||\"\"," \
    "fex=" NP_FEX_TOOLS ".indexOf(t.strCompatToolName||\"" NP_FALLBACK_TOOL "\")>=0," \
    "npZh=" NP_WEB_IS_ZH ",npIt=" NP_WEB_IS_IT ",npL=(en,zh,it)=>npZh?zh:npIt&&it?it:en," \
    NP_CX_LAUNCH_PARSE \
    "nat=t.unAppID<2147483648&&(t.vecPlatforms||[]).indexOf(\"osx\")>=0&&!t.strCompatToolName," \
    "wv=w=>w.value===null?o.slice(w.start,w.end):w.value," \
    "NE=E.c<0?[]:E.G.slice(0,E.c).filter(w=>/^[A-Za-z_]\\w*=/.test(wv(w)))," \
    /* The panel writes BRIDGEPLAY_<X>. NOTPROTON_<X>, from launch options written before 3.0, \
       is read too and wins, as it does in the run script and np-native. */ \
    "A1=k=>(nat?NE.filter(w=>wv(w).startsWith(k+\"=\")):E.e.filter(w=>o.startsWith(k+\"=\",w.start))).pop()," \
    "A=k=>/^BRIDGEPLAY_/.test(k)&&A1(\"NOTPROTON_\"+k.slice(11))||A1(k)," \
    "g=k=>{const p=A(k);if(!p)return\"\";const x=wv(p);return x.slice(x.indexOf(\"=\")+1)}," \
    "qv=v=>/^[\\w.,:=\\/+@%-]*$/.test(v)?v:\"'\"+v.replace(/'/g,\"'\\\\''\")+\"'\"," \
    "sl=ps=>{const add=ps.filter(p=>p[1]).map(p=>p[0]+\"=\"+qv(p[1])).join(\" \");let r;" \
    "if(!/%command%/i.test(o)){if(!add)return;r=add+\" %command%\"+(o.trim()?\" \"+o:\"\")}" \
    "else{let at=E.p;r=o.slice(0,at)+(add?add+\" \":\"\");" \
    "E.e.forEach(w=>{if(ps.some(p=>o.startsWith(p[0]+\"=\",w.start))){" \
    "r+=o.slice(at,w.start);at=w.end;while(o[at]===\" \"||o[at]===\"\\t\")at++}});r+=o.slice(at)}" \
    "SteamClient.Apps.SetAppLaunchOptions(t.unAppID,r.trim()===\"%command%\"?\"\":r)}," \
    /* Native games run through np-native, which also forces arm64: <launcher> VAR=VALUE ... \
       %command% <game args>. Assignments are read from any word before %command%, so the \
       older "/usr/bin/arch ... -e VAR=VALUE" form is understood, and rewritten without the \
       arch prefix and its DYLD_INSERT_LIBRARIES. */ \
    "sn=ps=>{const c=E.c<0?null:E.G[E.c]," \
    "L=Fx.h?Fx.h+\"/.bridgeplay/np-native\":(c&&E.G.slice(0,E.c).map(wv)" \
    ".find(x=>/\\/\\.(bridgeplay|notproton)\\/np-native$/.test(x)))||\"\";" \
    "if(!L||!c&&!ps.some(p=>p[1]))return;" \
    "const kn=w=>{const x=wv(w);return x.slice(0,x.indexOf(\"=\"))};" \
    "let vs=NE.filter(w=>kn(w)!==\"DYLD_INSERT_LIBRARIES\").map(w=>[kn(w),o.slice(w.start,w.end)]);" \
    "ps.forEach(p=>{const i=vs.findIndex(x=>x[0]===p[0]);vs=vs.filter(x=>x[0]!==p[0]);" \
    "if(p[1])vs.splice(i<0?vs.length:i,0,[p[0],p[0]+\"=\"+qv(p[1])])});" \
    "const h=[qv(L)].concat(vs.map(x=>x[1])).join(\" \");" \
    "SteamClient.Apps.SetAppLaunchOptions(t.unAppID," \
    "c?o.slice(0,E.p)+h+\" \"+o.slice(c.start):h+\" %command%\"+(o.trim()?\" \"+o.trim():\"\"))}," \
    /* Writing BRIDGEPLAY_<X> drops a NOTPROTON_<X> the line still carries. */ \
    "s=ps=>{ps=ps.concat(ps.filter(p=>/^BRIDGEPLAY_/.test(p[0])).map(p=>[\"NOTPROTON_\"+p[0].slice(11),\"\"]));" \
    "return nat?sn(ps):sl(ps)}," \
    "Fx=globalThis.MSCXFx||{}," \
    "dv=k=>{if(nat){const a=(Fx.na||{})[t.unAppID]||{},n=Fx.ng||{};" \
    "return k in a?a[k]:k in n?n[k]:(Fx.d||{})[k]||\"\"}" \
    "const a=(Fx.a||{})[t.unAppID]||{},en=Fx.e||{},x=en[t.strCompatToolName]||en[\"\"]||{};" \
    "return k in a?a[k]:k in(Fx.g||{})?Fx.g[k]:k in x?x[k]:(Fx.d||{})[k]||\"\"}," \
    "ev=k=>A(k)?g(k):dv(k)," \
    "T=(ks,l,on,off)=>(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:l," \
    "checked:ev(ks[0])===on," \
    "onChange:v=>s(ks.map(k=>[k,v?(dv(k)===on?\"\":on):(dv(k)===on?(off||\"0\"):\"\")]))},ks[0])," \
    /* A labelled dropdown: its label above it, full width, without a row box around it, \
       like the section dropdowns. n turns a raw value, set or not, into an option's data, so \
       picking what the confs already give drops the argument instead of writing it. */ \
    "D=(k,l,O,n)=>(0," RT ".jsx)(" BARREL ".m,{label:l,strClassName:\"MSCXDrop\",rgOptions:O," \
    "selectedOption:n(ev(k)),onChange:v=>s([[k,v.data===n(dv(k))?\"\":v.data]])},k)," \
    "lc=z=>x=>(x||z).toLowerCase()," \
    "fz=x=>{x=(x||\"\").toLowerCase();return x===\"1\"?\"2\":/^(0|off|false|no)?$/.test(x)?\"0\":x}," \
    "fo=fz(ev(\"BRIDGEPLAY_FRAMEGEN\"))!==\"0\"," \
    "FG=()=>(0," RT ".jsxs)(" BARREL ".XY,{label:\"Frame Generation (Experimental. Adds input lag)\",children:[" \
    "D(\"BRIDGEPLAY_FRAMEGEN\",\"Mode\",[{data:\"0\",label:\"Off\"},{data:\"2\",label:\"2x\"}," \
    "{data:\"3\",label:\"3x\"},{data:\"adaptive\",label:\"Adaptive (fills to display refresh)\"}],fz)," \
    "fo&&D(\"BRIDGEPLAY_FRAMEGEN_QUALITY\",\"Quality\",[{data:\"performance\",label:\"Performance\"}," \
    "{data:\"balanced\",label:\"Balanced\"},{data:\"quality\",label:\"Quality\"}],lc(\"balanced\"))," \
    "fo&&T([\"BRIDGEPLAY_FRAMEGEN_UI\"],\"Protect UI (keeps static HUD and menus sharp)\",\"1\",\"0\")," \
    "fo&&T([\"BRIDGEPLAY_FRAMEGEN_FALLBACK\"],\"Fast-motion fallback (skips frames that would smear)\",\"1\",\"0\")," \
    "fo&&D(\"BRIDGEPLAY_FRAMEGEN_ENGINE\",\"Engine\",[{data:\"own\",label:\"Built-in optical flow\"}," \
    "{data:\"metalfx\",label:\"MetalFX\"}],lc(\"own\"))]},\"fgn\")," \
    /* A toggle that is on unless set to "0" (upstream 1.2.0: AVX2, FEX x87 precision). */ \
    "X=(k,l)=>(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:l," \
    "checked:\"0\"!==ev(k),onChange:v=>s([[k,v?\"\":\"0\"]])},k)," \
    "bv=g(\"CX_GRAPHICS_BACKEND\"),b=fex&&\"d3dmetal\"===bv?\"\":bv," \
    "dm=!fex&&(\"\"===b||\"d3dmetal\"===b)," \
    "dx=\"\"===b||\"dxmt\"===b," \
    "sw=\"1\"===g(\"DXMT_METALFX_SPATIAL_SWAPCHAIN\")," \
    "F=\"d3d11.metalSpatialUpscaleFactor=\"," \
    "fe=g(\"DXMT_CONFIG\").split(\";\").filter(e=>e.trim())," \
    "fk=e=>/^[ \\t\\r]*d3d11\\.metalSpatialUpscaleFactor[ \\t\\r]*=/.test(e)," \
    "fx=v=>fe.filter(e=>!fk(e)).concat(v?[F+v]:[]).join(\";\")," \
    "fv=(fe.filter(fk).pop()||\"=2\").replace(/^[^=]*=/,\"\").replace(/\"/g,\"\").trim().split(/\\s/)[0]," \
    "fn=Math.max(isNaN(+fv)?2:+fv,1)," \
    "U=[{data:\"\",label:npL(\"Off\",\"关闭\",\"Disattivato\")}," \
    "{data:\"1.5\",label:\"1.5x\"}," \
    "{data:\"1.72\",label:\"1.72x\"}," \
    "{data:\"2.0\",label:\"2x\"}," \
    "{data:\"3.0\",label:\"3x\"}]," \
    "B=[{data:\"\",label:npL(\"Automatic\",\"自动\",\"Automatico\")}," \
    "{data:\"d3dmetal\",label:\"D3DMetal\"}," \
    "{data:\"dxmt\",label:\"DXMT\"}," \
    "{data:\"dxvk\",label:\"DXVK\"}," \
    "{data:\"wined3d\",label:\"WineD3D\"}].filter(x=>!fex||x.data!==\"d3dmetal\")," \
    /* The settings Game Defaults in the app also sets: the ones this game sets for itself, \
       which Use Bridgeplay defaults drops (DXMT_CONFIG keeps entries other than the factor). */ \
    "OV=[\"CX_GRAPHICS_BACKEND\",\"MTL_HUD_ENABLED\",\"D3DM_ENABLE_METALFX\",\"DXMT_ENABLE_NVEXT\"," \
    "\"ROSETTA_ADVERTISE_AVX\",\"WINEMSYNC\",\"BRIDGEPLAY_RETINA\",\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"DXMT_CONFIG\"," \
    "\"BRIDGEPLAY_FRAMEGEN\",\"BRIDGEPLAY_FRAMEGEN_QUALITY\",\"BRIDGEPLAY_FRAMEGEN_UI\",\"BRIDGEPLAY_FRAMEGEN_FALLBACK\"," \
    "\"BRIDGEPLAY_FRAMEGEN_ENGINE\",\"BRIDGEPLAY_VSYNC\",\"BRIDGEPLAY_BACKEND\"].filter(k=>\"DXMT_CONFIG\"===k?fe.some(fk):!!A(k));" \
    "if(nat)return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "})," \
    "T([\"MTL_HUD_ENABLED\"],\"Metal HUD\",\"1\"),FG()," \
    "(0," RT ".jsx)(" BARREL ".XY,{label:\"Controllers\",children:" \
    "D(\"NP_PAD_MODE\",\"Controller layer\",[{data:\"\",label:\"Automatic\"},{data:\"hid\",label:\"Raw HID (Unity, SDL, Unreal)\"}," \
    "{data:\"gc\",label:\"GameController\"},{data:\"off\",label:\"Off\"}],lc(\"\"))},\"ctl\")" \
    "]})});" \
    "return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "})," \
    "typeof MSCXPrefixRow==\"function\"&&(0," RT ".jsx)(\"div\",{className:\"MSCXRow\",ref:e=>e&&MSCXPrefixRow(e,t.unAppID)},\"npstate\")," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Graphics\",\"图形\",\"Grafica\"),children:[" \
    "(0," RT ".jsx)(" BARREL ".m,{rgOptions:B,selectedOption:b," \
    "onChange:v=>s([[\"CX_GRAPHICS_BACKEND\",v.data]]" \
    ".concat(\"\"===v.data||\"d3dmetal\"===v.data?[]:[[\"D3DM_ENABLE_METALFX\",\"\"]])" \
    ".concat(\"\"===v.data||\"dxmt\"===v.data?[]:" \
    "[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"\"],[\"DXMT_CONFIG\",fx(\"\")]])" \
    ".concat(\"dxmt\"===v.data?[]:[[\"DXMT_ENABLE_NVEXT\",\"\"]]))})," \
    "T([\"MTL_HUD_ENABLED\"],npL(\"Metal HUD\",\"Metal 性能监视器\",\"Metal HUD\"),\"1\")," \
    "dm&&T([\"D3DM_ENABLE_METALFX\"],\"DLSS\",\"1\")," \
    "\"dxmt\"===b&&T([\"DXMT_ENABLE_NVEXT\"],\"DLSS\",\"1\")," \
    "!fex&&X(\"ROSETTA_ADVERTISE_AVX\",npL(\"Advertise AVX2 to Rosetta\",\"向 Rosetta 声明 AVX2 支持\",\"Segnala AVX2 a Rosetta\"))," \
    "T([\"WINEMSYNC\"],\"MSync\",\"1\",\"0\")," \
    "T([\"BRIDGEPLAY_RETINA\"],npL(\"High Resolution\",\"高分辨率\",\"Alta risoluzione\"),\"1\",\"0\")" \
    "]},\"gfx\")," \
    "dx&&(0," RT ".jsx)(" BARREL ".XY," \
    "{label:npL(\"MetalFX Upscaling (Samples from the resolution the game is set to)\"," \
    "\"MetalFX 超分辨率（以游戏设置的分辨率为采样来源）\",\"Upscaling MetalFX (ingrandisce l'immagine dalla risoluzione impostata nel gioco)\")," \
    "children:(0," RT ".jsx)(" BARREL ".m,{rgOptions:U," \
    "selectedOption:sw?(U.find(u=>u.data&&+u.data===fn)||{data:String(fn)}).data:\"\"," \
    "onChange:v=>s([[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",v.data?\"1\":\"\"],[\"DXMT_CONFIG\",fx(v.data)]])})},\"usf\")," \
    "FG()," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Controllers\",\"控制器\",\"Controller\"),children:[" \
    "T([\"BRIDGEPLAY_RAW_CONTROLLERS\"],npL(\"Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)\"," \
    "\"允许游戏直接读取控制器（Mac 上推荐，仅在需要 Steam Input 按键映射时关闭）\"," \
    "\"Lascia che i giochi leggano direttamente i controller (consigliato su Mac, disattiva solo per la rimappatura di Steam Input)\"),\"1\",\"\")," \
    "T([\"BRIDGEPLAY_DISABLE_HIDRAW\"],npL(\"Disable hidraw\",\"停用 hidraw\",\"Disattiva hidraw\"),\"1\",\"\")" \
    "]},\"ctl\")," \
    "fex&&(0," RT ".jsx)(" BARREL ".XY,{label:\"FEX\"," \
    "children:X(\"FEX_X87REDUCEDPRECISION\"," \
    "\"Reduced x87 Precision (Reducing precision improves game performance, is enabled by default in CrossOver Preview)\")},\"fex\")," \
    "OV.length>0&&(0," RT ".jsx)(\"div\",{className:\"MSCXBtns\",children:(0," RT ".jsx)(\"button\",{className:\"MSCXBtn\"," \
    "onClick:()=>s(OV.map(k=>[k,\"DXMT_CONFIG\"===k?fx(\"\"):\"\"]))," \
    "children:npL(\"Use Bridgeplay defaults\",\"使用 Bridgeplay 默认设置\",\"Usa le impostazioni predefinite di Bridgeplay\")})},\"npdef\")" \
    "]})})}"

#define NP_CX_OPTIONS_CAPTURE(RT, BARREL) \
    "((npReact,npUI)=>" NP_CX_OPTIONS_BODY("np", "npReact()", "npUI()") ")(()=>" RT ",()=>" BARREL ")"

#define NP_CX_OPTIONS_COMPONENT \
    "MSCXLaunch=" NP_CX_LAUNCH ",MSCXPick=" NP_CX_PICK "," \
    "MSCXOpts=" NP_CX_OPTIONS_CAPTURE(NP_C4, NP_C5) ","

// Valve is testing a new compatibility page UI, this logic relates to supporting that
#define NP_CX_OPTIONS_STATEMENT \
    "var MSCXLaunch=" NP_CX_LAUNCH ";" \
    "var MSCXPick=" NP_CX_PICK ";" \
    "var MSCXToolQuery=" NP_CX_TOOL_QUERY ";" \
    "var MSCXOpts=" NP_CX_OPTIONS_CAPTURE(NP_C3, NP_C4) ";"

// 1.0.x saved CrossOver settings without %command%, this migrates them.
#define NP_LAUNCH_MIGRATION_RULE \
    "o=>{const T=/(?:[^\\s\"'\\\\]|\\\\[^]|\"(?:[^\"\\\\]|\\\\[^])*\"|'[^']*')+/g," \
    "w=o.match(T)||[]," \
    "k=x=>/^(BRIDGEPLAY_|CX_GRAPHICS|D3DM_|DXMT_|DXVK_|MTL_|NOTPROTON_|ROSETTA_|WINE)\\w*=/.test(x)," \
    "e=w.filter(k);" \
    "if(/%command%/i.test(o)||o.replace(T,\"\").trim()||!e.length)return null;" \
    "return e.map(x=>{const i=x.indexOf(\"=\"),v=x.slice(i+1);" \
    "return/[\"'\\\\]/.test(x)||/^[\\w.,:=\\/+@%-]*$/.test(v)?x:x.slice(0,i+1)+\"'\"+v+\"'\"})" \
    ".concat(\"%command%\",w.filter(x=>!k(x))).join(\" \")}"

#define NP_LAUNCH_MIGRATION \
    "(async()=>{try{" \
    "const K=\"NotProtonLaunchMigrated_\"+this.m_cm.steamid.GetAccountID();" \
    "if(localStorage.getItem(K))return;" \
    "const M=" NP_LAUNCH_MIGRATION_RULE ";" \
    "const A=[...window.appStore.m_mapApps.values()].filter(a=>a);let n=0;" \
    "for(let i=0;i<A.length;i+=20)await Promise.all(A.slice(i,i+20).map(async a=>{const id=a.appid;" \
    "const t=await Promise.race([window.appDetailsStore.RequestAppDetails(id)," \
    "new Promise(r=>setTimeout(r,5e3))]);" \
    "if(!t){console.warn(\"Bridgeplay: no details for app \"+id+\", its launch options were not moved\");return}" \
    "if(!(id<2147483648&&(t.vecPlatforms||[]).indexOf(\"osx\")>=0&&!t.strCompatToolName)){" \
    "const r=M(t.strLaunchOptions||\"\");" \
    "if(r!==null){SteamClient.Apps.SetAppLaunchOptions(id,r);n++;" \
    "console.log(\"Bridgeplay: moved the launch options of app \"+id)}}}));" \
    "console.log(\"Bridgeplay: checked the launch options of \"+A.length+\" apps, moved \"+n);" \
    "localStorage.setItem(K,\"1\")" \
    "}catch(e){console.error(\"Bridgeplay: launch options migration failed\",e)}})()"

// The properties tab Steam calls Compatibility. Its route stays /compatibility.
#define NP_TAB_FIND \
    "(0," NP_C1 ".CI)()&&" NP_C2 ".push({title:(0," NP_C3 ".we)(\"#AppProperties_CompatibilityPage\")"
#define NP_TAB_REPLACE "true&&" NP_C2 ".push({title:\"Bridgeplay\""

static const np_gate_t g_gates_forcetool[] = {
    // SteamPlay settings section
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".CI)()?",
      "function " NP_C1 "(" NP_C2 "){return true?", 1, 0 },
    // AppProperties Compatibility tab, shown as Bridgeplay (app and non-Steam-shortcut variants)
    { NP_TAB_FIND, NP_TAB_REPLACE, 2, 0 },
    // Settings page Compatibility entry, keeping the SteamOS exclusion (!rf())
    { "Compatibility:{visible:" NP_C1 "&&(0," NP_C2 ".CI)()&&!(0," NP_C2 ".rf)()",
      "Compatibility:{visible:" NP_C1 "&&true&&!(0," NP_C2 ".rf)()", 1, 0 },
    { "return(0," NP_C1 ".jsxs)(" NP_C1 ".Fragment,{children:[0!=" NP_C2 ".length&&(0," NP_C1 ".jsx)(" NP_C3 ",{label:(0," NP_C4 ".we)"
      "(\"#AppProperties_CompatilibityForceTool\"),checked:" NP_C5 ",onChange:" NP_C6 ",disabled:!" NP_C7 "||0===" NP_C2 ".length}),"
      NP_C5 "&&" NP_C2 ".length>0&&(0," NP_C1 ".jsx)(" NP_C8 ".m,{strClassName:" NP_C9 "().TopGap,rgOptions:" NP_C10 ","
      "selectedOption:" NP_C11 ".strCompatToolName,onChange:" NP_C12 "=>SteamClient.Apps.SpecifyCompatTool"
      "(" NP_C11 ".unAppID," NP_C12 ".data)})]})",
      "return(0," NP_C1 ".jsxs)(" NP_C1 ".Fragment,{children:[0!=" NP_C2 ".length&&(0," NP_C1 ".jsx)(" NP_C3 ",{label:(0," NP_C4 ".we)"
      "(\"#AppProperties_CompatilibityForceTool\"),checked:" NP_C5 ",onChange:" NP_C6 ",disabled:!" NP_C7 "||0===" NP_C2 ".length}),"
      NP_C5 "&&" NP_C2 ".length>0&&(0," NP_C1 ".jsx)(" NP_C8 ".m,{strClassName:" NP_C9 "().TopGap+\" MSCXNoBottomGap\",rgOptions:" NP_C10 ","
      "selectedOption:" NP_C11 ".strCompatToolName,onChange:" NP_C12 "=>{SteamClient.Apps.SpecifyCompatTool"
      "(" NP_C11 ".unAppID," NP_C12 ".data);MSCXPick(" NP_C11 "," NP_C12 ".data)}})]})", 1, 0 },
    // Compatibility page container
    { NP_C1 "=(0," NP_C2 ".PA)(" NP_C3 "=>(0," NP_C4 ".jsxs)(" NP_C5
      ".nB,{children:[(0," NP_C4 ".jsx)(\"div\",{className:" NP_C6
      "().HiddenIfNotLast,children:(0," NP_C7 ".we)(\"#AppProperties_CompatibilityNoOptions\")}),"
      "(0," NP_C4 ".jsx)(" NP_C8 ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(" NP_C9
      ",{..." NP_C3 "})]}));",
      NP_CX_OPTIONS_COMPONENT
      NP_C1 "=(0," NP_C2 ".PA)(" NP_C3 "=>(0," NP_C4 ".jsxs)(" NP_C5
      ".nB,{children:[(0," NP_C4 ".jsx)(\"div\",{className:" NP_C6
      "().HiddenIfNotLast,children:(0," NP_C7 ".we)(\"#AppProperties_CompatibilityNoOptions\")}),"
      "(0," NP_C4 ".jsx)(" NP_C8 ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(" NP_C9
      ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(MSCXOpts,{..." NP_C3 "})]}));", 1, 0 },
    { "get is_invalid_os_type(){return this.most_available_per_client_data.is_invalid_os_type}",
      "get is_invalid_os_type(){return false}", 1, 0 },
    // Reminder banner for 32 bit Mac games
    { NP_C1 ".is_invalid_os_type&&(0," NP_C2 ".jsx)(" NP_C3 ",{})",
      "!" NP_C1 ".local_per_client_data?.installed&&"
      NP_C1 ".most_available_per_client_data?.is_invalid_os_type&&"
      "(0," NP_C2 ".jsx)(" NP_C3 ",{})", 1, 0 },
    { "(0," NP_C1 ".we)(\"#GameList_Entry_Invalid_OSType2\")",
      NP_COMPAT_HINT, 1, 0 },
};

// Support for new compatibility tab UI in the Steam beta
static const np_gate_t g_gates_selecttool[] = {
    // AppProperties Compatibility tab, shown as Bridgeplay
    { NP_TAB_FIND, NP_TAB_REPLACE, 2, 0 },
    // Settings page Compatibility entry.
    { "Compatibility:{visible:" NP_C1 "&&(0," NP_C2 ".CI)(),title:",
      "Compatibility:{visible:" NP_C1 "&&true,title:", 1, 0 },
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]})}",
      NP_CX_OPTIONS_STATEMENT
      "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C3 ".Fragment,{children:["
      "(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]}),"
      "(0," NP_C3 ".jsx)(MSCXOpts,{details:" NP_C2 ".details})]})}", 1, 0 },
    // Compatibility Tool selector, wrapped to drop settings a FEX tool cannot use
    { "[" NP_C1 "," NP_C2 "]=(0," NP_C3 ".cT)(" NP_C4 ");if(" NP_C1 ".isLoading||!" NP_C1
      ".data?.tools?.length)return null;",
      "[" NP_C1 "," NP_C2 "]=(typeof MSCXToolQuery==\"function\"?MSCXToolQuery:r=>r)"
      "((0," NP_C3 ".cT)(" NP_C4 ")," NP_C4 ");if(" NP_C1
      ".isLoading||!" NP_C1 ".data?.tools?.length)return null;", 1, 1 },
    // CompatManager service: hands the page's transport to MSCXRoute for NotProton's own routes
    { NP_C7 "=" NP_C7 "||(0," NP_C8 ".OI)().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(\"Transport Error: no transport is available for request\"),"
      NP_C10 "(\"Transport Error: no transport is available for request\")}):"
      NP_C7 ".SendMsg(\"CompatManager.GetCompatTools#1\",(0," NP_C1 ".I8)(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}" NP_C5 ".GetCompatTools=" NP_C6 ";",
      NP_C7 "=" NP_C7 "||(0," NP_C8 ".OI)().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(\"Transport Error: no transport is available for request\"),"
      NP_C10 "(\"Transport Error: no transport is available for request\")}):"
      NP_C7 ".SendMsg(\"CompatManager.GetCompatTools#1\",(0," NP_C1 ".I8)(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}"
      "globalThis.MSCXRoute=(r,id)=>{const t=(0," NP_C8 ".OI)().GetDefaultTransport();"
      "return t?t.SendMsg(r,(0," NP_C1 ".I8)(" NP_C2 ",{appid:id})," NP_C4 ",{ePrivilege:1,eClientExecutionSite:2})"
      ".then(x=>x.BSuccess()?x.Body().toObject().default_tool_identifier||\"\":Promise.reject(\"result \"+x.GetEResult()))"
      ":Promise.reject(\"no transport\")};" NP_CX_PREFIX_ROW NP_C5 ".GetCompatTools=" NP_C6 ";", 1, 1 },
    { "get is_invalid_os_type(){return this.most_available_per_client_data.is_invalid_os_type}",
      "get is_invalid_os_type(){return false}", 1, 0 },
    // Reminder banner for 32 bit Mac games
    { NP_C1 ".is_invalid_os_type&&(0," NP_C2 ".jsx)(" NP_C3 ",{})",
      "!" NP_C1 ".local_per_client_data?.installed&&"
      NP_C1 ".most_available_per_client_data?.is_invalid_os_type&&"
      "(0," NP_C2 ".jsx)(" NP_C3 ",{})", 1, 0 },
    { "(0," NP_C1 ".we)(\"#GameList_Entry_Invalid_OSType2\")",
      NP_COMPAT_HINT, 1, 0 },
};

#define NP_PLATFORM_LISTS "window.__NOTPROTON_NATIVE_PLATFORM__"
#define NP_MAC_64(APP) \
    "(" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)&&!" APP ".most_available_per_client_data?.is_invalid_os_type)"
#define NP_MAC_CHECK(OS, APP) \
    "(0," OS ".Pr)()&&" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)?!" APP \
    ".most_available_per_client_data?.is_invalid_os_type:(0," OS ".Pr)()&&" \
    NP_WINDOWS(APP) "?!1:(0," OS ".Pr)()?" \
    APP ".is_available_on_current_platform&&!" APP ".most_available_per_client_data?.is_invalid_os_type:"
// .exe shortcuts = Windows
#define NP_RUNS_EXE "window.__NOTPROTON_RUNS_EXE__"
#define NP_RUNS_EXE_JS \
    NP_RUNS_EXE "=a=>{if(!a.BIsShortcut?.())return!1;const s=window.appDetailsStore,e=s?.m_mapAppData?.get(a.appid);" \
    "s&&!e?.cRegistered&&queueMicrotask(()=>s.m_mapAppData.get(a.appid)?.cRegistered||s.RegisterForAppData(a.appid));" \
    "return/\\.exe\"?$/i.test(e?.details?.strShortcutExe??\"\")};\n"
#define NP_WINDOWS(APP) \
    "(" NP_PLATFORM_LISTS ".windows.has(" APP ".appid)||" NP_RUNS_EXE "(" APP "))"
#define NP_WINDOWS_ONLY_CASE(OS, APP) \
    "case\"notprotonWindows\":return(0," OS ".Pr)()&&" NP_WINDOWS(APP) "&&!" \
    NP_MAC_64(APP) ";"

static const np_gate_t g_fixes[] = {
    { "(\"#AddNonSteam_Filter_Exe_MacOS\"),rFilePatterns:[\"*.app\"]",
      "(\"#AddNonSteam_Filter_Exe_MacOS\"),rFilePatterns:[\"*.app\",\"*.exe\"]", 1, 0 },
    { "{strFileTypeName:\"Image Files (*.tga,*.png)\",rFilePatterns:[\"*.tga\",\"*.png\"]}",
      "{strFileTypeName:" NP_IMAGE_FILES_LABEL ","
      "rFilePatterns:[\"*.tga\",\"*.png\",\"*.exe\"]}", 1, 0 },
    // Makes Steam's default compatibility tool setting work
    { "r=(0,s.q3)(()=>u.rV.settings.bCompatEnabled),a=function(e,t){const[r,i]=n.useState([]);"
      "return n.useEffect(()=>{SteamClient.Apps.GetAvailableCompatTools(e).then(i)},[e,t]),r}"
      "(t.unAppID,r),o=r&&!!t.strCompatToolName&&t.nCompatToolPriority==h.JN,"
      "l=a.length?a[0].strToolName:\"\"",
      "r=(0,s.q3)(()=>u.rV.settings.bCompatEnabled),a=function(e,t){const[r,i]=n.useState([]);"
      "return n.useEffect(()=>{SteamClient.Apps.GetAvailableCompatTools(e).then(i)},[e,t]),r}"
      "(t.unAppID,r),o=r&&!!t.strCompatToolName&&t.nCompatToolPriority==h.JN,"
      "l=a.length?(a.find(e=>e.strToolName===u.rV.settings.strCompatTool)||a[0]).strToolName:\"\"",
      1, 0 },
    // Shows the default tool picker before a default has been saved
    { "return " NP_C1 "?(0," NP_C2 ".jsx)(" NP_C3 ".B,{feature:" NP_C4 ".OK,label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_DefaultTool\"),rgOptions:" NP_C6 ",disabled:0==" NP_C6 ".length,"
      "selectedOption:" NP_C1 ",",
      "return(" NP_C1 "||" NP_C6 ".some(e=>e.data===\"" NP_FALLBACK_TOOL "\"))?(0," NP_C2 ".jsx)("
      NP_C3 ".B,{feature:" NP_C4 ".OK,label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_DefaultTool\"),rgOptions:" NP_C6 ",disabled:0==" NP_C6 ".length,"
      "selectedOption:" NP_C1 "||\"" NP_FALLBACK_TOOL "\",",
      1, 0 },
    { "this.m_bServicesInitialized=!0,SteamClient.UI.NotifyAppInitialized()",
      "this.m_bServicesInitialized=!0," NP_LAUNCH_MIGRATION ",SteamClient.UI.NotifyAppInitialized()", 1, 0 },
    // Pr means macOS, td means Windows.
    // Steam Play makes every game count as available, so the Apple filter goes by oslist.
    // Games missing from appinfo.vdf, and other platforms, keep Steam's check.
    // Bridgeplay forces is_invalid_os_type to false, so 32-bit Mac games are found through the per-client copy.
    { "case " NP_C1 "." NP_C2 ":return!!(0," NP_C3 ".td)()||" NP_C4
      ".is_available_on_current_platform&&!" NP_C4 ".is_invalid_os_type;",
      NP_WINDOWS_ONLY_CASE(NP_C3, NP_C4) "case " NP_C1 "." NP_C2 ":return " NP_MAC_CHECK(NP_C3, NP_C4)
      "!!(0," NP_C3 ".td)()||" NP_C4 ".is_available_on_current_platform&&!" NP_C4 ".is_invalid_os_type;", 1, 0 },
    { "case " NP_C1 "." NP_C2 ":return(0," NP_C3 ".CI)()&&!(0," NP_C3 ".mP)()?"
      NP_C4 "(" NP_C5 "):(0," NP_C3 ".td)()?!0:" NP_C5
      ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;",
      NP_WINDOWS_ONLY_CASE(NP_C3, NP_C5) "case " NP_C1 "." NP_C2 ":return " NP_MAC_CHECK(NP_C3, NP_C5)
      "(0," NP_C3 ".CI)()&&!(0," NP_C3 ".mP)()?" NP_C4 "(" NP_C5 "):(0,"
      NP_C3 ".td)()?!0:" NP_C5 ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;", 1, 0 },
};
#define NP_FIX_COUNT (sizeof(g_fixes) / sizeof(g_fixes[0]))

#define NP_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 2)
#define NP_UPDATED_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 1)

#define NP_PLATFORM_TIP "\"#GameList_View_Platform_Linux\":\"#GameList_View_Platform_Apple\""
#define NP_LOCALIZED_PLATFORM_TIP "(0," NP_C12 ".we)(\"#GameList_View_Platform_Linux\"):(0," NP_C12 \
    ".we)(\"#GameList_View_Platform_Apple\")"
#define NP_PLATFORM_BUTTON(tip) \
    NP_C1 "&&(0," NP_C2 ".jsxs)(" NP_C3 ".he,{direction:\"top\",nDelayShowMS:240,toolTipContent:" NP_C4 \
    "?" tip ",className:(0," NP_C5 ".A)(" NP_C6 "().CheckboxWithImage," NP_C7 "&&" NP_C6 "().Disabled," \
    NP_C8 "&&" NP_C6 "().Active),onClick:()=>" NP_C7 "||" NP_C9 "(" NP_C10 ".W6," NP_C10 ".Pu,!" NP_C8 \
    "),children:[" NP_C4 "&&(0," NP_C2 ".jsx)(" NP_C11 ".Wy0,{}),!" NP_C4 "&&(0," NP_C2 ".jsx)(" NP_C11 ".kPc,{})]})"
#define NP_WINDOWS_BUTTON \
    NP_C1 "&&!" NP_C4 "&&" NP_C11 ".Xz0&&(0," NP_C2 ".jsxs)(" NP_C3 ".he,{direction:\"top\",nDelayShowMS:240," \
    "toolTipContent:" NP_LIBRARY_WINDOWS_HINT ",className:(0," NP_C5 ".A)(" NP_C6 "().CheckboxWithImage," \
    NP_C7 "&&" NP_C6 "().Disabled,npWindows&&" NP_C6 "().Active),onClick:()=>" NP_C7 \
    "||npStore.SelectCollectionsAppFilterOption(\"notprotonWindows\",null,!npWindows)," \
    "children:[(0," NP_C2 ".jsx)(\"style\",{children:\".\"+" NP_C6 "().CheckboxWithImage+" \
    "\" .SVGIcon_WindowsLogo{width:13px;height:13px}.\"+" NP_C6 "().CheckboxWithImage+" \
    "\" .SVGIcon_WindowsLogo rect{fill:inherit}\"}),(0," NP_C2 ".jsx)(" NP_C11 ".Xz0,{})]})"

static const np_gate_t g_library_filters[] = {
    // Library list and search
    { "if(!" NP_C1 "(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 "))||!" NP_C1 "(" NP_C2 "[" NP_C3 ".sc],",
      "if(!(this.m_filterSpec.notprotonWindows?((npGroup,npCheck)=>{"
      "const npApple=npGroup.rgOptions.includes(" NP_C3 ".Pu);return " NP_C1 "({...npGroup,"
      "rgOptions:[...npGroup.rgOptions.filter(npOption=>npOption!==" NP_C3 ".Pu),\"notprotonWindows\"]},"
      "npOption=>npOption===\"notprotonWindows\"?npCheck(npOption)||npApple&&npCheck(" NP_C3 ".Pu):npCheck(npOption))"
      "})(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 ")):" NP_C1 "(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 ")))||!"
      NP_C1 "(" NP_C2 "[" NP_C3 ".sc],", 2, 0 },
    // Saved library filter
    { ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||\"\",filterGroups:",
      ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||\"\","
      "notprotonWindows:!!" NP_C1 "?.notprotonWindows,filterGroups:", 1, 0 },
    { "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;",
      "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){if(" NP_C1 "===\"notprotonWindows\"){"
      "this.m_filterSpec.notprotonWindows=!!" NP_C3 ";return}let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;", 1, 0 },
    { "Reset(){this.m_filterSpec.strSearchText=\"\",",
      "Reset(){this.m_filterSpec.notprotonWindows=!1,this.m_filterSpec.strSearchText=\"\",", 1, 0 },
    { "get bIsEmpty(){return this.searchText.length==0&&",
      "get bIsEmpty(){return!this.m_filterSpec.notprotonWindows&&this.searchText.length==0&&", 1, 0 },
    { "let " NP_C1 "=this.GetSelectedOptions(" NP_C2 ".W6);" NP_C1 ".length>0&&" NP_C3 ".push(" NP_C1 ".map("
      NP_C4 "=>{if(" NP_C4 "==" NP_C2 ".Pu){",
      "let " NP_C1 "=this.GetSelectedOptions(" NP_C2 ".W6);this.m_filterSpec.notprotonWindows&&(" NP_C1 "=[..."
      NP_C1 ",\"notprotonWindows\"]);" NP_C1 ".length>0&&" NP_C3 ".push(" NP_C1 ".map(" NP_C4 "=>{if(" NP_C4
      "===\"notprotonWindows\")return " NP_LIBRARY_WINDOWS_SUMMARY ";if(" NP_C4 "==" NP_C2 ".Pu){", 1, 0 },
    // Library toolbar
    { "," NP_C1 "=" NP_C2 ".n6.currentAppFilter.BIsSelected(" NP_C3 ".W6," NP_C3 ".Pu);return(0,"
      NP_C4 ".jsxs)(\"div\",{className:" NP_C5 "().Bar,",
      "," NP_C1 "=" NP_C2 ".n6.currentAppFilter.BIsSelected(" NP_C3 ".W6," NP_C3 ".Pu),npStore=" NP_C2 ".n6,"
      "npWindows=!!" NP_C2 ".n6.currentAppFilter.m_filterSpec.notprotonWindows;return(0,"
      NP_C4 ".jsxs)(\"div\",{className:" NP_C5 "().Bar,", 1, 0 },
    { "children:[" NP_PLATFORM_BUTTON(NP_PLATFORM_TIP), "children:[" NP_WINDOWS_BUTTON "," NP_PLATFORM_BUTTON(NP_PLATFORM_TIP), 1, 0 },
    // 1792192922 passes the tooltip through Steam's localize call.
    { "children:[" NP_PLATFORM_BUTTON(NP_LOCALIZED_PLATFORM_TIP),
      "children:[" NP_WINDOWS_BUTTON "," NP_PLATFORM_BUTTON(NP_LOCALIZED_PLATFORM_TIP), 1, 0 },
};
#define NP_LIBRARY_FILTER_COUNT (sizeof(g_library_filters) / sizeof(g_library_filters[0]))

// Exactly one of the two toolbar anchors has to match.
#define NP_LIBRARY_TOOLBAR (NP_LIBRARY_FILTER_COUNT - 2)
#define NP_LOCALIZED_LIBRARY_TOOLBAR (NP_LIBRARY_FILTER_COUNT - 1)

typedef struct {
    const char     *name;
    const char     *probe;
    const np_gate_t *gates;
    size_t          count;
} np_ui_shape_t;

static const np_ui_shape_t g_shapes[] = {
    { NP_SHAPE_FORCETOOL,  "#AppProperties_CompatilibityForceTool",
      g_gates_forcetool,  sizeof(g_gates_forcetool) / sizeof(g_gates_forcetool[0]) },
    { NP_SHAPE_SELECTTOOL, "#AppProperties_Compat_SelectTool",
      g_gates_selecttool, sizeof(g_gates_selecttool) / sizeof(g_gates_selecttool[0]) },
};
#define NP_SHAPE_COUNT (sizeof(g_shapes) / sizeof(g_shapes[0]))
_Static_assert(sizeof(g_gates_forcetool) / sizeof(np_gate_t) <= NP_GATE_MAX, "gate table too long");
_Static_assert(sizeof(g_gates_selecttool) / sizeof(np_gate_t) <= NP_GATE_MAX, "gate table too long");

static int has_suffix(const char *s, const char *suf) {
    size_t ls = strlen(s), lf = strlen(suf);
    return ls >= lf && memcmp(s + ls - lf, suf, lf) == 0;
}

static const char *inside_steamui(const char *path) {
    const char *at = strstr(path, "/steamui/");
    if (at)
        return at + sizeof("/steamui/") - 1;
    if (strncmp(path, "steamui/", sizeof("steamui/") - 1) == 0)
        return path + sizeof("steamui/") - 1;
    return NULL;
}

// The compatibility UI has shipped in both chunk~*.js and sp.js.
// np_webpatch_transform rejects scripts without matching anchors.
int np_webpatch_should_patch(const char *path) {
    if (!path || !has_suffix(path, ".js"))
        return 0;

    const char *rest = inside_steamui(path);
    if (!rest)
        return 0;

    return strncmp(rest, "localization/", sizeof("localization/") - 1) != 0
        && strncmp(rest, "libraries/", sizeof("libraries/") - 1) != 0;
}

// The panel shows what a launch will actually use. The run script resolves each setting as
// launch options > gamefixes/<appid>.conf > gamefixes-default/<appid>.conf >
// gamefixes/default.conf > gamefixes-default/default.conf > the engine, so the values below the launch options are handed to
// the page as globalThis.MSCXFx when Steam loads it (a later conf edit shows after a restart).
// Native games go through np-native instead, which reads gamefixes/native/<appid>.conf over
// gamefixes/native-default.conf with variable names as they are; those land in ng and na.
#define NP_FX_MAX 16384

// The panel's names for the variables Bridgeplay reads. The page also accepts the NOTPROTON_
// spelling in launch options, but the defaults it is handed always use these.
static const char *const fx_bridgeplay_keys[] = {
    "BRIDGEPLAY_RETINA", "BRIDGEPLAY_FRAMEGEN", "BRIDGEPLAY_FRAMEGEN_QUALITY",
    "BRIDGEPLAY_FRAMEGEN_UI", "BRIDGEPLAY_FRAMEGEN_FALLBACK", "BRIDGEPLAY_FRAMEGEN_ENGINE",
};

// The BRIDGEPLAY_ name whose suffix follows prefix in key ("" for the run script's short
// conf keys), or NULL.
static const char *fx_bridgeplay_key(const char *key, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(key, prefix, n) != 0) return NULL;
    for (size_t i = 0; i < sizeof(fx_bridgeplay_keys) / sizeof(fx_bridgeplay_keys[0]); i++)
        if (strcmp(key + n, fx_bridgeplay_keys[i] + sizeof("BRIDGEPLAY_") - 1) == 0)
            return fx_bridgeplay_keys[i];
    return NULL;
}

static const char *fx_panel_key(const char *key) {
    static const char *const same[] = {
        "MTL_HUD_ENABLED", "ROSETTA_ADVERTISE_AVX", "D3DM_ENABLE_METALFX", "DXMT_ENABLE_NVEXT",
    };
    if (strcmp(key, "MSYNC") == 0) return "WINEMSYNC";
    // RETINA=1, which the run script also takes as BRIDGEPLAY_RETINA=1.
    const char *bp = fx_bridgeplay_key(key, "");
    if (!bp) bp = fx_bridgeplay_key(key, "BRIDGEPLAY_");
    if (bp) return bp;
    for (size_t i = 0; i < sizeof(same) / sizeof(same[0]); i++)
        if (strcmp(key, same[i]) == 0) return same[i];
    return NULL;
}

// np-native confs name the variables themselves, in either spelling.
static const char *fx_native_key(const char *key) {
    static const char *const keys[] = { "MTL_HUD_ENABLED", "NP_PAD_MODE" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        if (strcmp(key, keys[i]) == 0) return keys[i];
    if (strncmp(key, "BRIDGEPLAY_FRAMEGEN", 19) != 0 && strncmp(key, "NOTPROTON_FRAMEGEN", 18) != 0)
        return NULL;
    const char *bp = fx_bridgeplay_key(key, "BRIDGEPLAY_");
    return bp ? bp : fx_bridgeplay_key(key, "NOTPROTON_");
}

// Characters that go into a JSON string unescaped, up to max of them.
static int fx_word(const char *v, size_t max) {
    size_t n = strlen(v);
    if (n > max) return 0;
    for (; *v; v++)
        if (!((*v >= 'A' && *v <= 'Z') || (*v >= 'a' && *v <= 'z') ||
              (*v >= '0' && *v <= '9') || *v == '.' || *v == '_' || *v == '-'))
            return 0;
    return 1;
}

// Values fit fx_pair_t.val. Tool names are longer ("bridgeplay-proton-winecx-11.17") and are
// bounded by the fallback name they are compared against instead.
static int fx_safe(const char *v) { return fx_word(v, 16); }

typedef struct { char key[32]; char val[20]; } fx_pair_t;
typedef struct { fx_pair_t p[16]; size_t n; } fx_set_t;

static void fx_set(fx_set_t *set, const char *key, const char *val) {
    for (size_t i = 0; i < set->n; i++)
        if (strcmp(set->p[i].key, key) == 0) { snprintf(set->p[i].val, sizeof(set->p[i].val), "%s", val); return; }
    if (set->n < sizeof(set->p) / sizeof(set->p[0])) {
        snprintf(set->p[set->n].key, sizeof(set->p[set->n].key), "%s", key);
        snprintf(set->p[set->n].val, sizeof(set->p[set->n].val), "%s", val);
        set->n++;
    }
}

static char *fx_trim(char *b) {
    while (*b == ' ' || *b == '\t') b++;
    char *e = b + strlen(b);
    while (e > b && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = '\0';
    return b;
}

// Same line rules as the run script's gamefix_read: KEY=VALUE, # comments, blank lines.
// A native conf follows np-native's load_conf: "export " allowed, whitespace around the =
// and one pair of matching quotes around the value dropped.
static void fx_read(const char *path, fx_set_t *set, int native) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *b = fx_trim(line);
        if (native && strncmp(b, "export ", 7) == 0) b = fx_trim(b + 7);
        char *eq = strchr(b, '=');
        if (*b == '#' || !eq) continue;
        *eq = '\0';
        char *val = eq + 1;
        const char *key;
        if (native) {
            char *k = b + strlen(b);
            while (k > b && (k[-1] == ' ' || k[-1] == '\t')) *--k = '\0';
            val = fx_trim(val);
            size_t vl = strlen(val);
            if (vl >= 2 && (val[0] == '"' || val[0] == '\'') && val[vl - 1] == val[0]) {
                val[vl - 1] = '\0';
                val++;
            }
            key = fx_native_key(b);
        } else {
            key = fx_panel_key(b);
        }
        if (key && fx_safe(val)) fx_set(set, key, val);
    }
    fclose(f);
}

static int fx_json_set(char *buf, size_t cap, size_t *len, const fx_set_t *set) {
    int n = snprintf(buf + *len, cap - *len, "{");
    if (n < 0 || (size_t)n >= cap - *len) return 0;
    *len += (size_t)n;
    for (size_t i = 0; i < set->n; i++) {
        n = snprintf(buf + *len, cap - *len, "%s\"%s\":\"%s\"", i ? "," : "", set->p[i].key, set->p[i].val);
        if (n < 0 || (size_t)n >= cap - *len) return 0;
        *len += (size_t)n;
    }
    n = snprintf(buf + *len, cap - *len, "}");
    if (n < 0 || (size_t)n >= cap - *len) return 0;
    *len += (size_t)n;
    return 1;
}

// A JSON string, for values that can hold any character (the home directory).
static int fx_json_str(char *buf, size_t cap, size_t *len, const char *v) {
    if (*len + 1 >= cap) return 0;
    buf[(*len)++] = '"';
    for (; *v; v++) {
        unsigned char c = (unsigned char)*v;
        char esc[8];
        int n;
        if (c == '"' || c == '\\') n = snprintf(esc, sizeof(esc), "\\%c", c);
        else if (c < 0x20 || c == 0x7f) n = snprintf(esc, sizeof(esc), "\\u%04x", c);
        else { esc[0] = (char)c; esc[1] = '\0'; n = 1; }
        if (n < 0 || *len + (size_t)n + 1 >= cap) return 0;
        memcpy(buf + *len, esc, (size_t)n);
        *len += (size_t)n;
    }
    buf[(*len)++] = '"';
    buf[*len] = '\0';
    return 1;
}

static int fx_appid(const char *name, char *out, size_t cap) {
    size_t n = 0;
    while (name[n] >= '0' && name[n] <= '9') n++;
    if (n == 0 || n >= cap || strcmp(name + n, ".conf") != 0) return 0;
    memcpy(out, name, n);
    out[n] = '\0';
    return 1;
}

// {"<appid>":{...},...} from the <appid>.conf files in dirs, later dirs winning per key.
static int fx_json_apps(char *buf, size_t cap, size_t *len, const char *root,
                        const char *const *dirs, int ndirs, int native) {
    char path[768];
    int n = snprintf(buf + *len, cap - *len, "{");
    if (n < 0 || (size_t)n >= cap - *len) return 0;
    *len += (size_t)n;
    char seen[64][16];
    size_t nseen = 0;
    for (int d = 0; d < ndirs; d++) {
        snprintf(path, sizeof(path), "%s/%s", root, dirs[d]);
        DIR *dir = opendir(path);
        if (!dir) continue;
        struct dirent *ent;
        while ((ent = readdir(dir)) && nseen < 64) {
            char id[16];
            if (!fx_appid(ent->d_name, id, sizeof(id))) continue;
            int dup = 0;
            for (size_t i = 0; i < nseen; i++) dup |= strcmp(seen[i], id) == 0;
            if (!dup) memcpy(seen[nseen++], id, sizeof(id));
        }
        closedir(dir);
    }
    int first = 1;
    for (size_t i = 0; i < nseen; i++) {
        fx_set_t app = {0};
        for (int d = 0; d < ndirs; d++) {
            snprintf(path, sizeof(path), "%s/%s/%s.conf", root, dirs[d], seen[i]);
            fx_read(path, &app, native);
        }
        if (!app.n) continue;
        n = snprintf(buf + *len, cap - *len, "%s\"%s\":", first ? "" : ",", seen[i]);
        if (n < 0 || (size_t)n >= cap - *len) return 0;
        *len += (size_t)n;
        first = 0;
        if (!fx_json_set(buf, cap, len, &app)) return 0;
    }
    n = snprintf(buf + *len, cap - *len, "}");
    if (n < 0 || (size_t)n >= cap - *len) return 0;
    *len += (size_t)n;
    return 1;
}

static int fx_build(char *buf, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) return 0;
    char root[512], path[768];
    np_support_path(root, sizeof(root), home, NULL);

    // Steam's chunks end in "//# sourceMappingURL=..." with no newline after it, so the
    // assignment starts a line of its own or the browser reads it as part of that comment.
    size_t len = 0;
    int n = snprintf(buf, cap, "\n;globalThis.MSCXFx={\"g\":");
    if (n < 0 || (size_t)n >= cap) return 0;
    len = (size_t)n;

    // Every game: Bridgeplay's shipped defaults, then the user's Game Defaults over them.
    fx_set_t global = {0};
    snprintf(path, sizeof(path), "%s/gamefixes-default/default.conf", root);
    fx_read(path, &global, 0);
    snprintf(path, sizeof(path), "%s/gamefixes/default.conf", root);
    fx_read(path, &global, 0);
    if (!fx_json_set(buf, cap, &len, &global)) return 0;

    // Per-app: the shipped file first, the user's second, as the run script reads them.
    n = snprintf(buf + len, cap - len, ",\"a\":");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;
    const char *dirs[2] = { "gamefixes-default", "gamefixes" };
    if (!fx_json_apps(buf, cap, &len, root, dirs, 2, 0)) return 0;

    // Engines: a tool whose description names msync runs with it on (tools: name, build,
    // arch, description, tab separated). "" stands for the default tool.
    n = snprintf(buf + len, cap - len, ",\"e\":{");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;
    snprintf(path, sizeof(path), "%s/tools", root);
    FILE *tools = fopen(path, "r");
    int first = 1;
    if (tools) {
        char line[512];
        while (fgets(line, sizeof(line), tools)) {
            char *tab = strchr(line, '\t');
            if (!tab) continue;
            *tab = '\0';
            if (!*line || !fx_word(line, sizeof(g_fallback_tool) - 1)) continue;
            const char *ms = strstr(tab + 1, "msync") ? "1" : "0";
            int fallback = g_fallback_tool[0] && strcmp(line, g_fallback_tool) == 0;
            n = snprintf(buf + len, cap - len, "%s\"%s\":{\"WINEMSYNC\":\"%s\"}",
                         first ? "" : ",", line, ms);
            if (n < 0 || (size_t)n >= cap - len) { fclose(tools); return 0; }
            len += (size_t)n;
            first = 0;
            if (fallback) {
                n = snprintf(buf + len, cap - len, ",\"\":{\"WINEMSYNC\":\"%s\"}", ms);
                if (n < 0 || (size_t)n >= cap - len) { fclose(tools); return 0; }
                len += (size_t)n;
            }
        }
        fclose(tools);
    }

    // The run script reads controllers directly unless the launch options say otherwise, and
    // overlay-shim keeps the UI sharp and falls back on fast motion unless told not to.
    n = snprintf(buf + len, cap - len, "},\"d\":{\"BRIDGEPLAY_RAW_CONTROLLERS\":\"1\","
                 "\"BRIDGEPLAY_FRAMEGEN_UI\":\"1\",\"BRIDGEPLAY_FRAMEGEN_FALLBACK\":\"1\"}");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;

    // Native games: np-native's own confs, and the home its launcher path is written under.
    n = snprintf(buf + len, cap - len, ",\"ng\":");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;
    fx_set_t native = {0};
    snprintf(path, sizeof(path), "%s/gamefixes/native-default.conf", root);
    fx_read(path, &native, 1);
    if (!fx_json_set(buf, cap, &len, &native)) return 0;
    n = snprintf(buf + len, cap - len, ",\"na\":");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;
    const char *ndirs[1] = { "gamefixes/native" };
    if (!fx_json_apps(buf, cap, &len, root, ndirs, 1, 1)) return 0;
    n = snprintf(buf + len, cap - len, ",\"h\":");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    len += (size_t)n;
    if (!fx_json_str(buf, cap, &len, home)) return 0;
    n = snprintf(buf + len, cap - len, "};");
    if (n < 0 || (size_t)n >= cap - len) return 0;
    return 1;
}

char *np_webpatch_transform(const uint8_t *src, size_t src_len, size_t *out_len,
                            const char **out_shape) {
    const char *s = (const char *)src;

    if (out_shape)
        *out_shape = NULL;

    const np_ui_shape_t *shape = NULL;
    for (size_t i = 0; i < NP_SHAPE_COUNT; i++) {
        if (count_matches(s, src_len, g_shapes[i].probe) == 0)
            continue;
        if (shape) {
            NP_WARN("webpatch: chunk carries both the '%s' and '%s' compat UI, "
                    "refusing to guess which one renders", shape->name, g_shapes[i].name);
            return NULL;
        }
        shape = &g_shapes[i];
    }
    int    fix_on[NP_FIX_COUNT];
    size_t fix_live = 0;
    char *native_mac_js = NULL;
    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        size_t n = count_matches(s, src_len, g_fixes[f].find);
        fix_on[f] = n == (size_t)g_fixes[f].expect;
        if ((f == NP_NATIVE_MAC_FILTER_FIX || f == NP_UPDATED_NATIVE_MAC_FILTER_FIX) && fix_on[f]) {
            free(native_mac_js);
            native_mac_js = np_nativeplatform_javascript();
        }
        if (fix_on[f]) { fix_live++; continue; }
        if (n)
            NP_WARN("webpatch: fix %zu expected %d occurrence(s), found %zu; "
                    "leaving it alone", f, g_fixes[f].expect, n);
    }
    if (!native_mac_js && (fix_on[NP_NATIVE_MAC_FILTER_FIX] || fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX])) {
        NP_WARN("webpatch: no platform list from appinfo.vdf, the Apple filter stays stock");
        fix_live -= fix_on[NP_NATIVE_MAC_FILTER_FIX] + fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX];
        fix_on[NP_NATIVE_MAC_FILTER_FIX] = fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX] = 0;
    }
    int library_filter = fix_on[NP_NATIVE_MAC_FILTER_FIX] || fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX];
    int library_on[NP_LIBRARY_FILTER_COUNT] = {0};
    for (size_t g = 0; library_filter && g < NP_LIBRARY_FILTER_COUNT; g++) {
        size_t n = count_matches(s, src_len, g_library_filters[g].find);
        library_on[g] = n == (size_t)g_library_filters[g].expect;
        if (library_on[g] || g == NP_LIBRARY_TOOLBAR || g == NP_LOCALIZED_LIBRARY_TOOLBAR) continue;
        NP_WARN("webpatch: library anchor %zu expected %d occurrence(s), found %zu; "
                "no Windows filter button", g, g_library_filters[g].expect, n);
        library_filter = 0;
    }
    if (library_filter && library_on[NP_LIBRARY_TOOLBAR] == library_on[NP_LOCALIZED_LIBRARY_TOOLBAR]) {
        NP_WARN("webpatch: %s; no Windows filter button",
                library_on[NP_LIBRARY_TOOLBAR] ? "both library toolbar anchors matched"
                                               : "no library toolbar anchor matched");
        library_filter = 0;
    }

    if (!shape && !fix_live) {
        free(native_mac_js);
        return NULL;   // Not the part carrying the compat UI.
    }

    int    gate_on[NP_GATE_MAX] = {0};
    size_t gate_live = 0;
    if (shape) {
        if (out_shape)
            *out_shape = shape->name;

        int drifted = 0;
        for (size_t g = 0; g < shape->count; g++) {
            size_t n = count_matches(s, src_len, shape->gates[g].find);
            gate_on[g] = n == (size_t)shape->gates[g].expect;
            if (gate_on[g]) { gate_live++; continue; }
            if (shape->gates[g].optional) {
                NP_WARN("webpatch: [%s] optional gate %zu expected %d occurrence(s), "
                        "found %zu; skipping it", shape->name, g, shape->gates[g].expect, n);
            } else {
                NP_WARN("webpatch: [%s] gate %zu expected %d occurrence(s), found %zu",
                        shape->name, g, shape->gates[g].expect, n);
                drifted = 1;
            }
        }
        if (drifted) {
            NP_ERR("webpatch: [%s] compat UI left unpatched, a Steam update moved the "
                   "anchors", shape->name);
            free(native_mac_js);
            return NULL;
        }
    }

    np_out_t out = {0};
    np_cap_t caps[NP_CAP_MAX];
    if (native_mac_js && (!out_put(&out, native_mac_js, strlen(native_mac_js)) ||
                          !out_put(&out, NP_RUNS_EXE_JS, sizeof(NP_RUNS_EXE_JS) - 1))) {
        free(out.buf);
        free(native_mac_js);
        return NULL;
    }
    free(native_mac_js);
    unsigned char can_start[256] = {0};
    for (size_t g = 0; shape && g < shape->count; g++)
        if (gate_on[g]) mark_start(can_start, shape->gates[g].find);
    for (size_t f = 0; f < NP_FIX_COUNT; f++)
        if (fix_on[f]) mark_start(can_start, g_fixes[f].find);
    for (size_t g = 0; library_filter && g < NP_LIBRARY_FILTER_COUNT; g++)
        if (library_on[g]) mark_start(can_start, g_library_filters[g].find);
    for (size_t i = 0; i < src_len; ) {
        size_t plain = i;
        while (plain < src_len && !can_start[(unsigned char)s[plain]]) plain++;
        if (plain > i) {
            if (!out_put(&out, s + i, plain - i)) { free(out.buf); return NULL; }
            i = plain;
            continue;
        }
        const np_gate_t *hit = NULL;
        size_t used = 0;
        for (size_t g = 0; shape && g < shape->count; g++) {
            if (!gate_on[g]) continue;
            used = match_at(s, src_len, i, shape->gates[g].find, caps);
            if (used) { hit = &shape->gates[g]; break; }
        }
        for (size_t f = 0; !hit && f < NP_FIX_COUNT; f++) {
            if (!fix_on[f]) continue;
            used = match_at(s, src_len, i, g_fixes[f].find, caps);
            if (used) { hit = &g_fixes[f]; break; }
        }
        for (size_t g = 0; !hit && library_filter && g < NP_LIBRARY_FILTER_COUNT; g++) {
            if (!library_on[g]) continue;
            used = match_at(s, src_len, i, g_library_filters[g].find, caps);
            if (used) { hit = &g_library_filters[g]; break; }
        }
        int ok = hit ? out_expand(&out, hit->replace, caps)
                     : out_put(&out, s + i, 1);
        if (!ok) { free(out.buf); return NULL; }
        i += hit ? used : 1;
    }

    if (shape) {
        char *fx = malloc(NP_FX_MAX);
        int built = fx && fx_build(fx, NP_FX_MAX);
        if (!built)
            NP_WARN("webpatch: [%s] conf defaults not handed to the panel, its toggles "
                    "show launch options only", shape->name);
        int ok = !built || out_put(&out, fx, strlen(fx));
        free(fx);
        if (!ok) { free(out.buf); return NULL; }
    }

    if (!out_reserve(&out, 0)) { free(out.buf); return NULL; }
    out.buf[out.len] = '\0';
    *out_len = out.len;
    if (library_filter) NP_LOG("webpatch: Windows library filter button added");
    NP_LOG("webpatch: [%s] %zu gates, %zu fixes applied",
           shape ? shape->name : "no compat UI", gate_live, fix_live);
    return out.buf;
}
