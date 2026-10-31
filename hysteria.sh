#!/usr/bin/env bash
#
#  Hysteria 2 一键安装脚本 · Alpine Linux 优化版（安全加固）
#  ------------------------------------------------------------------
#  基于 MisakaNo(https://github.com/Misaka-blog) 原脚本思路重写
#  适配 Alpine Linux / BusyBox，低内存环境可用
#
#  与旧版相比的关键改动：
#    1. 内核二进制下载后强制校验 SHA256（官方 hashes.txt），校验失败拒绝安装
#    2. 私钥 / 配置 / 客户端文件权限收紧为 600，目录 700
#    3. 不再使用 GitHub API（避免限流导致安装失败），改用 releases/latest/download
#    4. 去掉 curl -k，恢复 TLS 校验
#    5. 端口 / 密码 / 域名全部做输入校验，配置文件改为整体重写（不再用 sed 拼接）
#    6. 自动识别 CPU 架构（amd64 / arm64 / arm / 386 / loong64 / riscv64 ...）
#    7. Alpine 上自动注册 OpenRC 服务并开机自启；无 OpenRC 时回退 nohup
#    8. 修改端口 / 密码后自动同步服务端、客户端与分享链接，不再出现配置不一致
#
set -o pipefail

SCRIPT_VERSION="1.1.0"
UPSTREAM_REPO="apernet/hysteria"
DL_BASE="https://github.com/${UPSTREAM_REPO}/releases/latest/download"

CONF_DIR="/etc/hysteria"
CLIENT_DIR="/root/hy"
NODE_CONF="${CONF_DIR}/node.conf"
BIN="/usr/local/bin/hysteria"
PIDFILE="/run/hysteria.pid"
LOGFILE="/var/log/hysteria.log"
INIT_FILE="/etc/init.d/hysteria"

# ---------- 输出 ----------
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    BLUE=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=; GREEN=; YELLOW=; BLUE=; BOLD=; NC=
fi

info() { printf '%s[i]%s %s\n' "$BLUE"   "$NC" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN"  "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED"    "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

ask() { # ask 变量名 "提示" [默认值]
    local __var="$1" __prompt="$2" __def="${3-}" __ans=""
    if [ -n "$__def" ]; then
        printf '%s [%s]: ' "$__prompt" "$__def" >&2
    else
        printf '%s: ' "$__prompt" >&2
    fi
    IFS= read -r __ans || __ans=""
    [ -z "$__ans" ] && __ans="$__def"
    printf -v "$__var" '%s' "$__ans"
}

confirm() { # confirm "提示" -> y/n
    local a=""
    printf '%s [y/N]: ' "$1" >&2
    IFS= read -r a || a=""
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- 基础检测 ----------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 身份运行（当前 UID=$(id -u)）"
}

detect_arch() {
    local m
    m=$(uname -m 2>/dev/null || echo unknown)
    case "$m" in
        x86_64|amd64)        echo amd64   ;;
        aarch64|arm64)       echo arm64   ;;
        armv7l|armv7|armv6l) echo arm     ;;
        i386|i486|i586|i686) echo 386     ;;
        loongarch64)         echo loong64 ;;
        riscv64)             echo riscv64 ;;
        s390x)               echo s390x   ;;
        mipsle)              echo mipsle  ;;
        *)                   echo ""      ;;
    esac
}

# 统一下载入口：优先 curl，没有则用 wget（兼容 Alpine 的 busybox wget）
# 用法：http_get URL [输出文件] [超时秒数]
http_get() {
    local url="$1" out="${2:-}" tmo="${3:-30}"
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$out" ]; then
            curl -fsSL --max-time "$tmo" "$url" -o "$out"
        else
            curl -fsS4 --max-time "$tmo" "$url" 2>/dev/null || curl -fsS6 --max-time "$tmo" "$url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -n "$out" ]; then
            wget -qO "$out" -T "$tmo" "$url"
        else
            wget -qO- -T "$tmo" "$url"
        fi
    else
        return 127
    fi
}

