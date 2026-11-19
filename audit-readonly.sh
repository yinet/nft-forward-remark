#!/usr/bin/env bash
#
# nftables 转发脚本升级前体检（严格只读）
#
# 用途：在已安装旧版脚本（v1.0/v1.1）的机器上，升级到带备注的 v1.2 之前先"过一遍"。
# 本脚本不写任何文件、不调用 nft 的增删改命令，只读取内核规则与配置文件并比对。
#
# 用法：
#   bash audit-readonly.sh                    # 需 root（读取 nft 规则集）
#   CONF=/path/to/port-forward.conf bash audit-readonly.sh
#
set -u

CONF="${CONF:-/etc/nftables.d/port-forward.conf}"
TABLE="${TABLE:-port_forward}"

if [[ $EUID -ne 0 ]]; then
    echo "[提示] 非 root 运行，nft 规则可能读不到，建议 sudo bash $0" >&2
fi

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }
sec() { printf '\n\033[1m【%s】\033[0m\n' "$1"; }

sec "1. 机器与环境"
printf '主机名   : %s\n' "$(hostname 2>/dev/null || echo '?')"
printf '系统     : %s\n' "$( (grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"') || echo '?')"
printf '内核     : %s\n' "$(uname -r 2>/dev/null || echo '?')"
printf '当前时间 : %s\n' "$(date '+%F %T %Z')"
printf 'nft 版本 : %s\n' "$(nft --version 2>/dev/null || echo '未安装')"

sec "2. 内核转发参数"
printf 'ip_forward      : %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
printf '拥塞控制        : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
printf '默认队列        : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"

sec "3. nftables 服务"
printf 'is-enabled : %s\n' "$(systemctl is-enabled nftables 2>/dev/null || echo '?')"
printf 'is-active  : %s\n' "$(systemctl is-active nftables 2>/dev/null || echo '?')"
printf '主配置 include : '
if [[ -f /etc/nftables.conf ]]; then
    if grep -qF 'include "/etc/nftables.d/*.conf"' /etc/nftables.conf; then echo '已包含'; else echo '缺失（重启后可能丢规则）'; fi
else
    echo '/etc/nftables.conf 不存在'
fi

sec "4. 内核中实际生效的转发规则"
if nft list table ip "$TABLE" >/dev/null 2>&1; then
    printf 'DNAT 行数: %s    SNAT 行数: %s\n' \
        "$(nft list table ip "$TABLE" | grep -c 'dnat to')" \
        "$(nft list table ip "$TABLE" | grep -c 'snat to')"
    hr
    nft list table ip "$TABLE" | grep -E 'dnat to' | sed 's/^[[:space:]]*/  /'
else
    echo "表 ip $TABLE 不存在或无法读取（可能无规则、服务未启动、或非 root）"
fi

sec "5. 配置文件状态"
if [[ -f "$CONF" ]]; then
    printf '路径 : %s\n' "$CONF"
    printf '大小 : %s 字节   行数 : %s   md5 : %s\n' \
        "$(wc -c < "$CONF" | tr -d ' ')" "$(wc -l < "$CONF" | tr -d ' ')" "$(md5sum "$CONF" | cut -d' ' -f1)"
    printf '是否已含 @note 标记(即已被 v1.2 写过): %s 处\n' "$(grep -c '@note:' "$CONF" 2>/dev/null || true)"
    printf 'LOCAL_IP 定义 : %s\n' "$(grep -m1 'define LOCAL_IP' "$CONF" 2>/dev/null | sed 's/.*= *//' || echo '未找到')"
else
    printf '%s 不存在\n' "$CONF"
fi

sec "6. 脚本视角能识别的规则（决定重写后保留哪些）"
if [[ -f "$CONF" ]]; then
    n_std=$(grep -cE '^[[:space:]]*tcp dport [0-9]+ dnat to [0-9.]+:[0-9]+' "$CONF" 2>/dev/null || true)
    printf '可被 load_rules 识别的 tcp 规则: %s 条\n' "$n_std"
    hr
    grep -E '^[[:space:]]*tcp dport [0-9]+ dnat to [0-9.]+:[0-9]+' "$CONF" 2>/dev/null \
        | sed -E 's/^[[:space:]]*tcp dport ([0-9]+) dnat to ([0-9.]+:[0-9]+).*/  本机 \1 -> \2/' \
        | sed 's/$/  [会被保留]/'
else
    echo '配置文件不存在，跳过'
fi

