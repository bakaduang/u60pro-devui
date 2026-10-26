#!/bin/sh
# DevUI adapter for the 小海关 (customs) Mihomo plugin — xpage API 2.
# Called by u60pro-devui as: XP_VIEW=<tab> sh customs.sh <verb>
#   status                         KEY=VALUE lines for {{X_KEY}} (work limited to $XP_VIEW)
#   start | stop | restart         engine control, same steps as the web panel
#   pause | resume                 fw.sh clean / apply only; settings are unchanged
#   mode:rule|global|direct        runtime outbound mode (reset on engine restart)
#   strat:auto|balance|fallback|direct   strategy of 🚀 节点选择
#   pick:<sig>:<n>                 use node n of the cached node list <sig>
#   test                           latency test of the whole group
#   s1:off|white|all               terminal proxy scope   (persistent)
#   s2:on|off                      proxy the router itself (persistent)
#   dev:<sig>:<n>                  toggle device n in the whitelist (persistent)
#   boot:on|off                    小海关 autostart        (persistent)
#   subup                          refresh subscription providers
# Persistent changes edit only the matching lines of config.json (written by the
# web panel with JSON.stringify(..., 2)), validate the result with jsonfilter,
# keep config.json.bak, then patch the same variables the web panel would emit
# into fw.sh (ALLMODE, S2, WMACS, IPS) and start.sh (HS_TAKEOVER) and re-apply.

D=${XP_CUSTOMS_DIR:-/data/plugins/customs}
RUN=${XP_RUN_DIR:-/tmp/devui-x}
BOOT=${XP_BOOT_FILE:-/data/plugins/ufi_tools_boot.sh}
VIEW=${XP_VIEW:-main}
CFG=$D/config.json
NODES=$RUN/customs.nodes
DEVS=$RUN/customs.devs
DELAY=$RUN/customs.delay
VERF=$RUN/customs.ver
TRAF=$RUN/customs.traffic
LEASES=${XP_LEASES:-/tmp/dhcp.leases}
APIF=$RUN/customs.api
PER=5
G_MAIN='🚀 节点选择'
G_MAIN_ENC='%F0%9F%9A%80%20%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9'
S_AUTO='♻️ 自动选优'
S_AUTO_ENC='%E2%99%BB%EF%B8%8F%20%E8%87%AA%E5%8A%A8%E9%80%89%E4%BC%98'
S_BAL='⚖️ 负载均衡'
S_FAIL='🪜 故障转移'
S_FAIL_ENC='%F0%9F%AA%9C%20%E6%95%85%E9%9A%9C%E8%BD%AC%E7%A7%BB'
TEST_URL='https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'
BOOT_LINE="[ -f $D/start.sh ] && sh $D/start.sh # plugins/customs"
TAB=$(printf '\t')

mkdir -p "$RUN" 2>/dev/null

yaml_val() { sed -n "s/^$1:[[:space:]]*//p" "$D/config.yaml" 2>/dev/null | head -n 1 | sed "s/^[\"']//; s/[\"'][[:space:]]*$//"; }
PORT=$(sed -n 's/^external-controller:[[:space:]]*[^:]*:\([0-9][0-9]*\).*/\1/p' "$D/config.yaml" 2>/dev/null | head -n 1)
PORT=${PORT:-9090}
SECRET=$(yaml_val secret)
API="http://127.0.0.1:$PORT"

api() { # METHOD PATH [JSON] [TIMEOUT]
    if [ -n "$3" ]; then
        curl -s -m "${4:-3}" -X "$1" -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "$3" "$API$2" 2>/dev/null
    else
        curl -s -m "${4:-3}" -X "$1" -H "Authorization: Bearer $SECRET" "$API$2" 2>/dev/null
    fi
}
api_code() { # METHOD PATH [JSON] [TIMEOUT] -> http status
    if [ -n "$3" ]; then
        curl -s -m "${4:-5}" -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: Bearer $SECRET" \
            -H 'Content-Type: application/json' -d "$3" "$API$2" 2>/dev/null
    else
        curl -s -m "${4:-5}" -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: Bearer $SECRET" "$API$2" 2>/dev/null
    fi
}
jf() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
cfg() { jsonfilter -i "$CFG" -e "@.$1" 2>/dev/null; }
engine_pids() {
    for P in $(pidof mihomo 2>/dev/null); do
        [ "$(readlink "/proc/$P/exe" 2>/dev/null)" = "$D/mihomo" ] && printf '%s ' "$P"
    done
}
running() { [ -n "$(engine_pids)" ]; }
api_up() { [ "$(cat "$APIF" 2>/dev/null)" = 1 ]; }
fw_mounted() {
    { iptables -t nat -S PREROUTING 2>/dev/null; iptables -t nat -S OUTPUT 2>/dev/null; } | grep -q -- '-j HS_'
}
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
hesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
list_sig() { md5sum < "$1" 2>/dev/null | cut -c1-10; }
hms() { s=$1; h=$((s / 3600)); m=$((s % 3600 / 60))
    if [ "$h" -ge 24 ]; then echo "$((h / 24))天$((h % 24))时"; elif [ "$h" -gt 0 ]; then echo "${h}时${m}分"; else echo "${m}分"; fi; }
