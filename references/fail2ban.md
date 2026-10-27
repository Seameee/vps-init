# fail2ban

> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> **最重要的结论**：Debian 13 的 fail2ban 装完看起来"已启用、有 jail、封禁命令返回成功"，**但封禁实际完全没有生效**。3 个独立的坑，每个都能让防护变成摆设，且**全都无法通过读配置文件发现**，必须实测。

| # | 坑 | 一句话 |
|---|---|---|
| 1 | 默认 `banaction=nftables`，但 `nftables` 包不装 | 封禁命令返回成功，防火墙里什么都没发生 |
| 2 | 改端口后 `reload` 不重建规则 | 规则里还是旧端口，防护打在错端口 |
| 3 | **jail.d 的 `journalmatch` 覆盖了 filter 的正确值** | OpenSSH 10 进程名变成 `sshd-session`，jail 读不到任何日志 |

## 1. 坑 3（最隐蔽）：`defaults-debian.conf` 让 fail2ban 读不到 SSH 日志

现象：制造 5 次真实失败登录后 `fail2ban-client status sshd` 仍是 `Currently failed: 0` / `Total failed: 0`。

根因：Debian 13 的 OpenSSH 是 **10.0p2**，SSH 会话进程改名成 **`sshd-session`**（监听进程仍是 `sshd`）：

```
_SYSTEMD_UNIT = ssh.service
_COMM         = sshd-session      # ← OpenSSH 10 的新名字
SYSLOG_IDENTIFIER = sshd-session
```

filter 已知此事（`/etc/fail2ban/filter.d/sshd.conf` 第 129 行）：

```ini
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
```

**但 `/etc/fail2ban/jail.d/defaults-debian.conf` 覆盖成了过期的单值**：

```ini
[sshd]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd      # ← 匹配不到 sshd-session
enabled = true
```

于是 `fail2ban-client get sshd journalmatch` 返回错误的那一个。`journalctl` 1 小时窗口对比：`_COMM=sshd` → **17 行**（多为监听进程/无关行），`_COMM=sshd-session` → **31 行**（真正的认证失败都在这里）。

**修复：用排在 `d` 之后的文件名覆盖。** ⚠️ `jail.d` 按文件名字母序加载，后加载者覆盖先加载者；`'9' < 'd'`，所以 `99-vps-init.conf` **先**加载被覆盖（白写），必须用 `zz-`。

```ini
# /etc/fail2ban/jail.d/zz-vps-init.conf       ← 必须排在 defaults-debian.conf 之后
[DEFAULT]
backend   = systemd
ignoreip  = 127.0.0.1/8 ::1 <你的管理IP>
bantime.increment = true
bantime.factor    = 1.5
bantime.maxtime   = 4w
bantime   = 1h
findtime  = 10m
maxretry  = 3
banaction = nftables

[sshd]
enabled  = true
port     = 22222
mode     = aggressive
maxretry = 3
# 显式写全，修正 Debian 默认值漏掉 sshd-session 的问题
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session

[recidive]
enabled   = true
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = nftables
findtime  = 1d
bantime   = 1w
maxretry  = 3
```

```bash
fail2ban-client -t                  # OK: configuration test is successful
systemctl restart fail2ban
fail2ban-client get sshd journalmatch
# 必须返回：_SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
```

**关键验证（filter 匹配能力，最关键的一项）**：

```bash
journalctl -u ssh --since "10 minutes ago" --no-pager \
  | grep -E "Invalid user|Failed|Connection closed by authenticating" > /tmp/sshlog.txt
fail2ban-regex /tmp/sshlog.txt /etc/fail2ban/filter.d/sshd.conf
# 实测：Lines: 8 lines, 3 ignored, 5 matched, 0 missed    ← 关键看 matched
grep -iE "Ignore|Ban|Found" /var/log/fail2ban.log | tail
# 实测：INFO [sshd] Ignore 127.0.0.1 by ignoreself rule
```

