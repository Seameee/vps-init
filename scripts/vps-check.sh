#!/bin/sh
# vps-check.sh —— VPS 勘察 + 验收门禁（POSIX sh，Debian/Ubuntu/Alpine 通用）
#
#   sh vps-check.sh recon    只读勘察，不改任何系统状态（第一步必跑）
#   sh vps-check.sh gate     加固后验收门禁，失败项给修复提示
#
# 远程拉取（不要手抄脚本）：
#   REPO=https://raw.githubusercontent.com/Seameee/vps-init/main
#   curl -fsSL $REPO/scripts/vps-check.sh -o /tmp/vps-check.sh && sh /tmp/vps-check.sh recon
set -u
export LC_ALL=C
MODE=${1:-recon}
S=''
[ "$(id -u)" -eq 0 ] || S='sudo'

have() { command -v "$1" >/dev/null 2>&1; }
hr() { printf '\n===== %s =====\n' "$1"; }
ok() { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [!!]   %s\n' "$*"; BAD=$((BAD + 1)); }
BAD=0

# ---- 环境探测（两个模式共用）----
IS_ALPINE=no
[ -f /etc/alpine-release ] && IS_ALPINE=yes
if [ -d /run/systemd/system ] && have systemctl; then
  INIT_SYS=systemd
elif [ "$IS_ALPINE" = yes ] || { [ -f /etc/inittab ] && have rc-service; }; then
  INIT_SYS=openrc
else
  INIT_SYS=unknown
fi
IS_CONTAINER=no
if have systemd-detect-virt; then
  VT=$(systemd-detect-virt 2>/dev/null) || VT=none
  case "$VT" in
    lxc | docker | podman | openvz | systemd-nspawn | wsl) IS_CONTAINER=yes ;;
  esac