human() { awk -v b="${1:-0}" -v u="$2" 'BEGIN { s = "B"; if (b >= 1073741824) { b /= 1073741824; s = "GB" } else if (b >= 1048576) { b /= 1048576; s = "MB" } else if (b >= 1024) { b /= 1024; s = "KB" }; printf((b >= 100 || s == "B") ? "%.0f %s%s" : "%.1f %s%s", b, s, u) }'; }
short_strat() {
    case "$1" in
        "$S_AUTO") echo 自动选优 ;; "$S_BAL") echo 负载均衡 ;; "$S_FAIL") echo 故障转移 ;;
        DIRECT) echo 直连 ;; *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------- config.json ---
cfg_commit() { # validate $CFG.devui and replace config.json (keeps .bak)
    if [ -s "$CFG.devui" ] && jsonfilter -i "$CFG.devui" -e '@.s1' >/dev/null 2>&1; then
        cp -f "$CFG" "$CFG.bak" 2>/dev/null
        mv -f "$CFG.devui" "$CFG" && return 0
    fi
    rm -f "$CFG.devui"
    echo "写入配置失败（$1），未做改动"
    return 1
}
# Replace the value of a top-level key ("  \"key\": value,"); JSON value given raw.
cfg_set() {
    [ -f "$CFG" ] || { echo "未找到小海关配置"; return 1; }
    grep -q "^  \"$1\": .*,\$" "$CFG" || { echo "配置格式不支持（$1），请在网页端修改"; return 1; }
    sed "s/^  \"$1\": .*,\$/  \"$1\": $2,/" "$CFG" > "$CFG.devui"
    cfg_commit "$1"
}
# devices in config.json -> MAC \t ip \t name \t proxy(1/0)
devices_tsv() {
    awk -v T="$TAB" '
        function val(s) { sub(/^[^:]*: "/, "", s); sub(/",?$/, "", s); gsub(/\\"/, "\"", s); return s }
        /^  "devices": \[\],?$/ { exit }
        /^  "devices": \[$/ { indev = 1; next }
        !indev { next }
        /^  \],?$/ { exit }
        /^    [{]$/ { mac = ""; ip = ""; name = ""; host = ""; px = 0; next }
        /^      "mac": "/ { mac = val($0) }
        /^      "ip": "/ { ip = val($0) }
        /^      "name": "/ { name = val($0) }
        /^      "host": "/ { host = val($0) }
        /^      "proxy": true/ { px = 1 }
        /^    [}],?$/ { if (mac != "") print toupper(mac) T ip T (name != "" ? name : host) T px }
    ' "$CFG" 2>/dev/null
}
# set the proxy flag of MAC; insert the device when it is not listed yet
dev_set() { # MAC true|false IP NAME
    awk -v T="$1" -v V="$2" -v NIP="$3" -v NNAME="$4" '
        { L[++n] = $0 }
        END {
            for (i = 1; i <= n; i++) {
                if (L[i] ~ /^  "devices": \[\],?$/) { s = i; empty = 1; break }
                if (L[i] ~ /^  "devices": \[$/) { s = i; break }
            }
            if (!s) exit 3
            if (!empty) { for (i = s + 1; i <= n; i++) if (L[i] ~ /^  \],?$/) { e = i; break }; if (!e) exit 3 }
            if (!empty) for (i = s + 1; i < e; i++) {
                if (L[i] !~ /^    [{]$/) continue
                oe = 0; ml = 0; pl = 0; m = ""
                for (j = i; j < e; j++) if (L[j] ~ /^    [}],?$/) { oe = j; break }
                if (!oe) exit 3
                for (k = i; k <= oe; k++) {
                    if (L[k] ~ /^      "mac": "/) { m = L[k]; sub(/^      "mac": "/, "", m); sub(/",?$/, "", m); ml = k }
                    if (L[k] ~ /^      "proxy": /) pl = k
                }
                if (toupper(m) == toupper(T)) {
                    found = 1
                    if (pl) L[pl] = "      \"proxy\": " V (L[pl] ~ /,$/ ? "," : "")
                    else if (ml) {
                        if (L[ml] ~ /,$/) after[ml] = "      \"proxy\": " V ","
                        else { L[ml] = L[ml] ","; after[ml] = "      \"proxy\": " V }
                    } else exit 3
                }
                i = oe
            }
            if (!found) {
                if (NIP == "") exit 4
                obj = "    {\n      \"ip\": \"" NIP "\",\n      \"mac\": \"" toupper(T) "\",\n      \"host\": \"\",\n      \"name\": \"" NNAME "\",\n      \"proxy\": " V ",\n      \"line\": \"\",\n      \"online\": true\n    }"
                if (empty) L[s] = "  \"devices\": [\n" obj "\n  ]" (L[s] ~ /,$/ ? "," : "")
                else { if (L[e - 1] ~ /^    [}]$/) L[e - 1] = "    },"; L[e - 1] = L[e - 1] "\n" obj }
            }
            for (i = 1; i <= n; i++) { print L[i]; if (i in after) print after[i] }
        }' "$CFG" > "$CFG.devui" || { rm -f "$CFG.devui"; echo "设备列表格式不支持，请在网页端修改"; return 1; }
    cfg_commit devices
}

