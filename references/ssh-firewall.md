# SSH 加固与防火墙

> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> 这是整个技能里**最容易把机器弄丢**的部分。按顺序执行，每步都有验证门。

## 1. 前置硬条件（不满足就不要开始）

```bash
# a) 必须知道 sshd 的「运行中二进制」，PATH 里的 sshd 可能是假的/自编译的
SSHD_PID=$(pgrep -x sshd | head -1)
RB=$(readlink -f /proc/$SSHD_PID/exe)
echo "$RB"                    # 例：/usr/sbin/sshd
"$RB" -V                      # 例：OpenSSH_10.0p1
# 之后所有检查都用 "$RB" -T，绝不用裸 sshd -T

# b) 目标用户必须有可用公钥，且权限正确
ls -l /root/.ssh/authorized_keys /home/<user>/.ssh/authorized_keys
stat -c '%a %U:%G' /root/.ssh /root/.ssh/authorized_keys   # 期望 700 / 600 root:root
```

**权限错了 sshd 会静默拒绝密钥**（StrictModes）。写公钥的正确姿势——**只追加、先校验非空、后验证指纹**：

```bash
key="$(cat pub.key)"                      # 或 ssh-keygen -y -f privkey
[ -n "$key" ] || { echo "公钥为空，中止"; exit 1; }   # ← 空值绝不能继续
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys          # 只创建，绝不覆盖
grep -qxF "$key" /root/.ssh/authorized_keys || printf '%s\n' "$key" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -l -f /root/.ssh/authorized_keys   # 必须能打印出指纹才算数
```

> ❌ **不要用 `install /dev/null <file>` 来"初始化"authorized_keys**：那会把已有文件**截断成 0 字节**（指纹查不到、密钥登录失败）。也不要 `install -m 600 -o user -g user /dev/null ...` 之后再追加——顺序错了同样丢内容。
>
> ⚠️ 用 `sudo` 跑脚本时 `$HOME` 可能仍指向 root，导致公钥写成 root:root 而 sshd 拒绝 → **密钥登录失败 + 密码已关 = 锁死**。

## 2. 死手开关（动 SSH 前必做）

```bash
command -v at >/dev/null || apt-get install -y at
systemctl enable --now atd

# 20 分钟后把 SSH 恢复为「允许密码 + 22 端口」的保守配置
cat > /root/ssh-deadman.sh <<'EOF'
#!/bin/bash
# 保命开关（修正版）：直接重写加固文件，【不】依赖 drop-in 的加载顺序。
set -u
HD=/etc/ssh/sshd_config.d/00-hardening.conf
install -d -m 755 /etc/ssh/sshd_config.d
printf '# 由 ssh-deadman.sh 于 %s 回归\n' "$(date -Is)" > "$HD"
cat >> "$HD" <<'CONF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin prohibit-password
PubkeyAuthentication yes
Port 22
CONF
[ -f /etc/ssh/sshd_config.d/00-deadman.conf ] && mv -f /etc/ssh/sshd_config.d/00-deadman.conf /root/deadman.conf.fired 2>/dev/null || true
if /usr/sbin/sshd -t; then
  systemctl restart ssh
  logger -t deadman "SSH deadman switch fired; sshd restored to password+port22"
else
  logger -t deadman "SSH deadman switch: sshd -t FAILED, not restarting"
fi
EOF
chmod +x /root/ssh-deadman.sh
echo /root/ssh-deadman.sh | at now + 20 minutes
atq
```

### ⚠️ 死手开关的 3 条实现陷阱

1. **`Port` 是多值参数，不能用"覆盖"的思路回退。**
   写 `00-deadman.conf` 含 `Port 22`、`00-hardening.conf` 含 `Port 22222`，
   `sshd -T` 得到的是 **`port 22 port 22222`（两个都在听）**，端口没有回退；
   而同一次测试里 `PasswordAuthentication yes`（单值参数）**确实覆盖成功**。
   → **单值参数受"首个取值生效"约束；`Port`/`ListenAddress`/`AllowUsers` 等
   多值参数会累加**。死手开关若涉及端口，必须**改写/移除**加固文件里的 `Port` 行。
2. **文件名顺序对单值参数至关重要。** 写成 `99-deadman.conf` 对单值参数**无效**
   （`00-` 先加载、首个取值生效）。要覆盖单值参数就必须排在前面。
3. **不要用 `rm -f` 删加固文件**，也不要 `pkill`/`stop sshd`。把内容**重写**
   （`>` 截断后重写）比删除更安全，且不会因"删了却起不来"造成二次事故。

### ✅ 挂上之后必须实弹验证

