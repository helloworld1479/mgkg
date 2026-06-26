#!/usr/bin/env bash
#
# Cloudflare DDNS 通用脚本（多账号版 · 纯 IPv4）
# 功能：检测 VPS 公网 IPv4 是否变化，变化则自动更新多个 Cloudflare 账号的 A 记录
#
# 用法：
#   ./cf-ddns.sh           普通模式（带缓存，IP 没变就跳过，适合 cron 定时任务）
#   ./cf-ddns.sh --force   强制模式（忽略缓存，直接拉 Cloudflare 实际记录比对并更新，
#                          并把结果打印到屏幕，适合手动换 IP 时使用）
#

set -o errexit
set -o nounset
set -o pipefail

# ============================================================
#  运行模式
# ============================================================
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
    esac
done

# ============================================================
#  通用配置
# ============================================================

CFTTL=1                                       # TTL（1 = 自动）
PROXIED=false                                 # 是否开启 CF 小云朵代理（true/false）

# 获取公网 IPv4 的地址（备用多个，防止单点故障）
WANIP4_URLS=(
    "https://ip.sb"
    "https://api.ip.sb/ip"
    "https://4.ipw.cn"
    "https://myip.ipip.net/ip"
    "https://ipv4.icanhazip.com"
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
)

# IP 缓存文件路径
IP4_CACHE="/tmp/.cf_ddns_cached_ip4"

# 日志文件路径
LOG_FILE="/var/log/cf-ddns.log"

# ============================================================
#  账号 1 配置
# ============================================================

ACCOUNT1_CFKEY="754562d8862d840a8eb6009745b79fc352610"
ACCOUNT1_CFUSER="6733268@gmail.com"
ACCOUNT1_ZONES=("lieningzhuyi.com" "709900.xyz")
ACCOUNT1_RECORDS=("*.may" "twdt")
ACCOUNT1_COMMENTS=("DDNS自动更新" "DDNS自动更新")

# ============================================================
#  账号 2 配置
# ============================================================

ACCOUNT2_CFKEY="ab0d638bb9645a0aa5f134ec9988734d741ab"
ACCOUNT2_CFUSER="phungduyla@gmail.com"
ACCOUNT2_ZONES=("345686.cc" "345686.cc")
ACCOUNT2_RECORDS=("ls099991" "ls090991")
ACCOUNT2_COMMENTS=("DDNS自动更新" "DDNS自动更新")

# ============================================================
#  以下内容一般不需要修改
# ============================================================

# 强制模式下同时打印到屏幕，普通模式只写日志（保持 cron 静默）
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ "$FORCE" == "true" ]]; then
        echo "$msg"
    fi
    echo "$msg" >> "$LOG_FILE"
}

get_wan_ip4() {
    local ip="" raw=""
    for url in "${WANIP4_URLS[@]}"; do
        raw=$(curl -4 -s --max-time 5 "$url" 2>/dev/null) || continue
        ip=$(echo "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

get_zone_id() {
    local zone_name="$1" cfuser="$2" cfkey="$3"
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${zone_name}" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="id":")[^"]*' | head -1 || true
}

get_record_id() {
    local zone_id="$1" fqdn="$2" cfuser="$3" cfkey="$4"
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${fqdn}&type=A" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="id":")[^"]*' | head -1 || true
}

get_record_ip() {
    local zone_id="$1" fqdn="$2" cfuser="$3" cfkey="$4"
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${fqdn}&type=A" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="content":")[^"]*' | head -1 || true
}

create_record() {
    local zone_id="$1" fqdn="$2" ip="$3" comment="$4" cfuser="$5" cfkey="$6"
    local resp
    resp=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":${CFTTL},\"proxied\":${PROXIED},\"comment\":\"${comment}\"}")

    if [[ "$resp" == *'"success":true'* ]]; then
        log "✅ 创建成功 [A]: ${fqdn} -> ${ip}"
    else
        log "❌ 创建失败 [A]: ${fqdn}"
        log "   响应: ${resp}"
    fi
}

update_record() {
    local zone_id="$1" record_id="$2" fqdn="$3" ip="$4" comment="$5" cfuser="$6" cfkey="$7"
    local resp
    resp=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":${CFTTL},\"proxied\":${PROXIED},\"comment\":\"${comment}\"}")

    if [[ "$resp" == *'"success":true'* ]]; then
        log "✅ 更新成功 [A]: ${fqdn} -> ${ip}"
    else
        log "❌ 更新失败 [A]: ${fqdn}"
        log "   响应: ${resp}"
    fi
}

