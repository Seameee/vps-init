# 可选组件（Tier 1 / Tier 2）

> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> **默认不装。** 仅在用户明确需要、且机器资源允许时才装。每项记录：版本、改了什么、如何验证、如何回滚。

层级：**nexttrace = Tier 1**；**BBRv3-lite / 代理节点 / rfw / 蜜罐 = Tier 2**；换源与资源开销表按需参考。

## 1. nexttrace（路由追踪）

- **用途**：排障看真实路由 / AS 归属 / 地区。**开销**：无常驻进程。**版本**：`NextTrace v1.7.3 (2026-08-23)`。
- ⚠️ 官方 README 的 URL 容易抄错。**key 和仓库 URI 都在 `releases/latest/download/` 下**，不是 `nxtrace.github.io`。

```bash
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://github.com/nxtrace/nexttrace-debs/releases/latest/download/nexttrace-archive-keyring.gpg \
  -o /etc/apt/keyrings/nexttrace.gpg
cat > /etc/apt/sources.list.d/nexttrace.sources <<'CONF'
Types: deb
URIs: https://github.com/nxtrace/nexttrace-debs/releases/latest/download/
Suites: ./
Signed-By: /etc/apt/keyrings/nexttrace.gpg
CONF
apt-get update
apt-get install -y nexttrace          # 完整版；nexttrace-tiny 仅 traceroute；ntr 为 MTR 专用
nexttrace --version
nexttrace -n -q 1 1.1.1.1
```

实测输出（东京 → Cloudflare，6 跳到达）：
```
3  154.54.5.238  AS174  [COGENT-BONE]  日本 东京都 东京  cogentco.com   3.59 ms
5  103.22.201.83 AS13335 [CLOUDFLARE-AP] 日本 东京都 东京 cloudflare.com  16.95 ms
6  1.1.1.1       AS13335  Anycast  cloudflare.com   3.01 ms
Trace Stopped: Destination Reached at Hop 6
```

**注意**：输出带 ANSI 颜色码，脚本解析时加 `-n`（不做 DNS 反解）或自行 strip 转义。

回滚：`apt-get remove -y nexttrace`，另可删 `nexttrace.sources` 与 `keyrings/nexttrace.gpg`。

## 2. BBRv3-lite（拥塞控制与 TCP 调优）

- **版本**：`bbrv3-lite v8.0.7`。脚本 <https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh> 把上游 `net-tcp-tune.sh` 装成 `/usr/local/bin/bbr`（**带 SHA256 校验**）。安装后是 **726KB 的 Bash 脚本**（约 14000+ 行，不是二进制、也不是内核模块）。
- ⚠️ **不要以为它"只调 sysctl"**。`bbr kernel install` 会真的换内核。

```bash
bbr kernel status                 # 只读：当前内核 / 架构 / x86-64 level / BBR 兼容性
bbr kernel install                # 默认装 XanMod LTS —— 会改 APT 源、装内核、update-grub
bbr kernel install --track main   # XanMod Main（更新更快）
bbr kernel remove                 # 卸载【非运行中】的 XanMod 内核包
```

**`kernel install` 实现要点**（读源码确认）：**前置拦截** 非 Debian/Ubuntu、非 `x86_64`（ARM64 提示用发行版内核）、**容器内**、**Secure Boot 已启用** —— 四种都拒绝。**会做**：装 ca-certificates/curl/gnupg → 下载 `dl.xanmod.org/archive.key` 并 `gpg --show-keys` 校验 → dearmor → 写 `xanmod-release.list`（用你的 `VERSION_CODENAME` 拼地址）→ `apt-get update` → 装内核包 → `update-grub`。**按 CPU 能力选包**：用 `/proc/cpuinfo` flags 判定 x86-64 级别；v3 要求 `bmi`/`bmi1` **任一**、`abm`/`lzcnt` **任一**。LTS：v3→`linux-xanmod-lts-x64v3`（回退 v2/v1）；Main：v3→`linux-xanmod-x64v3`。源码有防呆：**Main 轨绝不降级用 LTS 包**。**卸载安全**：`kernel remove` **跳过正在运行的内核包**，装完明确提示"当前内核未被删除"。