# Patch the variables fw.sh / start.sh take from config (as the web panel's
# generator would) and re-apply when the engine runs.
regen_fw() {
    [ -f "$D/fw.sh" ] && [ -f "$D/start.sh" ] || { echo "缺少 fw.sh/start.sh，请先在网页端启动一次"; return 1; }
    for k in '^ALLMODE=' '^S2=' '^WMACS="' '^IPS="'; do
        grep -q "$k" "$D/fw.sh" || { echo "fw.sh 版本不匹配，请在网页端操作一次"; return 1; }
    done
    s1=$(cfg s1); s2=$(cfg s2); bm=$(cfg bootMode)
    W=$(devices_tsv | awk -F "$TAB" '$4 == 1 && length($1) == 17 && $1 ~ /^([0-9A-F][0-9A-F]:)+[0-9A-F][0-9A-F]$/ { printf "%s%s", sep, tolower($1); sep = " " }')
    I=""
    [ "$s1" = white ] && I=$(devices_tsv | awk -F "$TAB" '$4 == 1 && $2 ~ /^[0-9a-fA-F.:]+$/ { printf "%s%s", sep, $2; sep = " " }')
    A=0; [ "$s1" = all ] && A=1
    S=0; [ "$s2" = true ] && S=1
    TK=1; { [ "$s1" = off ] && [ "$s2" != true ]; } && TK=0; [ "$bm" = core ] && TK=0
    sed -i -e "s/^ALLMODE=.*/ALLMODE=$A/" -e "s/^S2=.*/S2=$S/" \
        -e "s/^WMACS=\".*\"\$/WMACS=\"$W\"/" -e "s/^IPS=\".*\"\$/IPS=\"$I\"/" "$D/fw.sh"
    sed -i "s/^HS_TAKEOVER=.*/HS_TAKEOVER=$TK/" "$D/start.sh"
    running || return 0
    if [ "$s1" != off ] || [ "$s2" = true ]; then sh "$D/fw.sh" apply >/dev/null 2>&1
    else sh "$D/fw.sh" clean >/dev/null 2>&1; fi
    return 0
}
s2_timer_stop() {
    P=$(cat "$D/.s2timer.pid" 2>/dev/null); [ -n "$P" ] && kill "$P" 2>/dev/null
    rm -f "$D/.s2timer.pid" "$D/.s2expired"
}
s2_timer_start() {
    keep=$(cfg s2Keep); case "$keep" in ''|*[!0-9]*) keep=0 ;; esac
    s2_timer_stop
    [ "$keep" -gt 0 ] || return 0
    nohup sh -c "sleep $((keep * 60)); while iptables -t nat -D OUTPUT -j HS_OUT 2>/dev/null; do :; done; date +%s > $D/.s2expired" >/dev/null 2>&1 &
    echo $! > "$D/.s2timer.pid"
}