> ⚠️ `journalctl -o cat` 会剥掉时间戳/主机名前缀，导致**全部 missed**——那是测试方法错，不是 filter 错。**必须用默认输出格式**。
>
> **本质**：OpenSSH 升级改变了进程名，fail2ban 的发行版默认配置没跟上。凡是"安全组件 + 系统主组件升级"的组合都要怀疑这种错配。**判断方法**：不看配置写得多正确，看 `Total failed` 在制造失败后**是否增长**。

## 2. 坑 1：默认 banaction 是 nftables，但 nftables 包不装

`defaults-debian.conf` 自带 `banaction = nftables`，但 **fail2ban 包并不依赖 `nftables` 包**：

```
fail2ban-client set sshd banip 203.0.113.66
→ 1                                    # ← 返回成功！
fail2ban-client get sshd banip
→ 203.0.113.66                         # ← IP 也进了列表！
nft list ruleset
→ (无任何规则)                          # ← 但防火墙里什么都没有
```

只有日志说实话：

```
fail2ban.actions NOTICE [sshd] Ban 203.0.113.66
fail2ban.utils  ERROR  ... stderr: '/bin/sh: 1: nft: not found'
fail2ban.utils  ERROR  ... returned 127
fail2ban.actions ERROR  Failed to execute ban jail 'sshd' action 'nftables' ... 'Script error'
```

```bash
apt-get install -y nftables
systemctl restart fail2ban        # 必须重启，reload 不足以让 action 重建

# 装好后实测（务必用 TEST-NET 保留地址，避免误封真人）
fail2ban-client set sshd banip 203.0.113.66
nft list ruleset | grep 203.0.113.66     # 必须能看到
fail2ban-client set sshd unbanip 203.0.113.66   # 清理
```

成功后的规则形态：

```
table inet f2b-table {
	set addr-set-sshd { type ipv4_addr; elements = { 203.0.113.66 } }
	chain f2b-chain {
		type filter hook input priority filter - 1; policy accept;
		tcp dport 22222 ip saddr @addr-set-sshd reject with icmp port-unreachable
	}
}
```

## 3. 坑 2：改了 port 之后，`reload` 留下**过期端口**的封禁规则

nftables action 把端口**烘进规则文本**，该文本在 action 启动时生成一次。

1. jail 写 `port = 22222` → `systemctl reload fail2ban`
2. `fail2ban-client get sshd port` 已是新值，但 `nft list ruleset` 里**仍是 `tcp dport 22`**
3. → 防护打在 22（此时是蜜罐），真 SSH 的 22222 反而**不受保护**
4. `systemctl restart fail2ban` 后才变成 `tcp dport 22222`

**改端口后必须 `restart`，不能只 `reload`；并把 nft 规则里的 dport 作为关键验证项。**

## 4. 🔴 上锁前必读：`f2b-guard` 守卫

蜜罐 jail 用 `action = nftables[type=allports]`。为验证封禁逻辑**临时把管理 IP 从 `ignoreip` 移除**，单次蜜罐尝试后就：

```
NOTICE [honeypot-ssh] Found <你的管理IP>
NOTICE [honeypot-ssh] Ban <你的管理IP>

$ ssh -p 22222 root@<host>
Connection closed by <host> port 22222        ← 彻底进不去
```

**`allports` 是全端口封禁，连真 SSH 一起封。管理 IP 被 ban = 失去整台机器**，最后靠跳板机换源 IP 才进去解封。

**防线 1：`ignoreip` 必须含管理 IP + 跳板机 IP**

```bash
ignoreip = 127.0.0.1/8 ::1 <你的管理IP> <跳板机IP>

for j in sshd honeypot-ssh recidive; do      # 改完立即复核三个 jail 的生效值
  fail2ban-client get $j ignoreip
done
```

**防线 2：装 `f2b-guard`，用 `f2b-guard restart` 代替裸 `systemctl restart fail2ban`**

```bash
install -m 755 <skill>/scripts/f2b-guard.sh /usr/local/sbin/f2b-guard
f2b-guard check      # 0=安全，1=危险
f2b-guard restart    # 守卫不通过就拒绝重启
```

