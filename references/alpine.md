# Alpine Linux 支持（OpenRC，无 systemd）
> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> 环境：Alpine 3.24.2（内核 6.18.53-0-virt，KVM，2C/3.9G）。**Alpine 与 Debian 差异极大**，照搬 Debian 配置会静默失效。

## 1. 一分钟速查：Alpine vs Debian/Ubuntu

| 维度 | Debian/Ubuntu | **Alpine** | 影响 |
|---|---|---|---|
| init | systemd | **OpenRC** | `systemctl` → `rc-service` / `rc-update` |
| 日志 | journald | **busybox syslogd** | 无 `journalctl`；日志在 `/var/log/messages`；`logread` 常为空 |
| shell | bash | **busybox ash** | **无 bash**；脚本必须 POSIX sh（bash 数组直接报错） |
| 包管理 | apt | **apk** | `apt install` → `apk add`；需先 `apk update` |
| libc | glibc | **musl** | glibc 动态二进制**无法运行**（见 §6） |
| 改 shell | `chsh -s` | **`chsh` 不存在** | 直接改 `/etc/passwd`（见 §5） |
| 服务自启 | `systemctl enable` | `rc-update add X default` | **apk 装的服务不会自动注册**（见 §3） |
| 防火墙后端 | nftables 优先 | **iptables（nf_tables 后端）** | fail2ban 用 `iptables-*` action |
| 定时任务 | systemd timer | **crond + /etc/periodic** | logrotate 靠 `/etc/periodic/daily/logrotate` |
| sysctl 持久化 | `/etc/sysctl.d/` | 同左，但由 `/etc/init.d/sysctl` 读取 | 需确认服务在跑 |
| 内核模块 | `systemd-modules-load` | **`/etc/modules`** | BBR 需显式写 `tcp_bbr`（见 §4） |
| `/usr/local/sbin` | 默认存在 | **默认不存在**（但在 PATH 里） | 装脚本前先 `mkdir -p` |
| 时区 | `timedatectl` | **`/etc/localtime`**（软链） | 无 `timedatectl` |
| 主机名 | `hostnamectl` | **`/etc/hostname`** (+ `hostname X`) | 镜像可能留 `localhost` |

## 2. 勘察与包安装
```bash
cat /etc/alpine-release                    # 3.24.2
cat /proc/1/comm                           # init（OpenRC）
rc-status --all                            # 所有 runlevel 与服务
rc-update show default                     # 开机自启列表
apk info | wc -l                           # 已装包数
cat /etc/apk/repositories                  # 仓库
command -v bash || echo "无 bash → 脚本必须 POSIX sh"
command -v chsh || echo "无 chsh → 改 /etc/passwd"
```

**关键**：`systemd-detect-virt`、`timedatectl`、`journalctl` **都不存在**，不要用。

```bash
apk update                    # 全新镜像必做（对应 Debian 的"没 update 就装"陷阱）
apk add --no-cache fail2ban ufw nftables iptables logrotate zsh git curl wget
```

- `--no-cache` 避免保留索引（Alpine 惯例，省磁盘）
- Alpine 的 `fail2ban` **硬依赖 `iptables`**（不是 nftables）；但 `iptables 1.8.13` 后端是 `nf_tables`，性能等效
- **`apk add` 后必须 `rc-update add <svc> default`**，否则重启不生效（见 §3）

## 3. 🔴 ufw 装了但没注册 runlevel
`ufw` 包会装 `/etc/init.d/ufw`，但**不会**自动加入 runlevel。更迷惑的是 `ufw --force enable` 会打印 "enabled on system startup"，**但那是 ufw 自己的 `/etc/ufw/ufw.conf` 里的 `ENABLED=yes`，与 OpenRC 的开机自启是两回事**：
```bash
# 实测：ufw enable 之后
$ rc-update show default | grep ufw
                                  # ← 空！重启后规则会丢
$ rc-service ufw status
 * status: stopped                # ← 也是 stopped（规则却已在内核）
# 正确做法：
rc-update add ufw default
rc-service ufw start             # 用 OpenRC 管理，别只依赖 ufw enable
```
```bash
rc-update show default | grep ufw          # 应显示 "ufw | default"
iptables -S | grep -E '^-P INPUT'          # 【关键】应为 -P INPUT DROP
ufw status | head -1                       # Status: active
```