# ------------------------------------------------------------- status ---
st_common() {
    if [ ! -x "$D/mihomo" ]; then
        echo "INSTALLED=0"; echo "RUN=0"; echo "INTERVAL=10"
        echo "STATE=未安装"; echo "STATECLASS=muted"; echo "HEADLINE=未检测到小海关"
        echo "SUBLINE=请先在 UFI-TOOLS 网页安装小海关插件与内核"
        return 1
    fi
    echo "INSTALLED=1"
    s1=$(cfg s1); s2=$(cfg s2)
    WN=$(devices_tsv | awk -F "$TAB" '$4 == 1' | grep -c '')
    case "$s1" in all) take="全部终端" ;; white) take="白名单 ${WN} 台" ;; *) take="不接管终端" ;; esac
    [ "$s2" = true ] && take="$take + 本机"
    echo "TAKE=$take"
    case "$s1" in all) echo "S1_ALL=seg-on" ;; white) echo "S1_WHITE=seg-on" ;; *) echo "S1_OFF=seg-on" ;; esac
    if [ "$s2" = true ]; then echo "S2CLASS=on"; echo "S2NEXT=off"; else echo "S2CLASS=off"; echo "S2NEXT=on"; fi
    want_fw=0; { [ "$s1" = all ] || [ "$s1" = white ] || [ "$s2" = true ]; } && want_fw=1
    pids=$(engine_pids); pid=${pids%% *}
    if [ -z "$pid" ]; then
        echo "RUN=0"; echo "INTERVAL=5"
        echo "STATE=已停止"; echo "STATECLASS=muted"; echo "HEADLINE=引擎已停止"
        echo "SUBLINE=终端直连上网 · 点「启动引擎」恢复代理"
        echo "PRIMARY_HREF=act:x:start"; echo "PRIMARY_LABEL=启动引擎"; echo "PRIMARY_CLASS=svc-primary"
        echo "RESTART_CLASS=disabled"; echo "PAUSE_HREF=act:x:refresh"; echo "PAUSE_LABEL=暂停接管"; echo "PAUSE_CLASS=disabled"
        echo "MODE=—"
        return 0
    fi
    echo "RUN=1"; echo "INTERVAL=3"
    rss=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$pid/status" 2>/dev/null)
    [ -n "$rss" ] && echo "RSS=$((rss / 1024)) MB"
    st=$(cut -d' ' -f22 "/proc/$pid/stat" 2>/dev/null); ut=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    up=""; [ -n "$st" ] && [ -n "$ut" ] && up=$(hms $((ut - st / 100)))
    if [ -f "$VERF" ] && [ "$(sed -n 1p "$VERF")" = "$pid" ]; then ver=$(sed -n 2p "$VERF")
    else ver=$(jf "$(api GET /version)" '@.version'); [ -n "$ver" ] && printf '%s\n%s\n' "$pid" "$ver" > "$VERF"; fi
    mode=$(jf "$(api GET /configs)" '@.mode')
    echo "PRIMARY_HREF=act:xc:stop"; echo "PRIMARY_LABEL=停止引擎"; echo "PRIMARY_CLASS="; echo "RESTART_CLASS="
    if [ -z "$mode" ]; then
        echo "STATE=无响应"; echo "STATECLASS=bad"; echo "HEADLINE=控制接口无响应"
        echo "SUBLINE=进程在运行但 $PORT 端口未应答，可尝试重启引擎"; echo "MODE=—"
        echo "PAUSE_HREF=act:x:refresh"; echo "PAUSE_LABEL=暂停接管"; echo "PAUSE_CLASS=disabled"
        return 0
    fi
    case "$mode" in rule) echo "MODE=规则"; echo "M_RULE=seg-on" ;; global) echo "MODE=全局"; echo "M_GLOBAL=seg-on" ;;
        direct) echo "MODE=直连"; echo "M_DIRECT=seg-on" ;; *) echo "MODE=$mode" ;; esac
    if fw_mounted; then
        echo "STATE=代理中"; echo "STATECLASS=ok"; echo "HEADLINE=终端流量已接管"
        echo "PAUSE_HREF=act:xc:pause"; echo "PAUSE_LABEL=暂停接管"; echo "PAUSE_CLASS="
    elif [ "$want_fw" = 1 ]; then
        echo "STATE=已暂停"; echo "STATECLASS=warn"; echo "HEADLINE=接管已暂停"
        echo "PAUSE_HREF=act:x:resume"; echo "PAUSE_LABEL=恢复接管"; echo "PAUSE_CLASS=svc-primary"
    else
        echo "STATE=运行中"; echo "STATECLASS=ok"; echo "HEADLINE=引擎运行中"
        echo "PAUSE_HREF=act:x:refresh"; echo "PAUSE_LABEL=暂停接管"; echo "PAUSE_CLASS=disabled"
    fi
    echo "SUBLINE=${ver:-mihomo}${up:+ · 已运行 $up}"
    return 0
}

# current selection of 🚀 节点选择 -> STRAT / NOWNODE / NOWDELAY / S_* ; sets $grp $eff
group_now() {
    grp=$(api GET "/proxies/$G_MAIN_ENC")
    now=$(jf "$grp" '@.now')
    [ -n "$now" ] || return 1
    eff="$now"; label="手动"
    case "$now" in
        "$S_AUTO") label=自动选优; eff=$(jf "$(api GET "/proxies/$S_AUTO_ENC")" '@.now'); echo "S_AUTO=seg-on" ;;
        "$S_BAL") label=负载均衡; eff=""; echo "S_BALANCE=seg-on" ;;
        "$S_FAIL") label=故障转移; eff=$(jf "$(api GET "/proxies/$S_FAIL_ENC")" '@.now'); echo "S_FALLBACK=seg-on" ;;
        DIRECT) label=直连; eff=""; echo "S_DIRECT=seg-on" ;;
    esac
    echo "STRAT=$label"
    echo "NOWNODE=${eff:-$label}"
    d=""; [ -n "$eff" ] && [ -s "$DELAY" ] && d=$(awk -F "$TAB" -v n="$eff" '$2 == n { print $1; exit }' "$DELAY")
    case "$d" in ''|0) echo "NOWDELAY=" ;; *) echo "NOWDELAY=${d}ms" ;; esac
    return 0
}