**守卫不含任何硬编码 IP**，按顺序自动确定"必须白名单的 IP"：① **当前 SSH 连接的客户端 IP**（`$SSH_CONNECTION` 第 1 字段）——此刻正在操作的人必须在白名单里；② **`/etc/fail2ban/guard-ips`**（可选，一行一个，用于跳板机/备用管理端，也可 `F2B_GUARD_IPS="ip1 ip2" f2b-guard check` 覆盖）：

```bash
printf '%s\n' '<跳板机IP>' '<其他管理IP>' > /etc/fail2ban/guard-ips
```

③ **兜底**：`ignoreip` 至少要有一个非回环 IP，防止被清成只剩 `127.0.0.1/::1`。

> 设计理由：**管理 IP 会变**（换网络、换跳板、多人运维），硬编码进脚本会立刻失效并产生误判；自动取当前连接 IP 则永远跟随实际。

实测守卫行为（Debian 13，全程无硬编码）：

```
$ f2b-guard check      # ✅ ignoreip 守卫通过（/etc/fail2ban/jail.d/zz-vps-init.conf）
                       #    ignoreip: ... <你的管理IP> <跳板机IP>；已校验 IP: <当前连接IP>   → 0
$ f2b-guard check      # ❌ ignoreip 缺少必要 IP: <当前连接IP>                            → 1
                       #    提示: 追加到 ignoreip（空格分隔），或写入 /etc/fail2ban/guard-ips
$ f2b-guard check      # ❌ ignoreip 里没有任何非回环 IP（当前只有 127.0.0.1/8 ::1)        → 1
                       #    → allports 封禁下这会让你无法登录
$ f2b-guard restart    # ⛔ 守卫拦截：未重启 fail2ban（避免把自己锁在门外）                 → 1
                       #    实测确认 fail2ban 的 ActiveEnterTimestamp 未变化
```

> ⚠️ 守卫依赖 `$SSH_CONNECTION`。cron / systemd timer / 无人 SSH 会话里拿不到 IP，必须依赖 `/etc/fail2ban/guard-ips`——无人值守场景必须**显式声明**管理 IP，不能靠推断。

**防线 3：确认有带外恢复通道**——VNC/控制台可用？有第二个可连的 IP？有跳板机？**没有兜底就不要改 fail2ban。**

绝对不要做：① 为测试封禁逻辑移除 `ignoreip` 里的管理 IP（**唯一**把你锁死的操作，"只测一下"也不安全）；② 在 allports jail 上用管理 IP 做封禁测试（单次命中即失联）；③ 假设"等它过期"可行（`recidive` 会把反复违规升级成长封，默认 1 周）；④ 用 `>/dev/null` 掩盖 fail2ban 命令的报错（会让你误以为配置已生效）。

安全的测试方式：

```bash
fail2ban-regex /tmp/honeypot.log /etc/fail2ban/filter.d/sshesame.conf   # ① 离线验证 filter
fail2ban-client set honeypot-ssh unbanip <测试IP>                      # ② 可牺牲来源 IP，测完立即解封
# ③ 临时把该 jail 的 action 降为端口级（不封全端口），测完改回
fail2ban-client set honeypot-ssh banip 203.0.113.66                    # ④ TEST-NET 保留地址，永不涉及真实 IP
fail2ban-client set honeypot-ssh unbanip 203.0.113.66
```

已经锁死了：详见 `rollback.md` 第 4 节，最快路径是**从另一个 IP 连进去解封**：

```bash
ssh -J user@jump.host -p 22222 root@<target> \
  'fail2ban-client set honeypot-ssh unbanip <你的IP>';
```

> `ProxyCommand` 含 `%h:%p` 时不要写在带引号的 `-o` 里（会报 `Bad stdio forwarding specification`），改用 `ssh -F <配置文件>`。

## 5. 生效与关键验证

```bash
fail2ban-client -t                       # "OK: configuration test is successful"
systemctl restart fail2ban               # 必须 restart：坑 1 需它重建 action，坑 2 需它重建端口规则
fail2ban-client status                   # 应列出 sshd 与 recidive
fail2ban-client status sshd              # Journal matches / Total failed / Banned IP list

nft list set inet f2b-table addr-set-sshd                  # 集合存在
nft list chain inet f2b-table f2b-chain | grep dport       # 端口必须等于真实 SSH 端口
fail2ban-client set sshd banip 203.0.113.66 && \
  nft list ruleset | grep -q 203.0.113.66 && echo "封禁链路 OK"
fail2ban-client set sshd unbanip 203.0.113.66
```