ensure_deps() {
    local missing="" c
    for c in openssl sha256sum; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    # curl 与 wget 至少有一个即可（Alpine 默认只有 busybox wget）
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing="$missing curl"
    fi
    [ -z "$missing" ] && return 0

    info "缺少依赖:$missing，尝试自动安装..."
    if command -v apk >/dev/null 2>&1; then
        local ver main_repo community_repo
        ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "3.21")
        main_repo="https://dl-cdn.alpinelinux.org/alpine/v${ver}/main"
        community_repo="https://dl-cdn.alpinelinux.org/alpine/v${ver}/community"
        touch /etc/apk/repositories
        grep -qxF "$main_repo" /etc/apk/repositories       || echo "$main_repo" >> /etc/apk/repositories
        grep -qxF "$community_repo" /etc/apk/repositories  || echo "$community_repo" >> /etc/apk/repositories
        apk update >/dev/null 2>&1 || warn "apk update 失败，可尝试换源后重试"
        # shellcheck disable=SC2086
        apk add --no-cache $missing || die "依赖安装失败：$missing"
    elif command -v apt-get >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        if ! { apt-get update -qq && apt-get install -y -qq $missing; }; then
            die "依赖安装失败：$missing"
        fi
    elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dnf install -y $missing || die "依赖安装失败：$missing"
    else
        die "未识别的包管理器，请手动安装：$missing"
    fi
    ok "依赖安装完成"
}

# ---------- 输入校验 ----------
valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_pwd() {
    [ "${#1}" -ge 4 ] || return 1
    # 仅允许 ASCII 安全字符：字母、数字与 . _ ~ ! @ # $ % ^ & * + = : , -
    case "$1" in
        *[!A-Za-z0-9._~!@#$%^\&*+=:,-]*) return 1 ;;
    esac
    return 0
}

valid_site() {
    case "$1" in
        ''|*[!A-Za-z0-9.:_-]*) return 1 ;;
    esac
    return 0
}

valid_domain() {
    case "$1" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
    case "$1" in *..*|.*|*.) return 1 ;; esac
    printf '%s' "$1" | grep -q '\.' || return 1
    return 0
}

udp_port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 1
    fi
}

gen_pwd() {
    local p=""
    p=$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)
    [ -n "$p" ] || p=$(date +%s%N | sha256sum | cut -c1-16)
    printf '%s' "$p"
}

urlencode() {
    local s="$1" out="" c i=0
    local LC_ALL=C
    while [ "$i" -lt "${#s}" ]; do
        c=${s:i:1}
        case "$c" in
            [A-Za-z0-9._~-]) out="${out}${c}" ;;
            *) out="${out}$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# ---------- 配置读写 ----------
load_node_conf() {
    [ -f "$NODE_CONF" ] || die "未找到 $NODE_CONF，请先执行安装（菜单 1）"
    # 该文件由本脚本生成、权限 600，格式为 KEY='value'
    # shellcheck disable=SC1090
    . "$NODE_CONF"
}

write_node_conf() {
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    umask 077
    cat > "$NODE_CONF" <<EOF
HY_IP='${HY_IP}'
HY_PORT='${HY_PORT}'
HY_PWD='${HY_PWD}'
HY_SNI='${HY_SNI}'
HY_MASQ='${HY_MASQ}'
HY_CERT='${HY_CERT}'
HY_KEY='${HY_KEY}'
HY_INSECURE='${HY_INSECURE}'
HY_ARCH='${HY_ARCH}'
EOF
    chmod 600 "$NODE_CONF"
}

host_for_url() {
    case "$HY_IP" in *:*) printf '[%s]' "$HY_IP" ;; *) printf '%s' "$HY_IP" ;; esac
}