st_main() {
    api_up || return 0
    group_now > "$RUN/customs.grp" && grep -E '^(STRAT|NOWNODE|NOWDELAY)=' "$RUN/customs.grp"
    api GET /connections "" 4 > "$RUN/customs.conn.json"
    if [ -s "$RUN/customs.conn.json" ]; then
        dn=$(jsonfilter -i "$RUN/customs.conn.json" -e '@.downloadTotal' 2>/dev/null); dn=${dn:-0}
        upb=$(jsonfilter -i "$RUN/customs.conn.json" -e '@.uploadTotal' 2>/dev/null); upb=${upb:-0}
        echo "CONNS=$(jsonfilter -i "$RUN/customs.conn.json" -e '@.connections[*].id' 2>/dev/null | grep -c '')"
        t=$(date +%s)
        if [ -f "$TRAF" ] && read -r pt pd pu < "$TRAF" && [ "$t" -gt "$pt" ] 2>/dev/null; then
            dt=$((t - pt)); rd=$(( (dn - pd) / dt )); ru=$(( (upb - pu) / dt ))
            [ "$rd" -lt 0 ] && rd=0; [ "$ru" -lt 0 ] && ru=0
            echo "SPEED_DOWN=$(human "$rd" /s)"; echo "SPEED_UP=$(human "$ru" /s)"
        else
            echo "SPEED_DOWN=…"; echo "SPEED_UP=…"
        fi
        echo "$t $dn $upb" > "$TRAF"
        echo "TOTAL=↓$(human "$dn") ↑$(human "$upb")"
    fi
    rm -f "$RUN/customs.conn.json"
}

st_nodes() {
    api_up || { echo "NODES_HTML=<div class='xempty'>引擎未运行，启动后才能切换节点</div>"; return 0; }
    if [ "$(cfg policySrc)" = direct ]; then
        echo "NODES_HTML=<div class='xempty'>订阅直通模式：请在网页端的订阅分组内切换节点</div>"
        return 0
    fi
    group_now > "$RUN/customs.grp" || { echo "NODES_HTML=<div class='xempty'>当前配置没有可切换的节点组</div>"; return 0; }
    cat "$RUN/customs.grp"
    jf "$grp" '@.all[*]' | grep -v -x -e "$S_AUTO" -e "$S_BAL" -e "$S_FAIL" -e DIRECT -e REJECT -e REJECT-DROP -e PASS > "$NODES.tmp"
    mv -f "$NODES.tmp" "$NODES"
    total=$(grep -c '' "$NODES" 2>/dev/null); total=${total:-0}
    if [ "$total" -le 0 ]; then echo "NODES_HTML=<div class='xempty'>订阅里还没有节点</div>"; return 0; fi
    idx=$(grep -n -x -F -e "$eff" "$NODES" 2>/dev/null | head -n 1 | cut -d: -f1)
    echo "PAGES_NODES=$(( (total + PER - 1) / PER ))"
    echo "CURPAGE_NODES=$(( (${idx:-1} - 1) / PER + 1 ))"
    echo "NODECOUNT=$total"
    [ -s "$DELAY" ] || printf '#\t#\n' > "$DELAY"
    rows=$(EFF="$eff" SIG="$(list_sig "$NODES")" PER="$PER" awk -F "$TAB" '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        FNR == NR { d[$2] = $1; next }
        {
            n = $0; i = FNR; per = ENVIRON["PER"] + 0
            if ((i - 1) % per == 0) printf "%s<div class=\"xpg xpg-nodes-%d\">", (i > 1 ? "</div>" : ""), (i - 1) / per + 1
            if (n == ENVIRON["EFF"]) { cls = "xrow on"; tag = "<span class=\"xd\">使用中</span>" }
            else {
                cls = "xrow"
                if (!(n in d)) tag = "<span class=\"xd n\">未测</span>"
                else if (d[n] + 0 <= 0) tag = "<span class=\"xd r\">超时</span>"
                else { v = d[n] + 0; tag = "<span class=\"xd " ((v < 300) ? "g" : (v < 800) ? "y" : "r") "\">" v "ms</span>" }
            }
            printf "<a href=\"act:x:pick:%s:%d\" class=\"%s\">%s%s</a>", ENVIRON["SIG"], i, cls, tag, esc(n)
        }
        END { if (FNR > 0 && NR > FNR) printf "</div>" }' "$DELAY" "$NODES")
    echo "NODES_HTML=$rows"
}

st_proxy() {
    s1=$(cfg s1); s2=$(cfg s2)
    case "$s1" in
        all) echo "S1DESC=所有连接本机的设备（包括之后新接入的）都走代理" ;;
        white) echo "S1DESC=只有「设备」里打开开关的设备走代理，现有 $(devices_tsv | awk -F "$TAB" '$4 == 1' | grep -c '') 台" ;;
        *) echo "S1DESC=终端设备不经过小海关，全部直连" ;;
    esac
    if [ "$s2" = true ]; then
        keep=$(cfg s2Keep)
        if [ -f "$D/.s2expired" ]; then echo "S2STATE=限时已到，本机代理已自动断开"
        elif [ "${keep:-0}" -gt 0 ] 2>/dev/null; then echo "S2STATE=已开启 · ${keep} 分钟后自动关闭"
        else echo "S2STATE=已开启 · 路由器自身的流量也走代理"; fi
    else
        echo "S2STATE=已关闭 · 路由器自身流量直连"
    fi
}