elif [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
  VT=container-other
  IS_CONTAINER=yes
else
  VT=unknown
fi
svc_state() {
  if [ "$INIT_SYS" = openrc ]; then
    rc-service "$1" status 2>&1 | head -1
  else
    systemctl is-active "$1" 2>/dev/null
  fi
}
list_ports() {
  if have ss; then ss -tulnp 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/'
  elif have netstat; then netstat -tulnp 2>/dev/null | awk 'NR==1 || /LISTEN/'
  else echo '  <ss 与 netstat 都不可用>'; fi
}
# 运行中的 sshd 二进制（PATH 里的 sshd 可能被遮蔽）
sshd_bin() {
  p=$(pgrep -x sshd 2>/dev/null | head -1)
  [ -z "$p" ] && p=$(pgrep -f '/usr/sbin/sshd' 2>/dev/null | head -1)
  [ -n "$p" ] && readlink -f "/proc/$p/exe" 2>/dev/null
}
ssh_ports() { list_ports | awk '/ssh/ {print}' ; }
f2b_jails() {
  fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ' | tr ',' ' '
}
# TCP LISTEN 的本地地址:端口（ss/nawk 通用，只用第 5 列）
listen_tcp() {
  list_ports | awk '$1=="tcp" && $2=="LISTEN" {print $5}' | sort -u
}
# 用合成样本验证 filter 真的能匹配（新机器没有攻击流量，不能靠线上日志）
# 只做事实陈述；是否算通过由调用方（gate）决定。返回 0 = 至少一个 filter 命中。
filter_smoke() {
  _s=/tmp/vps-init-filter-sample.$$
  {
    echo "Oct 27 12:00:00 sample sshd-session[123]: Failed password for invalid user admin from 203.0.113.66 port 5555 ssh2"
    echo "Oct 27 12:00:01 sample sshd-session[124]: Connection closed by 203.0.113.66 port 5678 [preauth]"
  } > "$_s"
  _hit=0
  for _f in /etc/fail2ban/filter.d/vps-init-sshd.conf /etc/fail2ban/filter.d/sshd.conf; do
    [ -f "$_f" ] || continue
    _m=$(count_matched "$_s" "$_f")
    echo "    filter $(basename "$_f"): matched=${_m:-?}"
    [ "${_m:-0}" -gt 0 ] 2>/dev/null && _hit=1
  done
  rm -f "$_s"
  return $((1 - _hit))
}
count_matched() {
  fail2ban-regex "$1" "$2" 2>/dev/null \
    | awk '/^Lines:/ {for (i=2;i<=NF;i++) if ($i ~ /^matched,?$/) {print $(i-1); exit}}'
}

# =============================== recon ===============================
recon() {
  hr "1. 发行版 / 内核 / init / 虚拟化"
  [ -r /etc/os-release ] && {
    . /etc/os-release
    echo "PRETTY_NAME : ${PRETTY_NAME:-?}"
    echo "ID / ID_LIKE: ${ID:-?} / ${ID_LIKE:-<none>}  (VERSION_ID=${VERSION_ID:-?})"
  }
  [ -f /etc/alpine-release ] && echo "alpine-release: $(cat /etc/alpine-release)"
  echo "kernel/arch : $(uname -r) $(uname -m)"
  echo "libc        : $(ldd --version 2>&1 | head -1)"
  echo "init        : $INIT_SYS (pid1=$(cat /proc/1/comm 2>/dev/null))"
  echo "virt        : $VT   IS_CONTAINER=$IS_CONTAINER"
  echo "bash        : $(have bash && echo 有 || echo '无 -> 脚本必须 POSIX sh')"
  echo "chsh        : $(have chsh && echo 有 || echo '无 -> 改 shell 要改 /etc/passwd')"
  [ "$IS_CONTAINER" = yes ] && echo "!! 容器内：跳过 sysctl/BBR、zram、主机防火墙"
  if [ "$INIT_SYS" = openrc ]; then
    echo "runlevel default: $(rc-update show default 2>/dev/null | tr -s ' ' | tr '\n' ';')"
    echo "/var/log      : $(ls /var/log 2>/dev/null | tr '\n' ' ')"
    echo "apk 已装     : $(apk info 2>/dev/null | wc -l) 包"
    echo "/usr/local/sbin: $([ -d /usr/local/sbin ] && echo 存在 || echo '缺失 -> 装脚本前 mkdir -p')"
    echo "!! Alpine：正文的 systemctl/journalctl/apt 都不适用，按 references/alpine.md 操作"
  fi

  hr "2. SSH 形态（决定 Port 怎么改）"
  if [ "$INIT_SYS" = openrc ]; then
    echo "sshd: $(svc_state sshd) / 自启: $(rc-update show default 2>/dev/null | grep -q sshd && echo yes || echo no)"
    echo "!! Alpine 无 ssh.socket/generator，端口纯由 sshd_config 决定；改完用 reload（restart 会断连）"
  else
    echo "ssh.service : $(systemctl is-active ssh.service 2>/dev/null)"
    echo "ssh.socket  : $(systemctl is-active ssh.socket 2>/dev/null)"
    if [ "$(systemctl is-active ssh.socket 2>/dev/null)" = active ]; then
      if [ -f /run/systemd/generator/ssh.socket.d/addresses.conf ]; then
        echo "  有 sshd-socket-generator(Ubuntu) -> 改 sshd_config.d 的 Port；手写 ListenStream 会被覆盖"
        grep ListenStream /run/systemd/generator/ssh.socket.d/addresses.conf 2>/dev/null | sed 's/^/     /'
      else
        echo "  无 generator -> 改 ssh.socket 的 ListenStream（先清空再设），daemon-reload + restart ssh.socket"
      fi
    fi
  fi
  echo "Include 行: $(grep -n '^[[:space:]]*Include' /etc/ssh/sshd_config 2>/dev/null || echo '<无 Include！drop-in 不生效>')"
  ls /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/  drop-in: /' || echo "  drop-in 目录不存在"

  hr "3. 运行中的 sshd 与生效配置"
  RB=$(sshd_bin)
  if [ -n "${RB:-}" ]; then
    echo "running binary: $RB"
    [ "$(command -v sshd 2>/dev/null)" != "$RB" ] && echo "!! PATH 遮蔽：检查一律用 \$RB"
    "$RB" -T 2>/dev/null | grep -Ei '^(port|listenaddress|passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|logingracetime|allowtcpforwarding)' | sed 's/^/  /'
  else
    echo "!! 未找到运行中的 sshd 进程"
  fi

  hr "4. 真实监听端口"
  list_ports | sed 's/^/  /'

  if [ "$IS_ALPINE" = no ] && { have snap || [ -e /snap ] || dpkg -l snapd >/dev/null 2>&1; }; then
    hr "4b. snap（Ubuntu 建议卸载，见 hardening.md §9）"
    echo "  snapd: $(dpkg-query -W -f='${Version}' snapd 2>/dev/null || echo '未装')"
    echo "  已装 snap 包数（非 0 需先迁移）: $(snap list 2>/dev/null | tail -n +2 | wc -l)"
    for f in /etc/environment /etc/sudoers /etc/profile.d/apps-bin-path.sh /etc/apt/apt.conf.d/20snapd.conf; do
      grep -q '/snap' "$f" 2>/dev/null && bad "$f 仍有 /snap 残留"
    done
    [ -f /etc/apt/preferences.d/nosnap.pref ] && ok 'nosnap.pref 已存在（Pin 生效）' || bad '无 nosnap.pref -> 卸了也会被 Recommends 装回来'
  fi

  hr "5. 防火墙"
  if have ufw; then
    echo "ufw: $(ufw status 2>/dev/null | head -1)"
    ufw status numbered 2>/dev/null | sed 's/^/  /'
    [ "$INIT_SYS" = openrc ] && {
      rc-update show default 2>/dev/null | grep -qE '^[[:space:]]*ufw[[:space:]]' \
        && ok 'ufw 已注册开机自启' \
        || bad 'ufw 未注册 runlevel -> 重启后规则丢失！修复: rc-update add ufw default'
    }
  else
    echo "ufw: 未安装"
  fi
  if have nft; then
    # 只看 hook 链与 policy，整份 ruleset 会刷屏
    $S nft list ruleset 2>/dev/null | grep -E '^\s*(table|chain|type .*hook)' | sed 's/^/  nft: /' | head -30
    $S nft list ruleset 2>/dev/null | grep -q 'hook input .*policy drop' && ok 'nft input policy drop' || echo "  nft input: 无 policy drop（可能用 ufw/iptables）"
  else
    echo "nftables: 未安装"
  fi
  iptables -S 2>/dev/null | grep -E '^-P' | sed 's/^/  iptables: /'

  hr "6. Docker（会绕过 ufw）"
  if have docker; then
    echo "docker: $(docker --version 2>/dev/null), 运行中容器: $(docker ps -q 2>/dev/null | wc -l)"
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|:::' | sed 's/^/  /'
    echo "iptables DOCKER 规则: $(iptables -S 2>/dev/null | grep -c DOCKER)"
  else
    echo "docker: 未安装"
  fi

  hr "7. 用户与公钥"
  awk -F: '$7 !~ /(nologin|false|sync|shutdown)$/ {print "  " $1 " uid=" $3 " home=" $6 " shell=" $7}' /etc/passwd
  for h in /root /home/*; do
    [ -d "$h" ] || continue
    ak="$h/.ssh/authorized_keys"
    if [ -f "$ak" ]; then
      echo "  $ak: $(grep -cE '^(ssh-|ecdsa-|sk-)' "$ak" 2>/dev/null) 个公钥, 权限 $(stat -c '%a %U:%G' "$ak" 2>/dev/null)"
    else
      echo "  $ak: <不存在>"
    fi
  done
  echo "root 密码: $(passwd -S root 2>/dev/null | awk '{print $2}')  [L=锁定 P=可用 NP=无密码]"

  hr "8. 资源 / 日志 / 时间 / 自动更新"
  free -h 2>/dev/null | sed 's/^/  /'
  df -hP / /var 2>/dev/null | sed 's/^/  /'
  echo "zram: $(lsmod 2>/dev/null | grep -c zram) 模块; 设备: $(ls /dev/zram* 2>/dev/null | tr '\n' ' ')"
  echo "TCP cc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if [ "$IS_ALPINE" = yes ]; then
    echo "时区: $(readlink -f /etc/localtime 2>/dev/null)"
    echo "NTP: ntpd=$(svc_state ntpd)  crond=$(svc_state crond)"
    echo "日志: syslogd $(pgrep -c syslogd 2>/dev/null) 进程, /var/log=$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
    grep -q '/var/log/messages' /etc/logrotate.d/* 2>/dev/null \
      && ok 'messages 有轮转规则' \
      || bad '/var/log/messages 无轮转规则 -> busybox syslogd 会写满磁盘（alpine.md §10）'
    echo "tcp_bbr 在 /etc/modules: $(grep -c '^tcp_bbr' /etc/modules 2>/dev/null) 处"
  else
    echo "时区: $(timedatectl show -p Timezone --value 2>/dev/null)  NTP同步: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    echo "journald: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)  限额: $(grep -hE '^SystemMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | tail -1 || echo 未设)"
    echo "unattended-upgrades: $(systemctl is-active unattended-upgrades 2>/dev/null)  needrestart: $(have needrestart && echo 已装 || echo 未装)"
    echo "rsyslog: $(systemctl is-active rsyslog 2>/dev/null)（Debian 13 默认为无 -> fail2ban 用 backend=systemd）"
  fi

  hr "9. fail2ban / 蜜罐"
  if have fail2ban-client; then
    echo "fail2ban: $(fail2ban-client --version 2>/dev/null | head -1)"
    for j in $(f2b_jails); do
      echo "  [$j] $(fail2ban-client status "$j" 2>/dev/null | grep -E 'Currently banned|Total banned|Total failed|File list' | tr -s ' \t' ' ' | tr '\n' ' ')"
    done
    BA=$(awk '/^\[DEFAULT\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*banaction[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); print; exit}' \
      /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.conf 2>/dev/null | tail -1 | tr -d ' ')
    echo "  banaction=${BA:-<未显式设置>}"
    case "$BA" in
      *nftables*) have nft && ok 'nft 存在' || bad 'banaction=nftables 但 nft 不存在 -> 封禁静默失效！apt install nftables && systemctl restart fail2ban' ;;
      *iptables*) have iptables && ok "iptables 存在（$(iptables --version 2>/dev/null | grep -oE 'nf_tables|legacy')）" || bad "banaction=$BA 但 iptables 不存在 -> 封禁静默失效" ;;
    esac
    if [ "$INIT_SYS" != openrc ]; then
      JM=$(fail2ban-client get sshd journalmatch 2>/dev/null | tail -1)
      case "$JM" in
        *sshd-session*) ok "sshd journalmatch 含 sshd-session" ;;
        '') : ;;
        *) bad "journalmatch 缺 _COMM=sshd-session（OpenSSH 10 会话进程名）-> Total failed 恒为 0。
         修复：jail.d 里用 zz- 前缀文件（排在 defaults-debian.conf 之后）写
         journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session" ;;
      esac
      nft list chain inet f2b-table f2b-chain 2>/dev/null | grep dport | sed 's/^/  nft: /'
    else
      iptables -S 2>/dev/null | grep -E 'f2b|fail2ban' | head -6 | sed 's/^/  iptables: /'
    fi
    echo "  --- filter 自检（对合成攻击样本，matched 必须 > 0）---"
    filter_smoke
  else
    echo "fail2ban: 未安装"
  fi
  for m in sshesame endlessh cowrie; do
    have "$m" && echo "  蜜罐 $m: $(command -v $m)" || echo "  蜜罐 $m: 未安装"
  done

  hr "10. cloud-init 是否会覆盖 SSH 配置"
  [ -d /etc/cloud/cloud.cfg.d ] \
    && grep -rn 'ssh_pwauth\|disable_root\|ssh_authorized_keys' /etc/cloud/ 2>/dev/null | head -10 | sed 's/^/  /' \
    || echo "  无 cloud-init 配置"

  hr "勘察完成"
  cat <<'NEXT'
下一步：
  1) 若 authorized_keys 为空且 PasswordAuthentication=yes -> 先配密钥，禁止开始任何加固。
  2) 动 SSH/防火墙前先挂死手开关（references/ssh-firewall.md §1）。
  3) 然后按 SKILL.md「流程」0->9 顺序推进；Alpine 先读 references/alpine.md。
NEXT
}

# =============================== gate ===============================
gate() {
  hr "验收门禁"
  RB=$(sshd_bin)
  if [ -n "${RB:-}" ]; then
    P=$("$RB" -T 2>/dev/null | awk '/^port /{printf "%s ", $2}')
    PA=$("$RB" -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    echo "  sshd 生效: port=[$P] passwordauthentication=$PA"
    [ -n "${P:-}" ] && ok "sshd 配置了端口: $P" || bad 'sshd -T 没有输出 port'
    case " $P " in
      *" 22 "*) echo "  [--]   22 在监听列表里（若 22 是蜜罐端口则正常）" ;;
    esac
    [ "$PA" = no ] && ok '密码认证已禁用' || bad "passwordauthentication=$PA（加固目标通常为 no）"
  else
    bad '未找到运行中的 sshd'
  fi

  L=$(list_ports)
  # 校验 sshd -T 报的端口真的在 LISTEN（不能只看:ss 的输出格式）
  for p in ${P:-}; do
    listen_tcp | grep -qE "[:.]$p\$" && ok "端口 $p 在 LISTEN" || bad "sshd -T 报端口 $p，但 ss 里没有 LISTEN"
  done
  echo "$L" | sed 's/^/    /'

  if have ufw; then
    ufw status 2>/dev/null | head -1 | grep -q 'Status: active' && ok 'ufw active' || bad 'ufw 未启用'
    ufw status 2>/dev/null | sed 's/^/    /'
  fi
  if have nft; then
    $S nft list ruleset 2>/dev/null | grep -E 'hook input.*policy drop' >/dev/null && ok 'nft input policy drop' || bad 'nft input 未见 policy drop'
  fi
  if [ "$INIT_SYS" = openrc ]; then
    iptables -S 2>/dev/null | grep -qE '^-P INPUT DROP' && ok 'iptables -P INPUT DROP' || bad 'iptables INPUT 非 DROP'
    rc-status --all 2>/dev/null | grep -i crashed | sed 's/^/    /'
    rc-update show default 2>/dev/null | sed 's/^/    /'
  else
    fail=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    [ "$fail" -eq 0 ] && ok 'systemctl --failed 为空' || bad "有 $fail 个失败单元（systemctl --failed 查看）"
  fi

  # fail2ban：filter 真的能匹配吗（禁密码后内置 filter 会静默 0 匹配）
  # 判据 = 对合成攻击样本能匹配；线上日志有没有命中取决于有没有攻击，
  # 新机器上必然是 0，不能拿它当门禁（否则永远过不了）。
  if have fail2ban-client; then
    for j in $(f2b_jails); do
      echo "  [$j] $(fail2ban-client status "$j" 2>/dev/null | grep -E 'Currently banned|Total failed|File list' | tr -s ' \t' ' ' | tr '\n' ' ')"
    done
    filter_smoke || bad '没有 filter 匹配上合成样本'
  else
    bad 'fail2ban 未安装（若在 Tier 1 计划内则算失败）'
  fi

  if have f2b-guard; then
    f2b-guard check >/dev/null 2>&1 && ok 'f2b-guard 通过（ignoreip 保命绳在位）' || bad 'f2b-guard 不通过 -> 立刻修 ignoreip，不要重启 fail2ban'
  elif [ -x /usr/local/sbin/f2b-guard ]; then
    /usr/local/sbin/f2b-guard check >/dev/null 2>&1 && ok 'f2b-guard 通过' || bad 'f2b-guard 不通过 -> 立刻修 ignoreip'
  else
    bad 'f2b-guard 未安装（铁律 0 的执行工具，见 SKILL.md §脚本）'
  fi

  hr "结果"
  if [ "$BAD" -eq 0 ]; then
    echo "全部通过。别忘了：报告里写清 改了什么 / 怎么回滚 / 还剩什么可选。"
  else
    echo "$BAD 项未通过，逐条修复后重跑。不要把「已配置」说成「已验证」。"
    exit 1
  fi
}

case "$MODE" in
  recon) recon ;;
  gate) gate ;;
  *) echo "用法: sh $0 [recon|gate]" >&2; exit 2 ;;
esac