> ⚠️ `bbr kernel status` 的 "BBR generation: unknown (BBR active; not proof of BBRv3)" **不是"没装 BBRv3 内核"**，而是"**运行时 API 无法证明内核里的 BBR 是 v3 还是 v1**"。若内核名含 `xanmod`，它会打印 `v3 expected (XanMod default; runtime API cannot prove generation)`。

**装 XanMod 内核的额外风险**：① 会改 APT 源并装新内核，XanMod 源不在默认 `Origins-Pattern` 里（见 `hardening.md` §2）；② **必须重启才生效**，新内核起不来要靠引导菜单选回旧内核（脚本不删旧内核，这是对的）；③ **建议先快照**——换内核是最可能导致机器无法启动的操作，`/boot` 需留足空间；④ 只想调 TCP 参数：**只跑 `bbr install`，别碰 `bbr kernel install`**。

### 安全流程（先预演再应用）

```bash
curl -fsSL -o /tmp/bbr-install.sh https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh
bash -n /tmp/bbr-install.sh
bash /tmp/bbr-install.sh install        # 自带 SHA256 校验 -> installed: /usr/local/bin/bbr
bbr status                              # 【关键】先预演，看它准备改什么
bbr explain --profile balanced --role mixed
bbr install --profile balanced --role mixed
```

`bbr explain` 实测只改这 10 个 sysctl（1C/13G 机器）：
```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216          # 从 212992 提高到 16MB
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
```

**明确声明不碰**：`tcp_mem`、`tcp_adv_win_scale`、TIME_WAIT、VM、文件限制、IRQ 亲和性、NIC offloads、RPS/RFS。**不会像某些"优化脚本"那样把 `vm.swappiness`、`fs.file-max` 乱改一气。**

| 它创建的路径（回滚依据） | 作用 |
|---|---|
| `/etc/sysctl.d/99-bbrv3-lite.conf` | 实际生效的 sysctl |
| `/etc/bbrv3-lite.conf` | 配置（`600`） |
| `/etc/systemd/system/bbrv3-lite.service` | 开机持久化（实测 `enabled`/`active`） |
| `/var/lib/bbrv3-lite/baseline` | **不可覆盖的初始基线**（回滚用） |
| `/var/lib/bbrv3-lite/.transaction.*` | 本次操作的回滚点 |

```bash
bbr status                      # Persistent sync 应为 SYNCED
sysctl -n net.core.rmem_max     # 16777216
sysctl -n net.ipv4.tcp_fastopen # 3
bbr restore                    # 恢复到基线（含安装时的不可覆盖基线）
bbr uninstall --purge-state    # 彻底卸载 bbr 命令与状态
bbr kernel remove              # 若装过 XanMod：卸载【非运行中】的包
# xanmod 源也不再需要时：删 sources.list.d/xanmod-release.list 与 keyrings/xanmod-archive-keyring.gpg，再 apt-get update
```

> 改 sysctl 后 SSH 通道未断（只调缓冲与队列，不动网络基础参数），但 `bbr kernel install` 属于**换内核**，风险等级完全不同。

## 3. LinuxMirrors 一键换源

**不是必须的**：默认源（`deb.debian.org`）在境外 VPS 上通常已够快。脚本 <https://linuxmirrors.cn/main.sh>（`SuperManito/LinuxMirrors`，MIT，8737 行）。

```bash
install -d -m 700 /root/apt-source-backup
cp -a /etc/apt/sources.list.d/debian.sources /root/apt-source-backup/
curl -fsSL -o /tmp/linuxmirrors.sh https://linuxmirrors.cn/main.sh
bash -n /tmp/linuxmirrors.sh
# 境外源；自动备份；先不升级不清理，便于观察
bash /tmp/linuxmirrors.sh --abroad --backup true --upgrade-software false --clean-cache false --lang zh
```

| 参数 | 说明 |
|---|---|
| `--abroad` / `--edu` | 境外源 / 中国教育网源 |
| `--source <域名>` | 指定源地址 |
| `--use-official-source true` | 用官方源 |
| `--backup true` | 备份原有源（会生成 `debian.sources.bak`） |
| `--upgrade-software false` / `--clean-cache false` | 换源后不升级 / 不清理 |
| `--lang zh` | 中文输出 |

- 换源后 `URIs` 变为 `http://mirrors.xtom.hk/debian/`，`apt-get update` 退出码 0；下载实测 `hello` 包 53.2 kB / 1s（82.1 kB/s）。
- ⚠️ **脚本内部会执行 `apt update`，可能超过 4 分钟**。要给足超时或放后台。**超时被中断时务必重新确认源文件状态**（可能停在半改状态）——不要假设"超时=没改"。