st_devices() {
    s1=$(cfg s1)
    removed=$(jsonfilter -i "$CFG" -e '@.removedMacs[*].mac' 2>/dev/null | tr 'a-f' 'A-F')
    neigh=$(ip neigh show 2>/dev/null | awk '$1 !~ /:/ && $4 == "lladdr" && $5 != "00:00:00:00:00:00" { print toupper($5), $1, $6 }')
    devices_tsv > "$DEVS.cfg"
    { cat "$DEVS.cfg"
      printf '%s\n' "$neigh" | while read -r mac ip state; do
        [ -n "$mac" ] || continue
        grep -q "^$mac$TAB" "$DEVS.cfg" && continue
        printf '%s\n' "$removed" | grep -qx "$mac" && continue
        host=$(awk -v m="$mac" 'toupper($2) == m && $4 != "*" { print $4; exit }' "$LEASES" 2>/dev/null)
        printf '%s\t%s\t%s\t0\n' "$mac" "$ip" "${host:-设备_${ip##*.}}"
      done; } > "$DEVS.tmp"
    rm -f "$DEVS.cfg"
    mv -f "$DEVS.tmp" "$DEVS"
    total=$(grep -c '' "$DEVS"); total=${total:-0}
    on=$(awk -F "$TAB" '$4 == 1' "$DEVS" | grep -c '')
    echo "DEVTITLE=走代理 $on / 共 $total 台"
    case "$s1" in
        white) echo "DEVNOTE=点设备即可切换是否走代理，立即生效" ;;
        all) echo "DEVNOTE=当前为「全部终端」：所有设备都走代理，白名单暂不生效" ;;
        *) echo "DEVNOTE=当前「不接管终端」：白名单暂不生效，可到「接管」切换" ;;
    esac
    [ -n "$(jsonfilter -i "$CFG" -e '@.lines[0].id' 2>/dev/null)" ] && echo "DEVNOTE=已配置分设备线路：白名单请在网页端修改"
    [ "$total" -gt 0 ] || { echo "DEV_HTML=<div class='xempty'>还没有发现设备</div>"; return 0; }
    echo "PAGES_DEVICES=$(( (total + PER - 1) / PER ))"
    onl=$(printf '%s\n' "$neigh" | awk '$3 ~ /REACHABLE|DELAY|PROBE|PERMANENT/ { print $1 }' | tr '\n' ' ')
    rows=$(SIG="$(list_sig "$DEVS")" PER="$PER" ONL=" $onl " awk -F "$TAB" '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
        {
            i = NR; per = ENVIRON["PER"] + 0
            if ((i - 1) % per == 0) printf "%s<div class=\"xpg xpg-devices-%d\">", (i > 1 ? "</div>" : ""), (i - 1) / per + 1
            online = index(ENVIRON["ONL"], " " $1 " ") > 0
            printf "<a href=\"act:x:dev:%s:%d\" class=\"xdev\"><span class=\"sw %s\"><span class=\"sw-track\"></span><span class=\"kn\"></span></span><span class=\"xdn\">%s</span><span class=\"xdi\">%s%s</span></a>", ENVIRON["SIG"], i, ($4 == 1 ? "on" : "off"), esc($3), esc($2), (online ? " · 在线" : "")
        }
        END { if (NR > 0) printf "</div>" }' "$DEVS")
    echo "DEV_HTML=$rows"
}

st_more() {
    if grep -qF "$BOOT_LINE" "$BOOT" 2>/dev/null; then echo "BOOTCLASS=on"; echo "BOOTNEXT=off"; echo "BOOTSTATE=开机后自动启动小海关"
    else echo "BOOTCLASS=off"; echo "BOOTNEXT=on"; echo "BOOTSTATE=开机不自动启动"; fi
    learned=$(sed -n 's/.*learned=\([0-9]*\).*/\1/p' "$D/learn.state" 2>/dev/null)
    case "$(cfg learnMode)" in on) lmt="进化中" ;; observe) lmt="只学习" ;; *) lmt="已关闭" ;; esac
    echo "LEARN=$lmt · 已直连 ${learned:-0} 个网站"
    echo "PLUGINVER=$(cfg ver)"
    api_up || { echo "SUB_HTML=<div class='xempty'>引擎未运行，无法读取订阅信息</div>"; return 0; }
    now=$(date +%s); html=""; i=0
    while [ $i -lt 10 ]; do
        if [ -n "$(cfg "subs[$i].url")" ]; then
            name=$(cfg "subs[$i].name"); [ -n "$name" ] || name="订阅 $((i + 1))"
            pj=$(api GET "/providers/proxies/sub$i")
            u=$(jf "$pj" '@.subscriptionInfo.Upload'); dl=$(jf "$pj" '@.subscriptionInfo.Download')
            tot=$(jf "$pj" '@.subscriptionInfo.Total'); exp=$(jf "$pj" '@.subscriptionInfo.Expire')
            line="$(jf "$pj" '@.proxies[*].name' | grep -c '') 个节点"
            case "$tot" in ''|0) ;; *) line="$line · 已用 $(human $(( ${u:-0} + ${dl:-0} ))) / $(human "$tot")" ;; esac
            case "$exp" in ''|0) ;; *) left=$(( (exp - now) / 86400 )); if [ "$left" -ge 0 ]; then line="$line · 剩 $left 天"; else line="$line · 已过期"; fi ;; esac
            html="$html<div class=\"xsub\"><span class=\"xsn\">$(hesc "$name")</span><span class=\"xsi\">$(hesc "$line")</span></div>"
        fi
        i=$((i + 1))
    done
    [ -n "$html" ] || html="<div class='xempty'>还没有订阅</div>"
    echo "SUB_HTML=$html"
}

