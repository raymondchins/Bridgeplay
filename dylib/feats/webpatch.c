// Enables Steam Play in the UI, and shows the game properties tab Steam calls Compatibility
// as Bridgeplay, since on a Mac every setting on it is Bridgeplay's
#include "webpatch.h"
#include "nativeplatform.h"
#include "displayrate.h"
#include "compatverdict.h"
#include "../util/log.h"
#include "../util/file.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

// Steam's Vite build imports its dialog components from another chunk under names that
// change with every build. Each name is read off one use of it in the chunk being patched
// (g_binds) and stands in a replacement as one of these bytes.
#define NP_B_CHECKBOX "\016"
#define NP_B_DROPDOWN "\017"
#define NP_B_SLIDER   "\020"
#define NP_B_MACOS    "\027"
#define NP_BIND_COUNT 4
#define NP_BIND_TEXT_MAX 64

static _Thread_local char g_bind_text[NP_BIND_COUNT][NP_BIND_TEXT_MAX];
static _Thread_local unsigned char g_bind_ok[NP_BIND_COUNT];

static int bind_index(char c) {
    switch (c) {
    case '\016': return 0;
    case '\017': return 1;
    case '\020': return 2;
    case '\027': return 3;
    default:      return -1;
    }
}

static const char *marker_text(char c) {
    if (c == NP_FALLBACK_TOOL[0]) return g_fallback_tool;
    if (c == NP_FEX_TOOLS[0]) return g_fex_tools;
    int b = bind_index(c);
    if (b >= 0) return g_bind_text[b];
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

        int css_class = f > find && f[-1] == '`' && f[1] == '`';
        if (s >= len || (!css_class && src[s] >= '0' && src[s] <= '9')) return 0;
        size_t run = 0;
        while (s + run < len &&
               (is_ident_char((unsigned char)src[s + run]) || (css_class && src[s + run] == '-')))
            run++;
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

static size_t count_matches_first(const char *src, size_t len, const char *find,
                                  np_cap_t *first) {
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
        if (used && !n && first) memcpy(first, caps, sizeof(caps));
        if (used) { n++; i += used; } else i++;
    }
    return n;
}

static size_t count_matches(const char *src, size_t len, const char *find) {
    return count_matches_first(src, len, find, NULL);
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

#define NP_WEB_IS_RU \
    "(()=>{const l=(globalThis.document?.documentElement?.lang||" \
    "globalThis.navigator?.language||\"\").toLowerCase().replace(/_/g,\"-\");" \
    "return /^(ru(-[a-z0-9]+)*|russian)$/.test(l)})()"

#define NP_WEB_TEXT(EN, ZH, IT, RU) \
    "(" NP_WEB_IS_ZH "?\"" ZH "\":" NP_WEB_IS_IT "?\"" IT "\":" NP_WEB_IS_RU "?\"" RU "\":\"" EN "\")"

#define NP_COMPAT_HINT NP_WEB_TEXT( \
    "Enable CrossOver under Properties \\u203a Bridgeplay to install and run the Windows version.", \
    "请在“属性 \\u203a Bridgeplay”中启用 CrossOver，以安装并运行 Windows 版本。", \
    "Abilita CrossOver in Propriet\\u00e0 \\u203a Bridgeplay per installare e avviare la versione Windows.", "Включите CrossOver в разделе «Свойства \\u203a Bridgeplay», чтобы установить и запустить версию для Windows.")

#define NP_IMAGE_FILES_LABEL NP_WEB_TEXT( \
    "Image Files (*.tga,*.png,*.exe)", "图像文件 (*.tga,*.png,*.exe)", "File immagine (*.tga,*.png,*.exe)", "Файлы изображений (*.tga,*.png,*.exe)")

#define NP_LIBRARY_WINDOWS_HINT NP_WEB_TEXT( \
    "Show only games that run on Windows and do not have a macOS version", \
    "仅显示可在 Windows 上运行且没有 macOS 版本的游戏", \
    "Mostra solo i giochi che funzionano su Windows e non hanno una versione macOS", "Показывать только игры, которые работают в Windows и не имеют версии для macOS")

#define NP_LIBRARY_WINDOWS_SUMMARY NP_WEB_TEXT( \
    "Runs on Windows, no macOS version", \
    "可在 Windows 上运行，无 macOS 版本", \
    "Funziona su Windows, nessuna versione macOS", "Работает в Windows, версии для macOS нет")

// Rebuild row in the CrossOver panel.
// The row is redrawn on every poll, so the bar keeps its phase from when the rebuild started
// instead of restarting on each redraw.
#define NP_PREFIX_NEED NP_WEB_TEXT("Switching to this compatibility tool requires a prefix rebuild. Rebuild now?", "切换到此兼容性工具需要重建游戏容器。现在重建吗？", "Per passare a questo strumento di compatibilità serve ricostruire il prefisso. Ricostruirlo ora?", "Для перехода на этот инструмент совместимости нужно пересоздать префикс. Пересоздать сейчас?")
#define NP_PREFIX_BACKUP NP_WEB_TEXT("Backup & Rebuild Prefix", "备份并重建游戏容器", "Backup e ricostruisci prefisso", "Создать копию и пересоздать префикс")
#define NP_PREFIX_REBUILD NP_WEB_TEXT("Rebuild Prefix", "重建游戏容器", "Ricostruisci prefisso", "Пересоздать префикс")
#define NP_PREFIX_RUNNING NP_WEB_TEXT("Quit the game to rebuild.", "请先退出游戏再重建。", "Chiudi il gioco per ricostruire.", "Закройте игру, чтобы пересоздать префикс.")
#define NP_PREFIX_SETUP NP_WEB_TEXT("Rebuilding prefix\\u2026", "正在重建游戏容器\\u2026", "Ricostruzione del prefisso\\u2026", "Префикс пересоздаётся\\u2026")
#define NP_PREFIX_COPY NP_WEB_TEXT("Copying your files\\u2026", "正在复制你的文件\\u2026", "Copia dei tuoi file\\u2026", "Копирование файлов\\u2026")
#define NP_PREFIX_FINISH NP_WEB_TEXT("Finishing\\u2026", "正在完成\\u2026", "Completamento\\u2026", "Завершение\\u2026")
#define NP_PREFIX_DONE NP_WEB_TEXT("Prefix rebuilt.", "游戏容器已重建。", "Prefisso ricostruito.", "Префикс пересоздан.")
#define NP_PREFIX_DONE_BACKUP NP_WEB_TEXT("Prefix rebuilt. A backup of the original is in Bridgeplay's Prefixes view.", "游戏容器已重建。原容器的备份在 Bridgeplay 的“游戏容器”视图中。", "Prefisso ricostruito. Un backup dell'originale è nella vista Prefissi di Bridgeplay.", "Префикс пересоздан. Резервная копия исходного — в разделе «Префиксы» в Bridgeplay.")
#define NP_PREFIX_FAILED NP_WEB_TEXT("Could not rebuild the prefix.", "无法重建游戏容器。", "Impossibile ricostruire il prefisso.", "Не удалось пересоздать префикс.")
#define NP_PREFIX_LOG NP_WEB_TEXT("Open Log", "打开日志", "Apri il log", "Открыть журнал")
#define NP_PREFIX_APP NP_WEB_TEXT("Could not find the Bridgeplay app. Move Bridgeplay to Applications, open it and click Install again.", "找不到 Bridgeplay 应用。请将 Bridgeplay 移到“应用程序”文件夹，打开它并再次点击“安装”。", "Impossibile trovare l'app Bridgeplay. Sposta Bridgeplay in Applicazioni, aprila e fai di nuovo clic su Installa.", "Не удалось найти приложение Bridgeplay. Переместите Bridgeplay в «Программы», откройте его и снова нажмите «Установить».")

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
    "st b=el('div','MSCXBar');t0||(t0=Date.now());const m=el('div','');m.style.animationDelay=-((Date.now()-t0)%2400)+'ms';b.append(m);k.push(b);live=1;timer=setTimeout(refresh,500)}else if((t0=0)||" \
    "term==='failed'){k.push(el('div','',T.failed));const r=el('div','MSCXBtns');r.append(btn(T.log,0" \
    ",0,()=>call('NotProton.OpenPrefixLog#1').catch(()=>0)));k.push(r);s&&s.needsRebuild&&s.app&&!s.r" \
    "unning&&k.push(pair(0))}else if(term)k.push(el('div','',term==='done-backup'?T.doneBackup:T.done" \
    "));else if(s&&s.needsRebuild){if(!s.app)k.push(el('div','',T.app));else{k.push(el('div','',s.run" \
    "ning?T.running:T.need),pair(s.running));s.running&&(timer=setTimeout(refresh,3e3))}}e.replaceChi" \
    "ldren(...k);e.style.display=k.length?'':'none'};e.style.flexDirection='column';e.style.gap='8px'" \
    ";e.style.display='none';const on=v=>{if(!e.isConnected)return e.npStop();v.detail===id&&!busy&&(" \
    "term='',refresh())};const stop=e.npStop=()=>{stopped=1;clearTimeout(timer);observer?.disconnect();globalThis.removeEventListener?.('mscxstat" \
    "e',on)};const observer=globalThis.MutationObserver?new globalThis.MutationObserver(()=>{if(!e.isConnected)stop()}):null;observer?.observe(e.ownerDocument,{childList:true,subtree:true});globalThis.addEventListener?.('mscxstate',on);refresh()};"

// Players' verdict and anti-cheat note: a row in the panel (MSCXVerdictRow) and, for a game
// that is not installed and is known not to run, a warning on its library page (MSCXWarnRow).
// Both read globalThis.MSCXVerdicts, which the transform builds from compat-verdicts.tsv
// (compatverdict.c), and a maintainer-confirmed ANTICHEAT gamefix from MSCXFx. No file, an
// unknown game or a verdict over 30 days old shows nothing. Text goes in with textContent only.
#define NP_CX_VERDICT_CSS \
    ".MSCXVerdictHead{font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#8b929a}" \
    ".MSCXVerdictMain{font-size:15px;color:#fff;text-wrap:balance}" \
    ".MSCXVerdictDim{font-size:13px;color:#8b929a;text-wrap:balance}" \
    ".MSCXVerdictNote{font-size:14px;color:#e8c46d;text-wrap:balance}" \
    ".MSCXVerdictBtns{display:flex;gap:8px;margin-top:4px}" \
    ".MSCXWarn{position:relative;display:flex;margin:12px 24px;padding:12px 44px 12px 14px;" \
    "border-left:3px solid #e8a800;border-radius:3px;background:rgba(59,63,72,.6);color:#dfe3e6;" \
    "font-size:14px;line-height:1.45}" \
    ".MSCXWarnBody{display:flex;flex-direction:column;gap:6px;min-width:0}" \
    ".MSCXWarnHead{font-weight:700;color:#fff;text-wrap:balance}" \
    ".MSCXWarnBody>div{text-wrap:balance}" \
    ".MSCXWarnBtn{background:#3d4450;color:#fff;border:none;border-radius:2px;padding:6px 14px;" \
    "font-size:14px;cursor:pointer}.MSCXWarnBtn:hover{background:#4c5361}" \
    ".MSCXWarnClose{position:absolute;top:6px;right:6px;width:28px;height:28px;padding:0;background:none;" \
    "border:none;border-radius:2px;color:#8b929a;font-size:20px;line-height:1;cursor:pointer}" \
    ".MSCXWarnClose:hover{color:#fff;background:rgba(255,255,255,.08)}" \
    ".MSCXWarnBtn:focus-visible,.MSCXWarnClose:focus-visible{outline:2px solid #fff;outline-offset:1px}"

