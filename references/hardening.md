# 收尾加固（更新、日志、内核参数、时间同步、内存）

> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> 本文件除 zram 需按规格判断外，全部属于 **Tier 0（默认必做）**。Tier 2 可选组件（nexttrace / BBRv3-lite / 换源 / 代理 / rfw / 蜜罐）见 `optional.md`。

| 项 | 层级 | 判断 |
|---|---|---|
| 系统更新、时区、journald、sysctl/BBR、sudo 日志、logrotate | **Tier 0** | 默认全做，开销近零 |
| zram | Tier 0（有条件） | **仅内存 <2GB 且非容器**；大内存机器不做 |
| 蜜罐 / rfw / Docker / 探针 / 代理脚本 | **Tier 2** | **默认不装**，需用户明确要求 |

> 资源受限的机器上，**少装东西**本身就是最重要的优化。

## 1. 系统更新：`apt upgrade` 会漏掉内核安全更新 ⚠️

```bash
apt-get upgrade --dry-run       | grep -c '^Inst'   # → 0
apt-get full-upgrade --dry-run  | grep -c '^Inst'   # → 2
```

同一个已 `apt update` 过的系统：`apt upgrade` 计划安装 **0** 个包；`full-upgrade` 计划安装 **2** 个，被扣下的正是 `linux-image-6.12.107+deb13-amd64` 与 `linux-image-amd64`。

**原因**：新内核是一个**新包名**（6.12.107 vs 当前 6.12.74）。`apt upgrade` 从不安装新包，只有 `full-upgrade` 会。于是 `apt upgrade` 之后系统看起来"已更新完成"，但**内核安全补丁永远不会被应用**。

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
```

> `--force-confold` 保留现有配置文件，避免被交互式提问卡住或覆盖你的 sshd 配置。

```bash
needrestart -b | grep -E 'KCUR|KEXP|KSTA'
# NEEDRESTART-KCUR: 6.12.74+deb13+1-amd64     当前运行
# NEEDRESTART-KEXP: 6.12.107+deb13-amd64      期望（已装最新）
# NEEDRESTART-KSTA: 3                         ← 3 = 需要重启才能生效
```

> ⚠️ **不要由 agent 擅自重启服务器**：会中断所有会话，必须由用户决定时机。只报告"需要重启"。

## 2. unattended-upgrades（自动安全更新）

```bash
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
```

验证配置真能跑（干跑不要加 `--debug`，输出极长且容易被管道 SIGPIPE 中断）：

```bash
timeout 90 unattended-upgrade --dry-run > /tmp/uu.log 2>&1; echo $?
grep -iE 'error|traceback' /tmp/uu.log      # 期望无输出
systemctl list-timers 'apt-daily*' --no-pager
timeout 100 unattended-upgrade --dry-run --verbose 2>&1 | grep -i "Allowed origins"
```

### ⚠️ 键名发行版相关：Debian 13 用 `Origins-Pattern`，**不是** `Allowed-Origins`

大量教程教你改 `Unattended-Upgrade::Allowed-Origins`。**Debian 13 的 `/etc/apt/apt.conf.d/50unattended-upgrades` 里根本没有这个键**（全文件 165 行、132 行注释，只有 `Origins-Pattern` 和 `Package-Blacklist`）。改一个不存在的键 = 白改，且不报错。而 **Ubuntu 26.04 用的正是 `Allowed-Origins`**——动手前先确认：

```bash
grep -nE 'Origins-Pattern|Allowed-Origins' /etc/apt/apt.conf.d/50unattended-upgrades
```

Ubuntu 实测生效值（`--dry-run --verbose`）：

```
Allowed origins are: o=Ubuntu,a=resolute, o=Ubuntu,a=resolute-security,
  o=UbuntuESMApps,a=resolute-apps-security, o=UbuntuESM,a=resolute-infra-security
```

**Debian 13 的实际写法**：

```
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
```

实测生效值：

```
Allowed origins are: origin=Debian,codename=trixie,label=Debian,
                     origin=Debian,codename=trixie,label=Debian-Security,
                     origin=Debian,codename=trixie-security,label=Debian-Security
