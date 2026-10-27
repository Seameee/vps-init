#!/bin/sh
# f2b-guard —— fail2ban ignoreip 守卫（POSIX sh 版，兼容 Debian/Ubuntu 与 Alpine）
#
# 【为什么用 /bin/sh 而不是 bash】
# Alpine 默认不带 bash，只有 busybox ash。用 bash 数组语法会导致
# `syntax error: unexpected "("`，守卫直接失效 —— 而守卫失效意味着
# 自锁保护失效。所以本脚本刻意只用 POSIX 语法。
#
# 【为什么需要它】
# 当 jail 使用全端口封禁（`iptables-allports` / `nftables[type=allports]`）时，
# 管理端 IP 一旦被 ban，连真 SSH 端口也是 `Connection closed`，
# 你会彻底失去对这台机器的访问。
#
# 实测（Debian 13）：为测试封禁逻辑临时把管理 IP 从 ignoreip 移除，
# 单次蜜罐尝试后立即 `Ban <管理IP>`，随后所有端口 `Connection closed`
# —— 整台机器被锁死，最后靠换一个来源 IP（跳板机）才恢复。
#
# 本守卫在「管理端 IP 不在 ignoreip 里」时**拒绝重启 fail2ban**，
# 把事情拦在上锁之前。
#
# 【IP 从哪来 —— 无需硬编码】
#   1) 若通过 SSH 运行，自动取当前连接的客户端 IP（$SSH_CONNECTION 第 1 字段）
#      —— 最贴合实际：**当前正在操作这台机器的人**必须在白名单里。
#   2) 可选：/etc/fail2ban/guard-ips 文件，一行一个 IP，用于额外要求
#      （例如跳板机、备用管理端）。适合多管理端/自动化场景。
#   3) 兜底：ignoreip 至少要有一个非回环 IP，防止被清成只剩 127.0.0.1/::1。
#
# 安装：
#   install -m 755 f2b-guard.sh /usr/local/sbin/f2b-guard
# 使用：
#   f2b-guard check        # 只检查；0=安全，1=危险
#   f2b-guard restart      # 守卫通过才重启 fail2ban
#
# 可选环境变量：
#   F2B_JAIL_CONF   指定 jail 配置文件（默认自动探测）
#   F2B_GUARD_IPS   额外要求的 IP，空格分隔（覆盖 guard-ips 文件）
set -u

# ---- 定位 jail 配置文件（自动探测，兼容不同命名）----
find_conf() {
  if [ -n "${F2B_JAIL_CONF:-}" ]; then
    [ -f "$F2B_JAIL_CONF" ] && { echo "$F2B_JAIL_CONF"; return 0; }
    return 1
  fi
  # 优先含 ignoreip 的配置文件
  for f in /etc/fail2ban/jail.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*ignoreip[[:space:]]*=' "$f"; then
      echo "$f"; return 0
    fi
  done
  # 退回 fail2ban 默认文件
  for f in /etc/fail2ban/jail.local /etc/fail2ban/jail.conf; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# ---- 收集「必须出现在 ignoreip 里的 IP」（每行一个）----
collect_required() {
  # 1) 当前 SSH 连接的客户端 IP
  if [ -n "${SSH_CONNECTION:-}" ]; then
    echo "$SSH_CONNECTION" | awk '{print $1}'
  elif [ -n "${SSH_CLIENT:-}" ]; then
    echo "$SSH_CLIENT" | awk '{print $1}'
  fi
  # 2) 额外要求：环境变量优先，其次 guard-ips 文件
  if [ -n "${F2B_GUARD_IPS:-}" ]; then
    for i in $F2B_GUARD_IPS; do echo "$i"; done
  elif [ -f /etc/fail2ban/guard-ips ]; then
    while IFS= read -r i || [ -n "$i" ]; do
      i=${i%%#*}
      i=$(echo "$i" | tr -d '[:space:]')
      [ -n "$i" ] && echo "$i"
    done < /etc/fail2ban/guard-ips
  fi
}

check() {
  conf=$(find_conf) || {
    echo "❌ 找不到含 ignoreip 的 fail2ban 配置文件" >&2
    echo "   （可用 F2B_JAIL_CONF=/path/to.conf 显式指定）" >&2
    return 1
  }
  line=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$conf" | tail -1)
  if [ -z "$line" ]; then
    echo "❌ $conf 里没有 ignoreip —— 全端口封禁会把管理员锁死" >&2
    return 1
  fi

  # 兜底检查：ignoreip 不能只有回环（IPv4 与 IPv6 都要认，纯 IPv6 机器上
  # 管理地址就是 IPv6，只认点分十进制会误判成"没有任何非回环 IP"）
  nonloop=$(echo "$line" \
    | sed 's/^[^=]*=//' \
    | tr ' ' '\n' \
    | grep -vE '^(|127\..*|::1(/[0-9]+)?|localhost)$' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$|^[0-9a-fA-F:]+(/[0-9]+)?$' || true)
  if [ -z "$nonloop" ]; then
    echo "❌ ignoreip 里没有任何非回环 IP（当前只有：$(echo "$line" | tr -s ' '))" >&2
    echo "   → 全端口封禁下这会让你无法登录" >&2
    return 1
  fi

  # 必须包含的 IP 检查（POSIX：用换行分隔的字符串而非数组）
  missing=""
  req=""
  collect_required | sort -u | while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if ! echo "$line" | grep -qF "$ip"; then
      echo "MISS:$ip"
    fi
  done > /tmp/f2b-guard.miss.$$

  while IFS= read -r m; do
    [ -z "$m" ] && continue
    missing="$missing ${m#MISS:}"
  done < /tmp/f2b-guard.miss.$$
  rm -f /tmp/f2b-guard.miss.$$ 2>/dev/null

  if [ -n "$missing" ]; then
    echo "❌ ignoreip 缺少必要 IP:$missing" >&2
    echo "   文件: $conf" >&2
    echo "   当前: $(echo "$line" | tr -s ' ')" >&2
    echo "   提示: 把上面缺失的 IP 追加到 ignoreip（空格分隔），或写入 /etc/fail2ban/guard-ips" >&2
    return 1
  fi

  echo "✅ ignoreip 守卫通过（$conf）"
  echo "   ignoreip: $(echo "$line" | tr -s ' ')"
  req=$(collect_required | awk 'NF' | sort -u | tr '\n' ' ')
  [ -n "$req" ] && echo "   已校验 IP: $req"
  return 0
}

# ---- 重启 fail2ban（自动适配 systemd / OpenRC）----
restart_f2b() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl restart fail2ban
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service fail2ban restart
  else
    echo "❌ 找不到可用的服务管理器（systemctl / rc-service 都没有）" >&2
    return 1
  fi
}

case "${1:-check}" in
  check) check ;;
  restart)
    if check; then
      if fail2ban-client -t >/dev/null 2>&1; then
        restart_f2b && echo "✅ fail2ban 已重启"
      else
        echo "❌ fail2ban 配置语法错误，拒绝重启" >&2
        exit 1
      fi
    else
      echo "⛔ 守卫拦截：未重启 fail2ban（避免把自己锁在门外）" >&2
      exit 1
    fi ;;
  *) echo "用法: f2b-guard [check|restart]   （可选: F2B_JAIL_CONF=... F2B_GUARD_IPS=\"ip1 ip2\"）" >&2; exit 2 ;;
esac