sec "7. 会被脚本重写丢弃的行（重点）"
if [[ -f "$CONF" ]]; then
    lost=$(grep 'dnat to' "$CONF" 2>/dev/null \
        | grep -vE '^[[:space:]]*(tcp|udp) dport [0-9]+ dnat to [0-9.]+:[0-9]+[[:space:]]*(#.*)?$' || true)
    if [[ -n "$lost" ]]; then
        echo "以下 dnat 行不符合脚本的自动生成格式，首次重写配置时会丢失："
        printf '%s\n' "$lost" | sed -E 's/^[[:space:]]*/  /'
    else
        echo "未发现非标准 dnat 行：配置文件与脚本自动生成格式一致，重写不会丢规则。"
    fi

    # 其余不含 dnat 的规则（例如 ip saddr 限定、独立 chain、set 定义）同样会被丢弃
    other=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null \
        | grep -vE '^#!/usr/sbin/nft' \
        | grep -vE '^[[:space:]]*define[[:space:]]' \
        | grep -vE '^[[:space:]]*table[[:space:]]' \
        | grep -vE '^[[:space:]]*chain[[:space:]]' \
        | grep -vE '^[[:space:]]*type[[:space:]]+nat[[:space:]]+hook' \
        | grep -vE '^[[:space:]]*[{}][[:space:]]*$' \
        | grep -v 'dnat to' \
        | grep -vE '^[[:space:]]*ip daddr [0-9.]+ (tcp|udp) dport [0-9]+ ct status dnat snat to' || true)
    if [[ -n "$other" ]]; then
        echo ""
        echo "以下内容也不属于脚本生成范围，重写时会一并消失："
        printf '%s\n' "$other" | sed 's/^/  /'
    fi
fi

sec "8. 内核规则与配置文件的差异"
if nft list table ip "$TABLE" >/dev/null 2>&1 && [[ -f "$CONF" ]]; then
    k=$(nft list table ip "$TABLE" | grep -oE 'dnat to [0-9.]+:[0-9]+' | sort -u)
    c=$(grep -oE 'dnat to [0-9.]+:[0-9]+' "$CONF" 2>/dev/null | sort -u)
    only_k=$(comm -23 <(printf '%s\n' "$k") <(printf '%s\n' "$c"))
    only_c=$(comm -13 <(printf '%s\n' "$k") <(printf '%s\n' "$c"))
    if [[ -z "$only_k" && -z "$only_c" ]]; then
        echo "内核与配置一致。"
    else
        [[ -n "$only_k" ]] && { echo "仅内核有此转发（配置里没有，重启后会丢）："; printf '%s\n' "$only_k" | sed 's/^/  /'; }
        [[ -n "$only_c" ]] && { echo "仅配置有此转发（内核里没有，未生效）："; printf '%s\n' "$only_c" | sed 's/^/  /'; }
    fi
else
    echo "跳过（表或配置不可读）"
fi

sec "9. 定位机器上的旧脚本"
found=0
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    found=1
    ver=$(grep -m1 -oE '管理工具 v[0-9.]+' "$f" 2>/dev/null | sed 's/.*v//')
    note=$(grep -c 'sanitize_note' "$f" 2>/dev/null || true)
    printf '  %-40s 版本:%-5s 含备注功能:%s\n' "$f" "${ver:-?}" "$([[ "$note" -gt 0 ]] && echo 是 || echo 否)"
done < <(grep -rl 'nftables 端口转发管理工具' /root /usr/local/bin /usr/bin /opt /home 2>/dev/null | head -10)
[[ $found -eq 0 ]] && echo "  未在 /root /usr/local/bin /usr/bin /opt /home 找到脚本（可能在当前目录，可手动 ls）"

sec "10. 防火墙与备份"
printf 'firewalld : %s\n' "$(systemctl is-active firewalld 2>/dev/null || echo '未运行')"
printf 'ufw       : %s\n' "$(command -v ufw >/dev/null 2>&1 && (ufw status 2>/dev/null | head -1) || echo '未安装')"
printf '备份目录  : '
if [[ -d /etc/nftables.d/backups ]]; then
    printf '%s 个文件，最近 3 个：\n' "$(ls -1 /etc/nftables.d/backups 2>/dev/null | wc -l | tr -d ' ')"
    ls -1t /etc/nftables.d/backups 2>/dev/null | head -3 | sed 's/^/  /'
else
    echo '不存在'
fi

hr
echo "体检结束。本脚本未做任何修改。"