render_configs() {
    load_node_conf
    local host insecure_flag
    host=$(host_for_url)
    [ "$HY_INSECURE" = "1" ] && insecure_flag="true" || insecure_flag="false"

    umask 077
    cat > "${CONF_DIR}/config.yaml" <<EOF
listen: :${HY_PORT}
tls:
  cert: ${HY_CERT}
  key: ${HY_KEY}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 16777216
auth:
  type: password
  password: '${HY_PWD}'
masquerade:
  type: proxy
  proxy:
    url: https://${HY_MASQ}
    rewriteHost: true
EOF
    chmod 600 "${CONF_DIR}/config.yaml"

    mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"
    cat > "${CLIENT_DIR}/hy-client.yaml" <<EOF
server: ${host}:${HY_PORT}
auth: '${HY_PWD}'
tls:
  sni: ${HY_SNI}
  insecure: ${insecure_flag}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 16777216
fastOpen: true
socks5:
  listen: 127.0.0.1:5080
EOF
    chmod 600 "${CLIENT_DIR}/hy-client.yaml"

    printf 'hysteria2://%s@%s:%s/?insecure=%s&sni=%s#Hysteria2-Alpine\n' \
        "$(urlencode "$HY_PWD")" "$host" "$HY_PORT" "$HY_INSECURE" "$HY_SNI" \
        > "${CLIENT_DIR}/url.txt"
    chmod 600 "${CLIENT_DIR}/url.txt"
}

show_config() {
    [ -f "${CLIENT_DIR}/hy-client.yaml" ] || die "尚未安装，没有可显示的配置"
    hr
    printf '%s客户端配置%s  %s\n' "$BOLD" "$NC" "${CLIENT_DIR}/hy-client.yaml"
    hr
    cat "${CLIENT_DIR}/hy-client.yaml"
    hr
    printf '%s分享链接%s    %s\n' "$BOLD" "$NC" "${CLIENT_DIR}/url.txt"
    hr
    cat "${CLIENT_DIR}/url.txt"
    hr
}

# ---------- 下载与校验 ----------
download_verified() { # download_verified <asset-name> <dest>
    local asset="$1" dest="$2"
    local tmp_bin tmp_hash expect actual size
    tmp_bin=$(mktemp /tmp/hysteria.XXXXXX) || die "无法创建临时文件"
    tmp_hash=$(mktemp /tmp/hashes.XXXXXX) || die "无法创建临时文件"

    info "下载 ${asset} ..."
    if ! wget -qO "$tmp_bin" "${DL_BASE}/${asset}"; then
        rm -f "$tmp_bin" "$tmp_hash"
        die "下载失败。请检查网络，或手动下载后放到 $dest"
    fi

    size=$(wc -c < "$tmp_bin" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000000 ]; then
        rm -f "$tmp_bin" "$tmp_hash"
        die "下载内容异常（仅 ${size} 字节），已中止"
    fi

    if wget -qO "$tmp_hash" "${DL_BASE}/hashes.txt"; then
        expect=$(awk -v a="$asset" '$0 ~ (a "$") {print $1; exit}' "$tmp_hash" | sed 's/^sha256://')
        actual=$(sha256sum "$tmp_bin" | awk '{print $1}')
        if [ "${#expect}" -ne 64 ]; then
            rm -f "$tmp_bin" "$tmp_hash"
            die "校验清单中找不到 ${asset} 的哈希，已中止（如确认可信可设 HY_SKIP_VERIFY=1 重试）"
        fi
        if [ "$expect" != "$actual" ]; then
            rm -f "$tmp_bin" "$tmp_hash"
            die "SHA256 校验失败！
    期望: $expect
    实际: $actual
    为避免安装被篡改的二进制，已中止。"
        fi
        ok "SHA256 校验通过"
    else
        if [ "${HY_SKIP_VERIFY:-0}" = "1" ]; then
            warn "无法获取 hashes.txt，已按 HY_SKIP_VERIFY=1 跳过校验（不建议）"
        else
            rm -f "$tmp_bin" "$tmp_hash"
            die "无法获取官方 hashes.txt，为安全起见已中止（如确认可信可设 HY_SKIP_VERIFY=1 重试）"
        fi
    fi

    mkdir -p "$(dirname "$dest")"
    if ! { cp "$tmp_bin" "$dest" && chmod 755 "$dest"; }; then
        die "写入 $dest 失败"
    fi
    rm -f "$tmp_bin" "$tmp_hash"
}

