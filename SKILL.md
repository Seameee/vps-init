---
name: vps-init
description: "Initialize and harden a Linux VPS (Debian/Ubuntu/Alpine). Use when asked to 初始化服务器, VPS 初始化, 服务器加固, 配置防火墙, SSH 安全加固, 装 fail2ban, 部署 SSH 蜜罐, 装 zsh/oh-my-zsh, 卸载 snap, alpine 初始化, openrc, harden a VPS, set up a server, 屏蔽中国 IP, rfw. Covers tiered minimal-by-default hardening, sshd/fail2ban, honeypot log ingest, BBR, zram, log rotation. Also audits an existing server."
metadata:
  version: "4.0"
  repo: "https://github.com/Seameee/vps-init"
  license: "MIT"
  platforms: "debian | ubuntu (ID_LIKE=debian) | alpine (OpenRC)"
---

# VPS Init & Hardening

**设计原则：默认极简。** 探针、蜜罐、Docker 这类重资源项一律**不默认安装**。
按机器规格与用户意愿决定装到哪一层（Tier 0 必做 / Tier 1 按需 / Tier 2 默认不装）。

## 0. 先判断发行版与 init 系统

```bash
cat /etc/os-release; cat /proc/1/comm
command -v systemctl >/dev/null && echo systemd || echo openrc
command -v bash >/dev/null || echo "无bash -> 脚本必须 POSIX sh"
```

| 若是 | 用 | 详见 |
|---|---|---|
| Debian / Ubuntu | `systemctl` / `journalctl` / `apt` | 本文件 + `references/hardening.md` |
| **Alpine** | `rc-service` / `logread` / `apk` | **`references/alpine.md`（必读）** |

> Alpine 是另一套体系（OpenRC、musl、无 bash、无 journald），照搬 Debian 命令会大面积静默失效。

## 部署方式：一切从 GitHub 拉，不要手抄

**脚本与配置一律用 curl 从仓库拉取，禁止用 heredoc / base64 把代码"抄"进终端**
（既费 token，又容易抄错、截断、少一行）。仓库：`github.com/Seameee/vps-init`

```bash
REPO=https://raw.githubusercontent.com/Seameee/vps-init/main
# 只读勘察（不落地执行可先 head 看一眼）
curl -fsSL $REPO/scripts/vps-check.sh -o /tmp/vps-check.sh
sh /tmp/vps-check.sh recon | tee /tmp/recon.out      # Alpine/Debian 通用
```

其余文件同理（`$REPO/scripts/f2b-guard.sh`、`$REPO/assets/zshrc.zshrc`、
`$REPO/references/<name>.md`）。**本地已有仓库副本时**直接用本地路径，不必联网。

技能目录本身就是该仓库的克隆，更新即 `git -C ~/.dsh/skills/vps-init pull --ff-only`。
改了技能要发布：`git add -A && git commit && git push`（改完先本地 `sh -n` 过一遍语法）。

## 分层

| 层 | 内容 | 说明 |
|---|---|---|
| **Tier 0 必做** | SSH 加固 / 时区+时间同步 / 系统更新 / 日志限额 / sysctl+BBR / zram(<2G) / sudo 日志 / **Ubuntu 卸 snap** | 纯配置，无常驻进程 |
| **Tier 1 按需** | ufw / fail2ban / zsh+oh-my-zsh / nexttrace | 低开销但常驻；**zsh 必须问** |
| **Tier 2 默认不装** | SSH 蜜罐(sshesame) / rfw / Komari 探针 / Docker / BBRv3-lite 换内核 | 重资源或高风险 |

> 1C1G / 512M 机器只做 Tier 0。装之前先问：这台机器的角色是什么？要暴露什么？

## 铁律

0. 🔴 **永不封锁管理 IP。** 优先于一切测试与"临时改动"。
   `ignoreip` 里的管理 IP 是保命绳：`allports` 封禁下管理 IP 被 ban = **全端口失联**（实测整机锁死）。
   - ❌ 为测试封禁逻辑移除/放宽 `ignoreip`；❌ 在 allports jail 上用管理 IP 做测试
   - ✅ 装 `f2b-guard`，改完 jail 一律 `f2b-guard restart`，**不要**裸 `systemctl restart fail2ban`
   - ✅ 本技能所有文件**不写具体 IP**；脚本自动取 `$SSH_CONNECTION`，或读 `/etc/fail2ban/guard-ips`