#define NP_CX_VERDICT \
    "\n;(()=>{const G=globalThis," \
    "N={eac:'Easy Anti-Cheat',battleye:'BattlEye',ricochet:'Ricochet',vanguard:'Vanguard',ace:'Anti-Cheat Expert'," \
    "xigncode3:'XIGNCODE3',nprotect:'nProtect GameGuard',javelin:'EA Javelin',denuvo:'Denuvo Anti-Cheat',vac:'VAC'}," \
    /* Kernel anti-cheat, which needs a Windows driver Wine cannot load. */ \
    "K=['ricochet','vanguard','javelin','xigncode3','nprotect','denuvo']," \
    "U='https://bridgeplay.dev/guides/anti-cheat-on-mac#alternatives',W='MSCXWarnDismissed';" \
    "let M=null,S=null,D=null;" \
    "const lang=()=>" NP_WEB_IS_ZH "?'zh':" NP_WEB_IS_IT "?'it':" NP_WEB_IS_RU "?'ru':'en'," \
    "tr=g=>(e,z,i,r)=>g==='zh'?z:g==='it'?i:g==='ru'&&r?r:e," \
    "fill=(s,x)=>s.replace(/\\{(\\w+)\\}/g,(m,k)=>String(x[k]))," \
    "table=()=>{const d=G.MSCXVerdicts;if(M&&S===d)return M;S=d;M=new Map;" \
    "if(d&&typeof d.g==='string')for(const r of d.g.split(';')){const c=r.indexOf(':'),f=r.slice(c+1).split(',');" \
    "c>0&&f.length===7&&M.set(+r.slice(0,c),{v:f[0],n:+f[1],p:+f[2],i:+f[3],b:+f[4],since:f[5],ac:f[6]?f[6].split('+'):[]})}" \
    "return M}," \
    /* A kernel anti-cheat is a hard no only when a maintainer confirmed it, or no recent Mac \
       ran the game well: some of these games run offline. */ \
    "info=id=>{id=+id;if(!(id>0&&id<2147483648))return null;" \
    "const r=table().get(id),u=+(G.MSCXVerdicts||{}).u||0,days=Math.max(0,Math.floor((Date.now()/1e3-u)/86400))," \
    "c=(((G.MSCXFx||{}).a||{})[id]||{}).ANTICHEAT,conf=typeof c==='string'&&(c in N||c==='other')?c:''," \
    "v=r&&r.v!=='-'&&r.n>0&&u>0&&days<=30?r.v:'',ac=(conf?[conf]:[]).concat(r?r.ac.filter(a=>a!==conf):[]);" \
    "if(!v&&!ac.length)return null;" \
    "const well=v==='p'||(v==='m'||v==='o')&&r.p>0,k=ac.find(a=>K.includes(a));" \
    "return{id,v,n:v?r.n:0,p:v?r.p:0,i:v?r.i:0,b:v?r.b:0,since:v?r.since:'',days,ac,conf:!!conf," \
    "hard:conf||(k&&!well?k:'')}}," \
    "since=(L,s)=>/^s\\d+$/.test(s)?L('Steam build ','Steam 版本 ','Steam build ','сборки Steam ')+s.slice(1):'Bridgeplay '+s," \
    "main=(L,x)=>fill(x.v==='p'?L('Ran well on {p} of {n} Macs','在 {n} 台 Mac 中有 {p} 台运行良好','Funziona bene su {p} Mac su {n}','Хорошо работает на {p} из {n} Mac')" \
    ":x.v==='d'?L('Did not run on {b} of {n} Macs','在 {n} 台 Mac 中有 {b} 台无法运行','Non si avvia su {b} Mac su {n}','Не запустилась на {b} из {n} Mac')" \
    ":x.v==='s'?L('Broken since {s}','仅在 {s} 之前运行良好'," \
    "'Funzionava solo prima di {s}','Хорошо работала только до {s}')" \
    ":x.v==='m'?L('Mixed: {p} good, {i} with issues, {b} failed','不一：{p} 良好，{i} 有问题，{b} 失败'," \
    "'Misti: {p} bene, {i} problemi, {b} falliti','Смешанно: хорошо {p}, проблемы {i}, сбой {b}')" \
    ":x.p?L('One report: ran well','仅 1 份报告：运行良好','Una segnalazione: funziona bene','Один отчёт: работает хорошо')" \
    ":x.i?L('One report: had issues','仅 1 份报告：有问题','Una segnalazione: con problemi','Один отчёт: с проблемами')" \
    ":L('One report: did not run','仅 1 份报告：无法运行','Una segnalazione: non si avvia','Один отчёт: не запускается')," \
    "Object.assign({s:since(L,x.since)},x))," \
    "dim=(L,x)=>(x.v==='p'||x.v==='d'||x.v==='s'?fill(L('{p} good · {i} with issues · {b} failed','{p} 良好 · {i} 有问题 · {b} 失败','{p} bene · {i} problemi · {b} falliti','хорошо: {p} · проблемы: {i} · сбой: {b}'),x)+' · ':'')" \
    "+(x.days<1?L('updated today','今天更新','aggiornato oggi','обновлено сегодня'):x.days<2?L('updated 1 day ago','1 天前更新','aggiornato 1 giorno fa','обновлено 1 день назад')" \
    ":fill(L('updated {d} days ago','{d} 天前更新','aggiornato {d} giorni fa','обновлено {d} дн. назад'),{d:x.days}))," \
    "acl=(L,x)=>{if(x.hard){const n=N[x.hard];" \
    "return(n?fill(L('Likely won’t start: Wine can’t run {a}.','Wine 无法运行 {a}，很可能无法启动。','Probabilmente non si avvia: Wine non supporta {a}.','Вряд ли запустится: Wine не поддерживает {a}.'),{a:n})" \
    ":L('Likely won’t start: Wine can’t run its anti-cheat.','Wine 不支持其反作弊，很可能无法启动。','Probabilmente non si avvia: Wine non supporta il suo anti-cheat.','Вряд ли запустится: Wine не поддерживает античит.'))" \
    "+(x.conf?' '+L('Bridgeplay asks first.','Bridgeplay 会先询问。','Bridgeplay chiede prima.','Bridgeplay спросит заранее.'):'')}" \
    "const a=x.ac.find(a=>a!=='vac')||x.ac[0];if(!a)return'';" \
    "if(a==='vac')return L('VAC: matchmaking may fail.','VAC：在线匹配可能失败。','VAC: il matchmaking potrebbe non funzionare.','VAC: онлайн-подбор может не работать.');" \
    "return N[a]?fill(L('{a}: online play may fail.','{a}：在线游戏可能失败。','{a}: il gioco online potrebbe non funzionare.','{a}: игра по сети может не работать.'),{a:N[a]})" \
    ":L('Anti-cheat: online play may fail.','反作弊：在线游戏可能失败。','Anti-cheat: il gioco online potrebbe non funzionare.','Античит: игра по сети может не работать.')}," \
    /* A plain link to Bridgeplay's own guide: no service is named or linked from here. */ \
    "away=(L,el,cls)=>{const k=[el('div','MSCXVerdictDim',L('Try cloud gaming or Remote Play.','可试试云游戏或远程畅玩。','Prova il cloud gaming o Remote Play.','Попробуйте облачный гейминг или Remote Play.'))]," \
    "s=G.SteamClient&&G.SteamClient.System;" \
    "if(s&&typeof s.OpenInSystemBrowser==='function'){const b=el('button',cls,L('Other Ways to Play','其他游玩方式','Altri modi per giocare','Другие способы играть'));" \
    "b.onclick=()=>{try{G.SteamClient.System.OpenInSystemBrowser(U)}catch(e){}};const r=el('div','MSCXVerdictBtns');r.append(b);k.push(r)}" \
    "return k}," \
    "mk=d=>(t,c,s)=>{const n=d.createElement(t);if(c)n.className=c;if(s!=null)n.textContent=s;return n}," \
    "css=d=>{try{if(d.getElementById('MSCXVerdictCSS'))return;const s=d.createElement('style');s.id='MSCXVerdictCSS';" \
    "s.textContent='" NP_CX_VERDICT_CSS "';(d.head||d.documentElement).appendChild(s)}catch(e){}}," \
    "gone=()=>{if(!D)try{D=JSON.parse(G.localStorage.getItem(W)||'{}')||{}}catch(e){D={}}return D};" \
    "G.MSCXVerdictFor=info;" \
    "G.MSCXVerdictRow=(e,id)=>{if(e.npVerdict===id)return;e.npVerdict=id;const x=info(id),d=e.ownerDocument;" \
    "if(!x||!d){e.style.display='none';return}css(d);const L=tr(lang()),el=mk(d),k=[];" \
    "x.v&&k.push(el('div','MSCXVerdictHead',L('Players report','玩家反馈','Segnalazioni dei giocatori','Отчёты игроков'))," \
    "el('div','MSCXVerdictMain',main(L,x)),el('div','MSCXVerdictDim',dim(L,x)));" \
    "const a=acl(L,x);a&&k.push(el('div','MSCXVerdictNote',a));(x.hard||x.v==='d')&&k.push(...away(L,el,'MSCXBtn'));" \
    "e.style.flexDirection='column';e.style.gap='4px';e.replaceChildren(...k);e.style.display=k.length?'':'none'};" \
    /* a anti-cheat, d players report it does not run, s it broke on a newer build. */ \
    /* A game Steam runs as its Mac version gets no Wine warning. */ \
    "G.MSCXWarnFor=id=>{let t;try{t=G.appDetailsStore?.GetAppDetails(id)}catch(e){}" \
    "if(t&&id<2147483648&&(t.vecPlatforms||[]).indexOf('osx')>=0&&!t.strCompatToolName)return'';" \
    "const x=info(id),r=x?x.hard?'a':x.v==='d'?'d':x.v==='s'?'s':'':'';return r&&gone()[x.id]!==r?r:''};" \
    "G.MSCXWarnRow=(e,id)=>{if(e.npWarn===id)return;e.npWarn=id;const r=G.MSCXWarnFor(id),x=info(id),d=e.ownerDocument;" \
    "if(!r||!d){e.style.display='none';return}css(d);const L=tr(lang()),el=mk(d),b=el('div','MSCXWarnBody');" \
    "e.className='MSCXWarn';e.setAttribute&&e.setAttribute('role','note');" \
    "b.append(el('div','MSCXWarnHead',L('Before you download','下载前请注意','Prima di scaricare','Перед загрузкой'))," \
    "el('div','',r==='a'?acl(L,x):r==='d'?fill(L('Failed on {b} of {n} players’ Macs.','{n} 位玩家中有 {b} 位无法运行。','Non si avvia per {b} giocatori su {n}.','Не запустилась у {b} из {n} игроков.'),x)" \
    ":fill(L('Broken since {s}, players report.','玩家反馈：仅在 {s} 之前运行良好。','Secondo i giocatori funzionava solo prima di {s}.','По отчётам игроков, хорошо работала только до {s}.'),{s:since(L,x.since)})));" \
    "r!=='s'&&b.append(...away(L,el,'MSCXWarnBtn'));" \
    "const c=el('button','MSCXWarnClose','×'),t=L('Dismiss','关闭','Chiudi','Закрыть');c.title=t;c.setAttribute&&c.setAttribute('aria-label',t);" \
    "c.onclick=()=>{const s=gone();s[x.id]=r;try{G.localStorage.setItem(W,JSON.stringify(s))}catch(e){}e.style.display='none'};" \
    "e.replaceChildren(b,c);e.style.display=''}})();"

// The banner Steam shows a 32-bit Mac game that is not installed. A game with no such banner
// that is known not to run gets Bridgeplay's warning in the same place instead.
#define NP_INSTALL_BANNER \
    "!" NP_C1 ".local_per_client_data?.installed&&(" NP_C1 ".most_available_per_client_data?.is_invalid_os_type?" \
    "(0," NP_C2 ".jsx)(" NP_C3 ",{}):typeof MSCXWarnFor==\"function\"&&MSCXWarnFor(" NP_C1 ".appid)?" \
    "(0," NP_C2 ".jsx)(\"div\",{ref:npW=>npW&&MSCXWarnRow(npW," NP_C1 ".appid)}):null)"

#define NP_CX_OPTIONS_CSS \
    "\".MSCXPanel{margin-top:10px}" \
    ".MSCXPanel .MSCXRow{display:flex;flex-direction:row;padding:9px;margin:0;" \
    "color:#dfe3e6;background:rgba(59,63,72,.5);border-radius:3px}" \
    ".MSCXPanel{text-wrap:balance}.MSCXHelp{display:block;font-size:13px;line-height:1.4;color:#acb2b8;letter-spacing:normal;text-transform:none;margin:2px 0 6px}" \
    ".MSCXPanel .MSCXRow:hover{box-shadow:0 6px 8px 0 rgba(0,0,0,.16)}" \
    ".MSCXPanel .MSCXDrop{display:flex;flex-direction:column;align-items:stretch;gap:6px;" \
    "padding:0;margin:10px 0;background:none}" \
    ".MSCXPanel .MSCXDrop>*{width:100%;max-width:none;margin:0}" \
    ".MSCXNoBottomGap{margin-bottom:0}" \
    ".MSCXPanel .MSCXDim{opacity:.45;pointer-events:none}" \
    ".MSCXPanel .MSCXAdv{margin:10px 0}" \
    ".MSCXPanel .MSCXAdv>summary{cursor:pointer;padding:6px 0;color:#dfe3e6;font-size:14px;user-select:none}" \
    ".MSCXPanel .MSCXAdv>summary:focus-visible{outline:2px solid #fff;outline-offset:1px}" \
    ".MSCXPanel .MSCXAdv>.MSCXRow{margin-top:6px}" \
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
    "@keyframes MSCXSlide{from{left:-30%}to{left:100%}}" \
    /* The info tip beside a label: shown while data-open is set (y: hover or keyboard focus, \
       p: clicked); Escape, a second click or a press elsewhere hides it. \
       Fixed, so a label that clips its overflow does not cut it off; I() places it. */ \
    ".MSCXLbl{display:inline-flex;align-items:center;gap:6px}" \
    ".MSCXTipW{display:inline-flex;align-items:center}" \
    ".MSCXTipB{background:none;border:none;margin:0;padding:0 2px;color:#8b929a;font-size:14px;" \
    "line-height:1;cursor:pointer;border-radius:50%;text-transform:none}" \
    ".MSCXTipB:hover,.MSCXTipW[data-open] .MSCXTipB{color:#dfe3e6}" \
    ".MSCXTipB:focus-visible{outline:2px solid #fff;outline-offset:1px}" \
    ".MSCXTipText{display:none;position:fixed;z-index:1000;width:max-content;max-width:280px;" \
    "padding:8px 10px;background:#3d4450;color:#dfe3e6;font-size:13px;font-weight:normal;line-height:1.4;" \
    "letter-spacing:normal;text-transform:none;text-align:left;white-space:normal;text-wrap:pretty;" \
    "border-radius:3px;box-shadow:0 6px 12px rgba(0,0,0,.4);pointer-events:none}" \
    /* Steam's checkbox label styles every span in it (display:flex), so these win outright */ \
    ".MSCXTipW>.MSCXTipText{display:none!important}.MSCXTipW[data-open]>.MSCXTipText{display:block!important}" \
    /* Reduce Motion: the bar stays still and fades instead of sliding. The row's delay is \
       taken modulo 2.4s, the fade's full cycle, so redraws don't jump. */ \
    "@media (prefers-reduced-motion:reduce){.MSCXPanel .MSCXRow:hover{box-shadow:none}" \
    ".MSCXBar>div{left:0;width:100%;animation:MSCXFade 1.2s ease-in-out infinite alternate}}" \
    "@keyframes MSCXFade{from{opacity:.35}to{opacity:1}}\""