回滚：`cp /etc/apt/sources.list.d/debian.sources.bak /etc/apt/sources.list.d/debian.sources && apt-get update`。

## 4. surge / vless-server 代理节点部署

- **来源**：<https://raw.githubusercontent.com/mozisen/surge/main/vless-server.sh>。**版本**：`多协议代理一键部署脚本 v3.7.2`（**30,892 行 / 1.2 MB**）。
- 协议：`VLESS+Reality`、`+Reality+XHTTP`、`VLESS+WS`、`VMess+WS`、`VLESS-XTLS-Vision`、`SOCKS5`、`SS2022`、`Hysteria2`、`Trojan`、`Snell v4/v5/v6`、`AnyTLS`、`TUIC`、`NaïveProxy`；可选 `ShadowTLS`。
- 会写：`/etc/vless-reality`、`/etc/hysteria`、`/etc/naive`、`/etc/nginx`、`/etc/cloudflared`、`/etc/systemd`、`/etc/sysctl.d`、`/etc/resolv.conf`、`/etc/timezone`。
- 自带非交互子命令：`--sync-traffic`、`--show-traffic`、`--tg-bot-poll`、`--check-expire`、`--setup-expire-cron`；无参数则进入**交互式菜单**。

非破坏性验证：`bash vless-server.sh --help`（实测退出码 0）。

注意：① **它是交互式的**，不适合自动化盲跑（需人选协议、填域名/端口）；② **它会开代理端口**，装之前先在防火墙规划好放行端口，**别和真 SSH 端口混淆**；③ 它调用外部二进制（xray/sing-box 等核心），先确认版本来源；④ 它写 `/etc/resolv.conf`（**会先备份为 `.bak`**）与 `/etc/sysctl.d`；⑤ 1C1G 跑 Xray + Nginx + ACME 可接受，但**不要同时装多个核心**。

> ⚠️ 未在本机执行实际部署（会开代理端口、改动面大，超出初始化范畴）。以上为静态审阅 + `--help` 验证。

## 5. rfw（eBPF/XDP 防火墙）

项目 <https://github.com/narwhal-cloud/rfw>（Rust + eBPF/XDP）。按**端口**拦不住的滥用，用按**国家方向** + **协议特征（DPI）** 的方式拦：
```bash
rfw --countries CN,RU,KP          # GeoIP 屏蔽指定国家
rfw --block-http --block-socks5 --block-fet-strict|loose --block-wireguard --block-quic --block-email
rfw --allow-only-countries US,JP,KR   # 白名单模式
```

### 安装（含哈希校验）

```bash
cd /tmp
VER=v0.1.9
BASE=https://github.com/narwhal-cloud/rfw/releases/download/$VER
curl -fsSL -o rfw "$BASE/rfw-x86_64-unknown-linux-musl"
curl -fsSL -o checksums.txt "$BASE/checksums.txt"
EXP=$(awk '/rfw-x86_64-unknown-linux-musl/{print $1}' checksums.txt)
ACT=$(sha256sum rfw | awk '{print $1}')
[ "$EXP" = "$ACT" ] && echo "SHA256 OK" || { echo "校验失败，中止"; exit 1; }
install -m 755 rfw /usr/local/bin/rfw
rfw --version
```

实测：`v0.1.9` 的 musl 资产 14,468,608 字节，SHA256 `ba0bd3a06fc0a784e44ad50568e973aac8d60232a7dbabea7d62f95b47f645ec`（与官方一致）。静态 musl 单文件，**无需 cargo/依赖**，但下载可能需要代理。

### 前置条件（不确认一定失败）

```bash
# 1) 内核要支持 eBPF + XDP + BTF（CO-RE 依赖 BTF）
[ -f /sys/kernel/btf/vmlinux ] && echo "BTF OK" || echo "无 BTF，rfw 无法运行"
grep -E '^CONFIG_(BPF|BPF_SYSCALL|DEBUG_INFO_BTF|XDP_SOCKETS)=y' /boot/config-$(uname -r)
# 2) 网卡名
ip -o -4 addr show | awk '{print $2, $4}'
# 3) 【最关键】确认管理 IP 不属于你要屏蔽的国家
curl -sS "http://ip-api.com/json/<你的管理IP>?fields=country,countryCode"
```