1. **先勘察再动手**：`vps-check.sh recon` 跑完并读懂前，不改任何系统配置。
2. **配置写完 ≠ 生效**：每个改动都要有运行时验证命令（见 §验收）。
3. **不可逆动作必须有回滚路径**：动 SSH/防火墙/端口前先建死手开关（`references/ssh-firewall.md` §1）。
4. **保留一条已认证的旧连接不关**，新连接验证成功后再关。
5. **命令失败就停下报告**，不要叠加；**永远不要** `pkill sshd`。
6. 容器内禁止改 sysctl/BBR、配 zram、动主机防火墙（ufw 在容器内通常不可用）。
7. 不要 `curl | bash` 第三方脚本；**本仓库自己的脚本可以**（同一信任域），其余先下载审阅。

## 生产模式 vs 开发模式

| | 生产（给机器做初始化） | 开发（改本 skill） |
|---|---|---|
| 验证范围 | 只做 §验收 里的门禁 | 每项实测复现、含反例 |
| 测试动作 | **不制造测试流量、不做性能基准、不做双向对照** | 故意触发、记录失败形态 |

> 生产机上多余测试既费时间又引入风险（本技能曾因"测试封禁逻辑"把管理 IP 封掉、整机失联）。

## 流程（顺序即安全约束）

```
0. recon 勘察（只读）
1. 问用户选到哪一层（不许自行决定；zsh/换端口/换内核必须单独确认）
2. 排包索引 + 基础包：apt-get update && apt-get full-upgrade -y / apk update && apk upgrade
3. 【仅 Ubuntu】卸 snap（purge + Pin + 清 PATH 残留 → hardening.md §9）
4. 校验/追加 SSH 公钥（只追加不截断，写后 ssh-keygen -l 验指纹）
5. 挂死手开关（at now + 20 minutes）        ← 不可逆动作前
6. fail2ban（+ f2b-guard 立刻装上）→ 放行新 SSH 端口 → 防火墙 default deny
7. 验证新端口能登录（硬门）→ 此时才禁密码登录/限 root → 再验证（硬门）
8. 迁端口（如需）→ Tier 2 可选件 → zsh 放最后（改默认 shell，失败不阻塞）
9. 撤销死手开关（atrm）+ vps-check.sh gate 验收
```

**最容易出事的点**：步骤 4 之前不碰认证配置；步骤 7 的硬门必须真连一次；
迁端口必须在放行新端口之后；卸 snap 要在 SSH 加固**之前**做完（别同时引入两个变更面）。

改 SSH 前先判断形态（三种）：

```bash
command -v rc-service >/dev/null && echo "OpenRC: 改 sshd_config.d 的 Port + rc-service sshd reload"
systemctl is-active ssh.socket                     # socket 激活？
test -f /run/systemd/generator/ssh.socket.d/addresses.conf && echo "有 generator(Ubuntu)"  # 手写 ListenStream 会被覆盖
```

## 必问项（即使用户已选层级）

1. **zsh / oh-my-zsh / 自定义 .zshrc**？内置已验证配置：`assets/zshrc.zshrc`
2. **SSH 是否换端口？22 是否给蜜罐占着？**
3. 是否需要按国家方向屏蔽（rfw）？
4. 是否装 BBRv3-lite 的 `bbr kernel install`（换 XanMod 内核 + 改 GRUB，高风险）？

用户不在场/说"按推荐来"时：默认 **Tier 0 + Tier 1(ufw, fail2ban, nexttrace)**，
zsh/蜜罐/rfw/Docker/换内核一律不装，并在报告里写清实际装了什么。

## 陷阱速查

全部是"看起来成功、其实没生效"。逐条实测复现过，细节见对应 reference。

### 通用 / Debian / Ubuntu