# ---------- 服务管理 ----------
has_openrc() {
    [ -f /sbin/openrc-run ] && command -v rc-service >/dev/null 2>&1
}

write_init() {
    [ -f "$INIT_FILE" ] && return 0
    cat > "$INIT_FILE" <<'EOF'
#!/sbin/openrc-run
name="hysteria"
description="Hysteria 2 proxy server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "$INIT_FILE"
}

svc_running() {
    if has_openrc && [ -f "$INIT_FILE" ]; then
        rc-service hysteria status >/dev/null 2>&1
        return $?
    fi
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

svc_start() {
    if has_openrc; then
        write_init
        rc-update add hysteria default >/dev/null 2>&1 || true
        rc-service hysteria start >/dev/null 2>&1
        sleep 1
        svc_running || { err "服务启动失败，请查看 $LOGFILE"; return 1; }
    else
        if svc_running; then warn "服务已在运行"; return 0; fi
        : >> "$LOGFILE"
        nohup "$BIN" server -c "${CONF_DIR}/config.yaml" >>"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        sleep 1
        svc_running || { err "服务启动失败，请查看 $LOGFILE"; return 1; }
    fi
    ok "Hysteria 2 已启动"
}

svc_stop() {
    if has_openrc && [ -f "$INIT_FILE" ]; then
        rc-service hysteria stop >/dev/null 2>&1
    fi
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    ok "Hysteria 2 已停止"
}

svc_restart() {
    if has_openrc && [ -f "$INIT_FILE" ]; then
        rc-service hysteria restart >/dev/null 2>&1
        sleep 1
        svc_running || { err "重启失败，请查看 $LOGFILE"; return 1; }
        ok "Hysteria 2 已重启"
    else
        svc_stop >/dev/null
        svc_start
    fi
}

svc_status() {
    hr
    if svc_running; then ok "运行状态：运行中"; else warn "运行状态：未运行"; fi
    if [ -f "$NODE_CONF" ]; then
        load_node_conf
        printf '  监听端口 : %s/udp\n' "$HY_PORT"
        printf '  伪装站点 : https://%s\n' "$HY_MASQ"
        printf '  证书 SNI : %s\n' "$HY_SNI"
    fi
    printf '  配置文件 : %s\n' "${CONF_DIR}/config.yaml"
    printf '  日志文件 : %s\n' "$LOGFILE"
    hr
}

# ---------- 证书 ----------
cert_selfsigned() {
    local d="$CONF_DIR"
    mkdir -p "$d"; chmod 700 "$d"
    openssl ecparam -genkey -name prime256v1 -out "$d/private.key" 2>/dev/null || die "生成私钥失败"
    openssl req -new -x509 -days 3650 -key "$d/private.key" -out "$d/cert.crt" \
        -subj "/CN=www.bing.com" 2>/dev/null || die "生成证书失败"
    chmod 644 "$d/cert.crt"
    chmod 600 "$d/private.key"
    HY_CERT="$d/cert.crt"
    HY_KEY="$d/private.key"
    HY_SNI="www.bing.com"
    HY_INSECURE="1"
    ok "已生成自签证书（CN=www.bing.com，有效期 10 年）"
    warn "自签证书要求客户端 insecure=true，无法抵御中间人攻击；生产环境建议用 ACME 证书"
}

cert_acme() {
    local domain tmp
    ask domain "请输入已解析到本机的域名（例如 example.com）"
    valid_domain "$domain" || die "域名格式不合法"
    info "下载并安装 acme.sh ..."
    tmp=$(mktemp /tmp/acme.XXXXXX) || die "无法创建临时文件"
    http_get https://get.acme.sh "$tmp" 60 || { rm -f "$tmp"; die "acme.sh 下载失败"; }
    [ -s "$tmp" ] || { rm -f "$tmp"; die "acme.sh 下载内容为空"; }
    grep -q 'acme.sh' "$tmp" || { rm -f "$tmp"; die "acme.sh 下载内容异常，已中止"; }
    sh "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "acme.sh 安装失败"; }
    rm -f "$tmp"

    [ -x "$HOME/.acme.sh/acme.sh" ] || die "acme.sh 未正确安装"

    info "申请证书（需 80 端口可被外网访问）..."
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone -k ec-256 >/dev/null 2>&1 \
        || die "证书申请失败，请确认域名解析与 80 端口"

    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" -k ec-256 \
        --key-file "$CONF_DIR/private.key" \
        --fullchain-file "$CONF_DIR/cert.crt" \
        --reloadcmd "rc-service hysteria restart >/dev/null 2>&1 || true" >/dev/null 2>&1 \
        || die "证书安装失败"

    chmod 644 "$CONF_DIR/cert.crt"
    chmod 600 "$CONF_DIR/private.key"
    HY_CERT="$CONF_DIR/cert.crt"
    HY_KEY="$CONF_DIR/private.key"
    HY_SNI="$domain"
    HY_INSECURE="0"
    ok "ACME 证书已就绪（$domain），并已配置自动续期"
}

cert_custom() {
    local c k d
    ask c "证书文件路径（如 /path/cert.pem）"
    ask k "私钥文件路径（如 /path/key.pem）"
    ask d "证书对应的域名（如 example.com）"
    [ -f "$c" ] || die "证书文件不存在：$c"
    [ -f "$k" ] || die "私钥文件不存在：$k"
    valid_domain "$d" || die "域名格式不合法"

    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    cp "$c" "$CONF_DIR/cert.crt"; chmod 644 "$CONF_DIR/cert.crt"
    cp "$k" "$CONF_DIR/private.key"; chmod 600 "$CONF_DIR/private.key"

    HY_CERT="$CONF_DIR/cert.crt"
    HY_KEY="$CONF_DIR/private.key"
    HY_SNI="$d"
    if confirm "该证书是否为自签证书？（自签需客户端 insecure）"; then
        HY_INSECURE="1"
    else
        HY_INSECURE="0"
    fi
    ok "已导入自定义证书"
}

select_cert() {
    local c=""
    info "请选择证书类型："
    printf '  1) 自签证书（默认，免域名）\n'
    printf '  2) ACME 自动申请（需域名 + 80 端口）\n'
    printf '  3) 使用已有证书文件\n'
    ask c "请输入选项" "1"
    case "$c" in
        1) cert_selfsigned ;;
        2) cert_acme ;;
        3) cert_custom ;;
        *) die "无效选项：$c" ;;
    esac
}