```

### 第三方源（Docker / nexttrace 等）

**默认行为是正确的：第三方源不会自动升级**。想让它自动更新必须**逐个精确指定**，先查出该源真实 origin/label（不要猜）：

```bash
apt-cache policy <包名>
cat /var/lib/apt/lists/<该源>_InRelease | grep -E '^(Origin|Label|Suite|Codename):'
grep -rhE '^(deb|URIs)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
```

然后加进 `Origins-Pattern`：`"origin=Docker,label=Docker CE";`

> ⚠️ **绝对不要写 `o=*` 或 `l=*` 图省事**。`o=*` 确实会被接受，但它让**任意**第三方源都进入自动升级范围——等于把供应链信任面无限放大。
>
> **特例（nexttrace 源）**：该源 `InRelease` **只有 `Date` 和校验和，没有 `Origin`/`Label`/`Suite` 字段**，**无法**用 `Origins-Pattern` 精确匹配，应**保持手动更新**。

**装内核后会自动重启吗？默认不会**——`//Unattended-Upgrade::Automatic-Reboot "false";` 被注释 = 默认 false，`apt-config dump` 无输出。UU 可自动装新内核，**但不会自动重启**。若要启用需显式设 `Automatic-Reboot "true"` 与 `Automatic-Reboot-Time`，并清楚它会无预警中断所有会话。

## 3. journald 限额（比 logrotate 管 journal 文件正确得多）

**⚠️ 不要用 logrotate + `copytruncate` 轮转 `/var/log/journal/*.journal`**，那是反模式，会损坏 journal 文件、造成记录丢失或失序。配置 journald 自身：

```bash
install -d -m 755 /etc/systemd/journald.conf.d      # 必须先建目录！
cat > /etc/systemd/journald.conf.d/99-vps-init.conf <<'CONF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=1month
CONF
systemctl restart systemd-journald
systemd-analyze cat-config systemd/journald.conf | grep -E '^(SystemMaxUse|MaxRetentionSec)'
journalctl --disk-usage
```

> ⚠️ 把 `cat > .../99-vps-init.conf` 写在 `install -d` **之前**会静默失败（`No such file or directory`）。**永远先建目录再写文件。**

磁盘紧张时可立即回收：`journalctl --vacuum-size=200M`、`journalctl --vacuum-time=1month`。

**关于 logrotate**：现代 Debian/Ubuntu 最小安装**没有 rsyslog**，`/var/log/syslog`、`/var/log/auth.log` **不存在**，针对它们的 logrotate 配置是**空转**（有 `missingok` 时连报错都没有）。先确认文件真的存在：

```bash
ls /var/log/syslog /var/log/auth.log 2>/dev/null || echo "这些文件不存在，别为它们写 logrotate"
```

- 若确实要写，注意 **`size` 与 `daily` 同时出现时 `size` 优先**。写完用 `logrotate -d /etc/logrotate.d/<file>` 干跑验证语法。

## 4. sysctl / BBR

**容器（LXC/Docker/WSL）内不要改这些**：sysctl 作用于宿主或直接报错。`systemd-detect-virt` 输出 lxc/docker/openvz → 跳过本节。

```bash
cat > /etc/sysctl.d/99-vps-init.conf <<'CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
CONF
sysctl --system
sysctl -n net.ipv4.tcp_congestion_control    # bbr
sysctl -n net.core.default_qdisc             # fq
```

**注意**：`ss -tin` 里看到 `bbr` 只对**新**连接生效，已建立的连接仍用旧算法，属正常。若 `sysctl -n net.ipv4.tcp_available_congestion_control | grep bbr` 为空，先 `modprobe tcp_bbr`。

## 5. 时间同步（chrony vs systemd-timesyncd）

默认 `systemd-timesyncd` 已能满足基本 NTP 需求，**不必盲目换 chrony**。需要更精确/更稳定（跑数据库、证书签发）再换：

```bash
apt-get install -y chrony
systemctl disable --now systemd-timesyncd     # 二者不能共存
systemctl enable --now chrony
chronyc tracking
```