# 处理单条 A 记录
process_single_record() {
    local zone_id="$1" fqdn="$2" ip="$3" comment="$4" cfuser="$5" cfkey="$6"

    local record_id
    record_id=$(get_record_id "$zone_id" "$fqdn" "$cfuser" "$cfkey")

    if [[ -z "$record_id" ]]; then
        log "📝 [A] 记录不存在，正在创建..."
        create_record "$zone_id" "$fqdn" "$ip" "$comment" "$cfuser" "$cfkey"
    else
        local cf_ip
        cf_ip=$(get_record_ip "$zone_id" "$fqdn" "$cfuser" "$cfkey")
        if [[ "$cf_ip" == "$ip" ]]; then
            log "⏭️  [A] ${fqdn} 已经是 ${ip}，无需更新"
        else
            log "📝 [A] 正在更新: ${cf_ip} -> ${ip}"
            update_record "$zone_id" "$record_id" "$fqdn" "$ip" "$comment" "$cfuser" "$cfkey"
        fi
    fi
}

# 处理单个账号下的所有域名记录
process_account() {
    local cfuser="$1" cfkey="$2" current_ip4="$3"
    shift 3
    # 剩余参数格式：zone1 record1 comment1 zone2 record2 comment2 ...
    local args=("$@")
    local count=$(( ${#args[@]} / 3 ))

    log "====== 账号: ${cfuser} ======"

    for (( i=0; i<count; i++ )); do
        local zone_name="${args[$((i*3))]}"
        local record_name="${args[$((i*3+1))]}"
        local comment="${args[$((i*3+2))]}"
        local fqdn="${record_name}.${zone_name}"

        log "--- 处理: ${fqdn} ---"

        local zone_id
        zone_id=$(get_zone_id "$zone_name" "$cfuser" "$cfkey")
        if [[ -z "$zone_id" ]]; then
            log "❌ 找不到域名 ${zone_name} 的 Zone ID，请检查 API Key 和域名"
            continue
        fi

        process_single_record "$zone_id" "$fqdn" "$current_ip4" "$comment" "$cfuser" "$cfkey"
    done
}

# ============================================================
#  主逻辑
# ============================================================
main() {
    if [[ "$FORCE" == "true" ]]; then
        log "========== 强制模式（--force）：忽略缓存，直接比对 Cloudflare 实际记录 =========="
    fi

    # 1. 获取当前公网 IPv4
    local current_ip4=""
    current_ip4=$(get_wan_ip4) || {
        log "⚠️  无法获取公网 IPv4，跳过本次检测"
        exit 0
    }

    if [[ -z "$current_ip4" ]]; then
        log "⚠️  无法获取公网 IPv4，跳过本次检测"
        exit 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        log "当前公网 IPv4: ${current_ip4}"
    fi

    # 2. 缓存比对（仅普通模式生效；--force 跳过此段，强制更新）
    if [[ "$FORCE" != "true" ]]; then
        local cached_ip4=""
        if [[ -f "$IP4_CACHE" ]]; then
            cached_ip4=$(cat "$IP4_CACHE" 2>/dev/null || true)
        fi

        # IP 没变，直接退出
        if [[ "$current_ip4" == "$cached_ip4" ]]; then
            exit 0
        fi

        if [[ -n "$cached_ip4" ]]; then
            log "🔄 检测到 IPv4 变化: ${cached_ip4} -> ${current_ip4}"
        else
            log "🚀 首次运行 IPv4: ${current_ip4}"
        fi
    fi

    # 3. 更新所有记录
    local account1_args=()
    for i in "${!ACCOUNT1_ZONES[@]}"; do
        account1_args+=("${ACCOUNT1_ZONES[$i]}" "${ACCOUNT1_RECORDS[$i]}" "${ACCOUNT1_COMMENTS[$i]}")
    done
    process_account "$ACCOUNT1_CFUSER" "$ACCOUNT1_CFKEY" "$current_ip4" "${account1_args[@]}"

    local account2_args=()
    for i in "${!ACCOUNT2_ZONES[@]}"; do
        account2_args+=("${ACCOUNT2_ZONES[$i]}" "${ACCOUNT2_RECORDS[$i]}" "${ACCOUNT2_COMMENTS[$i]}")
    done
    process_account "$ACCOUNT2_CFUSER" "$ACCOUNT2_CFKEY" "$current_ip4" "${account2_args[@]}"

    # 4. 更新缓存
    echo "$current_ip4" > "$IP4_CACHE"

    log "✅ 本次 DDNS 检测完成（共 2 个账号，仅 IPv4 / A 记录）"
}

main "$@"