# ---------- 安装 ----------
do_install() {
    require_root
    ensure_deps

    if [ -f "$BIN" ] || [ -f "$NODE_CONF" ]; then
        warn "检测到已安装的 Hysteria 2"
        confirm "继续将覆盖现有配置，是否继续？" || { info "已取消"; return 0; }
    fi

    HY_ARCH="${HY_ARCH:-$(detect_arch)}"
    [ -n "$HY_ARCH" ] || die "无法识别 CPU 架构（$(uname -m)），可用 HY_ARCH 环境变量指定，例如 HY_ARCH=arm64"
    info "CPU 架构：$(uname -m) → hysteria-linux-${HY_ARCH}"

    HY_IP=$(http_get https://ip.gs "" 8 2>/dev/null)
    case "$HY_IP" in ''|*[!0-9a-fA-F:.]*) HY_IP="" ;; esac
    if [ -z "$HY_IP" ]; then
        warn "自动获取公网 IP 失败"
        ask HY_IP "请手动输入服务器公网 IP"
        [ -n "$HY_IP" ] || die "IP 不能为空"
    fi
    info "公网 IP：$HY_IP"

    select_cert

    local p=""
    while :; do
        ask p "监听端口 [1-65535]，留空随机分配"
        [ -z "$p" ] && p=$(shuf -i 20000-60000 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(20000+rand()*40000)}')
        if ! valid_port "$p"; then warn "端口必须是 1-65535 的整数"; continue; fi
        if udp_port_in_use "$p"; then warn "UDP 端口 $p 已被占用，请更换"; continue; fi
        break
    done
    HY_PORT="$p"

    local pw=""
    ask pw "认证密码（留空自动生成）"
    if [ -z "$pw" ]; then
        pw=$(gen_pwd)
        info "已生成随机密码"
    elif ! valid_pwd "$pw"; then
        die "密码非法：至少 4 位，且不能包含空格、引号、反斜杠或非 ASCII 字符"
    fi
    HY_PWD="$pw"

    local site=""
    ask site "伪装站点（不含 https://）" "www.bing.com"
    site=${site#http://}; site=${site#https://}; site=${site%%/*}
    valid_site "$site" || die "伪装站点不合法（只允许字母、数字、点、连字符、冒号、下划线）"
    HY_MASQ="$site"

    download_verified "hysteria-linux-${HY_ARCH}" "$BIN"

    write_node_conf
    render_configs

    svc_start || die "服务未能启动，请检查 $LOGFILE"

    ok "安装完成（脚本版本 ${SCRIPT_VERSION}）"
    show_config
    hr
    warn "NAT VPS 请确认 UDP ${HY_PORT} 已映射到公网；云厂商安全组也需放行"
    printf '  放行示例：iptables -I INPUT -p udp --dport %s -j ACCEPT\n' "$HY_PORT"
    printf '            nft add rule inet filter input udp dport %s accept\n' "$HY_PORT"
    hr
}

# ---------- 修改配置 ----------
do_change_port() {
    require_root
    load_node_conf
    local p="" old="$HY_PORT"
    while :; do
        ask p "新端口 [1-65535]，留空随机分配"
        [ -z "$p" ] && p=$(shuf -i 20000-60000 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(20000+rand()*40000)}')
        if ! valid_port "$p"; then warn "端口必须是 1-65535 的整数"; continue; fi
        [ "$p" = "$old" ] && { warn "与原端口相同"; continue; }
        if udp_port_in_use "$p"; then warn "UDP 端口 $p 已被占用，请更换"; continue; fi
        break
    done
    HY_PORT="$p"
    write_node_conf
    render_configs
    svc_restart
    ok "端口已由 ${old} 改为 ${p}，客户端配置与分享链接已同步更新"
    show_config
}

do_change_pwd() {
    require_root
    load_node_conf
    local pw=""
    ask pw "新密码（留空自动生成）"
    if [ -z "$pw" ]; then
        pw=$(gen_pwd)
        info "已生成随机密码"
    elif ! valid_pwd "$pw"; then
        die "密码非法：至少 4 位，且不能包含空格、引号、反斜杠或非 ASCII 字符"
    fi
    HY_PWD="$pw"
    write_node_conf
    render_configs
    svc_restart
    ok "密码已更新，客户端配置与分享链接已同步"
    show_config
}

do_change_conf() {
    local c=""
    info "请选择要修改的项目："
    printf '  1) 端口\n'
    printf '  2) 密码\n'
    printf '  3) 伪装站点\n'
    ask c "请输入选项"
    case "$c" in
        1) do_change_port ;;
        2) do_change_pwd ;;
        3)
            require_root
            load_node_conf
            local site=""
            ask site "新的伪装站点（不含 https://）" "$HY_MASQ"
            site=${site#http://}; site=${site#https://}; site=${site%%/*}
            valid_site "$site" || die "伪装站点不合法（只允许字母、数字、点、连字符、冒号、下划线）"
            HY_MASQ="$site"
            write_node_conf
            render_configs
            svc_restart
            ok "伪装站点已更新为 https://${site}"
            ;;
        *) die "无效选项" ;;
    esac
}

