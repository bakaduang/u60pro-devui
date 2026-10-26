#!/bin/sh
# DevUI adapter for the 「Clash 管理」 plugin (mihomo) — xpage API 2.
# Called by u60pro-devui as: XP_VIEW=<tab> sh uclash.sh <verb>
#   status                          KEY=VALUE lines for {{X_KEY}} (work limited to $XP_VIEW)
#   start | stop | restart          via clashctl.sh
#   mode:rule|global|direct         outbound mode (persistent)
#   g:prev | g:next                 browse proxy groups on the 节点 tab
#   pick:<sig>:<n>                  select node n of the cached list <sig> in the current group
#   test                            latency test of the current group
#   tk:off|white|black|all          terminal takeover scope (persistent)
#   local:0|1  udp:0|1              router-self proxy / UDP proxy (persistent)
#   dev:<sig>:<n>                   toggle device n in the white/black list
#   use:<sig>:<n>                   switch to profile n
#   subup                           update the active subscription
#   boot:on|off                     autostart
# All persistent changes go through clashctl.sh, which validates and applies them.

D=${XP_CLASH_DIR:-/data/plugins/clash}
CTL=$D/clashctl.sh
RUN=${XP_RUN_DIR:-/tmp/devui-x}
VIEW=${XP_VIEW:-main}
TAB=$(printf '\t')
PER=5
GROUPS=$RUN/uclash.groups
GSEL=$RUN/uclash.gsel
NODES=$RUN/uclash.nodes
DELAY=$RUN/uclash.delay
DEVS=$RUN/uclash.devs
SUBS=$RUN/uclash.subs
TRAF=$RUN/uclash.traffic
PJ=$RUN/uclash.proxies.json
TEST_URL='https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'

mkdir -p "$RUN" 2>/dev/null

conf() { sed -n "s/^$1='\(.*\)'\$/\1/p" "$D/settings.conf" 2>/dev/null | head -n 1; }
CTRL=$(conf CTRL); CTRL=${CTRL:-9090}
SECRET=$(conf SECRET)
api() { # METHOD PATH [JSON] [TIMEOUT]
    if [ -n "$3" ]; then
        curl -s -m "${4:-3}" -X "$1" -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$CTRL$2" 2>/dev/null
    else
        curl -s -m "${4:-3}" -X "$1" -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$CTRL$2" 2>/dev/null
    fi
}
api_code() { # METHOD PATH JSON -> status
    curl -s -m 5 -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: Bearer $SECRET" \
        -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$CTRL$2" 2>/dev/null
}
urlenc() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g'; }
jf() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
jkey() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
hesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
list_sig() { md5sum < "$1" 2>/dev/null | cut -c1-10; }
human() { awk -v b="${1:-0}" -v u="$2" 'BEGIN { s = "B"; if (b >= 1073741824) { b /= 1073741824; s = "GB" } else if (b >= 1048576) { b /= 1048576; s = "MB" } else if (b >= 1024) { b /= 1024; s = "KB" }; printf((b >= 100 || s == "B") ? "%.0f %s%s" : "%.1f %s%s", b, s, u) }'; }
hms() { s=$1; h=$((s / 3600)); m=$((s % 3600 / 60))
    if [ "$h" -ge 24 ]; then echo "$((h / 24))天$((h % 24))时"; elif [ "$h" -gt 0 ]; then echo "${h}时${m}分"; else echo "${m}分"; fi; }
# 渲染程序会自行去掉屏幕字体没有的 emoji，这里只去掉首尾空格
noemoji() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
# 运行 clashctl.sh 并只返回最后一行（作为屏幕提示）
ctl() { out=$(sh "$CTL" "$@" 2>&1); rc=$?; printf '%s\n' "$out" | sed -n '/[^[:space:]]/h; ${x;p}'; return $rc; }