> **判断防火墙是否真的生效，永远看内核规则**（`iptables -S` / `nft list ruleset`），不要只看 `ufw status` 或服务状态。

## 4. BBR / sysctl（Alpine 差异）
```bash
modprobe tcp_bbr
grep tcp_bbr /proc/sys/net/ipv4/tcp_available_congestion_control || true
# 1) 写 sysctl（/etc/init.d/sysctl 会读 /etc/sysctl.d/*.conf）
cat > /etc/sysctl.d/99-vps-init.conf <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
CONF
sysctl -p /etc/sysctl.d/99-vps-init.conf
# 2) ⚠️ 关键：确保开机时 bbr 模块已载入，否则 sysctl 会回落到 cubic
grep -q '^tcp_bbr' /etc/modules || echo 'tcp_bbr' >> /etc/modules
# 3) 验证
sysctl -n net.ipv4.tcp_congestion_control   # bbr
sysctl -n net.core.default_qdisc            # fq
```

> `/etc/modules` 由 OpenRC 的 `modules` 服务读取（不同于 systemd 的 `modules-load.d`）。

## 5. zsh + oh-my-zsh（Alpine）
```bash
apk add --no-cache zsh git          # 不是 apt
# ⚠️ Alpine 没有 chsh —— 直接改 /etc/passwd
cp /etc/passwd /etc/passwd.bak-vps-init
sed -i 's|^\(root:[^:]*:[0-9]*:[0-9]*:[^:]*:[^:]*:\).*$|\1/bin/zsh|' /etc/passwd
grep '^root:' /etc/passwd | cut -d: -f7      # 验证：/bin/zsh
```
其余（oh-my-zsh、clone 两个外部插件、最后覆盖 `.zshrc`）与 `zsh.md` 完全相同。

## 6. 🔴 musl vs glibc：预编译二进制跑不起来
glibc 动态链接的二进制会直接报 `not found`（极具误导性——文件明明存在、权限也对）。
```bash
$ ldd sshesame
  /lib64/ld-linux-x86-64.so.2               # ← glibc 的 loader
$ ./sshesame -h
  sh: /usr/local/bin/sshesame: not found    # ← 实际是 loader 缺失
```

**① 首选：Go 交叉编译纯静态二进制**（`CGO_ENABLED=0`，否则会链到宿主 glibc，等于没解决）

```bash
git clone --depth=1 https://github.com/jaksi/sshesame /tmp/sshesame-src
cd /tmp/sshesame-src
env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomod \
    go build -trimpath -ldflags="-s -w" -o sshesame-static .
ldd sshesame-static          # 应显示 "not a dynamic executable"
```

> `GOCACHE`/`GOMODCACHE` 显式指定可避开 `$HOME/.cache` 权限问题。

**② 兜底：装 gcompat（Alpine 官方 glibc 兼容层）**

```bash
apk add --no-cache gcompat        # 实测可让 glibc 二进制跑起来
./sshesame -h                     # 现在有输出了
```

> gcompat 是权宜之计（多一层翻译、可能遇 glibc API 缺失）。**能用静态编译就用静态编译**。

**判断二进制是否兼容的最小检查**：

```bash
ldd <binary> 2>&1 | head -3
#  "not a dynamic executable"          → 静态，OK
#  "/lib/ld-musl-x86_64.so.1"          → musl 动态，OK
#  "/lib64/ld-linux-x86-64.so.2"       → glibc 动态，❌ 不能直接用
```

**好消息**：很多 Go/Rust 项目提供 musl 构建。`rfw` 有 `rfw-x86_64-unknown-linux-musl`（实测直接可用）；`nexttrace_linux_amd64` 本身静态（实测 OK）。