- 时区：`timedatectl set-timezone Asia/Shanghai`，验证 `timedatectl show -p Timezone --value`。**不要**用 `date +%Z` 判断时区（`CST` 可能是 China Standard Time，也可能是美国 Central Standard Time）。

## 6. zram / earlyoom

| 条件 | 建议 |
|---|---|
| 内存 < 2GB 且**非容器**、有 swap 分区 | 可选 zram（`zram-tools`），`ALGO=zstd`、`PERCENT=50` |
| 内存大（如 13GB）且已有 swap | **不需要** zram，装了反而多占 CPU |
| 容器内 | **禁止**（可能影响宿主） |
| 频繁 OOM | 用 `earlyoom` 主动干预，而非加 zram |

```bash
apt-get install -y zram-tools                # 仅在确有必要时
sed -i 's/^#\?ALGO=.*/ALGO=zstd/; s/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
systemctl restart zramswap
zramctl
```

## 7. needrestart

```bash
apt-get install -y needrestart
needrestart -b          # 机器可读输出，便于 agent 解析
```

`needrestart -b` 会把**所有**需重启的服务都列出来（`NEEDRESTART-SVC:` 行），很多是常规库更新，不一定都要立刻重启。重点关注 `KSTA` 与关键服务。

## 8. sudo 日志（🔴 先确认用的是 sudo 还是 sudo-rs）

Ubuntu 26.04 用的是 **`sudo-rs`**（Rust 重写版，`sudo -V` 显示 `sudo-rs 0.2.13-0ubuntu1.2`），向 `/etc/sudoers.d/` 写入 `logfile` / `log_input` / `iolog_dir` 后 `visudo -c` 报：

```
/etc/sudoers.d/99-vps-init-log:1:10: syntax error: unknown setting: 'logfile'
/etc/sudoers.d/99-vps-init-log:2:10: syntax error: unknown setting: 'log_input'
/etc/sudoers.d/99-vps-init-log:3:10: syntax error: unknown setting: 'iolog_dir'
visudo: invalid sudoers file
```

**写错 sudoers 会影响 sudo 可用性，是危险操作。**

**sudo-rs 什么都不用配 —— 默认就把命令记进 journald**：

```bash
journalctl --since "1 minute ago" | grep sudo
#   sudo[5443]: root :  PWD=/root ; USER=nobody ; COMMAND=/usr/bin/true
```

所以 Ubuntu 上**跳过这一节的配置**即可。传统 sudo（Debian 等）的写法：

```bash
sudo -V | head -1        # "Sudo version x.y" = 传统；"sudo-rs ..." = Rust 版

# 仅传统 sudo 使用以下配置：
cat > /etc/sudoers.d/99-vps-init-log <<'CONF'
Defaults logfile="/var/log/sudo.log"
Defaults log_input, log_output
Defaults iolog_dir="/var/log/sudo-io"
CONF
chmod 440 /etc/sudoers.d/99-vps-init-log
install -d -m 700 /var/log/sudo-io
visudo -c                    # 必须校验，写错文件会锁死 sudo
```

> `/etc/sudoers.d/` 下的文件**权限必须是 440（或 400）且属主 root**，否则 sudo 拒绝加载。每次修改后**一定** `visudo -c`——这也是能在造成实际影响前发现 sudo-rs 不兼容的原因。**sudoers 设置也是发行版/实现相关的**，失败就回退最小配置。

## 9. 卸载 snap（Ubuntu 默认必做）

Ubuntu Server 默认装 `snapd`，即使**一个 snap 包都没装**也会带来：常驻 `snapd` 服务、`/snap` 挂载机制、自动刷新（`snapd.refresh.timer`）后台占用，以及把 `firefox`/`chromium-browser` 这类包的 apt 候选**偷换成 snap 跳板包**（`1snap1-0ubuntu9.1` 这种版本号）。服务器上属于纯负担。

```bash
command -v snap                                  # 是否装了
snap list                                        # ⚠️ 有输出就说明有依赖，先迁走再卸
apt-get -s purge snapd | grep -E '^(Remv|Purg)'  # 干跑，看会连带移除什么
apt-cache rdepends --installed snapd             # 谁依赖它
```