实测环境：Debian 13、内核 6.12.74、`CONFIG_DEBUG_INFO_BTF=y`、`CONFIG_XDP_SOCKETS=y` → 支持；管理 IP 为 **JP（Tokyo）**，故 `--countries CN` 不会误伤管理通道。**这一步不能省。**

### ⚠️ 坑 1：默认 `--xdp-mode auto` 在 virtio_net 上会失败

```
Error: 无法以 auto 模式附加 XDP 程序到接口 eth0。
Caused by:
    0: netlink error: virtio_net: MTU too large to enable XDP without frags
    1: Invalid argument (os error 22)
```

原因：该 KVM 机器 `eth0` **MTU 是 9000**（巨型帧），virtio_net 在 MTU 过大时无法直接启用 XDP。**加 `--xdp-mode skb` 即可**（兼容性最好，代价是性能低于 `drv`）。

### ⚠️ 坑 2：`--log-port-access` 会留下 bpffs pin 残留

```
Error: 无法 pin PORT_ACCESS_LOG map，请确保 /sys/fs/bpf 已挂载且有写权限
Caused by:
    0: `BPF_OBJ_PIN` failed
    1: File exists (os error 17)
```

`/sys/fs/bpf/rfw_port_access_log` 退出后**不会被清理**，下次启动直接失败。核心功能（GeoIP + 协议拦截）**不需要** `--log-port-access`。
```bash
umount /sys/fs/bpf && mount -t bpf bpf /sys/fs/bpf   # 清残留 pin
ls /sys/fs/bpf/          # 应为空
```

### 推荐启动方式（systemd，后台 + 可回滚）

```bash
cat > /etc/systemd/system/rfw.service <<'UNIT'
[Unit]
Description=rfw eBPF firewall (GeoIP + protocol DPI)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
# 必须显式指定 xdp-mode skb（见坑 1）
ExecStart=/usr/local/bin/rfw --xdp-mode skb --iface eth0 --countries CN --block-http --block-socks5 --block-wireguard --block-quic
Restart=always
RestartSec=5s
AmbientCapabilities=CAP_BPF CAP_NET_ADMIN CAP_PERFMON
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
UNIT
```

> 进程正常退出会自动卸载 eBPF 程序（实测 `timeout 25 rfw ...` 退出后网卡 XDP 状态已恢复，管理通道未受影响）。

### 常用组合与 FET 模式

```bash
# 屏蔽中国方向的弱协议（最常用）
rfw --xdp-mode skb --iface eth0 --countries CN \
  --block-http --block-socks5 --block-fet-loose --block-wireguard --block-quic --block-email
rfw --xdp-mode skb --iface eth0 --block-all-from CN,RU,KP    # 屏蔽来源国的所有入站
rfw --xdp-mode skb --iface eth0 --allow-only-countries US,JP,KR --block-http   # 白名单
```

| 模式 | 行为 | 何时用 |
|---|---|---|
| `--block-fet-loose` | 不满足豁免条件时**放过** | **先从这个开始**，观察误判 |
| `--block-fet-strict` | 不满足豁免条件时**阻止** | 高安全场景，可能误杀合法流量 |

> 参考 <https://gfw.report/publications/usenixsecurity23/>。

### 验证：两件事必须都验证

**① 拦截确实生效**。对照实验：起 `python3 -m http.server 8899 --bind 0.0.0.0` → `ufw allow 8899/tcp` → 外部确认 HTTP=200 → 启动 `rfw --xdp-mode skb --iface eth0 --block-http`（不带 `--countries`）→ 外部再访问。结果：HTTP **000 / 三次 10s 超时（被拦）**，同一机器 `ssh -p 22222` **正常返回 `SSH-2.0-OpenSSH_10.0p2`**，管理 SSH 全程未断 → 按**协议特征**精确拦截，不粗暴封端口。**必须同时验证"该拦的拦住了"和"不该拦的没被误伤"。**