# ------------------------------------------------------------ actions ---
need_engine() { running || { echo "引擎未运行"; exit 1; }; }

do_stop() {
    sh "$D/fw.sh" clean >/dev/null 2>&1
    [ -f "$D/learn.sh" ] && sh "$D/learn.sh" stop >/dev/null 2>&1
    for P in $(engine_pids); do kill "$P" 2>/dev/null; done
    i=0; while running && [ $i -lt 6 ]; do sleep 1; i=$((i + 1)); done
    for P in $(engine_pids); do kill -9 "$P" 2>/dev/null; done
    redir=$(yaml_val redir-port)
    case "$redir" in ''|*[!0-9]*) ;; *) command -v conntrack >/dev/null 2>&1 && conntrack -D --dport "$redir" >/dev/null 2>&1 ;; esac
    ! running
}

do_start() {
    [ -x "$D/mihomo" ] || { echo "未安装小海关内核"; exit 1; }
    [ -f "$D/start.sh" ] || { echo "缺少启动脚本，请先在网页端启动一次"; exit 1; }
    running && { echo "引擎已在运行"; return 0; }
    sh "$D/start.sh" >/dev/null 2>&1
    i=0
    while [ $i -lt 20 ]; do
        running && [ "$(api_code GET /version)" = 200 ] && return 0
        sleep 1; i=$((i + 1))
    done
    sh "$D/fw.sh" clean >/dev/null 2>&1
    echo "启动失败，已恢复终端直连"; exit 1
}

set_strat_cfg() { # mode pausedAuto
    [ -f "$CFG" ] || return 0
    sed -i "s/^  \"mode\": \"[a-z]*\",\$/  \"mode\": \"$1\",/; s/^  \"pausedAuto\": [a-z]*,\$/  \"pausedAuto\": $2,/" "$CFG" 2>/dev/null
}

