# vps-init

Linux VPS 初始化与加固技能（Debian / Ubuntu / Alpine）。这是一个 **DeepSeek-Harness skill**，
同时也可以脱离 skill 系统单独用：脚本全在 `scripts/`，配置在 `assets/`，文档在 `references/`。

## 为什么有这个仓库

服务器上**不再手抄脚本**（heredoc / base64 一行行粘），一律 `curl` 本仓库的 raw URL：

```bash
REPO=https://raw.githubusercontent.com/Seameee/vps-init/main

# 只读勘察（不落地执行）
curl -fsSL $REPO/scripts/vps-check.sh -o /tmp/vps-check.sh
sh /tmp/vps-check.sh recon

# 加固后验收门禁
sh /tmp/vps-check.sh gate

# ignoreip 守卫（装完 fail2ban 就要装上）
curl -fsSL $REPO/scripts/f2b-guard.sh -o /tmp/f2b-guard.sh
install -m 755 /tmp/f2b-guard.sh /usr/local/sbin/f2b-guard
f2b-guard check
```

## 装成 skill

```bash
git clone https://github.com/Seameee/vps-init.git ~/.dsh/skills/vps-init
# 以后更新
git -C ~/.dsh/skills/vps-init pull --ff-only
```

## 结构

| 路径 | 内容 |
|---|---|
| `SKILL.md` | 入口：分层原则、铁律、流程、陷阱速查、验收 |
| `references/alpine.md` | Alpine/OpenRC 全套差异（Alpine 必读） |
| `references/ssh-firewall.md` | SSH 加固、防自锁死手开关、端口迁移、ufw/nftables |
| `references/fail2ban.md` | 三个"装完等于没装"的坑、推荐配置、蜜罐日志接入 |
| `references/hardening.md` | 系统更新、journald、sysctl/BBR、时间、zram、sudo 日志、卸 snap |
| `references/optional.md` | nexttrace / BBRv3-lite / 换源 / 代理 / rfw / SSH 蜜罐 |
| `references/zsh.md` | zsh + oh-my-zsh + 自定义 `.zshrc` |
| `references/rollback.md` | SSH/防火墙/fail2ban 锁死后的恢复路径 |
| `scripts/vps-check.sh` | `recon`（只读勘察）/ `gate`（验收门禁），POSIX sh |
| `scripts/f2b-guard.sh` | fail2ban ignoreip 守卫，拒绝把你自己锁在门外 |
| `assets/zshrc.zshrc` | 已验证的 `.zshrc` |

## 原则

- **默认极简**：探针 / 蜜罐 / Docker / 换内核一律不默认装。
- **永不封锁管理 IP**：`ignoreip` 是保命绳，装 `f2b-guard`，改 jail 用 `f2b-guard restart`。
- **生产模式不做冗余测试**：只跑 `gate` 里的门禁，不搞性能基准、不做封禁实验。
- **不写具体 IP**：脚本从 `$SSH_CONNECTION` 或 `/etc/fail2ban/guard-ips` 取。

## License

MIT