# --------------------------------------------------------- proxy groups ---
# 刷新组列表（GLOBAL 的顺序，只保留可展示的组）；输出 TSV：名称 类型 当前
load_groups() {
    api GET /proxies '' 5 > "$PJ"
    [ -s "$PJ" ] || return 1
    jsonfilter -i "$PJ" -e '@.proxies.GLOBAL.all[*]' 2>/dev/null > "$GROUPS.names"
    [ "$(conf MODE)" = global ] && sed -i '1i GLOBAL' "$GROUPS.names"
    : > "$GROUPS.tmp"
    while IFS= read -r n; do
        k=$(jkey "$n")
        t=$(jsonfilter -i "$PJ" -e "@.proxies[\"$k\"].type" 2>/dev/null)
        case "$t" in Selector|URLTest|Fallback|LoadBalance) ;; *) continue ;; esac
        printf '%s\t%s\t%s\n' "$n" "$t" "$(jsonfilter -i "$PJ" -e "@.proxies[\"$k\"].now" 2>/dev/null)" >> "$GROUPS.tmp"
    done < "$GROUPS.names"
    rm -f "$GROUPS.names"
    mv -f "$GROUPS.tmp" "$GROUPS"
    [ -s "$GROUPS" ]
}
cur_group() { # 当前浏览的组（行号）
    total=$(grep -c '' "$GROUPS" 2>/dev/null); total=${total:-0}
    want=$(cat "$GSEL" 2>/dev/null)
    gi=$(cut -f1 "$GROUPS" | grep -n -x -F -e "$want" 2>/dev/null | head -n 1 | cut -d: -f1)
    [ -n "$gi" ] || gi=1
    gname=$(sed -n "${gi}p" "$GROUPS" | cut -f1); gtype=$(sed -n "${gi}p" "$GROUPS" | cut -f2); gnow=$(sed -n "${gi}p" "$GROUPS" | cut -f3)
}
type_label() { case "$1" in Selector) echo 手动选择 ;; URLTest) echo 自动选择 ;; Fallback) echo 故障转移 ;; LoadBalance) echo 负载均衡 ;; *) echo "$1" ;; esac; }
# 沿着组的 now 一路找到实际节点
resolve_now() {
    n=$1; i=0
    while [ "$i" -lt 5 ]; do
        nx=$(awk -F "$TAB" -v n="$n" '$1 == n { print $3; exit }' "$GROUPS" 2>/dev/null)
        [ -n "$nx" ] || break
        n=$nx; i=$((i + 1))
    done
    printf '%s' "$n"
}