**关键判断**：`snap list` **非空**就先迁走，否则卸载会连带删掉应用数据；为空（常见于纯服务器）可安全卸载。实测（Ubuntu 26.04）：`purge snapd` **只移除 snapd 自己**；`command-not-found` 只是 `Suggests: snapd`，**可以保留**（实测重装它不会带回 snapd）。

### 完整卸载（4 步，缺一不可）

```bash
export DEBIAN_FRONTEND=noninteractive

# 1) 卸载主体（--purge 连配置一起）
apt-get purge -y snapd

# 2) 阻止 apt 通过 Recommends/Suggests 把它装回来（关键，否则迟早回来）
install -d -m 755 /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref <<'CONF'
# 阻止 apt 把 snapd 再装回来
Package: snapd
Pin: release a=*
Pin-Priority: -10
CONF

# 3) 清理 PATH 与钩子残留（apt purge 不做这些！）
sed -i 's|:/snap/bin||' /etc/environment                    # 登录 PATH
sed -i 's|:/snap/bin||' /etc/sudoers                        # sudo secure_path ← 最容易漏
: > /etc/apt/apt.conf.d/20snapd.conf                        # apt 的 advise-snap 钩子
# /etc/profile.d/apps-bin-path.sh 会把 /snap/bin 加进 PATH，精简为只设 XDG：
cat > /etc/profile.d/apps-bin-path.sh <<'SH'
# shellcheck shell=sh
# snapd 已移除，原脚本会追加不存在的 /snap/bin 与 /var/lib/snapd/desktop
if [ -z "$XDG_DATA_DIRS" ]; then
    export XDG_DATA_DIRS="/usr/local/share:/usr/share"
fi
SH

# 4) 验证（改过 sudoers 必须 visudo）
visudo -c
```

**验证（必须做，否则你以为清干净了）**：

```bash
command -v snap                       # 应为空
dpkg -l snapd | grep -c '^ii'          # 应为 0
apt-cache policy snapd | grep Candidate   # 应为 (none) ← 证明 Pin 生效
[ -e /snap ] && echo 残留 || echo 已移除
bash -lc 'echo $PATH' | grep snap && echo "⚠️ PATH 仍有残留" || echo "PATH 干净"
grep -rn '/snap/bin' /etc/environment /etc/sudoers /etc/profile.d/ 2>/dev/null
```

### ⚠️ 陷阱：只做 `apt purge snapd` 是不够的

purge 之后 `snap` 命令没了、`/snap` 目录也删了，但 **`sudo` 与登录 shell 的 PATH 里仍留着 `/snap/bin`**——分别来自 `/etc/sudoers` 的 `secure_path`、`/etc/environment`、`/etc/profile.d/apps-bin-path.sh`。**apt purge 不会清理这些**。

### 副作用：想装 firefox/chromium 会报错（这是预期行为）

```
$ apt-get -s install firefox
 firefox : PreDepends: snapd (>= 2.54) but it is not installable
 E: Unable to satisfy dependencies.
```

**这是期望效果**——它逼你不要走 snap 路线。要装浏览器就用官方 deb 仓库：

```bash
install -d -m 755 /etc/apt/keyrings
wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg \
  | tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] \
https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
apt-get update && apt-get install -y firefox
```

## 10. 其他建议项

- `passwd -l root`：锁定 root 密码（不影响密钥登录）。仅在确认有非 root sudo 用户可登录后执行。
- `cloud-init`：若镜像带 cloud-init，它会管理 sshd 配置与 root 登录策略（`/etc/cloud/cloud.cfg` 有 `disable_root: true`）。改 SSH 前先看 `/etc/cloud/cloud.cfg.d/*.cfg` 里的 `ssh_pwauth` / `disable_root`，否则重启后被覆盖。
- 定期巡检：`lynis` 或本 skill 的 `scripts/preflight.sh` 重跑做基线对比。

> 验收：`sh scripts/vps-check.sh gate`