| 陷阱 | 正确做法 |
|---|---|
| `apt upgrade` 不装新内核 | 用 `apt-get full-upgrade` |
| 全新系统索引过期 → 安装报 404 | 任何安装前先 `apt-get update` |
| `unattended-upgrades` 占着 dpkg 锁（实测跑了 11 分钟） | 先 `fuser /var/lib/dpkg/lock-frontend`，**等待**不要强杀；`>/dev/null` 会把"没装上"伪装成成功 |
| fail2ban 默认 `banaction=nftables` 但不装 nftables → 封禁静默失效 | `apt install nftables && systemctl restart fail2ban` |
| jail.d 覆盖了正确的 `journalmatch`（OpenSSH 10 进程名是 `sshd-session`）→ `Total failed` 恒为 0 | 用 **`zz-` 前缀**文件（须排在 `defaults-debian.conf` 之后），显式写两个 `_COMM` |
| 改 jail 端口后 `reload` 不重建 nft 规则（仍是旧端口） | 改端口必须 `restart`；验收看 nft 里的 dport |
| `install /dev/null <authorized_keys>` 清空公钥 | 只 `touch` + 去重追加，写后 `ssh-keygen -l -f` |
| Debian 13 无 rsyslog，`/var/log/auth.log` 不存在 | fail2ban 用 `backend = systemd`；logrotate 别管 journal 文件 |
| logrotate `copytruncate` 轮转 `.journal` 会损坏日志 | 用 `journald.conf` 的 `SystemMaxUse` |
| `ufw --dry-run enable` 会挂起 | 用 `ufw --force enable` |
| `systemctl is-active ufw` 显示 inactive 是正常的（oneshot） | 看 `ufw status` + nft `policy drop` |
| 先写文件后建目录 → 静默失败 | 永远先 `install -d` |
| `apt install endlessh` 会自动 enable 并监听 2222 | 装完 `systemctl disable --now endlessh`；任何 apt install 后复查 `ss -tlnp` |
| Debian 13 用 `Origins-Pattern`，Ubuntu 用 `Allowed-Origins` | 先 grep 实际键名再改；别写 `o=*`（供应链风险） |
| Ubuntu 26.04 用 `sudo-rs`，不认 `logfile`/`iolog_dir` | sudo-rs 默认记 journald；改 sudoers 后必须 `visudo -c` |
| Ubuntu 手写 `ssh.socket.d/ListenStream` 被 generator 覆盖（实测 22 掉了） | 改 `sshd_config.d` 的 `Port`（多值），再 `daemon-reload` + `restart ssh.socket`；必查 `ss -tlnp` |
| Ubuntu 卸 snap 后 `/snap/bin` 仍在 PATH | 清 4 处残留：`/etc/sudoers` secure_path、`/etc/environment`、`/etc/profile.d/apps-bin-path.sh`、`apt.conf.d/20snapd.conf` |
| `Port` 是多值参数，死手开关"覆盖"不掉它 | `sshd -T` 会得到 `port 22 port 22222`；涉及端口要**重写**加固文件；死手文件名须排在加固文件**之前** |
| 远端 `/dev/tcp` 探测端口不可信（透明代理下任何端口都"开放"） | 用服务器侧 nft `policy drop` + 计数器，或端到端真实连接 |
| 只跑一个子命令就断定大脚本"不会改 X" | 先 `grep -nE 'kernel\|grub\|sources.list\|sysctl'` 穷尽能力（bbrv3-lite 就有 `bbr kernel install`） |
| 蜜罐 jail 用 `nftables[type=allports]` 会把管理端一起封（连 22222 也 `Connection closed`） | 见铁律 0；恢复靠**另一个 IP**（跳板机 `ssh -J`）`fail2ban-client set <jail> unbanip <你的IP>` |
| `ignoreself` 是独立于 `ignoreip` 的第二道忽略 | 本机自发测试永远 0 命中；用真正外部源或 `fail2ban-regex` 离线验证 |
| 蜜罐 `maxretry=3` 等于不封（扫描器只试 2 次就走） | 蜜罐 jail 设 `maxretry=1` |
| `ssh -i <key>` 报 `ssh-askpass: No such file`（有 DISPLAY 时），伪装成"命令不存在" | 加 `BatchMode yes` 或 `env -u DISPLAY -u WAYLAND_DISPLAY` |
| oh-my-zsh 的 `plugins=(...)` 外部插件不会自动装 | 先 `grep -A6 '^plugins='`，clone 到 `custom/plugins/`；顺序：omz → 插件 → 最后覆盖 `.zshrc` |
| 装完 zsh 当前会话仍是 bash | 正常，`exec zsh` 或重连；别改当前进程的 shell |
| 脚本用 `set -e` + "预期失败"的检查 → 恢复步骤没执行 | 含预期失败的检查就不要 `set -e`，或 `check \|\| true`；测完复核最终状态 |