# --------------------------------------------------------------- status ---
st_common() {
    sh "$CTL" status > "$RUN/uclash.st" 2>/dev/null
    S() { sed -n "s/^$1=//p" "$RUN/uclash.st" | head -n 1; }
    if [ "$(S INSTALLED)" != 1 ]; then
        echo "RUN=0"; echo "INTERVAL=10"
        echo "STATE=未安装"; echo "STATECLASS=muted"; echo "HEADLINE=未安装 mihomo 内核"
        echo "SUBLINE=请在 UFI-TOOLS 网页「Clash」里下载内核并添加订阅"
        echo "PRIMARY_HREF=act:x:refresh"; echo "PRIMARY_LABEL=启动"; echo "PRIMARY_CLASS=disabled"; echo "RESTART_CLASS=disabled"
        return 1
    fi
    echo "COREVER=mihomo $(S CORE_VER)"
    tk=$(S TAKEOVER); n=$(S MACS | wc -w)
    case "$tk" in all) take=全部终端 ;; white) take="白名单 $n 台" ;; black) take="排除 $n 台" ;; *) take=不接管终端 ;; esac
    [ "$(S LOCAL)" = 1 ] && take="$take + 本机"
    echo "TAKE=$take"
    case "$(S MODE)" in rule) echo "M_RULE=seg-on" ;; global) echo "M_GLOBAL=seg-on" ;; direct) echo "M_DIRECT=seg-on" ;; esac
    if [ "$(S BOOT)" = 1 ]; then echo "BOOTCLASS=on"; echo "BOOTNEXT=off"; echo "BOOTSTATE=开机后自动启动"
    else echo "BOOTCLASS=off"; echo "BOOTNEXT=on"; echo "BOOTSTATE=开机不自动启动"; fi
    if [ "$(S RUN)" != 1 ]; then
        echo "RUN=0"; echo "INTERVAL=5"; echo "UP=0"
        c=$(S CONFLICT); cr=$(S CRASHED)
        echo "STATE=已停止"; echo "STATECLASS=muted"
        if [ -n "$c" ]; then echo "HEADLINE=有其他代理在运行"; echo "SUBLINE=$c"
        elif [ -n "$cr" ]; then echo "STATECLASS=bad"; echo "HEADLINE=内核连续崩溃已停止"; echo "SUBLINE=终端已恢复直连 · 请在网页查看日志"
        else echo "HEADLINE=Clash 已停止"; echo "SUBLINE=终端直连上网 · 当前订阅：$(S ACTIVE_NAME)"; fi
        echo "PRIMARY_HREF=act:x:start"; echo "PRIMARY_LABEL=启动"; echo "PRIMARY_CLASS=svc-primary"; echo "RESTART_CLASS=disabled"
        echo "GNAME=当前节点"; echo "NOWNODE=—"; echo "CONNS=—"; echo "RSS=—"
        return 0
    fi
    echo "RUN=1"; echo "INTERVAL=3"
    rss=$(S RSS); echo "RSS=$(( ${rss:-0} / 1024 )) MB"
    up=$(S UPTIME)
    echo "PRIMARY_HREF=act:xc:stop"; echo "PRIMARY_LABEL=停止"; echo "PRIMARY_CLASS="; echo "RESTART_CLASS="
    if [ "$(api_code GET /version '')" != 200 ]; then
        echo "UP=0"; echo "STATE=无响应"; echo "STATECLASS=bad"; echo "HEADLINE=控制接口无响应"
        echo "SUBLINE=内核在运行但 $CTRL 端口未应答，可尝试重启"
        return 0
    fi
    echo "UP=1"
    if [ "$(S FW)" = 1 ]; then echo "STATE=代理中"; echo "STATECLASS=ok"; echo "HEADLINE=终端流量已接管"
    elif [ "$tk" = off ] && [ "$(S LOCAL)" != 1 ]; then echo "STATE=运行中"; echo "STATECLASS=ok"; echo "HEADLINE=仅端口代理 $(S MIXED)"
    else echo "STATE=未接管"; echo "STATECLASS=warn"; echo "HEADLINE=接管规则未挂载"; fi
    echo "SUBLINE=$(noemoji "$(S ACTIVE_NAME)")${up:+ · 已运行 $(hms "$up")}"
    return 0
}

st_main() {
    [ "$UP" = 1 ] || return 0
    if load_groups; then
        first=$(awk -F "$TAB" '$2 == "Selector" && $1 != "GLOBAL" { print $1; exit }' "$GROUPS")
        [ -n "$first" ] || first=$(sed -n '1p' "$GROUPS" | cut -f1)
        echo "GNAME=$(noemoji "$first")"
        echo "NOWNODE=$(noemoji "$(resolve_now "$first")")"
    fi
    api GET /connections '' 4 > "$RUN/uclash.conn.json"
    if [ -s "$RUN/uclash.conn.json" ]; then
        dn=$(jsonfilter -i "$RUN/uclash.conn.json" -e '@.downloadTotal' 2>/dev/null); dn=${dn:-0}
        upb=$(jsonfilter -i "$RUN/uclash.conn.json" -e '@.uploadTotal' 2>/dev/null); upb=${upb:-0}
        echo "CONNS=$(jsonfilter -i "$RUN/uclash.conn.json" -e '@.connections[*].id' 2>/dev/null | grep -c '')"
        t=$(date +%s)
        if [ -f "$TRAF" ] && read -r pt pd pu < "$TRAF" && [ "$t" -gt "$pt" ] 2>/dev/null; then
            dt=$((t - pt)); rd=$(( (dn - pd) / dt )); ru=$(( (upb - pu) / dt ))
            [ "$rd" -lt 0 ] && rd=0; [ "$ru" -lt 0 ] && ru=0
            echo "SPEED_DOWN=$(human "$rd" /s)"; echo "SPEED_UP=$(human "$ru" /s)"
        else
            echo "SPEED_DOWN=…"; echo "SPEED_UP=…"
        fi
        echo "$t $dn $upb" > "$TRAF"
    fi
    rm -f "$RUN/uclash.conn.json"
}

