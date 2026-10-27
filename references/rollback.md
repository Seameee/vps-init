# 回滚与救援
> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
## 1. 事前：让回滚成为可能
**执行任何有风险的操作前**，先确认你有以下至少一条退路：

| 退路 | 如何确认 | 说明 |
|---|---|---|
| 云厂商 VNC / 串口控制台 | 服务商面板里能找到入口 | 最可靠，不依赖网络端口 |
| 救援模式 / Rescue System | 面板里有该选项 | 可挂载磁盘改配置 |
| 第二个已认证 SSH 会话 | 现在就开一个并保持 | 断了一个还有一个 |
| 死手开关（at 定时任务） | `atq` 有任务 | 见 `ssh-firewall.md` §2 |
| 快照 / 备份 | 面板里有快照 | 最省事的兜底 |

**唯一绝对不能做的**：在只有一个 SSH 入口、且没有上述任何退路的情况下改 SSH/防火墙。
## 2. SSH 登不上了
按可能性从高到低排查（需要控制台或救援模式）：
```bash
systemctl status ssh                                          # a) sshd 是否在跑
/usr/sbin/sshd -t                                             # b) 配置语法
ss -tlnp | grep sshd                                          # c) 是否在听正确端口
journalctl -u ssh -n 50 --no-pager                            # d) 真实拒绝原因
stat -c '%a %U:%G' /root/.ssh /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys   # e) 权限
fail2ban-client status sshd                                   # f) 是否被 fail2ban 封了自己
fail2ban-client set sshd unbanip <你的IP>
ufw status verbose                                            # g) 是否被防火墙挡了
```

**紧急恢复 SSH 到"能进"的状态**（纯新增，幂等）：

```bash
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-emergency.conf <<'CONF'
Port 22
PasswordAuthentication yes
PermitRootLogin yes
CONF
/usr/sbin/sshd -t && systemctl restart ssh
ufw allow 22/tcp 2>/dev/null || true
```

> 只要能进一次，就有机会修好一切。安全永远让位于可达性——先恢复访问，再重新加固。
## 3. 防火墙把自己锁了
```bash
ufw disable                      # 立刻放开（最简单）
ufw status numbered && ufw delete <编号>   # 或只删掉错的规则
```

> **Docker 场景**：`ufw disable` 之后 Docker 发布端口依然开放（Docker 直接写 iptables/nft，不看 ufw）。别以为关了 ufw 就安全了，见 `ssh-firewall.md` §11。
## 4. fail2ban 封了自己（🔴 会被完全锁在门外）
jail 用 `action = nftables[type=allports]`（蜜罐 jail 的推荐配置）时，**封禁是"全端口"的**：管理 IP 一旦被 ban，**连真 SSH 端口（22222）也是 `Connection closed`**，整台机器无法登录。实测现象：为测试封禁逻辑临时从 `ignoreip` 移除管理 IP，单次蜜罐尝试后立刻 `Ban <你的管理IP>`，随后直连 22222 报 `Connection closed by <目标IP> port 22222`。
### 恢复方法（按推荐顺序）
**① 从另一个 IP 连进去解封（最快，无需控制台）** —— 封禁按**来源 IP**，换一个出口就能进：

```bash
ssh -J user@jump.host -p 22222 root@<target> \
  'fail2ban-client set honeypot-ssh unbanip <你的原IP>
   fail2ban-client set sshd unbanip <你的原IP>
   fail2ban-client set recidive unbanip <你的原IP>'
```

> 若 `ProxyCommand` 里含 `%h:%p`，**别写在带引号的 `ssh -o ProxyCommand="..."` 里**（会报 `Bad stdio forwarding specification`）。改用 `ssh -F <config>`，在 `ProxyCommand` 行里用 `-W %h:%p`。

**② VPS 控制台 / VNC** —— 面板里登录后执行同样的 `unbanip`。最可靠的兜底。

**③ 从内部清空封禁（若有其它入口）**

```bash
fail2ban-client unban --all          # 清空所有 jail 的封禁
# 或直接清 nft 集合（注意：不会同步 fail2ban 视图，见 fail2ban.md §7）
```
### 预防（必须做）
```bash
grep '^ignoreip' /etc/fail2ban/jail.d/zz-vps-init.conf   # 应含 <你的管理IP>
fail2ban-client get honeypot-ssh ignoreip                # 每次改完复核生效值
```

> `ignoreip` 是最后一道保险。**动了它，就等于把唯一的钥匙也锁进保险箱**——尤其 `action` 是 `allports` 时，封禁会连同管理通道一起断掉。测试封禁逻辑时用可牺牲的来源 IP（跳板机、临时 VPS）。另外 `recidive` 读 `fail2ban.log`，会把反复被封的 IP 升级成长封（默认 1 周），所以"等它自然过期"通常不现实——**优先换 IP 或控制台恢复**。
## 5. 蜜罐占着 22 导致连不上真 SSH
```bash
systemctl disable --now sshesame            # 或 endlessh
install -d -m 755 /etc/ssh/sshd_config.d
printf 'Port 22\n' > /etc/ssh/sshd_config.d/00-restore22.conf
/usr/sbin/sshd -t && systemctl restart ssh
ss -tlnp | grep ':22 '
```
## 6. 服务起不来的通用排查
```bash
systemctl status <svc> -l --no-pager      # -l 显示完整日志
journalctl -u <svc> -n 50 --no-pager
systemd-analyze verify /etc/systemd/system/<svc>.service
```

**常见 systemd 沙箱导致的启动失败**：

| 报错 | 原因 | 修复 |
|---|---|---|
| `Failed to set up mount namespacing: <path>: No such file or directory`（status=226/NAMESPACE） | `ReadWritePaths=` 指向的目录不存在 | 先 `install -d` 建目录 |
| `mkdir /.local: read-only file system` | `ProtectSystem=strict` 下程序试图写 `$HOME` | 显式指定可写路径（如 `-data_dir`）或设 `Environment=HOME=<可写目录>` |
## 7. 回滚加固配置（正常情况）
本 skill 的加固都写成**独立的新增文件**，所以回滚 = 删掉/停用这些文件：
```bash
rm /etc/ssh/sshd_config.d/00-hardening.conf          # SSH 加固
/usr/sbin/sshd -t && systemctl reload ssh
ufw disable                                          # 防火墙（或 ufw reset 清空所有规则）
systemctl disable --now fail2ban                     # fail2ban
# 或只停用某个 jail：在 jail.d 里设 enabled = false 后 restart
rm /etc/sysctl.d/99-vps-init.conf /etc/systemd/journald.conf.d/99-vps-init.conf   # sysctl / journald
rm /etc/sudoers.d/99-vps-init-log                                                # sudo 日志
sysctl --system && systemctl restart systemd-journald
```
## 8. 每次改动前的最小备份
```bash
BK=/root/vps-init-backup-$(date +%Y%m%d-%H%M%S)
install -d -m 700 "$BK"
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$BK"/ 2>/dev/null
ufw status verbose > "$BK/ufw.status" 2>/dev/null
ls -la /etc/fail2ban/jail.d > "$BK/fail2ban-jail.d.list" 2>/dev/null
echo "$BK"      # 记住这个路径
```

> 验收：`sh scripts/vps-check.sh gate`