## 6. rsyslog 与 journal

- Debian 13 最小安装**没有 rsyslog**，`/var/log/auth.log`、`/var/log/syslog` **都不存在**。
- 所以 fail2ban 必须用 `backend = systemd`；否则报 "Have not found any log file"。
- **不要** `apt install rsyslog` 只为满足 fail2ban——systemd 后端更好。
- 也意味着：**任何针对 `/var/log/syslog`、`/var/log/auth.log` 的 logrotate 配置都是空转**。

## 7. 封禁方式：用 nft set，不要用 ufw 逐条

`ipset` 是 iptables 时代的同类方案；nftables 系统上**直接用 nft set，不必装 ipset**。

实测（对 50 个保留测试地址逐条封禁）：ufw `ufw insert 1 deny from <IP>` 总耗时 **13.73 秒**、单个 **274.6 ms**、**54 条链上规则**（每 IP 一条）；nft set `nft add element` 总耗时 **0.21 秒**、单个 **4.3 ms**、**1 条规则** + 集合 50 个元素。**nft set 快约 64 倍**：ufw 每次封禁都是一次完整重写（重新序列化全部规则 + 写入 + 重载，Python 启动 + nft 事务），IP 越多越慢且规则线性增长（封 10000 个就是 10000 条规则）；nft set 是常数时间查找（哈希/区间），**始终只有 1 条规则**。

规则形态：

```
table inet f2b-table {
	set addr-set-honeypot-ssh { type ipv4_addr; elements = { 73.147.19.171 } }
	chain f2b-chain {
		type filter hook input priority filter - 1; policy accept;
		meta l4proto tcp ip saddr @addr-set-honeypot-ssh reject with icmp port-unreachable
	}
}
```

⚠️ 清理陷阱：

1. **任何批量操作后必须用计数复核**，不要靠"我跑过清理命令了"：

   ```bash
   for i in $(seq 1 50); do ufw --force delete deny from 198.51.100.$i >/dev/null 2>&1; done
   ufw status | grep -c '198.51.100'          # 必须是 0
   ufw status numbered                        # 目视确认只剩合法规则
   ```

2. **不要在生产机上做规则规模测试**。用容器/临时 VM，或纯计算：nft 集合的优势来自算法（常数时间查找 vs 线性遍历），不需要污染真实防火墙来证明。

3. **不要用 `nft flush set` 清空封禁**：它能在内核层原子清空集合，**但不同步 fail2ban 状态**——fail2ban 仍认为那些 IP 被封着，于是一个真实攻击者封禁（`47.251.249.41`）被**静默解除**了，而 `fail2ban-client get sshd banip` 还显示它被封。正确做法：

   ```bash
   fail2ban-client set <jail> unbanip <IP>     # 或 unbanip --all 清空该 jail
   systemctl restart fail2ban                  # 让 nft 集合按 fail2ban 状态重建
   fail2ban-client get sshd banip              # 复核两边一致
   nft list set inet f2b-table addr-set-sshd
   ```

   若已误用 `flush`，`systemctl restart fail2ban` 会把数据库里的封禁重新下发到 nft。

确认 banaction（若显示 `iptables-*` 老版本默认，改掉）：

```bash
grep -rE '^[[:space:]]*banaction' /etc/fail2ban/jail.d/ /etc/fail2ban/jail.conf
```

```ini
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]
```

> `[type=allports]` = 封禁该 IP 的**所有端口**。蜜罐 jail 应该用 allports（连蜜罐的人该被整个拒掉）。

## 8. 蜜罐日志接入 fail2ban，全局封禁扫描者

**思路**：蜜罐在 22 端口钓鱼，**凡连上来的都是扫描者**。为它单独建 jail，命中后**全端口封禁**。

```bash
cat > /etc/fail2ban/filter.d/sshesame.conf <<'CONF'
[Definition]
failregex = ^.*\[<HOST>:\d+\] authentication for user .*
ignoreregex =
CONF
```