st_nodes() {
    [ "$UP" = 1 ] || { echo "GTITLE=节点"; echo "GPOS=—"; echo "NODES_HTML=<div class='xempty'>Clash 未运行，启动后才能切换节点</div>"; return 0; }
    load_groups || { echo "GTITLE=节点"; echo "GPOS=—"; echo "NODES_HTML=<div class='xempty'>当前配置没有可切换的策略组</div>"; return 0; }
    cur_group
    echo "GTITLE=$(noemoji "$gname")"
    echo "GPOS=$gi / $total"
    if [ "$gtype" = Selector ]; then echo "GNOTE=$(type_label "$gtype") · 点一下节点即切换"
    else echo "GNOTE=$(type_label "$gtype") · 由内核自动选择，不能手动切换"; fi
    jsonfilter -i "$PJ" -e "@.proxies[\"$(jkey "$gname")\"].all[*]" 2>/dev/null > "$NODES.tmp"
    mv -f "$NODES.tmp" "$NODES"
    cnt=$(grep -c '' "$NODES" 2>/dev/null); cnt=${cnt:-0}
    [ "$cnt" -gt 0 ] || { echo "NODES_HTML=<div class='xempty'>该组没有节点</div>"; return 0; }
    idx=$(grep -n -x -F -e "$gnow" "$NODES" 2>/dev/null | head -n 1 | cut -d: -f1)
    echo "PAGES_NODES=$(( (cnt + PER - 1) / PER ))"
    echo "CURPAGE_NODES=$(( (${idx:-1} - 1) / PER + 1 ))"
    [ -s "$DELAY" ] || printf '#\t#\n' > "$DELAY"
    sig=$(list_sig "$NODES")
    rows=$(NOW="$gnow" SIG="$sig" PER="$PER" SEL="$gtype" awk -F "$TAB" '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        FNR == NR { d[$2] = $1; next }
        {
            n = $0; i = FNR; per = ENVIRON["PER"] + 0
            if ((i - 1) % per == 0) printf "%s<div class=\"xpg xpg-nodes-%d\">", (i > 1 ? "</div>" : ""), (i - 1) / per + 1
            if (n == ENVIRON["NOW"]) { cls = "xrow on"; tag = "<span class=\"xd\">使用中</span>" }
            else {
                cls = "xrow"
                if (!(n in d)) tag = "<span class=\"xd n\">未测</span>"
                else if (d[n] + 0 <= 0) tag = "<span class=\"xd r\">超时</span>"
                else { v = d[n] + 0; tag = "<span class=\"xd " ((v < 300) ? "g" : (v < 800) ? "y" : "r") "\">" v "ms</span>" }
            }
            href = (ENVIRON["SEL"] == "Selector") ? "act:x:pick:" ENVIRON["SIG"] ":" i : "act:x:refresh"
            printf "<a href=\"%s\" class=\"%s\">%s%s</a>", href, cls, tag, esc(n == "" ? "(未命名)" : n)
        }
        END { if (FNR > 0 && NR > FNR) printf "</div>" }' "$DELAY" "$NODES")
    echo "NODES_HTML=$rows"
}

st_proxy() {
    S() { sed -n "s/^$1=//p" "$RUN/uclash.st" | head -n 1; }
    tk=$(S TAKEOVER)
    case "$tk" in
        all) echo "T_ALL=seg-on"; echo "TKDESC=所有连接本机的设备都走 Clash" ;;
        white) echo "T_WHITE=seg-on"; echo "TKDESC=只有下面打开开关的设备走 Clash" ;;
        black) echo "T_BLACK=seg-on"; echo "TKDESC=除下面打开开关的设备外，全部走 Clash" ;;
        *) echo "T_OFF=seg-on"; echo "TKDESC=终端不经过 Clash，只提供 $(S MIXED) 端口代理" ;;
    esac
    if [ "$(S LOCAL)" = 1 ]; then echo "LOCALCLASS=on"; echo "LOCALNEXT=0"; echo "LOCALSTATE=路由器自身流量也走代理"
    else echo "LOCALCLASS=off"; echo "LOCALNEXT=1"; echo "LOCALSTATE=路由器自身流量直连"; fi
    if [ "$(S UDP)" = 1 ]; then
        echo "UDPCLASS=on"; echo "UDPNEXT=0"
        if [ "$(S FW)" = 1 ] && [ "$(S FWUDP)" != 1 ] && [ "$tk" != off ]; then echo "UDPSTATE=内核不支持 TPROXY"; else echo "UDPSTATE=游戏 / 语音走代理"; fi
    else echo "UDPCLASS=off"; echo "UDPNEXT=1"; echo "UDPSTATE=UDP 直连"; fi
    sh "$CTL" devices 2>/dev/null | awk -F "$TAB" '$1 == "DEV" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' > "$DEVS"
    total=$(grep -c '' "$DEVS"); total=${total:-0}
    on=$(awk -F "$TAB" '$5 == 1' "$DEVS" | grep -c '')
    case "$tk" in
        white) echo "DEVTITLE=走代理 $on / $total 台"; echo "DEVNOTE=开关打开 = 走代理" ;;
        black) echo "DEVTITLE=排除 $on / $total 台"; echo "DEVNOTE=开关打开 = 不走代理" ;;
        *) echo "DEVTITLE=$on / $total 台"; echo "DEVNOTE=切到白名单或黑名单后，名单才生效" ;;
    esac
    [ "$total" -gt 0 ] || { echo "DEV_HTML=<div class='xempty'>还没有发现设备</div>"; return 0; }
    echo "PAGES_DEVICES=$(( (total + PER - 1) / PER ))"
    rows=$(SIG="$(list_sig "$DEVS")" PER="$PER" awk -F "$TAB" '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        {
            i = NR; per = ENVIRON["PER"] + 0
            if ((i - 1) % per == 0) printf "%s<div class=\"xpg xpg-devices-%d\">", (i > 1 ? "</div>" : ""), (i - 1) / per + 1
            nm = ($3 != "") ? $3 : "设备 " $2
            printf "<a href=\"act:x:dev:%s:%d\" class=\"xdev\"><span class=\"sw %s\"><span class=\"sw-track\"></span><span class=\"kn\"></span></span><span class=\"xdn\">%s</span><span class=\"xdi\">%s%s</span></a>", ENVIRON["SIG"], i, ($5 == 1 ? "on" : "off"), esc(nm), esc($2 != "" ? $2 : toupper($1)), ($4 == 1 ? " · 在线" : "")
        }
        END { if (NR > 0) printf "</div>" }' "$DEVS")
    echo "DEV_HTML=$rows"
}