case "$1" in
    status)
        if [ -x "$D/mihomo" ] && running && [ "$(api_code GET /version "" 2)" = 200 ]; then echo 1 > "$APIF"; else echo 0 > "$APIF"; fi
        st_common || exit 0
        case "$VIEW" in nodes) st_nodes ;; proxy) st_proxy ;; devices) st_devices ;; more) st_more ;; *) st_main ;; esac ;;
    refresh) echo "已刷新" ;;
    start) do_start; echo "引擎已启动" ;;
    stop) if do_stop; then echo "已停止，终端恢复直连"; else echo "停止失败，请重试"; exit 1; fi ;;
    restart) do_stop || { echo "停止失败，请重试"; exit 1; }; sleep 1; do_start; echo "引擎已重启" ;;
    pause)
        need_engine; sh "$D/fw.sh" clean >/dev/null 2>&1
        if fw_mounted; then echo "仍有接管规则残留"; exit 1; fi
        echo "已暂停接管，终端临时直连" ;;
    resume)
        need_engine
        out=$(sh "$D/fw.sh" apply 2>&1)
        if fw_mounted; then echo "已恢复接管"; else echo "恢复失败：$(printf '%s' "$out" | sed -n '/[^[:space:]]/{p;q;}')"; exit 1; fi ;;
    mode:rule|mode:global|mode:direct)
        need_engine; m=${1#mode:}
        c=$(api_code PATCH /configs "{\"mode\":\"$m\"}")
        case "$c" in 200|204) ;; *) echo "切换失败（HTTP $c）"; exit 1 ;; esac
        case "$m" in rule) echo "已切换：规则模式" ;; global) echo "已切换：全局（重启引擎后回到规则）" ;; direct) echo "已切换：直连（重启引擎后回到规则）" ;; esac ;;
    strat:auto|strat:balance|strat:fallback|strat:direct)
        need_engine
        case "${1#strat:}" in
            auto) n="$S_AUTO"; cm=auto; pa=false ;; balance) n="$S_BAL"; cm=balance; pa=false ;;
            fallback) n="$S_FAIL"; cm=fallback; pa=false ;; direct) n=DIRECT; cm=manual; pa=true ;;
        esac
        c=$(api_code PUT "/proxies/$G_MAIN_ENC" "{\"name\":\"$(json_esc "$n")\"}")
        case "$c" in 200|204) set_strat_cfg "$cm" "$pa"; echo "已切换：$(short_strat "$n")" ;; *) echo "切换失败（HTTP $c）"; exit 1 ;; esac ;;
    pick:*)
        need_engine
        rest=${1#pick:}; want=${rest%%:*}; n=${rest#*:}
        case "$n" in ''|*[!0-9]*) echo "无效的节点"; exit 1 ;; esac
        case "$want" in ''|*[!0-9a-f]*) echo "无效的节点"; exit 1 ;; esac
        [ -s "$NODES" ] && [ "$(list_sig "$NODES")" = "$want" ] || { echo "节点列表已变化，请重选"; exit 1; }
        name=$(sed -n "${n}p" "$NODES")
        [ -n "$name" ] || { echo "无效的节点"; exit 1; }
        c=$(api_code PUT "/proxies/$G_MAIN_ENC" "{\"name\":\"$(json_esc "$name")\"}")
        case "$c" in 200|204) set_strat_cfg manual true; echo "已切换：$name" ;; *) echo "切换失败（HTTP $c）"; exit 1 ;; esac ;;
    test)
        need_engine
        r=$(api GET "/group/$G_MAIN_ENC/delay?url=$TEST_URL&timeout=2500" "" 20)
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
    s1:off|s1:white|s1:all)
        v=${1#s1:}
        [ "$(cfg s1)" = "$v" ] && { echo "已经是该模式"; exit 0; }
        cfg_set s1 "\"$v\"" || exit 1
        regen_fw || exit 1
        case "$v" in
            all) echo "已切换：全部终端走代理" ;;
            white) n=$(devices_tsv | awk -F "$TAB" '$4 == 1' | grep -c '')
                   if [ "$n" -gt 0 ]; then echo "已切换：白名单（$n 台）"; else echo "已切换：白名单（还没有设备，去「设备」添加）"; fi ;;
            *) echo "已切换：不接管终端" ;;
        esac ;;
    s2:on|s2:off)
        if [ "$1" = s2:on ]; then cfg_set s2 true || exit 1; s2_timer_start
        else cfg_set s2 false || exit 1; s2_timer_stop; fi
        regen_fw || exit 1
        if [ "$1" = s2:on ]; then echo "本机代理已开启"; else echo "本机代理已关闭"; fi ;;
    dev:*)
        rest=${1#dev:}; want=${rest%%:*}; n=${rest#*:}
        case "$n" in ''|*[!0-9]*) echo "无效的设备"; exit 1 ;; esac
        case "$want" in ''|*[!0-9a-f]*) echo "无效的设备"; exit 1 ;; esac
        [ -s "$DEVS" ] && [ "$(list_sig "$DEVS")" = "$want" ] || { echo "设备列表已变化，请重试"; exit 1; }
        [ -n "$(jsonfilter -i "$CFG" -e '@.lines[0].id' 2>/dev/null)" ] && { echo "已配置分设备线路，请在网页端修改白名单"; exit 1; }
        row=$(sed -n "${n}p" "$DEVS")
        [ -n "$row" ] || { echo "无效的设备"; exit 1; }
        mac=$(printf '%s\n' "$row" | cut -f1); ip=$(printf '%s\n' "$row" | cut -f2)
        name=$(printf '%s\n' "$row" | cut -f3); px=$(printf '%s\n' "$row" | cut -f4)
        case "$mac" in [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) ;; *) echo "设备地址无效"; exit 1 ;; esac
        case "$ip" in *[!0-9.]*) ip="" ;; esac
        nv=true; [ "$px" = 1 ] && nv=false
        safe=$(printf '%s' "$name" | tr -d '"\\' | cut -c1-48)
        dev_set "$mac" "$nv" "$ip" "$safe" || exit 1
        regen_fw || exit 1
        if [ "$nv" = true ]; then msg="已加入白名单：$name"; else msg="已移出白名单：$name"; fi
        [ "$(cfg s1)" = white ] || msg="$msg（当前不是白名单模式）"
        echo "$msg" ;;
    boot:on|boot:off)
        if [ "$1" = boot:on ]; then
            mkdir -p "$(dirname "$BOOT")"
            [ -f "$BOOT" ] || printf '#!/bin/sh\n' > "$BOOT"
            grep -qF "$BOOT_LINE" "$BOOT" || printf '%s\n' "$BOOT_LINE" >> "$BOOT"
            chmod 700 "$BOOT"; cfg_set autostart true >/dev/null
            echo "已开启小海关开机自启"
        else
            [ -f "$BOOT" ] && sed -i '\|plugins/customs|d' "$BOOT"
            cfg_set autostart false >/dev/null
            echo "已关闭小海关开机自启"
        fi ;;
    subup)
        need_engine
        i=0; okn=0; bad=0
        while [ $i -lt 10 ]; do
            if [ -n "$(cfg "subs[$i].url")" ]; then
                c=$(api_code PUT "/providers/proxies/sub$i" "" 40)
                case "$c" in 200|204) okn=$((okn + 1)) ;; *) bad=$((bad + 1)) ;; esac
            fi
            i=$((i + 1))
        done
        [ $((okn + bad)) -gt 0 ] || { echo "还没有订阅"; exit 1; }
        if [ "$bad" -eq 0 ]; then echo "订阅已更新（$okn 个）"; else echo "更新完成 $okn 个，失败 $bad 个"; exit 1; fi ;;
    *) echo "未知操作：$1"; exit 2 ;;
esac