```bash
# 1) 造一个模拟加固态
printf 'PasswordAuthentication no\nPort 22222\n' > /etc/ssh/sshd_config.d/00-hardening.conf
/usr/sbin/sshd -T | grep -E '^port|^passwordauth'   # 应为 port 22222 / no

# 2) 手工触发死手脚本
bash /root/ssh-deadman.sh

# 3) 验证真的回退了（这一步不能省）
/usr/sbin/sshd -T | grep -E '^port|^passwordauth'   # 应为 port 22 / yes
ss -tlnp | grep -cE ':22 |:22222 '                  # 确认真实监听
# 4) 确认当前会话没断（Debian 的 ssh 单元是 KillMode=process，restart 不会杀活动会话）
```

**确认新配置可用后**：`atq` → `atrm <job号>`，并删掉 `00-deadman.conf`（或留空覆盖）。

## 3. 先判断 ssh 是 service 还是 socket 激活

Ubuntu 24.04 起（部分 Debian 镜像也是）默认 `ssh.socket` 激活，此时 **`sshd_config` 里的 `Port` 被忽略**，端口由 socket 的 `ListenStream` 决定。

```bash
systemctl is-active ssh.socket
systemctl cat ssh.socket 2>/dev/null | grep -i listenstream
```

**若 socket 激活**，换端口必须改 socket：

```bash
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/10-port.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=22222
EOF
systemctl daemon-reload
systemctl restart ssh.socket
```

**若是传统 service**（如 `ssh.service active` / `ssh.socket disabled`），改 `sshd_config` 的 Port 即可。

## 4. 确认 drop-in 真的会被加载

```bash
grep -n '^[[:space:]]*Include' /etc/ssh/sshd_config
# 必须存在：Include /etc/ssh/sshd_config.d/*.conf
```

**没有这行时，写 drop-in 是「假安全」**——配置看起来存在但不生效。老系统（Debian ≤11）需改主配置或加 Include。

## 5. 写加固 drop-in（顺序：先加端口，后禁密码）

```bash
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
# 认证
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
# 减少暴露面
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
# 端口（迁移期先同时保留新旧端口！）
Port 22
Port 22222
EOF

# 硬验证：语法 + 生效值，都必须用运行中二进制
"$RB" -t && echo "语法 OK" || echo "语法错误，立刻修"
"$RB" -T | grep -Ei '^(port|passwordauthentication|permitrootlogin|maxauthtries|allowtcpforwarding)'
```

**只有 `-t` 通过才 reload**（reload 比 restart 安全：不会先停后起）：

```bash
systemctl reload ssh 2>/dev/null || systemctl reload sshd
ss -tlnp | grep sshd      # 应看到 22 和 22222 都在听
```

> 迁移期**故意同时监听两个端口**，这样旧连接不断、新端口可测。

## 6. 验证门（另开一个会话完成，不关旧会话）

```bash
# 在【新终端】里：
ssh -p 22222 <user>@<host> 'whoami; sudo -n true && echo "sudo OK"'
```

通过后，才删掉 drop-in 里的 `Port 22`（此时 sshd 只监听新端口，旧连接仍保持），再 `systemctl reload ssh`。
第 6 步验证通过前，**不要**再收紧 `PermitRootLogin no` 之类；要改就确认已有非 root sudo 用户能登录。

## 7. SSH 常见陷阱清单

| 陷阱 | 症状 | 处理 |
|---|---|---|
| PATH 遮蔽 | `sshd -T` 显示 port 22 / password yes，与运行中服务不符 | 用 `/proc/<pid>/exe` 取真实二进制 |
| socket 激活 | 改了 Port 没反应 | 改 `ssh.socket` 的 ListenStream |
| Include 缺失 | drop-in 写了不生效 | 主配置补 Include |
| drop-in 文件名顺序 | 被后加载的文件覆盖 | 用 `00-` 前缀确保先加载，且避免与他人的文件冲突 |
| 权限错误 | 密钥登录失败 | `700 .ssh` / `600 authorized_keys` / 属主正确 |
| cloud-init 覆盖 | 重启后又允许密码登录 | 检查 `/etc/cloud/cloud.cfg.d/*.cfg` 的 `ssh_pwauth` |
| `PasswordAuthentication` 与 `ChallengeResponseAuthentication` | 仍有密码提示 | 同时设 `KbdInteractiveAuthentication no` |
| 用 restart 而非 reload | 语法错时 sshd 起不来 | 先 `-t`，再 `reload` |

## 8. 防火墙：选 ufw 还是 nftables

| 场景 | 推荐 | 理由 |
|---|---|---|
| 单机 VPS、规则简单 | **ufw** | 上手快、规则清晰、自动处理 v4/v6 |
| 复杂规则 / 需要 set、map、限速 | nftables 原生 | 更灵活 |
| 装了 Docker | 两者都要额外处理 | 见 §12 Docker 绕过 |

