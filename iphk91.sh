#!/usr/bin/env bash
#
# Cloudflare DDNS 通用脚本（单账号版）
# 功能：每分钟检测 VPS 公网 IP（IPv4 + IPv6）是否变化，变化则自动更新 Cloudflare DNS 记录
#

set -o errexit
set -o nounset
set -o pipefail

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

# 获取公网 IPv6 的地址
WANIP6_URLS=(
    "https://api6.ipify.org"
    "https://ipv6.icanhazip.com"
    "https://6.ipw.cn"
    "https://api-ipv6.ip.sb/ip"
    "https://v6.ident.me"
)

# IP 缓存文件路径
IP4_CACHE="/tmp/.cf_ddns_cached_ip4"
IP6_CACHE="/tmp/.cf_ddns_cached_ip6"

# 日志文件路径
LOG_FILE="/var/log/cf-ddns.log"

# ============================================================
#  账号配置
# ============================================================

ACCOUNT1_CFKEY="754562d8862d840a8eb6009745b79fc352610"
ACCOUNT1_CFUSER="6733268@gmail.com"
ACCOUNT1_ZONES=("lieningzhuyi.com" "2019-east.com")
ACCOUNT1_RECORDS=("admin07" "admin07")
ACCOUNT1_COMMENTS=("DJ-香港91D7" "DJ-香港91P7")
# 是否同时创建 AAAA 记录（true/false），与上面数组一一对应
ACCOUNT1_ENABLE_IPV6=("true" "true" "true")

# ============================================================
#  以下内容一般不需要修改
# ============================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
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

get_wan_ip6() {
    local ip="" raw=""
    for url in "${WANIP6_URLS[@]}"; do
        raw=$(curl -6 -s --max-time 5 "$url" 2>/dev/null) || continue
        # 匹配标准 IPv6 地址
        ip=$(echo "$raw" | grep -oEi '[0-9a-f:]{3,39}' | grep ':' | head -1 || true)
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

# 通用：按记录类型获取 record id
get_record_id() {
    local zone_id="$1" fqdn="$2" rtype="$3" cfuser="$4" cfkey="$5"
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${fqdn}&type=${rtype}" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="id":")[^"]*' | head -1 || true
}

# 通用：按记录类型获取当前 IP
get_record_ip() {
    local zone_id="$1" fqdn="$2" rtype="$3" cfuser="$4" cfkey="$5"
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${fqdn}&type=${rtype}" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="content":")[^"]*' | head -1 || true
}

create_record() {
    local zone_id="$1" fqdn="$2" ip="$3" rtype="$4" comment="$5" cfuser="$6" cfkey="$7"
    local resp
    resp=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${rtype}\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":${CFTTL},\"proxied\":${PROXIED},\"comment\":\"${comment}\"}")

    if [[ "$resp" == *'"success":true'* ]]; then
        log "✅ 创建成功 [${rtype}]: ${fqdn} -> ${ip}"
    else
        log "❌ 创建失败 [${rtype}]: ${fqdn}"
        log "   响应: ${resp}"
    fi
}

update_record() {
    local zone_id="$1" record_id="$2" fqdn="$3" ip="$4" rtype="$5" comment="$6" cfuser="$7" cfkey="$8"
    local resp
    resp=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "X-Auth-Email: ${cfuser}" \
        -H "X-Auth-Key: ${cfkey}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${rtype}\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":${CFTTL},\"proxied\":${PROXIED},\"comment\":\"${comment}\"}")

    if [[ "$resp" == *'"success":true'* ]]; then
        log "✅ 更新成功 [${rtype}]: ${fqdn} -> ${ip}"
    else
        log "❌ 更新失败 [${rtype}]: ${fqdn}"
        log "   响应: ${resp}"
    fi
}

# 处理单条 DNS 记录（A 或 AAAA）
process_single_record() {
    local zone_id="$1" fqdn="$2" ip="$3" rtype="$4" comment="$5" cfuser="$6" cfkey="$7"

    local record_id
    record_id=$(get_record_id "$zone_id" "$fqdn" "$rtype" "$cfuser" "$cfkey")

    if [[ -z "$record_id" ]]; then
        log "📝 [${rtype}] 记录不存在，正在创建..."
        create_record "$zone_id" "$fqdn" "$ip" "$rtype" "$comment" "$cfuser" "$cfkey"
    else
        local cf_ip
        cf_ip=$(get_record_ip "$zone_id" "$fqdn" "$rtype" "$cfuser" "$cfkey")
        if [[ "$cf_ip" == "$ip" ]]; then
            log "⏭️  [${rtype}] ${fqdn} 已经是 ${ip}，无需更新"
        else
            log "📝 [${rtype}] 正在更新: ${cf_ip} -> ${ip}"
            update_record "$zone_id" "$record_id" "$fqdn" "$ip" "$rtype" "$comment" "$cfuser" "$cfkey"
        fi
    fi
}