st_subs() {
    S() { sed -n "s/^$1=//p" "$RUN/uclash.st" | head -n 1; }
    act=$(S ACTIVE)
    sh "$CTL" profiles 2>/dev/null | awk -F "$TAB" '$1 == "PROFILE"' | cut -f2- > "$SUBS"
    total=$(grep -c '' "$SUBS"); total=${total:-0}
    [ "$total" -gt 0 ] || { echo "SUB_HTML=<div class='xempty'>还没有订阅，请在网页端添加</div>"; return 0; }
    idx=$(cut -f1 "$SUBS" | grep -n -x -F -e "$act" | head -n 1 | cut -d: -f1)
    echo "PAGES_SUBS=$(( (total + 3) / 4 ))"
    echo "CURPAGE_SUBS=$(( (${idx:-1} - 1) / 4 + 1 ))"
    rows=$(SIG="$(list_sig "$SUBS")" ACT="$act" NOW="$(date +%s)" awk -F "$TAB" '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        function hb(b,  s) { s = "B"; if (b >= 1073741824) { b /= 1073741824; s = "G" } else if (b >= 1048576) { b /= 1048576; s = "M" } else if (b >= 1024) { b /= 1024; s = "K" }; return sprintf((b >= 100 || s == "B") ? "%.0f%s" : "%.1f%s", b, s) }
        {
            i = NR
            if ((i - 1) % 4 == 0) printf "%s<div class=\"xpg xpg-subs-%d\">", (i > 1 ? "</div>" : ""), (i - 1) / 4 + 1
            # id name src conv updated bytes up down total expire nodes
            info = ($5 + 0 > 0) ? ($11 " 个节点") : "未下载"
            if ($9 + 0 > 0) info = info " · " hb($7 + $8) "/" hb($9)
            if ($10 + 0 > 0) { left = int(($10 - ENVIRON["NOW"]) / 86400); info = info ((left >= 0) ? " · 剩" left "天" : " · 已过期") }
            if ($3 == "") info = info " · 本地"
            if ($1 == ENVIRON["ACT"]) printf "<a href=\"act:x:refresh\" class=\"xrow on\"><span class=\"xd\">使用中</span>%s</a>", esc($2)
            else printf "<a href=\"act:xc:use:%s:%d\" class=\"xrow\"><span class=\"xd n\">%s</span>%s</a>", ENVIRON["SIG"], i, esc(info), esc($2)
            if ($1 == ENVIRON["ACT"]) printf "<div class=\"xnote\">%s</div>", esc(info)
        }
        END { if (NR > 0) printf "</div>" }' "$SUBS")
    echo "SUB_HTML=$rows"
}

# -------------------------------------------------------------- actions ---
up_or_die() { [ "$(api_code GET /version '')" = 200 ] || { echo "Clash 未运行"; exit 1; }; }
pick_row() { # file sig n -> row
    case "$3" in ''|*[!0-9]*) return 1 ;; esac
    case "$2" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ -s "$1" ] && [ "$(list_sig "$1")" = "$2" ] || return 1
    sed -n "${3}p" "$1"
}