> ufw 0.36.2 在底层就是 nftables（`table ip filter` / `ip6 filter` 由 iptables-nft 管理）。
> **不要 ufw 与裸 nft 混写同一张 filter 表**，会互相覆盖。

## 9. 启用顺序（错了会锁死自己）

```bash
# ① 先加规则，此时防火墙还没启用 —— 零风险
ufw default deny incoming
ufw default allow outgoing
ufw allow 22222/tcp comment 'real SSH (hardened)'
ufw allow 22/tcp    comment 'ssh honeypot - intentionally open'   # 蜜罐必须显式放行！

# ② 检查规则
ufw show added

# ③ 启用
ufw --force enable
```

### ⚠️ 坑 1：`ufw --dry-run enable` 会卡住

`ufw --dry-run enable` 会**挂起**（等待交互确认），导致命令超时、防火墙处于"规则已加但未启用"的中间状态。**用 `ufw --force enable`**。

### ⚠️ 坑 2：别忘了蜜罐端口

`ufw default deny incoming` 之后，**蜜罐的 22 如果不显式放行就没有任何人能连上**，蜜罐变成摆设。放行时务必写注释说明"这是故意开放的"，避免以后自己或同事把它当漏洞删掉。

### 为什么启用防火墙不会切断你当前的 SSH

`ufw enable` 之后正在进行的 SSH 会话**没有断开**。原因在 ufw 生成的链（`nft list table ip filter`）：

```
chain ufw-before-input {
    iifname "lo" accept
    ct state related,established accept      # ← 已建立连接在链首就被放行
    ct state invalid jump ufw-logging-deny
    ...
    jump ufw-user-input
}
```

`ct state related,established accept` 排在放行规则之前，所以**已建立的连接不受影响，只有新连接会被新规则过滤**。

> 但这**不意味着你可以不挂死手开关**：一旦你断开当前会话再重连，就会走新规则。顺序仍是「先放行端口，再启用」，并保持一个已认证会话不关。

## 10. 验证：找权威证据

### 坑 3：从远端探测端口"开不开"经常不可信

从部署机用 `bash /dev/tcp/host/80` 和 `curl telnet://host:80` 探测，**连接任意端口都显示"成功/开放"，包括根本不存在的 1337、9999、65000**——路径上有透明代理时 `time_connect` 恒为 0.001s。**这种探测结论是假的，不要采信。**

**方法 A：看链的默认策略与计数器**（服务器侧，最可靠）

```bash
nft list table ip filter | grep -E 'hook input|policy'
# 期望：type filter hook input priority filter; policy drop;
nft list chain ip filter ufw-user-input
# 期望：只列出你放行的端口，且 counter 数字在增长（说明真有过流量且被放行）
```

真实形态：

```
chain ufw-user-input {
    tcp dport 22222 counter packets 3 bytes 180 accept
    tcp dport 22    counter packets 5 bytes 324 accept
}
type filter hook input priority filter; policy drop;     # ← 默认拒绝
```

**方法 B：服务器本地自测**

```bash
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22222' && echo 应可达
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80'    || echo 应不可达
```

**方法 C：真正的端到端**

```bash
ssh -p 22222 user@host 'echo ok'   # 放行的端口能登录
curl -m 5 http://host/             # 未放行端口应明确失败（timeout / refused）
```

> 关键验证：`nft list table ip filter` 必须出现 `policy drop`，
> 且 `nft list chain ip filter ufw-user-input` 里的 dport 必须等于**真实 SSH 端口**
> （改端口后忘了更新防火墙，是"放行了却连不上"的头号原因）。

## 11. Docker 与 ufw 的著名冲突

**Docker 会绕过 ufw/nftables 的 INPUT 过滤。** Docker 在 `nat` 表的 `DOCKER` 链里做 DNAT，并在 `filter` 表的 `FORWARD` 链放行，于是：

- `-p 8080:80` 发布的端口**对全网开放**，即使 `ufw deny 8080`；
- 因为流量走 FORWARD/PREROUTING，不经过 ufw 的 `ufw-user-input`。

**对策（三选一）**：

1. **容器端口一律绑回环**：`-p 127.0.0.1:8080:80`（最简单、最安全）
2. **用 `DOCKER-USER` 链**：在 `filter` 表的 `DOCKER-USER` 链里加限制规则（Docker 官方推荐位置）
3. **装 `ufw-docker`**：自动把 ufw 规则同步到 `DOCKER-USER`

排查命令：

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0|:::'
iptables -S | grep -c DOCKER       # 有 docker 时必有 DOCKER 相关规则
```

## 12. 已经把自己锁在外面了怎么办

见 `rollback.md`。优先走云厂商的 **VNC / 串口控制台 / 救援模式**，不要反复重启。

> 验收：`sh scripts/vps-check.sh gate`