### Alpine 专属

| 陷阱 | 正确做法 |
|---|---|
| 🔴 没有 bash，`#!/bin/bash` 的死手开关到点报 `sh: bash: not found` | 全部 POSIX sh，`sh -n` 验证；`f2b-guard.sh` 已是 POSIX |
| 🔴 禁密码后内置 sshd filter 完全 0 匹配（实测 53 行 0 命中） | 自定义 filter 抓 `Connection closed ... [preauth]`，`maxretry=5`；必须 `fail2ban-regex` 验 matched>0 |
| fail2ban 是 iptables 后端、必须 `backend = auto` | 显式 `logpath` + `banaction = iptables-multiport/allports` |
| 多个 jail 指向同一个日志文件 → 监控错位 | sshd 读 `/var/log/messages`，sshesame 读自己的 log；逐个核对 `File list` |
| 🔴 apt/apk 装的服务不会自动注册开机自启（ufw 尤其） | 每个服务 `rc-update add <svc> default`；看内核规则判断生效 |
| 🔴 musl 跑不了 glibc 二进制，报 `sh: /path: not found`（文件明明在） | `ldd` 看 `ld-linux`，用 `CGO_ENABLED=0` 静态编译或 `apk add gcompat` |
| 🔴 `rc-service sshd restart` 会切断当前会话（`who` 从 1 变 0） | 改配置用 `reload`；`restart` 只留给死手开关且须有第二条入口 |
| 无 `chsh`、无 `/usr/local/sbin`、无 `timedatectl` | 改 `/etc/passwd`；先 `mkdir -p /usr/local/sbin`；时区用 `/etc/localtime` 软链 |
| `/var/log/messages` 默认不轮转 | 补 logrotate 规则用 `copytruncate`（`/etc/periodic/daily/logrotate` 触发） |
| BBR 重启后丢 | `/etc/modules` 写 `tcp_bbr` + `/etc/sysctl.d/` |

## 验收

```bash
sh /tmp/vps-check.sh gate        # 失败项直接给修复提示
```

`gate` 覆盖：新端口可登、密码认证被拒、`ss -tlnp` 与预期一致、
防火墙 `policy drop` 且只放行必要端口、`systemctl --failed` 为空（Alpine 用 `rc-status`）、
`fail2ban-regex` matched>0、`f2b-guard check` 返回 0。

> **不要把「已配置」说成「已验证」。** 特别地：禁密码的机器上 fail2ban 内置 filter
> 会静默 0 匹配，**必须**用 `fail2ban-regex` 证明 matched > 0。
> 交付时写清：改了什么 / 怎么回滚 / 还剩什么可选。

## 参考文件

| 文件 | 内容 |
|---|---|
| `references/alpine.md` | Alpine/OpenRC 全套差异（Alpine 必读） |
| `references/ssh-firewall.md` | SSH 加固+防自锁死手开关、端口迁移、ufw/nftables、Docker 绕过 |
| `references/fail2ban.md` | 三个"装完等于没装"的坑、推荐配置、蜜罐日志接入 |
| `references/hardening.md` | 系统更新、unattended-upgrades、journald、sysctl/BBR、时间、zram、sudo 日志、卸 snap |
| `references/optional.md` | nexttrace / BBRv3-lite / 换源 / 代理 / rfw / SSH 蜜罐 / 资源开销 |
| `references/zsh.md` | zsh + oh-my-zsh + 自定义 `.zshrc`（含内置资产说明） |
| `references/rollback.md` | SSH/防火墙/fail2ban 锁死后的恢复路径 |

## 脚本

- `scripts/vps-check.sh recon` — **只读**勘察（第一步必跑），自适应 systemd/OpenRC。
- `scripts/vps-check.sh gate` — 加固后验收门禁。
- `scripts/f2b-guard.sh` — ignoreip 守卫，铁律 0 的执行工具；不含硬编码 IP。
  装到 `/usr/local/sbin/f2b-guard`：`f2b-guard check`（0=安全）／`f2b-guard restart`（守卫通过才重启）。

**不提供一键加固大脚本**：把探测、决策、不可逆变更塞进一个 root 脚本，
正是旧 `linux-init.sh` 失败的根因。