## 7. 🔴 fail2ban：Alpine 与 systemd 版完全不同
四处必须改（照搬 Debian 配置会**静默失效**）：
### ① backend 必须是 `auto`（无 journald）
```ini
[DEFAULT]
backend = auto            # 不是 systemd！
```
`/etc/fail2ban/paths.conf` 在 Alpine 上是**空的**，所以 `auto` 找不到路径时**必须显式写 `logpath`**：
```ini
[sshd]
logpath = /var/log/messages
```
### ② 每个 jail 的日志文件不同
- sshd 写 **`/var/log/messages`**（busybox syslogd）
- sshesame 写 **它自己的 `/var/log/sshesame.log`**（OpenRC 的 `output_log`）

**别把两个 jail 指向同一个文件**（用 `sed` 批量改会导致 sshd jail 也指向 sshesame 的日志，`File list` 看起来"正常"但监控完全错位）。
### ③ banaction 用 iptables 系列
```ini
banaction          = iptables-multiport     # 不是 nftables
banaction_allports = iptables-allports
```
Alpine 的 fail2ban 只带 iptables action 为默认（`nftables*.conf` 文件在，但默认链到 iptables）。
### ④ 🔴 禁密码后，内置 sshd filter 匹配不到任何东西
`PasswordAuthentication no` 时 sshd **永远不会**产生 `Failed password` 行：
```
$ fail2ban-regex /var/log/messages /etc/fail2ban/filter.d/alpine-sshd.conf
Lines: 53 lines, 0 ignored, 0 matched, 53 missed      ← 完全失效
$ fail2ban-regex /var/log/messages /etc/fail2ban/filter.d/sshd.conf
Lines: 53 lines, 0 ignored, 0 matched, 53 missed      ← 同样失效
```
攻击者留下的唯一痕迹是 **`Connection closed ... [preauth]`**（端口扫描），内置 filter 不匹配它：
```ini
# /etc/fail2ban/filter.d/vps-init-sshd.conf
[Definition]
_daemon = sshd-session
failregex = ^.*sshd(-session)?\[\d+\]: Connection closed by <HOST> port \d+ \[preauth\]\s*$
            ^.*sshd(-session)?\[\d+\]: Invalid user .* from <HOST> port \d*
            ^.*sshd(-session)?\[\d+\]: Received disconnect from <HOST> port \d+:\d+:  \[preauth\]\s*$
            ^.*sshd(-session)?\[\d+\]: Did not receive identification string from <HOST>\s*$
ignoreregex = ^.*sshd(-session)?\[\d+\]: Accepted (publickey|password) for .*
[Init]
maxlines = 10
```
实测：同一份日志从 **0 matched → 5 matched**。

> **权衡**：`Connection closed [preauth]` 也可能是正常客户端异常断开，所以 `maxretry` 设 **5**（而非 3）以降低误伤。

**Alpine 日志格式特点**：busybox syslogd 会插入 `facility.level` 层：

```
Sep 27 14:03:22 localhost auth.info sshd-session[6266]: Connection closed by <攻击者IP> port 5678 [preauth]
                          ^^^^^^^^^ 多这一层
```
用 `^.*` 兜住前缀最稳妥；**不要**行首锚定到 `[`。
### 关键验证
```bash
fail2ban-regex /var/log/messages     /etc/fail2ban/filter.d/vps-init-sshd.conf | grep Lines   # matched > 0
fail2ban-regex /var/log/sshesame.log /etc/fail2ban/filter.d/sshesame.conf      | grep Lines   # matched > 0
# 两个都必须 matched > 0，否则等于没装
```