[ -f "$CTL" ] || { echo "STATE=未安装"; echo "HEADLINE=未检测到 Clash 插件"; exit 0; }
case "$1" in
    status)
        st_common > "$RUN/uclash.st.out"; rc=$?
        cat "$RUN/uclash.st.out"
        [ "$rc" = 0 ] || { rm -f "$RUN/uclash.st.out"; exit 0; }
        UP=$(sed -n 's/^UP=//p' "$RUN/uclash.st.out")
        rm -f "$RUN/uclash.st.out"
        case "$VIEW" in nodes) st_nodes ;; proxy) st_proxy ;; subs) st_subs ;; *) st_main ;; esac ;;
    refresh) echo "已刷新" ;;
    start) ctl start ;;
    stop) ctl stop ;;
    restart) ctl restart ;;
    mode:rule|mode:global|mode:direct) ctl set "MODE=${1#mode:}" ;;
    tk:off|tk:white|tk:black|tk:all) ctl set "TAKEOVER=${1#tk:}" ;;
    local:0|local:1) ctl set "LOCAL=${1#local:}" ;;
    udp:0|udp:1) ctl set "UDP=${1#udp:}" ;;
    boot:on) ctl boot-on ;;
    boot:off) ctl boot-off ;;
    subup) ctl sub-update ;;
    g:prev|g:next)
        [ -s "$GROUPS" ] || load_groups || { echo "没有策略组"; exit 1; }
        cur_group
        if [ "$1" = g:next ]; then gi=$((gi % total + 1)); else gi=$(( (gi + total - 2) % total + 1 )); fi
        sed -n "${gi}p" "$GROUPS" | cut -f1 > "$GSEL"
        echo "$(noemoji "$(cat "$GSEL")")" ;;
    pick:*)
        up_or_die
        rest=${1#pick:}
        name=$(pick_row "$NODES" "${rest%%:*}" "${rest#*:}") || { echo "节点列表已变化，请重选"; exit 1; }
        cur_group
        [ "$gtype" = Selector ] || { echo "该组为自动选择，不能手动切换"; exit 1; }
        c=$(api_code PUT "/proxies/$(urlenc "$gname")" "{\"name\":\"$(json_esc "$name")\"}")
        case "$c" in 200|204) echo "已切换：$(noemoji "$name")" ;; *) echo "切换失败（HTTP $c）"; exit 1 ;; esac ;;
    test)
        up_or_die
        [ -s "$GROUPS" ] || load_groups
        cur_group
        r=$(api GET "/group/$(urlenc "$gname")/delay?url=$TEST_URL&timeout=2500" "" 25)
        [ -n "$r" ] || { echo "测速失败：接口无响应"; exit 1; }
        printf '%s' "$r" | tr -d '\n' | awk '
            { s = $0; n = length(s); i = 1
              while (i <= n) {
                c = substr(s, i, 1)
                if (c != "\"") { i++; continue }
                k = ""; i++
                while (i <= n) {
                    c = substr(s, i, 1)
                    if (c == "\\") {
                        e = substr(s, i + 1, 1)
                        if (e == "u") { h = tolower(substr(s, i + 2, 4)); k = k (h == "0026" ? "&" : h == "003c" ? "<" : h == "003e" ? ">" : "?"); i += 6 }
                        else { k = k e; i += 2 }
                        continue
                    }
                    if (c == "\"") break
                    k = k c; i++
                }
                i++
                while (i <= n && substr(s, i, 1) != ":") i++
                i++; v = ""
                while (i <= n) { c = substr(s, i, 1); if (c ~ /[0-9]/) { v = v c; i++ } else if (c == " ") i++; else break }
                if (k != "" && v != "") print v "\t" k
              } }' > "$DELAY.body"
        { printf '#\t#\n'; cat "$DELAY.body"; } > "$DELAY.tmp"
        rm -f "$DELAY.body"; mv -f "$DELAY.tmp" "$DELAY"
        ok=$(awk -F "$TAB" '$2 != "#" && $1 + 0 > 0' "$DELAY" | grep -c '')
        echo "测速完成：$ok 个节点可用" ;;
    dev:*)
        rest=${1#dev:}
        row=$(pick_row "$DEVS" "${rest%%:*}" "${rest#*:}") || { echo "设备列表已变化，请重试"; exit 1; }
        mac=$(printf '%s\n' "$row" | cut -f1); inl=$(printf '%s\n' "$row" | cut -f5)
        macs=$(conf MACS)
        if [ "$inl" = 1 ]; then macs=$(for m in $macs; do [ "$m" = "$mac" ] || printf '%s ' "$m"; done)
        else macs="$macs $mac"; fi
        ctl set "MACS=$(echo $macs)" ;;
    use:*)
        rest=${1#use:}
        row=$(pick_row "$SUBS" "${rest%%:*}" "${rest#*:}") || { echo "订阅列表已变化，请重试"; exit 1; }
        ctl profile-use "$(printf '%s\n' "$row" | cut -f1)" ;;
    *) echo "未知操作：$1"; exit 2 ;;
esac