// Labels both panels (native and Wine) show, as npL(en, zh, it, ru) calls.
#define NP_L_OFF "npL(\"Off\",\"关闭\",\"Disattivato\",\"Выкл.\")"
#define NP_L_AUTO "npL(\"Automatic\",\"自动\",\"Automatico\",\"Автоматически\")"
#define NP_L_PO_TITLE "npL(\"Performance Overlay\"," \
    "\"性能叠加层\"," \
    "\"Overlay prestazioni\",\"Оверлей производительности\")"
#define NP_L_PO_OPTIONS "[{data:\"0\",label:" NP_L_OFF "},{data:\"fps\",label:\"FPS\"}," \
    "{data:\"summary\",label:npL(\"Summary\",\"摘要\",\"Riepilogo\",\"Сводка\")}," \
    "{data:\"detailed\",label:npL(\"Detailed\",\"详细\",\"Dettagliato\",\"Подробно\")}," \
    "{data:\"hud\",label:npL(\"Metal HUD\",\"Metal 性能监视器\",\"Metal HUD\",\"Metal HUD\")}]"
#define NP_L_FL_TITLE "npL(\"FPS Limit\"," \
    "\"帧率限制\",\"Limite FPS\",\"Ограничение FPS\")"
#define NP_L_FL_SWITCH "npL(\"Enable\",\"启用\",\"Attiva\",\"Включить\")"
#define NP_L_FL_COOL "npL(\"Lower FPS when the Mac runs hot\",\"Mac 过热时降低帧率\",\"Riduci gli FPS se il Mac si scalda\",\"Снижать FPS при перегреве Mac\")"
#define NP_L_SQ_TITLE "npL(\"Scaling Filter\"," \
    "\"缩放滤镜\"," \
    "\"Filtro di scala\",\"Фильтр масштабирования\")"
#define NP_L_SQ_REST \
    "{data:\"linear\",label:npL(\"Linear (smooth)\",\"线性（平滑）\",\"Lineare (morbido)\",\"Линейный (плавный)\")}," \
    "{data:\"nearest\",label:npL(\"Nearest (sharp pixels at any scale)\",\"最近邻（任何比例都保持锐利像素）\"," \
    "\"Nearest (pixel nitidi a qualsiasi scala)\",\"Ближайший (чёткие пиксели при любом масштабе)\")}," \
    "{data:\"integer\",label:npL(\"Integer (sharp at exact 2x or 3x, smooth otherwise)\"," \
    "\"整数（正好 2 倍或 3 倍时锐利，其他比例平滑）\",\"Intero (nitido a 2x o 3x esatti, morbido altrimenti)\",\"Целочисленный (чёткий ровно при 2x или 3x, иначе плавный)\")}"
#define NP_L_CONTROLLERS "npL(\"Controllers\",\"控制器\",\"Controller\",\"Контроллеры\")"

// Info tips beside the labels, as npL(en, zh, it, ru): what each setting does, from the code
// that acts on it (overlay-shim, compat_run.sh, native-shim).
#define NP_TIP_PO "npL(\"Shows live stats in the game's top-left corner. FPS is the frame rate alone, Summary adds frame time, CPU, GPU, memory and battery, Detailed adds a frame-time graph, and Metal HUD is Apple's own overlay.\",\"在游戏左上角显示实时数据。FPS 只显示帧率，摘要还会显示帧时间、CPU、GPU、内存和电池，详细会再加上帧时间图，Metal 性能监视器是 Apple 自带的叠加层。\",\"Mostra dati in tempo reale nell'angolo in alto a sinistra del gioco. FPS mostra solo i fotogrammi al secondo, Riepilogo aggiunge tempo per fotogramma, CPU, GPU, memoria e batteria, Dettagliato aggiunge un grafico dei tempi e Metal HUD è l'overlay di Apple.\",\"Показывает данные в реальном времени в левом верхнем углу игры. FPS показывает только частоту кадров, «Сводка» добавляет время кадра, CPU, GPU, память и батарею, «Подробно» добавляет график времени кадра, а Metal HUD это собственный оверлей Apple.\")"
#define NP_TIP_FL "npL(\"Caps the game at this many frames per second, from 15 up to your display's refresh rate, and syncs frames to the display. OpenGL games ignore it.\",\"把游戏限制在这个帧率，范围从 15 到显示器的刷新率，并让画面与显示器同步。OpenGL 游戏不受影响。\",\"Limita il gioco a questi fotogrammi al secondo, da 15 fino alla frequenza dello schermo, e sincronizza i fotogrammi con lo schermo. Non ha effetto sui giochi OpenGL.\",\"Ограничивает игру этим числом кадров в секунду, от 15 до частоты обновления дисплея, и синхронизирует кадры с дисплеем. На игры с OpenGL не действует.\")"
#define NP_TIP_FL_SWITCH "npL(\"Turns the cap on or off. Off keeps the slider's value, so turning it back on brings back the same cap.\",\"打开或关闭帧率限制。关闭后滑块的数值会保留，再次打开时恢复同样的限制。\",\"Attiva o disattiva il limite. Da disattivato il valore del cursore resta, così riattivandolo torna lo stesso limite.\",\"Включает или выключает ограничение. Значение ползунка при выключении сохраняется, и после включения вернётся то же ограничение.\")"
#define NP_TIP_FL_COOL "npL(\"When macOS reports the Mac as seriously hot, the cap drops to about 3/4 of your limit (of the display's refresh rate with no limit), and to about 1/2 when critically hot, never below 30 FPS. It goes back up once the Mac has been cooler for 30 seconds.\",\"当 macOS 报告 Mac 温度严重偏高时，帧率上限降到你所设限制的约 3/4（未设限制时按显示器刷新率计算），温度达到危险时降到约 1/2，但不低于 30 FPS。Mac 降温持续 30 秒后恢复原来的限制。\",\"Quando macOS segnala il Mac molto caldo, il limite scende a circa 3/4 del tuo (della frequenza dello schermo se non c'è limite) e a circa 1/2 quando è critico, mai sotto 30 FPS. Torna su dopo che il Mac è rimasto più fresco per 30 secondi.\",\"Когда macOS сообщает о сильном нагреве Mac, предел снижается примерно до 3/4 вашего ограничения (или частоты дисплея, если ограничения нет), а при критическом нагреве примерно до 1/2, но не ниже 30 FPS. Прежний предел возвращается, когда Mac 30 секунд остаётся прохладнее.\")"
#define NP_TIP_SQ_WINE "npL(\"When the game draws fewer pixels than your screen has, this picks how the picture is stretched to fill it. Automatic keeps the pixels sharp and square while High Resolution is off.\",\"游戏画面的像素少于屏幕时，这里决定如何拉伸画面铺满屏幕。自动：关闭高分辨率时保持像素锐利方正。\",\"Quando il gioco disegna meno pixel di quanti ne ha lo schermo, sceglie come allargare l'immagine. Automatico mantiene i pixel nitidi e quadrati con Alta risoluzione disattivata.\",\"Когда игра рисует меньше пикселей, чем у экрана, здесь выбирается, как растянуть картинку. «Авто» сохраняет пиксели чёткими и квадратными, пока высокое разрешение выключено.\")"
#define NP_TIP_SQ_NAT "npL(\"When the game draws fewer pixels than your screen has, this picks how the picture is stretched to fill it. Automatic keeps what the game sets, which is smooth by default.\",\"游戏画面的像素少于屏幕时，这里决定如何拉伸画面铺满屏幕。自动：沿用游戏的设置，默认是平滑。\",\"Quando il gioco disegna meno pixel di quanti ne ha lo schermo, sceglie come allargare l'immagine. Automatico lascia l'impostazione del gioco, morbida in modo predefinito.\",\"Когда игра рисует меньше пикселей, чем у экрана, здесь выбирается, как растянуть картинку. «Автоматически» оставляет настройку игры, по умолчанию плавную.\")"
#define NP_TIP_FG "npL(\"Adds made-up frames between the game's real frames so motion looks smoother. Each real frame waits up to half a frame longer, so controls respond a little later.\",\"在游戏的真实帧之间插入生成的帧，让画面更流畅。每个真实帧最多会晚半帧显示，所以操作响应会稍慢。\",\"Aggiunge fotogrammi generati tra quelli reali del gioco per un movimento più fluido. Ogni fotogramma reale arriva fino a mezzo fotogramma dopo, quindi i comandi rispondono un po' più tardi.\",\"Добавляет сгенерированные кадры между настоящими, чтобы движение было плавнее. Каждый настоящий кадр показывается позже, до половины кадра, поэтому управление откликается чуть медленнее.\")"
#define NP_TIP_FG_MODE "npL(\"2x adds one frame between each pair of real frames and 3x adds two. Adaptive adds as many as fit before the next real frame, up to three, to fill the display's refresh rate.\",\"2x 在每两帧真实画面之间插入一帧，3x 插入两帧。自适应会在下一真实帧之前尽量多插，最多三帧，以补足显示器刷新率。\",\"2x aggiunge un fotogramma tra ogni coppia di fotogrammi reali e 3x ne aggiunge due. Adattiva ne aggiunge quanti ne entrano prima del prossimo reale, fino a tre, per arrivare alla frequenza dello schermo.\",\"2x добавляет один кадр между каждой парой настоящих, 3x добавляет два. «Адаптивный» добавляет столько, сколько помещается до следующего настоящего кадра, до трёх, чтобы добрать до частоты дисплея.\")"
#define NP_TIP_FG_QUALITY "npL(\"How finely motion is measured between frames. Performance is lightest on the graphics chip, and Quality is the most accurate and the heaviest.\",\"决定帧间运动测量的精细程度。性能对显卡负担最小，画质最准确但负担最大。\",\"Quanto finemente si misura il movimento tra i fotogrammi. Prestazioni pesa meno sulla grafica, Qualità è la più precisa e la più pesante.\",\"Насколько точно измеряется движение между кадрами. «Производительность» меньше всего нагружает графику, «Качество» точнее всего, но нагружает сильнее всего.\")"
#define NP_TIP_FG_UI "npL(\"Parts that are the same in both real frames, like a HUD or menu, are copied as they are and never warped. Where the motion guess is unsure, the nearest real frame is used.\",\"两帧真实画面中相同的部分（如 HUD 或菜单）会原样保留，不做变形。运动估计不确定的地方使用最近的真实帧。\",\"Le parti uguali nei due fotogrammi reali, come HUD o menu, vengono copiate così come sono, senza deformarle. Dove la stima del movimento è incerta si usa il fotogramma reale più vicino.\",\"Части, одинаковые в обоих настоящих кадрах, например HUD или меню, копируются как есть, без искажений. Там, где оценка движения неуверенная, берётся ближайший настоящий кадр.\")"
#define NP_TIP_FG_FALLBACK "npL(\"When motion is too fast to follow, the nearest real frame is shown in place of each made-up one, so fast scenes don't smear.\",\"运动太快无法跟踪时，用最近的真实帧代替生成的帧，避免快速场景出现拖影。\",\"Quando il movimento è troppo veloce da seguire, al posto di ogni fotogramma generato si mostra quello reale più vicino, così le scene rapide non si impastano.\",\"Когда движение слишком быстрое, вместо каждого сгенерированного кадра показывается ближайший настоящий, и быстрые сцены не смазываются.\")"
#define NP_TIP_FG_ENGINE "npL(\"Built-in optical flow is Bridgeplay's own method and follows the Mode. MetalFX uses Apple's frame interpolation on macOS 26 or later and adds one frame per real frame whatever the Mode.\",\"内置光流是 Bridgeplay 自己的方法，按模式插帧。MetalFX 使用 Apple 的插帧功能（需要 macOS 26 或更高版本），无论模式如何，每个真实帧只插一帧。\",\"Flusso ottico integrato è il metodo di Bridgeplay e segue la Modalità. MetalFX usa l'interpolazione di Apple su macOS 26 o successivo e aggiunge un fotogramma per ogni reale, qualunque sia la Modalità.\",\"Встроенный оптический поток это собственный метод Bridgeplay, он следует режиму. MetalFX использует интерполяцию кадров Apple на macOS 26 и новее и добавляет один кадр на каждый настоящий при любом режиме.\")"
#define NP_TIP_GFX "npL(\"How the game's Windows graphics (DirectX) are turned into Metal for your Mac. Automatic uses what Bridgeplay set for this game; try another one if the game crashes or draws wrong.\",\"决定如何把游戏的 Windows 图形（DirectX）转换为 Mac 的 Metal。自动会使用 Bridgeplay 为这款游戏设定的方式；游戏崩溃或画面错误时可以换一个试试。\",\"Come la grafica Windows del gioco (DirectX) viene tradotta in Metal per il Mac. Automatico usa quanto impostato da Bridgeplay per questo gioco; provane un altro se il gioco va in crash o si vede male.\",\"Как графика Windows (DirectX) игры переводится в Metal для Mac. «Автоматически» использует вариант, заданный Bridgeplay для этой игры; попробуйте другой, если игра вылетает или рисует неправильно.\")"
#define NP_TIP_DLSS "npL(\"Lets games that offer NVIDIA DLSS turn it on, with Apple's MetalFX doing the upscaling.\",\"让支持 NVIDIA DLSS 的游戏可以开启它，由 Apple 的 MetalFX 完成放大。\",\"Permette ai giochi con NVIDIA DLSS di attivarlo, con l'upscaling fatto da MetalFX di Apple.\",\"Позволяет играм с NVIDIA DLSS включить его, а масштабирование выполняет MetalFX от Apple.\")"
#define NP_TIP_NVAPI "npL(\"Tells the game it runs on an NVIDIA GeForce RTX 4090, since games offer DLSS only on NVIDIA cards. Some games then take NVIDIA-only paths and crash.\",\"告诉游戏它运行在 NVIDIA GeForce RTX 4090 上，因为游戏只在 NVIDIA 显卡上提供 DLSS。有些游戏因此走 NVIDIA 专用路径而崩溃。\",\"Fa credere al gioco di girare su una NVIDIA GeForce RTX 4090, perché i giochi offrono DLSS solo su schede NVIDIA. Alcuni giochi così usano percorsi solo NVIDIA e vanno in crash.\",\"Сообщает игре, что она работает на NVIDIA GeForce RTX 4090, ведь игры предлагают DLSS только на картах NVIDIA. Некоторые игры из-за этого идут по путям только для NVIDIA и вылетают.\")"
#define NP_TIP_RETINA "npL(\"On, the game draws at your screen's full Retina resolution. Off, it draws at half the width and height and is scaled up, which runs faster and looks softer.\",\"开启时，游戏以屏幕完整的 Retina 分辨率绘制。关闭时以一半的宽度和高度绘制再放大，运行更快但画面更柔和。\",\"Attiva, il gioco disegna alla piena risoluzione Retina dello schermo. Disattiva, disegna a metà larghezza e altezza e viene ingrandito, più veloce e più morbido.\",\"Включено: игра рисует в полном Retina-разрешении экрана. Выключено: рисует в половину ширины и высоты и растягивается, это быстрее, но мягче.\")"
#define NP_TIP_AVX "npL(\"Tells the game your processor has AVX and AVX2, which Rosetta translates for Apple chips. Some games need this to start; it is on by default.\",\"告诉游戏处理器支持 AVX 和 AVX2，由 Rosetta 为 Apple 芯片转译。有些游戏需要它才能启动，默认开启。\",\"Dice al gioco che il processore ha AVX e AVX2, tradotte da Rosetta per i chip Apple. Alcuni giochi ne hanno bisogno per avviarsi; è attivo in modo predefinito.\",\"Сообщает игре, что процессор поддерживает AVX и AVX2, которые Rosetta переводит для чипов Apple. Некоторым играм это нужно для запуска; включено по умолчанию.\")"
#define NP_TIP_MSYNC "npL(\"A faster way for the game's threads to wait for each other. It is on by default where supported.\",\"让游戏的各个线程更快地互相等待的方式。在支持时默认开启。\",\"Un modo più rapido con cui i thread del gioco si aspettano a vicenda. È attivo in modo predefinito dove è supportato.\",\"Более быстрый способ, которым потоки игры ждут друг друга. Включено по умолчанию там, где поддерживается.\")"
#define NP_TIP_METALFX "npL(\"The game draws at a lower resolution and Apple's MetalFX scales it up to the window by this factor. A higher factor runs faster and looks softer.\",\"游戏以较低分辨率绘制，再由 Apple 的 MetalFX 按此倍数放大到窗口大小。倍数越高运行越快，画面越柔和。\",\"Il gioco disegna a una risoluzione più bassa e MetalFX di Apple la ingrandisce alla finestra di questo fattore. Un fattore più alto è più veloce e più morbido.\",\"Игра рисует в меньшем разрешении, а MetalFX от Apple увеличивает картинку до окна в это число раз. Чем больше множитель, тем быстрее и мягче.\")"
#define NP_TIP_RAW "npL(\"On, the game reads your controllers itself. Off, controllers that Steam Input is using are hidden from the game.\",\"开启时，游戏直接读取手柄。关闭时，Steam 输入正在使用的手柄对游戏隐藏。\",\"Attivo, il gioco legge da sé i controller. Disattivo, i controller usati da Steam Input vengono nascosti al gioco.\",\"Включено: игра сама читает контроллеры. Выключено: контроллеры, которые использует Steam Input, скрыты от игры.\")"
#define NP_TIP_HIDRAW "npL(\"Stops the game from reading controllers as raw USB or Bluetooth devices, so they go through the usual controller support only. Try it if a controller acts wrong.\",\"不让游戏以原始 USB 或蓝牙设备方式读取手柄，只通过常规手柄支持。手柄表现异常时可以试试。\",\"Impedisce al gioco di leggere i controller come dispositivi USB o Bluetooth grezzi, così passano solo dal supporto controller normale. Provalo se un controller si comporta male.\",\"Не даёт игре читать контроллеры как «сырые» USB- или Bluetooth-устройства, они идут только через обычную поддержку контроллеров. Попробуйте, если контроллер ведёт себя неправильно.\")"
#define NP_TIP_X87 "npL(\"Runs old-style x87 math at lower precision, which is faster. On by default; turn it off if the game acts oddly.\",\"以较低精度运行旧式 x87 数学运算，速度更快。默认开启；游戏表现异常时请关闭。\",\"Esegue i calcoli x87 di vecchio tipo con precisione ridotta, più veloce. Attivo in modo predefinito; disattivalo se il gioco si comporta in modo strano.\",\"Выполняет старые вычисления x87 с меньшей точностью, это быстрее. Включено по умолчанию; отключите, если игра ведёт себя странно.\")"
#define NP_TIP_PAD "npL(\"Raw HID suits Unity, SDL and Unreal games, and GameController suits games that use Apple's controller framework. Automatic picks Raw HID for Unity games and both for the rest.\",\"Raw HID 适合 Unity、SDL 和 Unreal 游戏，GameController 适合使用 Apple 手柄框架的游戏。自动：Unity 游戏用 Raw HID，其他游戏两者都用。\",\"Raw HID va bene per i giochi Unity, SDL e Unreal, GameController per i giochi che usano il framework controller di Apple. Automatico sceglie Raw HID per i giochi Unity ed entrambi per gli altri.\",\"Raw HID подходит для игр на Unity, SDL и Unreal, GameController для игр, использующих фреймворк контроллеров Apple. «Автоматически» выбирает Raw HID для игр на Unity и оба варианта для остальных.\")"