# 处理单个账号下的所有域名记录
process_account() {
    local cfuser="$1" cfkey="$2" current_ip4="$3" current_ip6="$4"
    shift 4
    # 剩余参数格式：zone1 record1 comment1 enable_ipv6_1 zone2 record2 comment2 enable_ipv6_2 ...
    local args=("$@")
    local count=$(( ${#args[@]} / 4 ))

    log "====== 账号: ${cfuser} ======"

    for (( i=0; i<count; i++ )); do
        local zone_name="${args[$((i*4))]}"
        local record_name="${args[$((i*4+1))]}"
        local comment="${args[$((i*4+2))]}"
        local enable_ipv6="${args[$((i*4+3))]}"
        local fqdn="${record_name}.${zone_name}"

        log "--- 处理: ${fqdn} ---"

        # 获取 Zone ID
        local zone_id
        zone_id=$(get_zone_id "$zone_name" "$cfuser" "$cfkey")
        if [[ -z "$zone_id" ]]; then
            log "❌ 找不到域名 ${zone_name} 的 Zone ID，请检查 API Key 和域名"
            continue
        fi

        # 处理 A 记录（IPv4）
        if [[ -n "$current_ip4" ]]; then
            process_single_record "$zone_id" "$fqdn" "$current_ip4" "A" "$comment" "$cfuser" "$cfkey"
        else
            log "⚠️  无 IPv4 地址，跳过 A 记录"
        fi

        # 处理 AAAA 记录（IPv6）
        if [[ "$enable_ipv6" == "true" ]]; then
            if [[ -n "$current_ip6" ]]; then
                process_single_record "$zone_id" "$fqdn" "$current_ip6" "AAAA" "$comment" "$cfuser" "$cfkey"
            else
                log "⚠️  无 IPv6 地址，跳过 AAAA 记录: ${fqdn}"
            fi
        fi
    done
}

# ============================================================
#  主逻辑
# ============================================================
main() {
    # 1. 获取当前公网 IP
    local current_ip4=""
    local current_ip6=""

    current_ip4=$(get_wan_ip4) || {
        log "⚠️  无法获取公网 IPv4"
        current_ip4=""
    }

    current_ip6=$(get_wan_ip6) || {
        log "⚠️  无法获取公网 IPv6（可能不支持 IPv6）"
        current_ip6=""
    }

    if [[ -z "$current_ip4" && -z "$current_ip6" ]]; then
        log "⚠️  IPv4 和 IPv6 均无法获取，跳过本次检测"
        exit 0
    fi

    # 2. 读取缓存 IP，对比是否有变化
    local cached_ip4="" cached_ip6=""
    if [[ -f "$IP4_CACHE" ]]; then
        cached_ip4=$(cat "$IP4_CACHE" 2>/dev/null || true)
    fi
    if [[ -f "$IP6_CACHE" ]]; then
        cached_ip6=$(cat "$IP6_CACHE" 2>/dev/null || true)
    fi

    local ip4_changed=false ip6_changed=false

    if [[ -n "$current_ip4" && "$current_ip4" != "$cached_ip4" ]]; then
        ip4_changed=true
    fi
    if [[ -n "$current_ip6" && "$current_ip6" != "$cached_ip6" ]]; then
        ip6_changed=true
    fi

    # 两个都没变，直接退出
    if [[ "$ip4_changed" == "false" && "$ip6_changed" == "false" ]]; then
        exit 0
    fi

    # 3. 打印变化信息
    if [[ "$ip4_changed" == "true" ]]; then
        if [[ -n "$cached_ip4" ]]; then
            log "🔄 检测到 IPv4 变化: ${cached_ip4} -> ${current_ip4}"
        else
            log "🚀 首次运行 IPv4: ${current_ip4}"
        fi
    fi
    if [[ "$ip6_changed" == "true" ]]; then
        if [[ -n "$cached_ip6" ]]; then
            log "🔄 检测到 IPv6 变化: ${cached_ip6} -> ${current_ip6}"
        else
            log "🚀 首次运行 IPv6: ${current_ip6}"
        fi
    fi

    # 4. 更新所有记录
    local account1_args=()
    for i in "${!ACCOUNT1_ZONES[@]}"; do
        account1_args+=("${ACCOUNT1_ZONES[$i]}" "${ACCOUNT1_RECORDS[$i]}" "${ACCOUNT1_COMMENTS[$i]}" "${ACCOUNT1_ENABLE_IPV6[$i]}")
    done
    process_account "$ACCOUNT1_CFUSER" "$ACCOUNT1_CFKEY" "$current_ip4" "$current_ip6" "${account1_args[@]}"

    # 5. 更新缓存
    if [[ -n "$current_ip4" ]]; then
        echo "$current_ip4" > "$IP4_CACHE"
    fi
    if [[ -n "$current_ip6" ]]; then
        echo "$current_ip6" > "$IP6_CACHE"
    fi

    log "✅ 本次 DDNS 检测完成（共 1 个账号，IPv4 + IPv6）"
}

main "$@"