## 8. OpenRC 服务（替代 systemd 单元）
```sh
#!/sbin/openrc-run
name="myapp"
description="..."
command="/usr/local/bin/myapp"
command_args="--foo"
command_background="yes"          # 后台运行（否则 OpenRC 等它退出）
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/myapp.log"   # ⚠️ 日志去这里，不是 /var/log/messages
error_log="/var/log/myapp.log"
depend() {
	need net
	after firewall
}
start_pre() {
	checkpath --directory --mode 0700 /var/lib/myapp
	touch /var/log/myapp.log
	chmod 640 /var/log/myapp.log
}
```
```bash
chmod 755 /etc/init.d/myapp
rc-update add myapp default
rc-service myapp start
```
### 🔴 `restart` 会杀掉现有 SSH 连接
```bash
rc-service sshd restart      # ← 实测：who 从 1 个用户变成 0，连接被切断！
rc-service sshd reload       # ← 正确：平滑重载，不断连
```

**Alpine 上改 SSH 配置一律用 `reload`**。必须有第二条连接或死手开关兜底才能 `restart`。

## 9. 死手开关（Alpine 版）
两个必须的差异：

1. **shebang 必须是 `#!/bin/sh`** —— 无 bash 时写 `#!/bin/bash` 会导致 `at` 到点执行失败（`sh: bash: not found`），**死手开关形同不存在**。
2. **服务重启用 `rc-service`**，且死手场景下用 `restart` 是**可接受的**（目的就是恢复访问，断连无所谓）。

```sh
#!/bin/sh
set -u
logger -t deadman "fired at $(date -Is)"
HD=/etc/ssh/sshd_config.d/00-hardening.conf
{
  printf '# deadman fired %s\n' "$(date -Is)"
  echo 'PasswordAuthentication yes'
  echo 'KbdInteractiveAuthentication yes'
  echo 'PermitRootLogin prohibit-password'
  echo 'PubkeyAuthentication yes'
  echo 'Port 22'
} > "$HD"
if /usr/sbin/sshd -t; then rc-service sshd restart; fi
```
```bash
apk add --no-cache at
rc-update add atd default
rc-service atd start
echo /root/ssh-deadman.sh | at now + 45 minutes && atq
```

> 务必用 `sh -n` 验证脚本。其余死手开关的实现陷阱（`Port` 是多值参数不能靠覆盖回退）见 `ssh-firewall.md` §2。

## 10. 日志轮转（Alpine）
自带 `/etc/periodic/daily/logrotate`（无需 systemd timer），但 **`/var/log/messages` 默认没有轮转规则**（busybox syslogd 会无限增长）。
```bash
cat > /etc/logrotate.d/vps-init <<'CONF'
/var/log/messages {
	weekly
	rotate 4
	missingok
	notifempty
	compress
	delaycompress
	copytruncate
	create 0640 root root
}
CONF
logrotate -d /etc/logrotate.conf      # 干跑验证
```

> Alpine 用 `copytruncate` 更稳（syslogd 不会重开文件）。

## 11. Alpine 上各组件可用性

| 组件 | 可用性 | 做法 |
|---|---|---|
| ufw | ✅ | **必须 `rc-update add ufw default`**（§3） |
| nftables | ✅ | `apk add nftables`；内核有 `nf_tables.ko` |
| iptables | ✅ | 后端是 `nf_tables` |
| fail2ban | ⚠️ 需适配 | backend/logpath/filter/banaction 四处都要改（§7） |
| logrotate | ✅ 自带 periodic | 补 `/var/log/messages` 规则（§10） |
| zsh + oh-my-zsh | ✅ | 无 `chsh`，改 `/etc/passwd`（§5） |
| nexttrace | ✅ 静态 | apk 无包；上游 `nexttrace_linux_amd64` 静态，直接用 |
| sshesame | ⚠️ 需静态编译 | 官方二进制是 glibc；`CGO_ENABLED=0` 自编译（§6） |
| rfw | ✅ 有 musl 构建 | `rfw-x86_64-unknown-linux-musl`；需 BTF（`/sys/kernel/btf/vmlinux`） |
| Docker | ✅ | `apk add docker`; `rc-update add docker default` |

> rfw 在 Alpine 的安装命令与坑见 `optional.md` §5「Alpine 上的 rfw 要点」。

> 验收：`sh scripts/vps-check.sh gate`