# ---------- 更新 / 卸载 ----------
do_update() {
    require_root
    load_node_conf
    local arch
    arch="${HY_ARCH:-$(detect_arch)}"
    [ -n "$arch" ] || die "无法识别 CPU 架构"
    download_verified "hysteria-linux-${arch}" "$BIN"
    HY_ARCH="$arch"; write_node_conf
    svc_restart
    local v=""
    if command -v timeout >/dev/null 2>&1; then
        v=$(timeout 5 "$BIN" version 2>/dev/null | head -1)
    fi
    ok "内核已更新${v:+：$v}"
}

do_uninstall() {
    require_root
    confirm "确认卸载 Hysteria 2 并删除所有配置？" || { info "已取消"; return 0; }
    has_openrc && rc-update del hysteria default >/dev/null 2>&1 || true
    svc_stop >/dev/null
    rm -f "$INIT_FILE" "$BIN" "$PIDFILE" "$LOGFILE"
    rm -rf "$CONF_DIR" "$CLIENT_DIR"
    ok "已卸载（二进制、配置、客户端文件、服务项均已清理）"
}

do_switch() {
    local c=""
    info "请选择操作："
    printf '  1) 启动\n'
    printf '  2) 停止\n'
    printf '  3) 重启\n'
    printf '  4) 查看状态\n'
    ask c "请输入选项"
    case "$c" in
        1) require_root; svc_start ;;
        2) require_root; svc_stop ;;
        3) require_root; svc_restart ;;
        4) svc_status ;;
        *) die "无效选项" ;;
    esac
}

