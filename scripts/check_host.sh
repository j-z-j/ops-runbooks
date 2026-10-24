#!/usr/bin/env bash
# 主机巡检脚本：12 项检查，输出可读报告，异常项统一标记为 [WARN] / [FAIL]
# 用法：./check_host.sh            # 巡检本机
#      ./check_host.sh -f hosts    # 按 hosts 文件批量巡检（每行一个 IP，需已配 SSH 密钥）
# 退出码：0 全部正常，1 存在 WARN，2 存在 FAIL（可直接用于监控/CI 判断）

set -uo pipefail

THRESH_LOAD_FACTOR=1.5      # 负载阈值 = 核数 * 1.5
THRESH_DISK=85
THRESH_MEM=10               # 可用内存低于 10% 告警
THRESH_INODE=90
THRESH_SWAP=100

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; RST=$'\e[0m'
fail=0; warn=0

ok()   { printf '  %s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YEL" "$RST" "$*"; warn=$((warn+1)); }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; fail=$((fail+1)); }

check_local() {
    echo "=== 主机巡检 $(hostname) $(date '+%F %T') ==="

    # 1 负载
    local cores load
    cores=$(nproc); load=$(awk '{print $1}' /proc/loadavg)
    awk -v l="$load" -v c="$cores" -v t="$THRESH_LOAD_FACTOR" 'BEGIN{exit !(l > c*t)}' \
        && warn "1m 负载 ${load} 超过 ${cores} 核 * ${THRESH_LOAD_FACTOR}" \
        || ok "1m 负载 ${load}（${cores} 核）"

    # 2 内存
    local mem_avail
    mem_avail=$(awk '/MemAvailable/{printf "%d", $2*100/$1}' /proc/meminfo)
    [ "$mem_avail" -lt "$THRESH_MEM" ] && warn "可用内存仅 ${mem_avail}%" || ok "可用内存 ${mem_avail}%"

    # 3 磁盘
    while read -r used mount; do
        local u=${used%\%}
        if [ "$u" -ge "$THRESH_DISK" ]; then warn "分区 ${mount} 使用率 ${u}%"; else ok "分区 ${mount} 使用率 ${u}%"; fi
    done < <(df -PT -x tmpfs -x devtmpfs | awk 'NR>1{print $6, $7}')

    # 4 inode
    while read -r used mount; do
        local u=${used%\%}
        [ "$u" -ge "$THRESH_INODE" ] && warn "分区 ${mount} inode 使用率 ${u}%"
    done < <(df -iT -x tmpfs -x devtmpfs | awk 'NR>1{print $6, $7}')

    # 5 关键服务
    for svc in sshd firewalld chronyd; do
        systemctl is-active --quiet "$svc" 2>/dev/null && ok "服务 ${svc} 运行中" || bad "服务 ${svc} 未运行"
    done

    # 6 时间同步
    if command -v chronyc >/dev/null 2>&1; then
        chronyc tracking 2>/dev/null | grep -q 'Leap status     : Normal' && ok "chrony 同步正常" || warn "chrony 同步异常"
    fi

    # 7 登录失败次数（暴力破解迹象）
    local failed
    failed=$(journalctl -u sshd --since '-1 hour' --no-pager 2>/dev/null | grep -c 'Failed password' || true)
    [ "${failed:-0}" -gt 50 ] && warn "近 1 小时 SSH 登录失败 ${failed} 次" || ok "近 1 小时 SSH 失败 ${failed:-0} 次"

    # 8 端口监听
    local listen
    listen=$(ss -lntH | awk '{print $4}' | sed 's/.*://' | sort -n | uniq | tr '\n' ' ')
    ok "监听端口：${listen}"

    # 9 已删除但未释放的文件（磁盘"假满"）
    local deleted
    deleted=$(lsof +L1 2>/dev/null | awk 'NR>1 && $7>1073741824' | wc -l)
    [ "$deleted" -gt 0 ] && warn "有 ${deleted} 个 >1G 的已删除文件仍被占用" || ok "无大文件句柄泄漏"

    # 10 僵尸进程
    local zombie
    zombie=$(ps -eo stat | grep -c '^Z' || true)
    [ "${zombie:-0}" -gt 0 ] && warn "存在 ${zombie} 个僵尸进程" || ok "无僵尸进程"

    # 11 NTP 偏移
    if command -v chronyc >/dev/null 2>&1; then
        local skew
        skew=$(chronyc tracking 2>/dev/null | awk -F': ' '/System time/{print $2}' | awk '{print $1}')
        ok "系统时间偏移 ${skew:-N/A} 秒"
    fi

    # 12 OOM 记录
    local oom
    oom=$(dmesg -T 2>/dev/null | grep -ci 'out of memory' || true)
    [ "${oom:-0}" -gt 0 ] && warn "内核日志有 ${oom} 条 OOM 记录" || ok "无 OOM 记录"
}

if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ]; then
    while read -r ip; do
        [ -z "$ip" ] && continue
        echo "--- ${ip} ---"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${ip}" 'bash -s' < "$0" || warn "${ip} 巡检失败"
    done < "$2"
else
    check_local
fi

echo "=== 结果：FAIL=${fail} WARN=${warn} ==="
[ "$fail" -gt 0 ] && exit 2
[ "$warn" -gt 0 ] && exit 1
exit 0