**设计取舍**：只匹配**认证相关**行，**不匹配** `[channel N] command ...` / `session requested`。攻击者成功登录后会连发几十条命令（实测真实攻击者 `73.147.19.171` 发了 30 条）：

```
[channel 4] command "ps | grep '[Mm]iner'" requested
[channel 6] command "ls -la ~/.local/share/TelegramDesktop/tdata ..." requested
[channel 7] command "locate D877F783D5D3EF8Cs" requested
```

若逐条计数会反复触发、日志被 `already banned` 刷屏：`NOTICE [honeypot-ssh] 73.147.19.171 already banned`。只算认证行即可同时抓住"探测"与"爆破"，且不刷屏。

### ⚠️ 致命陷阱：不要行首锚定到 `[`

实测矩阵（33 行真实日志）：

| failregex | 结果 |
|---|---|
| `^\[<HOST>:\d+\]` | **0 matched**（错！） |
| `^.*\[<HOST>:\d+\].*$` | 33 matched |
| `\[<HOST>:\d+\]` | 33 matched |
| `^\s*<HOST>:\d+\]\s` | 33 matched |
| `^<HOST>` | **0 matched** |

原因：fail2ban **先剥离日期前缀**，剥离后剩余文本并不从行首 `[` 开始，所以 `^\[` 永远匹配不上——**而且不报语法错误**，只是静默 0 命中。这个坑极难发现：配置看着完全正常、`fail2ban-client status` 不报错，但 `Total failed` 永远是 0。**唯一可靠的判断是 `fail2ban-regex` 的 matched 数 > 0。**

> 顺带澄清：fail2ban **支持** `(?:...)` 非捕获组（它自己的日期模板里就在用），真正的问题只是行首锚定位置。

验证：

```bash
journalctl -u sshesame --since "3 hours ago" --no-pager -o json 2>/dev/null \
 | python3 -c "
import sys,json,re
for l in sys.stdin:
    try: m=json.loads(l).get('MESSAGE','')
    except: continue
    if re.search(r'\[\d+\.\d+\.\d+\.\d+:\d+\]', m): print(m)
" > /tmp/only_ip.log

fail2ban-regex /tmp/only_ip.log /etc/fail2ban/filter.d/sshesame.conf
# 实测：4 matched / 29 missed（missed 的是命令噪音，符合预期）
```

### 蜜罐 jail（注意 `zz-` 前缀）

```ini
# /etc/fail2ban/jail.d/zz-vps-init.conf
[honeypot-ssh]
enabled   = true
filter    = sshesame
backend   = systemd
journalmatch = _SYSTEMD_UNIT=sshesame.service
port      = 22
maxretry  = 3
findtime  = 1h
bantime   = 1d
# 全端口封禁
action    = nftables[type=allports]
```

实测结果（真的抓到了攻击者）：

```
Status for the jail: honeypot-ssh
|- Filter
|  |- Total failed:  30
|  `- Journal matches: _SYSTEMD_UNIT=sshesame.service
`- Actions
   |- Currently banned: 1
   `- Banned IP list:  73.147.19.171        ← 真实攻击者，不是测试地址
```

对应 nft 规则是**全端口**（无 `dport` 限定，与 sshd jail 的 `tcp dport 22222` 形成对比）：

```
meta l4proto tcp ip saddr @addr-set-honeypot-ssh reject with icmp port-unreachable
```

`recidive` 读 `/var/log/fail2ban.log`，把反复被封的 IP 升级为长期封禁（实测 1 周）。链路：蜜罐封禁 → 写入 fail2ban.log → recidive 再升级。

注意：**`ignoreip` 必须包含管理 IP**，否则测试连自己的蜜罐就会被封（实测 `127.0.0.1` 触发了 `Ignore 127.0.0.1 by ignoreself rule`）；**蜜罐日志量大**（攻击者每条命令一行），必须给 journald 设限额（`SystemMaxUse=200M`，见 `hardening.md`）；不用担心"封了 IP 蜜罐就没用"——封禁按 IP，新 IP 照样能进来触发记录，老 IP 被拒本身就是收益。

> 验收：`sh scripts/vps-check.sh gate`