# ---------- 菜单 ----------
banner() {
    clear 2>/dev/null || true
    printf '%s\n' "############################################################"
    printf '#   %sHysteria 2 一键安装脚本 · Alpine 优化版%s\n' "$BOLD" "$NC"
    printf '#   版本 %s\n' "$SCRIPT_VERSION"
    printf '#   上游 %s · 原作者 Misaka-blog\n' "$UPSTREAM_REPO"
    printf '%s\n\n' "############################################################"
}

menu() {
    local c=""
    while :; do
        banner
        printf '  1) 安装 Hysteria 2\n'
        printf '  2) 卸载 Hysteria 2\n'
        printf '  -------------\n'
        printf '  3) 启动 / 停止 / 重启 / 状态\n'
        printf '  4) 修改配置（端口 / 密码 / 伪装站点）\n'
        printf '  5) 显示客户端配置与分享链接\n'
        printf '  6) 更新内核\n'
        printf '  0) 退出\n\n'
        ask c "请输入选项" "0"
        case "$c" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_switch ;;
            4) do_change_conf ;;
            5) show_config ;;
            6) do_update ;;
            0) exit 0 ;;
            *) warn "无效选项：$c" ;;
        esac
        printf '\n' >&2
        printf '按回车返回菜单...' >&2
        IFS= read -r _ || true
        printf '\n' >&2
    done
}

usage() {
    cat <<EOF
Hysteria 2 一键安装脚本 v${SCRIPT_VERSION}

用法: $0 [选项]

  -h, --help     显示帮助
  -V, --version  显示版本

不带参数运行进入交互式菜单。

环境变量:
  HY_ARCH=arm64        强制指定 CPU 架构（默认自动识别）
  HY_SKIP_VERIFY=1     无法获取官方哈希时仍继续安装（不建议）
EOF
}

main() {
    case "${1-}" in
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
        "")           menu ;;
        *)            err "未知参数：$1"; usage; exit 1 ;;
    esac
}

main "$@"