**② GeoIP 数据真的加载了**。`--countries CN` 若 GeoIP 没加载就是**空转**（服务在跑，实际不拦任何东西）。它不是 MaxMind `.mmdb`（`MaxMind.com` 在二进制里出现 **0 次**，磁盘无 `.mmdb`），而是 **LPM trie 前缀树**（`GEOIP_MAP`、`is_geoip_match`、`in_geoip_list`），数据**每次启动时运行时自动下载**指定国家 IP 段（[lyc8503/sing-box-rules](https://github.com/lyc8503/sing-box-rules)），**不落盘**，直灌 BPF map。🔴 **仅支持 IPv4**。

```bash
apt-get install -y --no-install-recommends bpftool     # 约 1 MB、无常驻进程
bpftool map show | grep -i geoip          # 1) eBPF map 是否存在（名字就是 GEOIP_MAP）
#   41: lpm_trie  name GEOIP_MAP  flags 0x1   key 8B  value 1B  max_entries 65536
bpftool map dump name GEOIP_MAP | grep -c key   # 2) 【关键】数真灌进去多少条国家网段
#   实测 --countries CN → 6163 条（IPv4 的 CN 前缀）
ip link show eth0 | grep -o 'xdp[a-z]*'   # 3) XDP 是否真挂在网卡上
#   xdpgeneric        ← skb 模式
```

实测环境：`v0.1.9`（static-pie）、Debian 13、KVM、virtio_net、MTU 1500、`--xdp-mode skb`、常驻内存 ~13.6 MB。

> ⚠️ **rfw 开机依赖 GitHub 可达**（GeoIP 每次运行自动下载）。**重启后应复查 `bpftool map dump name GEOIP_MAP | grep -c key` 是否非 0**。

### 性能特征与层次关系

XDP 在网卡驱动层处理、零拷贝，README 称可处理 10Gbps+；GeoIP 查询 **O(1)**。协议检测**只在启用对应规则时**才有开销。`--xdp-mode skb` 性能低于 `drv`/`hw`：网卡支持就先试 `auto`，失败再退 `skb`。

| 组件 | 层次 | 职责 |
|---|---|---|
| ufw / nftables | 端口级 | 只放行必要端口 |
| fail2ban | 行为级 | 根据日志动态封禁爆破 IP（**用 nft set，见 `fail2ban.md`**） |
| rfw | 协议/地理级 | 按国家方向 + 协议特征拦截 |

**可以同时使用**：rfw 在 XDP 层（网卡驱动之前）拦包，ufw/nftables 在 netfilter（更靠后），规则独立生效、不互相覆盖。排障时记得"包可能在 XDP 层就被丢了，所以 iptables/nft 计数器里看不到"。

### Alpine 上的 rfw 要点

安装同上面 §5「安装（含哈希校验）」，只把资产换成 musl 版（Alpine 上必须用 musl 构建，见 `alpine.md` §6）：
```bash
wget -O rfw "https://github.com/narwhal-cloud/rfw/releases/download/v0.1.9/rfw-x86_64-unknown-linux-musl"
install -m 755 rfw /usr/local/bin/rfw
test -f /sys/kernel/btf/vmlinux && echo OK      # CO-RE 必需
# 选项互斥：--countries 与 --block-all-from 不能同时用
rfw --iface eth0 --countries CN --block-http --block-socks5 --block-wireguard
apk add --no-cache bpftool && bpftool net show  # 权威验证：应看到 "eth0(2) driver id N"
```

> MTU 1500 时 `--xdp-mode auto` 可用（MTU 9000 仍需 `skb`）。`--block-all-from CN` 会警告 "未启用任何规则"（GeoIP 数据缺失），但 `--countries CN --block-XXX` 组合正常工作。Alpine 无 systemd，用 OpenRC 单元代替上面的 `rfw.service`。

```bash
systemctl disable --now rfw                     # 回滚
umount /sys/fs/bpf 2>/dev/null && mount -t bpf bpf /sys/fs/bpf   # 清 pin 残留
# rm /usr/local/bin/rfw   （按需）
```

> 未验证项：从 CN 侧的真实来源流量端到端 GeoIP 拦截（已用 `bpftool` 证明 6163 条 CN 前缀入 map，即"数据已加载、规则会命中"）；`--block-fet-*`/`--block-quic` 的实际命中。

## 6. SSH 蜜罐（sshesame / endlessh）

> **⚠️ Tier 2 可选，默认不装。** 蜜罐会 ① 常驻一个进程；② 产生**大量日志**（每条命令一行）；③ 要求真 sshd 先让出 22 端口（带来锁死风险）。**1C1G/512M 的极小机器上不要装**——收益远小于复杂度；Tier 1 的 fail2ban + 防火墙已能挡住绝大部分爆破。若决定要装，**优先用 apt 包 `sshesame`**，不要用 Docker 或 GitHub 下载。

| 包 | 版本（trixie） | 作用 | 推荐 |
|---|---|---|---|
| `sshesame` | 0.0~git20210926.d7fdb81 | 假 SSH 服务：接受任意凭据，**记录攻击者的用户名/密码/公钥指纹/命令** | ⭐ 首选 |
| `endlessh` | 1.1-5.1 | SSH tarpit：不发完整 banner，把爆破工具挂住数小时 | 可选（见坑 3） |

安装：`apt-get install -y sshesame`（⚠️ 会连带自动启动并 enable `endlessh`，见坑 3）。

源码：<https://github.com/jaksi/sshesame>、<https://github.com/skeeto/endlessh>。Docker 版 `fffaraz/fakessh`（镜像 `honeok/fakessh`）在 Debian 上属于绕远路。

**实测价值**：部署后**当天就抓到真实攻击者**，行为链完整可见：

```
authentication for user "root" with password "root" accepted     ← 弱口令命中
[channel 4] command "ps | grep '[Mm]iner'" requested             ← 找挖矿程序
[channel 6] command "ls -la ~/.local/share/TelegramDesktop/tdata ..."  ← 翻 Telegram 数据
[channel 7] command "locate D877F783D5D3EF8Cs" requested         ← 搜索特定文件
```

这正是蜜罐相对 fail2ban 的额外价值：**能看清攻击者想干什么**。

### ⚠️ 坑 1：sshesame 的配置文件是**嵌套**的

Debian 打包的字段名与上游 README 不一致，顶层直接写 `listen_address` 会报 `field listen_address not found in type main.config`。正确格式（`/etc/sshesame/config.yaml`）：
```yaml
server:
  listen_address: ":22"
logging:
  timestamps: true
```

字段名可从二进制提取（`grep -aoE 'yaml:"[^"]+"' /usr/bin/sshesame`）：`server.listen_address`、`server.max_tries`、`server.host_keys`、`server.server_version`、`logging.timestamps`、`metrics_address` 等。**`max_tries` 属于 server 之外的另一层，放错同样报错。**

### ⚠️ 坑 2：包**不带 systemd 单元**，且 `ProtectSystem` 下默认 data_dir 不可写

`dpkg -L sshesame` 只有 `/usr/bin/sshesame`（外加 `/usr/bin/testproxy`），**没有 .service**。必须自己写单元并显式指定 `-data_dir`。两个连续失败：

1. `ProtectSystem=strict` + `ReadWritePaths=/var/lib/sshesame` 但目录不存在 → `Failed to set up mount namespacing: /var/lib/sshesame: No such file or directory`（status=226/NAMESPACE）
2. 目录建好后仍失败：默认 data_dir 是 `$HOME/.local/share/sshesame` → `Failed to load config: mkdir /.local: read-only file system`

```ini
# /etc/systemd/system/sshesame.service
[Unit]
Description=sshesame SSH honeypot (fake sshd on :22)
Documentation=https://github.com/jaksi/sshesame
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
# 关键：显式 -data_dir，否则默认写 $HOME/.local/share，在 ProtectSystem=strict 下失败
ExecStart=/usr/bin/sshesame -config /etc/sshesame/config.yaml -data_dir /var/lib/sshesame
Environment=HOME=/var/lib/sshesame
Restart=always
RestartSec=10s
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/sshesame
StandardOutput=journal
StandardError=journal
StandardInput=null
[Install]
WantedBy=multi-user.target
```

```bash
install -d -m 700 /var/lib/sshesame     # 必须先建，否则 226/NAMESPACE
install -d -m 755 /etc/sshesame
systemctl daemon-reload && systemctl enable --now sshesame
```

### 部署顺序（先验后切，务必遵守）

```bash
# ① 先在高端口验证配置能跑（不碰 22，零风险）
sed 's/:22/:2200/' /etc/sshesame/config.yaml > /tmp/t.yaml
timeout 10 /usr/bin/sshesame -config /tmp/t.yaml -data_dir /tmp/sshtest &
ss -tlnp | grep 2200          # 必须看到监听，没看到就别继续
# ② 确认 22 真的空了（真 sshd 已迁到 22222）
ss -tlnp | grep ':22 ' || echo "22 空闲，可以部署"
# ③ 建目录、写单元、启动 → ④ 验证
systemctl is-active sshesame
ss -tlnp | grep ':22 '        # 应为 sshesame
```

```bash
ssh -p 22 root@<host>     # -> "This is an SSH honeypot. Everything is logged and monitored."
                          #    Permission denied (password,publickey)
journalctl -u sshesame -n 20
#   [<你的管理IP>:58286] authentication for user "root" without credentials rejected
#   [<你的管理IP>:58286] authentication for user "root" with public key "SHA256:NmWa...PiIY" rejected
```

### ⚠️ 坑 3：`apt install endlessh` 会**自动启动并 enable**，且监听 2222

```bash
ss -tlnp | grep endlessh            # *:2222
systemctl is-enabled endlessh       # enabled
systemctl disable --now endlessh    # 只用 sshesame（推荐）就停掉它
ss -tlnp | grep 2222 || echo "2222 已释放"
```

这是一个你并不想要、也不会出现在计划里的**额外对外开放端口**。装 `sshesame` **不会**自动启动（它连单元都没有），但 `endlessh` 会。**任何 `apt install` 之后都要复查 `ss -tlnp`**——这是"我明明没开这个端口"类问题的常见来源。

**endlessh（若确实要用）**：包**带** `/usr/lib/systemd/system/endlessh.service`，但**不带** `/etc/endlessh/config`。端口由 `ConfigurationDirectory=endlessh`（`/etc/endlessh/`）下的 config 决定，无 config 时用内置默认 **2222**。单元里 `PrivateUsers=true` 且 `AmbientCapabilities=CAP_NET_BIND_SERVICE` **被注释掉**，所以直接跑**绑不了 22**；要绑特权端口需取消注释 `AmbientCapabilities`、注释 `PrivateUsers`（`systemctl cat endlessh | grep -B2 -A2 -i 'AmbientCapabilities\|PrivateUsers'`）。

> **只想二选一时选 sshesame**。endlessh 优势是拖时间，但部署更绕、还会自动占端口。

### 与 fail2ban 的配合：记录 + 全端口封禁

只记录是不够的（攻击者可无限次尝试）——必须**记录 + 达阈值全端口封禁**。要点：① **单独 jail，不要复用 `[sshd]`**（`_COMM=sshesame` vs `sshd-session`）；② `journalmatch = _SYSTEMD_UNIT=sshesame.service`；③ **`action = nftables[type=allports]`**；④ **`ignoreip` 必须含管理 IP**；⑤ **只匹配"认证"行**，否则登录后几十条命令会让 jail 反复触发、日志被 `already banned` 刷屏；⑥ **fail2ban 正则不能行首锚定到 `[`**，否则静默 0 命中。完整配置与实测证据见 **`fail2ban.md` §8**。

- 蜜罐日志量大，**务必给 journald 设限额**（`SystemMaxUse=200M`，见 `hardening.md` §3）。"封了就没人进蜜罐"是多余的：封禁按 IP，新 IP 照样进来；被拒的老 IP 本身就是收益。想持续收集情报可把 `bantime` 设短（如 `1d`）。

```bash
systemctl disable --now sshesame   # 回滚
# 真 sshd 恢复 22：drop-in 里加回 Port 22 → sshd -t → reload
```

> 顺序上要**先确保 sshd 能监听 22**（蜜罐已停、端口已释放），再考虑其他调整。

## 7. 资源开销参考

| 组件 | 常驻进程 | 实测占用 |
|---|---|---|
| fail2ban | 是（Python） | ~26 MB 内存峰值 |
| sshesame 蜜罐 | 是（Go） | 很低，但**日志量大**（需 journald 限额） |
| rfw | 是（eBPF + 用户态） | 13.8 MB 二进制；GeoIP 数据另计 |
| Docker | 是（daemon + containerd） | 数百 MB 起，且会改 iptables 链 |
| Komari 探针 | 是 | 持续上报，有网络开销 |
| nexttrace | **否** | 0（按需运行） |
| bbrv3-lite | 是（仅持久化 unit） | 极小，只是 sysctl + 可能的 tc |

> 验收：`sh scripts/vps-check.sh gate`