// FEX runs arm64 Wine, which has no D3DMetal and never runs under Rosetta.
#define NP_CX_OPTIONS_BODY(ARG, RT, BARREL, SLIDER) \
    ARG "=>{" \
    "const t=" ARG ".details,o=t.strLaunchOptions||\"\"," \
    /* MSCXApply hands in its own writer, to run several changes into one write. */ \
    "W=" ARG ".write||((a,b)=>SteamClient.Apps.SetAppLaunchOptions(a,b))," \
    "fex=" NP_FEX_TOOLS ".indexOf(t.strCompatToolName||\"" NP_FALLBACK_TOOL "\")>=0," \
    "npZh=" NP_WEB_IS_ZH ",npIt=" NP_WEB_IS_IT ",npRu=" NP_WEB_IS_RU "," \
    "npL=(en,zh,it,ru)=>npZh?zh:npIt&&it?it:npRu&&ru?ru:en," \
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
    "W(t.unAppID,r.trim()===\"%command%\"?\"\":r)}," \
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
    "W(t.unAppID," \
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
    "H=text=>(0," RT ".jsx)(\"div\",{className:\"MSCXHelp\",children:text})," \
    /* I(label, tip): the label with an info button whose tip text it is described by. The tip \
       sits under the button, inside the window, above it when there is no room below; the \
       second pass corrects for a transformed ancestor, which moves where fixed lands. */ \
    "tc={n:0},tw=e=>e.currentTarget.parentNode," \
    /* One tip open per document: showing one (y on hover or keyboard focus, p when clicked) \
       hides the last, and a press anywhere outside it hides it. */ \
    "th=d=>{const o=d.__mscxTip;o&&o.removeAttribute(\"data-open\");d.__mscxTip=null}," \
    "ts=(w,p)=>{const d=w.ownerDocument;d.__mscxTip&&d.__mscxTip!==w&&th(d);" \
    "w.setAttribute(\"data-open\",p?\"p\":\"y\");d.__mscxTip=w;tp(w);" \
    "d.__mscxTipL||!d.addEventListener||(d.__mscxTipL=1,d.addEventListener(\"pointerdown\",e=>{" \
    "const o=d.__mscxTip;o&&o.contains&&!o.contains(e.target)&&th(d)},!0)," \
    "d.addEventListener(\"keydown\",e=>{const o=d.__mscxTip;if(e.key!==\"Escape\"||!o)return;" \
    "if(o.isConnected===!1){d.__mscxTip=null;return}e.preventDefault();e.stopPropagation();th(d)},!0))}," \
    "tp=w=>{try{const b=w.firstChild,x=w.lastChild,v=w.ownerDocument.defaultView,r=b.getBoundingClientRect()," \
    "W=v.innerWidth,Hh=v.innerHeight,L=Math.max(8,Math.min(r.left,W-x.offsetWidth-8));" \
    "let T=r.bottom+6;T+x.offsetHeight>Hh-8&&(T=Math.max(8,r.top-6-x.offsetHeight));" \
    "x.style.left=L+\"px\";x.style.top=T+\"px\";const q=x.getBoundingClientRect();" \
    "x.style.left=2*L-q.left+\"px\";x.style.top=2*T-q.top+\"px\"}catch(e){}}," \
    "I=(l,x)=>{const id=\"MSCXTip\"+t.unAppID+\"-\"+(++tc.n);" \
    "return(0," RT ".jsxs)(\"span\",{className:\"MSCXLbl\",children:[l,(0," RT ".jsxs)(\"span\",{className:\"MSCXTipW\"," \
    "onMouseEnter:e=>{const w=e.currentTarget;w.getAttribute(\"data-open\")!==\"p\"&&ts(w,0)}," \
    "onMouseLeave:e=>{const w=e.currentTarget;w.getAttribute(\"data-open\")===\"y\"&&th(w.ownerDocument)},children:[" \
    "(0," RT ".jsx)(\"button\",{type:\"button\",className:\"MSCXTipB\"," \
    "\"aria-label\":npL(\"About \",\"关于\",\"Informazioni su \",\"Подробнее: \")+l,\"aria-describedby\":id," \
    "onClick:e=>{e.preventDefault();e.stopPropagation();const w=tw(e);" \
    "w.getAttribute(\"data-open\")===\"p\"?th(w.ownerDocument):ts(w,1)}," \
    "onKeyDown:e=>{const w=tw(e);if(e.key!==\"Escape\"||!w.getAttribute(\"data-open\"))return;" \
    "e.preventDefault();e.stopPropagation();th(w.ownerDocument)}," \
    "onFocus:e=>{const w=tw(e);try{e.currentTarget.matches(\":focus-visible\")&&ts(w,0)}catch(x){}}," \
    "onBlur:e=>{const w=tw(e);w.getAttribute(\"data-open\")&&th(w.ownerDocument)},children:\"\\u24d8\"})," \
    "(0," RT ".jsx)(\"span\",{id,role:\"tooltip\",className:\"MSCXTipText\",children:x})]})]})}," \
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
    "FG=()=>(0," RT ".jsxs)(" BARREL ".XY,{label:I(npL(\"Frame Generation\"," \
    "\"帧生成\",\"Generazione fotogrammi\",\"Генерация кадров\")," NP_TIP_FG "),children:[" \
    "H(npL(\"Experimental. Adds input lag.\",\"实验功能，会增加输入延迟。\",\"Sperimentale. Aumenta la latenza dei comandi.\",\"Экспериментальная функция. Повышает задержку ввода.\")),D(\"BRIDGEPLAY_FRAMEGEN\",I(npL(\"Mode\",\"模式\",\"Modalit\\u00e0\",\"Режим\")," NP_TIP_FG_MODE "),[{data:\"0\",label:" NP_L_OFF "},{data:\"2\",label:\"2x\"}," \
    "{data:\"3\",label:\"3x\"},{data:\"adaptive\",label:npL(\"Adaptive (fills to display refresh)\"," \
    "\"自适应（补足到显示器刷新率）\",\"Adattiva (arriva alla frequenza dello schermo)\",\"Адаптивный (добирает до частоты обновления дисплея)\")}],fz)," \
    "fo&&D(\"BRIDGEPLAY_FRAMEGEN_QUALITY\",I(npL(\"Quality\",\"画质\",\"Qualit\\u00e0\",\"Качество\")," NP_TIP_FG_QUALITY ")," \
    "[{data:\"performance\",label:npL(\"Performance\",\"性能\",\"Prestazioni\",\"Производительность\")}," \
    "{data:\"balanced\",label:npL(\"Balanced\",\"均衡\",\"Bilanciato\",\"Сбалансированно\")}," \
    "{data:\"quality\",label:npL(\"Quality\",\"画质\",\"Qualit\\u00e0\",\"Качество\")}],lc(\"balanced\"))," \
    "fo&&T([\"BRIDGEPLAY_FRAMEGEN_UI\"],I(npL(\"Keep HUD and menus sharp\"," \
    "\"保持 HUD 和菜单清晰\",\"Mantieni nitidi HUD e menu\",\"Сохранять чёткость HUD и меню\")," NP_TIP_FG_UI "),\"1\",\"0\")," \
    "fo&&T([\"BRIDGEPLAY_FRAMEGEN_FALLBACK\"],I(npL(\"Skip blurry frames in fast motion\"," \
    "\"快速运动时跳过模糊帧\",\"Salta i fotogrammi sfocati nei movimenti rapidi\",\"Пропускать смазанные кадры при быстром движении\")," NP_TIP_FG_FALLBACK "),\"1\",\"0\")," \
    "fo&&D(\"BRIDGEPLAY_FRAMEGEN_ENGINE\",I(npL(\"Engine\",\"引擎\",\"Motore\",\"Движок\")," NP_TIP_FG_ENGINE ")," \
    "[{data:\"own\",label:npL(\"Built-in optical flow\",\"内置光流\",\"Flusso ottico integrato\",\"Встроенный оптический поток\")}," \
    "{data:\"metalfx\",label:\"MetalFX\"}],lc(\"own\"))]},\"fgn\")," \
    /* The performance overlay and Apple's Metal HUD are one choice, so only one of them \
       is ever on screen. The Metal HUD wins in overlay-shim when both come from the confs. */ \
    "pf=x=>{x=(x||\"\").toLowerCase();return x===\"1\"?\"fps\":/^(fps|summary|detailed)$/.test(x)?x:\"0\"}," \
    "PO=(l,O)=>(0," RT ".jsxs)(" BARREL ".XY,{label:l,children:[(0," RT ".jsx)(" BARREL ".m,{rgOptions:O," \
    "selectedOption:\"1\"===ev(\"MTL_HUD_ENABLED\")?\"hud\":pf(ev(\"BRIDGEPLAY_PERF_OVERLAY\"))," \
    "onChange:v=>{const h=\"hud\"===v.data,p=h?\"0\":v.data;" \
    "s([[\"BRIDGEPLAY_PERF_OVERLAY\",pf(dv(\"BRIDGEPLAY_PERF_OVERLAY\"))===p?\"\":p]," \
    "[\"MTL_HUD_ENABLED\",(\"1\"===dv(\"MTL_HUD_ENABLED\"))===h?\"\":h?\"1\":\"0\"]])}})]},\"pov\")," \
    /* The frame rate limit: a slider in whole frames per second from 15 to the fastest \
       display's refresh rate (Fx.fm), and Enable frame limit, which applies it; unchecked, the \
       slider dims and keeps its value (BRIDGEPLAY_FPS_LIMIT_OFF=1). overlay-shim clamps to the display the game \
       is on, so a value from the game, which knows that display, is kept up to 360 even when \
       Fx.fm, read when Steam loaded this page, is lower. display and half from earlier releases show as the rate they give, 0 or no value \
       as no limit. Without Steam's slider, a menu in steps of 5 stands in. npKey and npSet are for \
       MSCXApply, which sets the value even while the switch dims the slider. Switching off a \
       limit at the slider's top, with no default limit under it, drops both keys: switching \
       on again gives the same value. ex is one more row \
       under the switch (Cool and steady, BRIDGEPLAY_SUSTAINED, for Wine games). */ \
    "fm=+Fx.fm>=15&&+Fx.fm<=360?+Fx.fm:60," \
    "lf=x=>{x=(x||\"\").toLowerCase();return x===\"display\"?fm:x===\"half\"?Math.max(15,Math.round(fm/2)):" \
    "/^\\d+$/.test(x)&&+x>=10&&+x<=360?Math.min(fm,Math.max(15,+x)):0}," \
    "SL=" SLIDER "," \
    "FL=(l,dl,ex)=>{const n=lf(ev(\"BRIDGEPLAY_FPS_LIMIT\")),off=!n||ev(\"BRIDGEPLAY_FPS_LIMIT_OFF\")===\"1\",v=n||fm," \
    "set=(x,top)=>{x=Math.min(top||fm,Math.max(15,Math.round(+x)));if(!(x>=15))return;const b=dv(\"BRIDGEPLAY_FPS_LIMIT\");" \
    "s([[\"BRIDGEPLAY_FPS_LIMIT\",/^\\d+$/.test(b)&&+b===x?\"\":String(x)]])}," \
    "tog=on=>{const d=!on,b=dv(\"BRIDGEPLAY_FPS_LIMIT_OFF\")===\"1\"," \
    "cl=d&&+g(\"BRIDGEPLAY_FPS_LIMIT\")===fm&&!lf(dv(\"BRIDGEPLAY_FPS_LIMIT\"))," \
    "ps=[[\"BRIDGEPLAY_FPS_LIMIT_OFF\",d?(b||cl?\"\":\"1\"):(b?\"0\":\"\")]];" \
    "cl&&ps.push([\"BRIDGEPLAY_FPS_LIMIT\",\"\"]);d||n||ps.push([\"BRIDGEPLAY_FPS_LIMIT\",String(v)]);s(ps)}," \
    "R=[];for(let x=15;x<fm;x+=5)R.push(x);R.push(fm);R.indexOf(v)<0&&R.push(v);" \
    "return(0," RT ".jsxs)(" BARREL ".XY,{label:l,children:[(0," RT ".jsx)(\"div\",{className:off?\"MSCXDim\":\"\",children:" \
    "SL?(0," RT ".jsx)(SL,{min:15,max:fm,value:v,showValue:!0,valueSuffix:\" FPS\",disabled:off," \
    "npKey:\"BRIDGEPLAY_FPS_LIMIT\",npSet:x=>set(x,360),onChange:x=>{off||set(x)}}):" \
    "(0," RT ".jsx)(" BARREL ".m,{rgOptions:R.sort((a,b)=>a-b).map(x=>({data:x,label:x+\" FPS\"})),selectedOption:v," \
    "disabled:off,npKey:\"BRIDGEPLAY_FPS_LIMIT\",npSet:x=>set(x,360),onChange:o=>{off||set(o.data)}})})," \
    "(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:dl,checked:!off,npKey:\"BRIDGEPLAY_FPS_LIMIT_OFF\"," \
    "onChange:tog}),ex]},\"fpl\")}," \
    /* The filter Core Animation scales the game's frames to the screen with. 0 leaves it as \
       Wine (nearest with High Resolution off) or a native game (linear) sets it. */ \
    "sq=x=>{x=(x||\"\").toLowerCase();return/^(linear|nearest|integer)$/.test(x)?x:\"0\"}," \
    "SQ=(l,O)=>(0," RT ".jsxs)(" BARREL ".XY,{label:l,children:[H(npL(\"Applies below display resolution.\",\"游戏分辨率低于屏幕分辨率时生效。\",\"Si applica sotto la risoluzione dello schermo.\",\"Для игр с разрешением ниже экранного.\")),(0," RT ".jsx)(" BARREL ".m,{rgOptions:O," \
    "selectedOption:sq(ev(\"BRIDGEPLAY_SCALING_FILTER\"))," \
    "onChange:v=>s([[\"BRIDGEPLAY_SCALING_FILTER\",sq(dv(\"BRIDGEPLAY_SCALING_FILTER\"))===v.data?\"\":v.data]])})]},\"scf\")," \
    /* A toggle that is on unless set to "0" (upstream 1.2.0: AVX2, FEX x87 precision). */ \
    "X=(k,l)=>(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:l," \
    "checked:\"0\"!==ev(k),onChange:v=>s([[k,v?\"\":\"0\"]])},k)," \
    /* The run script takes a valid BRIDGEPLAY_BACKEND over CX_GRAPHICS_BACKEND, so the menu \
       shows that one, and a pick from the menu drops it. */ \
    "pb=g(\"BRIDGEPLAY_BACKEND\"),bv=/^(dxmt|dxvk|wined3d|d3dmetal)$/.test(pb)?pb:g(\"CX_GRAPHICS_BACKEND\")," \
    "b=fex&&\"d3dmetal\"===bv?\"\":bv," \
    "dm=!fex&&(\"\"===b||\"d3dmetal\"===b)," \
    "dx=\"\"===b||\"dxmt\"===b," \
    "sw=\"1\"===g(\"DXMT_METALFX_SPATIAL_SWAPCHAIN\")," \
    "F=\"d3d11.metalSpatialUpscaleFactor=\"," \
    "fe=g(\"DXMT_CONFIG\").split(\";\").filter(e=>e.trim())," \
    "fk=e=>/^[ \\t\\r]*d3d11\\.metalSpatialUpscaleFactor[ \\t\\r]*=/.test(e)," \
    "fx=v=>fe.filter(e=>!fk(e)).concat(v?[F+v]:[]).join(\";\")," \
    "fv=(fe.filter(fk).pop()||\"=2\").replace(/^[^=]*=/,\"\").replace(/\"/g,\"\").trim().split(/\\s/)[0]," \
    "fn=Math.max(isNaN(+fv)?2:+fv,1)," \
    "U=[{data:\"\",label:" NP_L_OFF "}," \
    "{data:\"1.5\",label:\"1.5x\"}," \
    "{data:\"1.72\",label:\"1.72x\"}," \
    "{data:\"2.0\",label:\"2x\"}," \
    "{data:\"3.0\",label:\"3x\"}]," \
    "B=[{data:\"\",label:" NP_L_AUTO "}," \
    "{data:\"d3dmetal\",label:\"D3DMetal\"}," \
    "{data:\"dxmt\",label:\"DXMT\"}," \
    "{data:\"dxvk\",label:\"DXVK\"}," \
    "{data:\"wined3d\",label:\"WineD3D\"}].filter(x=>!fex||x.data!==\"d3dmetal\")," \
    /* The settings Game Defaults in the app also sets: the ones this game sets for itself, \
       which Use Bridgeplay defaults drops (DXMT_CONFIG keeps entries other than the factor). */ \
    "OV=[\"CX_GRAPHICS_BACKEND\",\"MTL_HUD_ENABLED\",\"D3DM_ENABLE_METALFX\",\"DXMT_ENABLE_NVEXT\"," \
    "\"ROSETTA_ADVERTISE_AVX\",\"WINEMSYNC\",\"BRIDGEPLAY_RETINA\",\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"DXMT_CONFIG\"," \
    "\"BRIDGEPLAY_FRAMEGEN\",\"BRIDGEPLAY_FRAMEGEN_QUALITY\",\"BRIDGEPLAY_FRAMEGEN_UI\",\"BRIDGEPLAY_FRAMEGEN_FALLBACK\"," \
    "\"BRIDGEPLAY_FRAMEGEN_ENGINE\",\"BRIDGEPLAY_VSYNC\",\"BRIDGEPLAY_BACKEND\",\"BRIDGEPLAY_PERF_OVERLAY\",\"BRIDGEPLAY_FPS_LIMIT\",\"BRIDGEPLAY_FPS_LIMIT_OFF\",\"BRIDGEPLAY_SCALING_FILTER\",\"BRIDGEPLAY_NVAPI\",\"BRIDGEPLAY_SUSTAINED\"].filter(k=>\"DXMT_CONFIG\"===k?fe.some(fk):!!A(k));" \
    "const AO=globalThis.MSCXAdvOpen||(globalThis.MSCXAdvOpen={}),ga=(Fx.a||{})[t.unAppID]||{}," \
    "ao=t.unAppID in AO?AO[t.unAppID]:[!fex&&\"ROSETTA_ADVERTISE_AVX\",\"WINEMSYNC\",\"BRIDGEPLAY_RAW_CONTROLLERS\",\"BRIDGEPLAY_DISABLE_HIDRAW\"," \
    "fex&&\"FEX_X87REDUCEDPRECISION\",dx&&\"DXMT_METALFX_SPATIAL_SWAPCHAIN\"].some(k=>k&&(!!A(k)||k in ga))||dx&&fe.some(fk);" \
    "if(nat)return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "})," \
    "PO(I(" NP_L_PO_TITLE "," NP_TIP_PO ")," NP_L_PO_OPTIONS ")," \
    "FL(I(" NP_L_FL_TITLE "," NP_TIP_FL "),I(" NP_L_FL_SWITCH "," NP_TIP_FL_SWITCH "))," \
    "SQ(I(" NP_L_SQ_TITLE "," NP_TIP_SQ_NAT "),[" \
    "{data:\"0\",label:npL(\"Automatic (as the game sets it)\",\"自动（沿用游戏的设置）\",\"Automatico (come lo imposta il gioco)\",\"Автоматически (как задано в игре)\")}," \
    NP_L_SQ_REST "]),FG()," \
    "(0," RT ".jsx)(" BARREL ".XY,{label:" NP_L_CONTROLLERS ",children:" \
    "D(\"NP_PAD_MODE\",I(npL(\"Controller layer\",\"控制器层\",\"Livello controller\",\"Слой контроллера\")," NP_TIP_PAD "),[{data:\"\",label:" NP_L_AUTO "}," \
    "{data:\"hid\",label:npL(\"Raw HID (Unity, SDL, Unreal)\",\"Raw HID（Unity、SDL、Unreal）\",\"Raw HID (Unity, SDL, Unreal)\",\"Raw HID (Unity, SDL, Unreal)\")}," \
    "{data:\"gc\",label:\"GameController\"},{data:\"off\",label:" NP_L_OFF "}],lc(\"\"))},\"ctl\")" \
    "]})});" \
    "return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "})," \
    "typeof MSCXVerdictFor==\"function\"&&MSCXVerdictFor(t.unAppID)&&(0," RT ".jsx)(\"div\",{className:\"MSCXRow\"," \
    "ref:e=>e&&MSCXVerdictRow(e,t.unAppID)},\"npverdict\")," \
    "typeof MSCXPrefixRow==\"function\"&&(0," RT ".jsx)(\"div\",{className:\"MSCXRow\",ref:e=>e&&MSCXPrefixRow(e,t.unAppID)},\"npstate\")," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:I(npL(\"Graphics\",\"图形\",\"Grafica\",\"Графика\")," NP_TIP_GFX "),children:[" \
    "(0," RT ".jsx)(" BARREL ".m,{rgOptions:B,selectedOption:b," \
    "onChange:v=>s([[\"CX_GRAPHICS_BACKEND\",v.data],[\"BRIDGEPLAY_BACKEND\",\"\"]]" \
    ".concat(\"\"===v.data||\"d3dmetal\"===v.data?[]:[[\"D3DM_ENABLE_METALFX\",\"\"],[\"BRIDGEPLAY_NVAPI\",\"\"]])" \
    ".concat(\"\"===v.data||\"dxmt\"===v.data?[]:" \
    "[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"\"],[\"DXMT_CONFIG\",fx(\"\")]])" \
    ".concat(\"dxmt\"===v.data?[]:[[\"DXMT_ENABLE_NVEXT\",\"\"]]))})," \
    "dm&&T([\"D3DM_ENABLE_METALFX\"],I(\"DLSS\"," NP_TIP_DLSS "),\"1\")," \
    /* NVAPI=1 is a shipped default; off writes BRIDGEPLAY_NVAPI=0, which wins over every conf. */ \
    "dm&&T([\"BRIDGEPLAY_NVAPI\"],I(npL(\"NVIDIA GPU for DLSS\",\"为 DLSS 报告 NVIDIA GPU\",\"GPU NVIDIA per DLSS\",\"GPU NVIDIA для DLSS\")," NP_TIP_NVAPI "),\"1\",\"0\")," \
    "dm&&H(npL(\"Turn off if the game crashes.\",\"游戏崩溃时请关闭。\",\"Disattiva se il gioco va in crash.\",\"Отключите при вылетах.\"))," \
    "\"dxmt\"===b&&T([\"DXMT_ENABLE_NVEXT\"],I(\"DLSS\"," NP_TIP_DLSS "),\"1\")," \
    "T([\"BRIDGEPLAY_RETINA\"],I(npL(\"High Resolution\",\"高分辨率\",\"Alta risoluzione\",\"Высокое разрешение\")," NP_TIP_RETINA "),\"1\",\"0\")" \
    "]},\"gfx\")," \
    "PO(I(" NP_L_PO_TITLE "," NP_TIP_PO ")," NP_L_PO_OPTIONS ")," \
    "FL(I(" NP_L_FL_TITLE "," NP_TIP_FL "),I(" NP_L_FL_SWITCH "," NP_TIP_FL_SWITCH ")," \
    "T([\"BRIDGEPLAY_SUSTAINED\"],I(" NP_L_FL_COOL "," NP_TIP_FL_COOL "),\"1\",\"0\"))," \
    "SQ(I(" NP_L_SQ_TITLE "," NP_TIP_SQ_WINE "),[" \
    "{data:\"0\",label:npL(\"Automatic (sharp with High Resolution off)\"," \
    "\"自动（关闭高分辨率时保持锐利）\",\"Automatico (nitido con Alta risoluzione disattivata)\",\"Авто (чётко при выключенном высоком разрешении)\")}," \
    NP_L_SQ_REST "])," \
    "FG()," \
    /* Expert settings, in a group that starts closed unless one of its settings is set, for \
       this game in its launch options or its own conf, or the player opened it this session. */ \
    "(0," RT ".jsxs)(\"details\",{className:\"MSCXAdv\",open:ao,onToggle:e=>{AO[t.unAppID]=!!e.target.open},children:[" \
    "(0," RT ".jsx)(\"summary\",{children:npL(\"Advanced\",\"高级\",\"Avanzate\",\"Дополнительно\")})," \
    "!fex&&X(\"ROSETTA_ADVERTISE_AVX\",I(\"AVX2\"," NP_TIP_AVX "))," \
    "T([\"WINEMSYNC\"],I(\"MSync\"," NP_TIP_MSYNC "),\"1\",\"0\")," \
    "dx&&(0," RT ".jsx)(" BARREL ".XY," \
    "{label:I(\"MetalFX\"," NP_TIP_METALFX ")," \
    "children:(0," RT ".jsx)(" BARREL ".m,{rgOptions:U," \
    "selectedOption:sw?(U.find(u=>u.data&&+u.data===fn)||{data:String(fn)}).data:\"\"," \
    "onChange:v=>s([[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",v.data?\"1\":\"\"],[\"DXMT_CONFIG\",fx(v.data)]])})},\"usf\")," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:" NP_L_CONTROLLERS ",children:[" \
    "T([\"BRIDGEPLAY_RAW_CONTROLLERS\"],I(npL(\"Direct input\",\"直接输入\",\"Input diretto\",\"Прямой ввод\")," NP_TIP_RAW "),\"1\",\"\")," \
    "H(npL(\"Turn off for Steam Input remaps.\",\"用 Steam 输入改键时关闭。\",\"Disattiva per rimappare con Steam Input.\",\"Отключите для переназначения в Steam Input.\"))," \
    "T([\"BRIDGEPLAY_DISABLE_HIDRAW\"],I(npL(\"Disable hidraw\",\"停用 hidraw\",\"Disattiva hidraw\",\"Отключить hidraw\")," NP_TIP_HIDRAW "),\"1\",\"\")" \
    "]},\"ctl\")," \
    "fex&&(0," RT ".jsx)(" BARREL ".XY,{label:\"FEX\"," \
    "children:X(\"FEX_X87REDUCEDPRECISION\"," \
    "I(npL(\"Reduced x87 precision\"," \
    "\"降低 x87 精度\"," \
    "\"Precisione x87 ridotta\",\"Пониженная точность x87\")," NP_TIP_X87 "))},\"fex\")" \
    "]},\"adv\")," \
    "OV.length>0&&(0," RT ".jsx)(\"div\",{className:\"MSCXBtns\",children:(0," RT ".jsx)(\"button\",{className:\"MSCXBtn\"," \
    "onClick:()=>s(OV.map(k=>[k,\"DXMT_CONFIG\"===k?fx(\"\"):\"\"]))," \
    "children:npL(\"Use Bridgeplay defaults\",\"使用 Bridgeplay 默认设置\",\"Usa le impostazioni predefinite di Bridgeplay\",\"Использовать настройки Bridgeplay по умолчанию\")})},\"npdef\")" \
    "]})})}"

// Find the slider by its original name in webpack's barrel despite export renames.
#define NP_WEBPACK_SLIDER \
    "globalThis.MSCXSliderField||(globalThis.MSCXSliderField=(()=>{try{return Object.values(npUI())" \
    ".find(f=>typeof f===\"function\"&&/\"SliderField\"/.test(String(f)))}catch(e){return null}})())"
#define NP_CX_OPTIONS_CAPTURE(RT, BARREL, SLIDER) \
    "((npReact,npUI)=>" NP_CX_OPTIONS_BODY("np", "npReact()", "npUI()", SLIDER) ")(()=>" RT ",()=>" BARREL ")"

// Changes from a game's in-game quick settings (overlay-shim/sidebar.m, collected by the
// NotProton.TakeQuickSettings route) go through the panel's own menus, so a pick in the game
// is written exactly as the same pick in Steam Properties › Bridgeplay would be: the same
// keys, the same native or Wine form, nothing written when it matches the game's confs.
#define NP_CX_APPLY \
    "(t,ch)=>{let o=t.strLaunchOptions||\"\";const o0=o," \
    /* The sidebar's values only, as the route allows: never the Metal HUD, never display or \
       half. A menu is found by an option only it has, the frame limit's slider and switch by \
       the npKey they carry (Enable frame limit is checked for BRIDGEPLAY_FPS_LIMIT_OFF=0). The \
       limit goes before its switch, so a value set while the limit is switched off is kept. */ \
    "K={BRIDGEPLAY_PERF_OVERLAY:\"hud\",BRIDGEPLAY_SCALING_FILTER:\"integer\"}," \
    "V={BRIDGEPLAY_PERF_OVERLAY:[\"0\",\"fps\",\"summary\",\"detailed\"],BRIDGEPLAY_FPS_LIMIT_OFF:[\"0\",\"1\"]," \
    "BRIDGEPLAY_SCALING_FILTER:[\"0\",\"linear\",\"nearest\",\"integer\"]}," \
    "ok=(k,x)=>k===\"BRIDGEPLAY_FPS_LIMIT\"?/^\\d+$/.test(x)&&+x>=15&&+x<=360:(V[k]||[]).indexOf(x)>=0," \
    "find=(n,f)=>{let r=null;const w=x=>{if(r||!x||typeof x!==\"object\")return;if(Array.isArray(x))return x.forEach(w);" \
    "const p=x.props;if(!p)return;if(f(p))r=p;else w(p.children)};w(n);return r};" \
    "[\"BRIDGEPLAY_PERF_OVERLAY\",\"BRIDGEPLAY_FPS_LIMIT\",\"BRIDGEPLAY_FPS_LIMIT_OFF\",\"BRIDGEPLAY_SCALING_FILTER\"]" \
    ".forEach(k=>{if(!ch||!(k in ch)||!ok(k,ch[k]))return;" \
    "const d=find(MSCXOpts({details:Object.assign({},t,{strLaunchOptions:o}),write:(a,r)=>{o=r}})," \
    "p=>k in K?Array.isArray(p.rgOptions)&&p.rgOptions.some(z=>z.data===K[k]):p.npKey===k);if(!d)return;" \
    "k===\"BRIDGEPLAY_FPS_LIMIT\"?d.npSet(+ch[k]):k===\"BRIDGEPLAY_FPS_LIMIT_OFF\"?d.onChange(ch[k]===\"0\"):d.onChange({data:ch[k]})});" \
    "if(o!==o0)SteamClient.Apps.SetAppLaunchOptions(t.unAppID,o);return o}"

// One poll's changes, by appid. The route has already removed their files, so an app Steam
// has no details for yet keeps its changes here and is tried again on the next polls (a
// newer pick of the same setting wins), for about a minute, before they are dropped.
#define NP_CX_TAKE \
    "async q=>{const w=globalThis.MSCXSyncWait||{};globalThis.MSCXSyncWait={};" \
    "for(const id of Object.keys(q||{}))w[id]={ch:Object.assign({},w[id]&&w[id].ch,q[id]),n:0};" \
    "for(const id of Object.keys(w)){let t=null;" \
    "try{t=await globalThis.window.appDetailsStore.RequestAppDetails(+id)}catch(e){}" \
    "if(t){try{console.log(\"Bridgeplay: quick settings for app \"+id+\" saved: \"+MSCXApply(t,w[id].ch))}" \
    "catch(e){console.warn(\"Bridgeplay: quick settings for app \"+id+\" not saved\",e)}}" \
    "else if(++w[id].n<30)globalThis.MSCXSyncWait[id]=w[id];" \
    "else console.warn(\"Bridgeplay: quick settings for app \"+id+\" dropped, Steam has no details for it\")}}"

// Started once per page context; a page without Steam's app store (the test harness) skips it.
#define NP_CX_SYNC \
    "globalThis.window&&window.appDetailsStore&&!globalThis.MSCXSyncOn&&" \
    "(globalThis.MSCXSyncOn=setInterval(()=>{if(typeof MSCXRoute!==\"function\"||globalThis.MSCXSyncBusy)return;" \
    /* From a resolved promise, so a route that throws at once still reaches finally and clears busy. */ \
    "globalThis.MSCXSyncBusy=1;Promise.resolve().then(()=>MSCXRoute(\"NotProton.TakeQuickSettings#1\",0))" \
    ".then(j=>MSCXTake(JSON.parse(j||\"{}\")))" \
    ".catch(e=>console.warn(\"Bridgeplay: quick settings not saved\",e)).finally(()=>{globalThis.MSCXSyncBusy=0})},2000))"

#define NP_CX_OPTIONS_COMPONENT \
    "MSCXLaunch=" NP_CX_LAUNCH ",MSCXPick=" NP_CX_PICK "," \
    "MSCXOpts=" NP_CX_OPTIONS_CAPTURE(NP_C4, NP_C5, NP_WEBPACK_SLIDER) "," \
    "MSCXApply=" NP_CX_APPLY ",MSCXTake=" NP_CX_TAKE ",MSCXSync=" NP_CX_SYNC ","

// Valve is testing a new compatibility page UI, this logic relates to supporting that
#define NP_CX_OPTIONS_STATEMENT_WITH(RT, BARREL, SLIDER) \
    "var MSCXLaunch=" NP_CX_LAUNCH ";" \
    "var MSCXPick=" NP_CX_PICK ";" \
    "var MSCXToolQuery=" NP_CX_TOOL_QUERY ";" \
    "var MSCXOpts=" NP_CX_OPTIONS_CAPTURE(RT, BARREL, SLIDER) ";" \
    "var MSCXApply=" NP_CX_APPLY ";var MSCXTake=" NP_CX_TAKE ";var MSCXSync=" NP_CX_SYNC ";"
#define NP_CX_OPTIONS_STATEMENT NP_CX_OPTIONS_STATEMENT_WITH(NP_C3, NP_C4, NP_WEBPACK_SLIDER)

// The Vite build has no barrel module, so the panel gets one made of the bound components.
#define NP_VITE_UI(SECTION) \
    "({XY:" SECTION ",Yh:" NP_B_CHECKBOX ",m:" NP_B_DROPDOWN ",SliderField:" NP_B_SLIDER "})"
#define NP_CX_OPTIONS_VITE NP_CX_OPTIONS_STATEMENT_WITH(NP_C3, NP_VITE_UI(NP_C4), "npUI().SliderField")

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
      NP_INSTALL_BANNER, 1, 0 },
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
      NP_INSTALL_BANNER, 1, 0 },
    { "(0," NP_C1 ".we)(\"#GameList_Entry_Invalid_OSType2\")",
      NP_COMPAT_HINT, 1, 0 },
};

// The same page from Steam's Vite build: template literals, and imports called as bare names.
static const np_gate_t g_gates_selecttool_vite[] = {
    { NP_C1 "()&&" NP_C2 ".push({title:" NP_C3 "(`#AppProperties_CompatibilityPage`)",
      NP_TAB_REPLACE, 2, 0 },
    { "Compatibility:{visible:" NP_C1 "&&" NP_C2 "(),title:",
      "Compatibility:{visible:" NP_C1 "&&true,title:", 1, 0 },
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C4 ",{label:" NP_C5
      "(`#Settings_SteamPlay_SteamPlay`),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ",{setting:`compat_show_all_tools`,label:" NP_C5
      "(`#Settings_SteamPlay_ShowAll`),feature:7})]})}",
      NP_CX_OPTIONS_VITE
      "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C3 ".Fragment,{children:["
      "(0," NP_C3 ".jsxs)(" NP_C4 ",{label:" NP_C5
      "(`#Settings_SteamPlay_SteamPlay`),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ",{setting:`compat_show_all_tools`,label:" NP_C5
      "(`#Settings_SteamPlay_ShowAll`),feature:7})]}),"
      "(0," NP_C3 ".jsx)(MSCXOpts,{details:" NP_C2 ".details})]})}", 1, 0 },
    { "[" NP_C1 "," NP_C2 "]=" NP_C3 "(" NP_C4 ");if(" NP_C1 ".isLoading||!" NP_C1
      ".data?.tools?.length)return null;",
      "[" NP_C1 "," NP_C2 "]=(typeof MSCXToolQuery==\"function\"?MSCXToolQuery:r=>r)"
      "(" NP_C3 "(" NP_C4 ")," NP_C4 ");if(" NP_C1
      ".isLoading||!" NP_C1 ".data?.tools?.length)return null;", 1, 1 },
    // The arrow's names carry a prefix, since this build names its imports t, r and the like.
    { NP_C7 "||=" NP_C8 "().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(`Transport Error: no transport is available for request`),"
      NP_C10 "(`Transport Error: no transport is available for request`)}):"
      NP_C7 ".SendMsg(`CompatManager.GetCompatTools#1`," NP_C1 "(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}" NP_C5 ".GetCompatTools=" NP_C6 ";",
      NP_C7 "||=" NP_C8 "().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(`Transport Error: no transport is available for request`),"
      NP_C10 "(`Transport Error: no transport is available for request`)}):"
      NP_C7 ".SendMsg(`CompatManager.GetCompatTools#1`," NP_C1 "(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}"
      "globalThis.MSCXRoute=(npR,npId)=>{const npT=" NP_C8 "().GetDefaultTransport();"
      "return npT?npT.SendMsg(npR," NP_C1 "(" NP_C2 ",{appid:npId})," NP_C4 ",{ePrivilege:1,eClientExecutionSite:2})"
      ".then(npX=>npX.BSuccess()?npX.Body().toObject().default_tool_identifier||\"\":Promise.reject(\"result \"+npX.GetEResult()))"
      ":Promise.reject(\"no transport\")};" NP_CX_PREFIX_ROW NP_C5 ".GetCompatTools=" NP_C6 ";", 1, 1 },
    { "get is_invalid_os_type(){return this.most_available_per_client_data.is_invalid_os_type}",
      "get is_invalid_os_type(){return false}", 1, 0 },
    { NP_C1 ".is_invalid_os_type&&(0," NP_C2 ".jsx)(" NP_C3 ",{})",
      NP_INSTALL_BANNER, 1, 0 },
    { NP_C1 "(`#GameList_Entry_Invalid_OSType2`)",
      NP_COMPAT_HINT, 1, 0 },
};

// One use of each component the Vite build imports, its name in capture 1. All must match
// exactly once, or every replacement naming that component is left out; the slider falls
// back to null, so the panel's frame limit uses its menu instead.
typedef struct { char marker; const char *find; const char *fallback; } np_bind_t;
static const np_bind_t g_binds[NP_BIND_COUNT] = {
    { '\016', "(0," NP_C2 ".jsx)(" NP_C1 ",{label:" NP_C3 "(`#LaunchOptionsDialog_Remember`),checked:", NULL },
    { '\017', "(0," NP_C2 ".jsx)(" NP_C1 ",{label:" NP_C3
              "(`#Settings_ControllerCalibration_TurnOnSound`),rgOptions:", NULL },
    { '\020', "(0," NP_C2 ".jsx)(" NP_C1 ",{min:0,max:100,label:" NP_C3 "(`#VoiceInputGain`),", "null" },
    { '\027', "if(" NP_C1 "())return " NP_C2 "(`#FilterElement_ValidPlatform_MacOS`)", NULL },
};

static void resolve_binds(const char *src, size_t len) {
    for (size_t b = 0; b < NP_BIND_COUNT; b++) {
        np_cap_t first[NP_CAP_MAX] = {{0}};
        size_t n = count_matches_first(src, len, g_binds[b].find, first);
        const char *text = g_binds[b].fallback;
        size_t tlen = text ? strlen(text) : 0;
        if (n == 1 && first[0].at && first[0].len < NP_BIND_TEXT_MAX) {
            text = first[0].at;
            tlen = first[0].len;
        } else if (n) {
            NP_WARN("webpatch: component %zu used %zu times where one was expected", b, n);
        }
        g_bind_ok[b] = text != NULL;
        memcpy(g_bind_text[b], text ? text : "", tlen);
        g_bind_text[b][tlen] = '\0';
    }
}

static void clear_binds(void) {
    for (size_t b = 0; b < NP_BIND_COUNT; b++) {
        g_bind_ok[b] = 0;
        g_bind_text[b][0] = '\0';
    }
}

static int uses_binds(const char *replace) {
    for (const char *r = replace; *r; r++)
        if (bind_index(*r) >= 0) return 1;
    return 0;
}

// A replacement naming a component no use of which was found cannot be written.
static int binds_ready(const char *replace) {
    for (const char *r = replace; *r; r++) {
        int b = bind_index(*r);
        if (b >= 0 && !g_bind_ok[b]) return 0;
    }
    return 1;
}

#define NP_PLATFORM_LISTS "window.__NOTPROTON_NATIVE_PLATFORM__"
#define NP_MAC_64(APP) \
    "(" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)&&!" APP ".most_available_per_client_data?.is_invalid_os_type)"
#define NP_MAC_CHECK_CALL(PR, APP) \
    PR "&&" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)?!" APP \
    ".most_available_per_client_data?.is_invalid_os_type:" PR "&&" \
    NP_WINDOWS(APP) "?!1:" PR "?" \
    APP ".is_available_on_current_platform&&!" APP ".most_available_per_client_data?.is_invalid_os_type:"
#define NP_MAC_CHECK(OS, APP) NP_MAC_CHECK_CALL("(0," OS ".Pr)()", APP)
// .exe shortcuts = Windows
#define NP_RUNS_EXE "window.__NOTPROTON_RUNS_EXE__"
#define NP_RUNS_EXE_JS \
    NP_RUNS_EXE "=a=>{if(!a.BIsShortcut?.())return!1;const s=window.appDetailsStore,e=s?.m_mapAppData?.get(a.appid);" \
    "s&&!e?.cRegistered&&queueMicrotask(()=>s.m_mapAppData.get(a.appid)?.cRegistered||s.RegisterForAppData(a.appid));" \
    "return/\\.exe\"?$/i.test(e?.details?.strShortcutExe??\"\")};\n"
#define NP_WINDOWS(APP) \
    "(" NP_PLATFORM_LISTS ".windows.has(" APP ".appid)||" NP_RUNS_EXE "(" APP "))"
#define NP_WINDOWS_ONLY_CASE_CALL(PR, APP) \
    "case\"notprotonWindows\":return " PR "&&" NP_WINDOWS(APP) "&&!" NP_MAC_64(APP) ";"
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
    // The first two again, as the Vite build writes them.
    { "(`#AddNonSteam_Filter_Exe_MacOS`),rFilePatterns:[`*.app`]",
      "(`#AddNonSteam_Filter_Exe_MacOS`),rFilePatterns:[`*.app`,`*.exe`]", 1, 0 },
    { "{strFileTypeName:`Image Files (*.tga,*.png)`,rFilePatterns:[`*.tga`,`*.png`]}",
      "{strFileTypeName:" NP_IMAGE_FILES_LABEL ","
      "rFilePatterns:[`*.tga`,`*.png`,`*.exe`]}", 1, 0 },
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
    // The Vite build inlines the enum and calls CI, mP and td by bare names; Pr is bound.
    { "case 5:return " NP_C1 "()&&!" NP_C2 "()?" NP_C4 "(" NP_C5 "):" NP_C3 "()?!0:" NP_C5
      ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;"
      "case 6:return " NP_C6 ".BIsAppPrivate(" NP_C5 ".appid);",
      NP_WINDOWS_ONLY_CASE_CALL(NP_B_MACOS "()", NP_C5) "case 5:return "
      NP_MAC_CHECK_CALL(NP_B_MACOS "()", NP_C5) NP_C1 "()&&!" NP_C2 "()?" NP_C4 "(" NP_C5 "):"
      NP_C3 "()?!0:" NP_C5 ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;"
      "case 6:return " NP_C6 ".BIsAppPrivate(" NP_C5 ".appid);", 1, 0 },
};
#define NP_FIX_COUNT (sizeof(g_fixes) / sizeof(g_fixes[0]))

// The Apple filter fixes come last: at most one of them matches a given client.
#define NP_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 3)
#define NP_UPDATED_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 2)
#define NP_VITE_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 1)
#define NP_IS_MAC_FILTER_FIX(f) ((f) >= NP_NATIVE_MAC_FILTER_FIX)

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

#define NP_PLATFORM_BUTTON_VITE \
    NP_C1 "&&(0," NP_C2 ".jsxs)(" NP_C3 ",{direction:`top`,nDelayShowMS:240," \
    "toolTipContent:" NP_C4 "(" NP_C5 "?`#GameList_View_Platform_Linux`:`#GameList_View_Platform_Apple`)," \
    "className:" NP_C6 "(`" NP_C7 "`," NP_C8 "&&`" NP_C9 "`," NP_C10 "&&`" NP_C11 "`)," \
    "onClick:()=>" NP_C8 "||" NP_C12 "(1,5,!" NP_C10 "),"
// The Vite library chunk never imports WindowsLogo.
#define NP_WINDOWS_PANE(x, y) \
    "(0," NP_C2 ".jsx)(\"rect\",{x:" x ",y:" y ",width:7,height:7,fill:\"inherit\"})"
#define NP_WINDOWS_BUTTON_VITE \
    NP_C1 "&&!" NP_C5 "&&(0," NP_C2 ".jsxs)(" NP_C3 ",{direction:\"top\",nDelayShowMS:240," \
    "toolTipContent:" NP_LIBRARY_WINDOWS_HINT ",className:" NP_C6 "(`" NP_C7 "`," NP_C8 "&&`" NP_C9 "`," \
    "npWindows&&`" NP_C11 "`),onClick:()=>" NP_C8 \
    "||npStore.SelectCollectionsAppFilterOption(\"notprotonWindows\",null,!npWindows)," \
    "children:(0," NP_C2 ".jsxs)(\"svg\",{className:\"SVGIcon_Button SVGIcon_WindowsLogo\"," \
    "style:{width:13,height:13},viewBox:\"0 0 16 16\",\"aria-hidden\":true,children:[" \
    NP_WINDOWS_PANE("0", "0") "," NP_WINDOWS_PANE("9", "0") "," \
    NP_WINDOWS_PANE("0", "9") "," NP_WINDOWS_PANE("9", "9") "]})})"

static const np_gate_t g_library_filters_vite[] = {
    // Library list and search (Vite inlines filter group 1/2 and platform option 5)
    { "let " NP_C2 "=this.m_filterSpec.filterGroups;if(!" NP_C1 "(" NP_C2 "[1],"
      NP_C3 "(" NP_C4 "))||!" NP_C1 "(" NP_C2 "[2],",
      "let " NP_C2 "=this.m_filterSpec.filterGroups;if(!(this.m_filterSpec.notprotonWindows?((npGroup,npCheck)=>{"
      "const npApple=npGroup.rgOptions.includes(5);return " NP_C1 "({...npGroup,"
      "rgOptions:[...npGroup.rgOptions.filter(npOption=>npOption!==5),\"notprotonWindows\"]},"
      "npOption=>npOption===\"notprotonWindows\"?npCheck(npOption)||npApple&&npCheck(5):npCheck(npOption))"
      "})(" NP_C2 "[1]," NP_C3 "(" NP_C4 ")):" NP_C1 "(" NP_C2 "[1]," NP_C3 "(" NP_C4 ")))||!"
      NP_C1 "(" NP_C2 "[2],", 2, 0 },
    // Saved library filter
    { ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||``,filterGroups:",
      ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||``,"
      "notprotonWindows:!!" NP_C1 "?.notprotonWindows,filterGroups:", 1, 0 },
    { "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;",
      "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){if(" NP_C1 "===\"notprotonWindows\"){"
      "this.m_filterSpec.notprotonWindows=!!" NP_C3 ";return}let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;", 1, 0 },
    { "Reset(){this.m_filterSpec.strSearchText=``,",
      "Reset(){this.m_filterSpec.notprotonWindows=!1,this.m_filterSpec.strSearchText=``,", 1, 0 },
    { "get bIsEmpty(){return this.searchText.length==0&&",
      "get bIsEmpty(){return!this.m_filterSpec.notprotonWindows&&this.searchText.length==0&&", 1, 0 },
    { "let " NP_C1 "=this.GetSelectedOptions(1);" NP_C1 ".length>0&&" NP_C2 ".push(" NP_C1 ".map("
      NP_C3 "=>{if(" NP_C3 "==5){",
      "let " NP_C1 "=this.GetSelectedOptions(1);this.m_filterSpec.notprotonWindows&&(" NP_C1 "=[..."
      NP_C1 ",\"notprotonWindows\"]);" NP_C1 ".length>0&&" NP_C2 ".push(" NP_C1 ".map(" NP_C3 "=>{if(" NP_C3
      "===\"notprotonWindows\")return " NP_LIBRARY_WINDOWS_SUMMARY ";if(" NP_C3 "==5){", 1, 0 },
    // Library toolbar
    { "," NP_C5 "=" NP_C6 "()," NP_C1 "=" NP_C2 ".currentAppFilter.BIsSelected(1,5);return(0,"
      NP_C3 ".jsxs)(`div`,{className:" NP_C4 ",",
      "," NP_C5 "=" NP_C6 "()," NP_C1 "=" NP_C2 ".currentAppFilter.BIsSelected(1,5),npStore=" NP_C2 ","
      "npWindows=!!" NP_C2 ".currentAppFilter.m_filterSpec.notprotonWindows;return(0,"
      NP_C3 ".jsxs)(`div`,{className:" NP_C4 ",", 1, 0 },
    { "children:[" NP_PLATFORM_BUTTON_VITE,
      "children:[" NP_WINDOWS_BUTTON_VITE "," NP_PLATFORM_BUTTON_VITE, 1, 0 },
};
#define NP_LIBRARY_FILTER_VITE_COUNT (sizeof(g_library_filters_vite) / sizeof(g_library_filters_vite[0]))
#define NP_VITE_LIBRARY_TOOLBAR (NP_LIBRARY_FILTER_VITE_COUNT - 2)
#define NP_VITE_LIBRARY_BUTTON (NP_LIBRARY_FILTER_VITE_COUNT - 1)
#define NP_LIBRARY_FILTER_MAX (NP_LIBRARY_FILTER_COUNT > NP_LIBRARY_FILTER_VITE_COUNT \
    ? NP_LIBRARY_FILTER_COUNT : NP_LIBRARY_FILTER_VITE_COUNT)

static int same_capture(np_cap_t a, np_cap_t b) {
    return a.at && b.at && a.len == b.len && memcmp(a.at, b.at, a.len) == 0;
}

typedef struct {
    const char     *name;
    const char     *probe;
    const np_gate_t *gates;
    size_t          count;
} np_ui_shape_t;

static const np_ui_shape_t g_shapes[] = {
    { NP_SHAPE_FORCETOOL,  "#AppProperties_CompatilibityForceTool",
      g_gates_forcetool,  sizeof(g_gates_forcetool) / sizeof(g_gates_forcetool[0]) },
    { NP_SHAPE_SELECTTOOL, "\"#AppProperties_Compat_SelectTool\"",
      g_gates_selecttool, sizeof(g_gates_selecttool) / sizeof(g_gates_selecttool[0]) },
    { NP_SHAPE_SELECTTOOL_VITE, "`#AppProperties_Compat_SelectTool`",
      g_gates_selecttool_vite, sizeof(g_gates_selecttool_vite) / sizeof(g_gates_selecttool_vite[0]) },
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
    "BRIDGEPLAY_PERF_OVERLAY", "BRIDGEPLAY_FPS_LIMIT", "BRIDGEPLAY_FPS_LIMIT_OFF", "BRIDGEPLAY_SCALING_FILTER",
    "BRIDGEPLAY_NVAPI", "BRIDGEPLAY_SUSTAINED",
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
        // A maintainer-confirmed anti-cheat (docs/GAMEFIXES.md), for the verdict row.
        "ANTICHEAT",
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
    if (strncmp(key, "BRIDGEPLAY_FRAMEGEN", 19) != 0 && strncmp(key, "NOTPROTON_FRAMEGEN", 18) != 0 &&
        strcmp(key, "BRIDGEPLAY_PERF_OVERLAY") != 0 && strcmp(key, "NOTPROTON_PERF_OVERLAY") != 0 &&
        strcmp(key, "BRIDGEPLAY_FPS_LIMIT") != 0 && strcmp(key, "NOTPROTON_FPS_LIMIT") != 0 &&
        strcmp(key, "BRIDGEPLAY_FPS_LIMIT_OFF") != 0 && strcmp(key, "NOTPROTON_FPS_LIMIT_OFF") != 0 &&
        strcmp(key, "BRIDGEPLAY_SCALING_FILTER") != 0 && strcmp(key, "NOTPROTON_SCALING_FILTER") != 0)
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
typedef struct { fx_pair_t p[24]; size_t n; } fx_set_t;

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
    // np-native lets NOTPROTON_<X> win over BRIDGEPLAY_<X> from the same file, whatever
    // the order, so a BRIDGEPLAY_ line does not replace a key this file set the old way.
    const char *legacy[sizeof(set->p) / sizeof(set->p[0])];
    size_t nlegacy = 0;
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
            if (key && fx_safe(val)) {
                size_t i = 0;
                while (i < nlegacy && strcmp(legacy[i], key) != 0) i++;
                if (strncmp(b, "NOTPROTON_", 10) == 0) {
                    if (i == nlegacy && nlegacy < sizeof(legacy) / sizeof(legacy[0])) legacy[nlegacy++] = key;
                } else if (i < nlegacy) {
                    continue;
                }
            }
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
    // arch, description, tab separated), and so does a CrossOver build whose runner has the
    // .notproton-msync marker the app writes, which the run script reads from the same
    // place. "" stands for the default tool.
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
            char *build = tab + 1, *build_end = strchr(build, '\t');
            if (*ms == '0' && build_end) {
                *build_end = '\0';
                char marker[sizeof(root) + 128];
                int m = snprintf(marker, sizeof(marker),
                                 "%s/runners/crossover-%s/CrossOver/.notproton-msync", root, build);
                if (*build && fx_word(build, 64) && !strchr(build, '_') &&
                    m > 0 && (size_t)m < sizeof(marker) && access(marker, F_OK) == 0)
                    ms = "1";
                *build_end = '\t';
            }
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
    // The frame rate limit slider's top: the fastest display's refresh rate now.
    n = snprintf(buf + len, cap - len, ",\"fm\":%d};", np_display_max_hz());
    if (n < 0 || (size_t)n >= cap - len) return 0;
    return 1;
}

static _Thread_local size_t g_last_gates_live, g_last_gates_total;
static _Thread_local int    g_last_gates_drifted;

void np_webpatch_last_gates(size_t *live, size_t *total, int *drifted) {
    *live = g_last_gates_live;
    *total = g_last_gates_total;
    *drifted = g_last_gates_drifted;
}

char *np_webpatch_transform(const uint8_t *src, size_t src_len, size_t *out_len,
                            const char **out_shape) {
    const char *s = (const char *)src;

    if (out_shape)
        *out_shape = NULL;
    g_last_gates_live = g_last_gates_total = 0;
    g_last_gates_drifted = 0;

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
    int    need_binds = shape != NULL;
    size_t mac_variants = 0;
    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        size_t n = count_matches(s, src_len, g_fixes[f].find);
        fix_on[f] = n == (size_t)g_fixes[f].expect;
        if (NP_IS_MAC_FILTER_FIX(f) && n) mac_variants++;
        need_binds |= fix_on[f] && uses_binds(g_fixes[f].replace);
        if (!fix_on[f] && n)
            NP_WARN("webpatch: fix %zu expected %d occurrence(s), found %zu; "
                    "leaving it alone", f, g_fixes[f].expect, n);
    }
    if (mac_variants > 1) {
        NP_WARN("webpatch: multiple platform filter patterns matched; leaving the library filters stock");
        for (size_t f = NP_NATIVE_MAC_FILTER_FIX; f < NP_FIX_COUNT; f++) fix_on[f] = 0;
    }
    if (need_binds) resolve_binds(s, src_len);
    else clear_binds();
    int mac_filter = 0;
    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        if (fix_on[f] && !binds_ready(g_fixes[f].replace)) {
            NP_WARN("webpatch: fix %zu names a component this chunk never uses; "
                    "leaving it alone", f);
            fix_on[f] = 0;
        }
        fix_live += fix_on[f];
        if (NP_IS_MAC_FILTER_FIX(f)) mac_filter |= fix_on[f];
    }
    char *native_mac_js = mac_filter ? np_nativeplatform_javascript() : NULL;
    if (!native_mac_js && mac_filter) {
        NP_WARN("webpatch: no platform list from appinfo.vdf, the Apple filter stays stock");
        for (size_t f = NP_NATIVE_MAC_FILTER_FIX; f < NP_FIX_COUNT; f++) {
            fix_live -= fix_on[f];
            fix_on[f] = 0;
        }
        mac_filter = 0;
    }
    int library_filter = mac_filter;
    int vite_library = fix_on[NP_VITE_NATIVE_MAC_FILTER_FIX];
    const np_gate_t *lib_gates = vite_library ? g_library_filters_vite : g_library_filters;
    size_t lib_count = vite_library ? NP_LIBRARY_FILTER_VITE_COUNT : NP_LIBRARY_FILTER_COUNT;
    int library_on[NP_LIBRARY_FILTER_MAX] = {0};
    np_cap_t vite_toolbar[NP_CAP_MAX] = {{0}}, vite_button[NP_CAP_MAX] = {{0}};
    for (size_t g = 0; mac_filter && g < lib_count; g++) {
        np_cap_t *first = NULL;
        if (vite_library && g == NP_VITE_LIBRARY_TOOLBAR) first = vite_toolbar;
        if (vite_library && g == NP_VITE_LIBRARY_BUTTON) first = vite_button;
        size_t n = count_matches_first(s, src_len, lib_gates[g].find, first);
        library_on[g] = n == (size_t)lib_gates[g].expect;
        if (library_on[g] || (!vite_library && (g == NP_LIBRARY_TOOLBAR || g == NP_LOCALIZED_LIBRARY_TOOLBAR)))
            continue;
        NP_WARN("webpatch: [%s] library anchor %zu expected %d occurrence(s), found %zu; "
                "no Windows filter button", vite_library ? "Vite" : "webpack", g, lib_gates[g].expect, n);
        library_filter = 0;
    }
    if (!mac_variants && count_matches(s, src_len, g_library_filters_vite[NP_VITE_LIBRARY_BUTTON].find))
        NP_WARN("webpatch: [Vite] library toolbar found without a platform filter; no Windows filter button");
    if (library_filter && vite_library &&
        (!same_capture(vite_toolbar[0], vite_button[9]) ||
         !same_capture(vite_toolbar[2], vite_button[1]) ||
         !same_capture(vite_toolbar[4], vite_button[4]))) {
        NP_WARN("webpatch: [Vite] library toolbar bindings differ; no Windows filter button");
        library_filter = 0;
    }
    if (library_filter && !vite_library &&
        library_on[NP_LIBRARY_TOOLBAR] == library_on[NP_LOCALIZED_LIBRARY_TOOLBAR]) {
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
            if (gate_on[g] && !binds_ready(shape->gates[g].replace)) {
                NP_WARN("webpatch: [%s] gate %zu names a component this chunk never uses",
                        shape->name, g);
                gate_on[g] = 0;
                n = 0;
            }
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
        g_last_gates_live = gate_live;
        g_last_gates_total = shape->count;
        g_last_gates_drifted = drifted;
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
    for (size_t g = 0; library_filter && g < lib_count; g++)
        if (library_on[g]) mark_start(can_start, lib_gates[g].find);
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
        for (size_t g = 0; !hit && library_filter && g < lib_count; g++) {
            if (!library_on[g]) continue;
            used = match_at(s, src_len, i, lib_gates[g].find, caps);
            if (used) { hit = &lib_gates[g]; break; }
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
        // Players' verdicts, then the code that reads them: without the file it shows nothing.
        char *verdicts = np_compatverdict_javascript(getenv("HOME"));
        ok = (!verdicts || out_put(&out, verdicts, strlen(verdicts)))
            && out_put(&out, NP_CX_VERDICT, sizeof(NP_CX_VERDICT) - 1);
        free(verdicts);
        if (!ok) { free(out.buf); return NULL; }
    }

    if (!out_reserve(&out, 0)) { free(out.buf); return NULL; }
    out.buf[out.len] = '\0';
    *out_len = out.len;
    if (library_filter) NP_LOG("webpatch: Windows library filter button added (%s)", vite_library ? "Vite" : "webpack");
    NP_LOG("webpatch: [%s] %zu gates, %zu fixes applied",
           shape ? shape->name : "no compat UI", gate_live, fix_live);
    return out.buf;
}
