# zsh + oh-my-zsh + 自定义 .zshrc
> 出自 github.com/Seameee/vps-init —— 可用 curl 直接拉取，无需手抄。
>
> **Tier 1 可选组件，必须询问用户后才装**。它不属于默认必做项：会切换默认 shell、下载用户的个人配置。

## 1. 依赖清单（先看清再装）

| 组件 | 来源 | 必需性 |
|---|---|---|
| `zsh` | apt / apk | 必需 |
| `git` | apt / apk | 必需（oh-my-zsh 用 git 克隆） |
| oh-my-zsh | `install.ohmyz.sh` | 必需 |
| `zsh-autosuggestions` | GitHub（**非内置**，需单独 clone） | 由 .zshrc 的 `plugins=` 决定 |
| `zsh-syntax-highlighting` | GitHub（**非内置**，需单独 clone） | 由 .zshrc 的 `plugins=` 决定 |
| 主题 `ys` | oh-my-zsh 内置 | 无需额外下载 |

> **踩坑点**：oh-my-zsh 的 `plugins=(...)` 里写的外部插件**不会自动安装**。引用了未 clone 的插件，开 zsh 会报 `plugin 'zsh-autosuggestions' not found`（或静默不生效）。**必须逐个 clone 到 `${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/`。**

## 2. 安装步骤
```bash
export DEBIAN_FRONTEND=noninteractive
# 1) 装 zsh + git
apt-get install -y zsh git
# 2) 切换默认 shell 为 zsh
chsh -s /usr/bin/zsh root        # 普通用户换成对应用户名
grep '^root:' /etc/passwd | cut -d: -f7   # 验证：应显示 /usr/bin/zsh
# 3) 装 oh-my-zsh（RUNZSH=no 避免安装器直接切进 zsh、打断当前会话）
RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://install.ohmyz.sh/)"
# 4) 装 .zshrc 需要的外部插件（按 .zshrc 的 plugins= 决定）
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
    "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
# 5) 覆盖为用户的自定义 .zshrc（放在最后，否则会被 oh-my-zsh 模板覆盖）
#    方式 A（推荐）：用本 skill 内置、已实机验证的配置（见 §3）
install -m 644 "$SKILL_DIR/assets/zshrc-seameee.zshrc" "$HOME/.zshrc"
#    方式 B：从用户的 gist 拉取
# curl -fsSL -o "$HOME/.zshrc" \
#     "https://gist.githubusercontent.com/<用户>/<gist-id>/raw/.zshrc"
# 6) 验证
zsh -n "$HOME/.zshrc"                       # 语法检查
zsh -ic 'echo "plugins OK: ${#plugins[@]}"' # 交互式加载，看有无报错
```
### 关于 `RUNZSH=no CHSH=no`
两个都要：`RUNZSH=no` —— 装完不要把当前会话切成 zsh（会中断后续脚本）；`CHSH=no` —— 不要自动改默认 shell（我们自己 `chsh`，避免安装器把 shell 切到非预期路径）。

## 3. 本 skill 内置的用户配置（可直接选用，免下载）
**`assets/zshrc-seameee.zshrc`** —— 已在 **NoBrand-JP 2**（Debian 13，2026-10-14）实机验证通过。

| 项 | 值 |
|---|---|
| 来源 gist | `https://gist.githubusercontent.com/Seameee/ab0a81e3ef476e6059f35a0785f12a32/raw/.zshrc` |
| 行数 / 字节 | 267 行 / 10134 字节 |
| **SHA256** | `fb36c3c63ca6936a0a51a75ba5057d9b1be5acfafb79083072ddeca49c96c587` |
| 主题 | `ys`（oh-my-zsh **内置**，无需下载） |
| `plugins=` | `git zsh-autosuggestions zsh-syntax-highlighting z extract web-search` |
| **需额外 clone 的插件** | 仅 `zsh-autosuggestions`、`zsh-syntax-highlighting`（其余为内置） |
| 运行期额外依赖 | `jq`、`wget`（`getip` 函数用）；`fastfetch`/`neofetch` 见下方警告 |

```bash
SKILL_DIR=~/.dsh/skills/vps-init
install -m 644 "$SKILL_DIR/assets/zshrc-seameee.zshrc" "$HOME/.zshrc"
sha256sum "$HOME/.zshrc"    # 必须等于上表的 SHA256
```

> ⚠️ **副作用（务必知情）**：该 `.zshrc` 在 **`[[ -o login ]] && [[ -o interactive ]]`** 分支里，若检测不到 `fastfetch`/`neofetch`，会**打印提示并自动执行 `apt-get update && apt-get install -y fastfetch`（失败则退回 neofetch）**。也就是说：**第一次交互式登录会自动装包**。生产机上若不希望它擅自装包，**先手动装好 `fastfetch`**，或删除 `.zshrc` 里 `install_info_tools` / 该交互分支。
>
> 其他不影响主流程的内容：`alias sudo='sudo '`（保留补全）、`alias aptest='curl nxtrace.org/speedtest -sL | bash'`（**仅在你手动调用时**才 curl|bash）、`alias rustscan='docker run ...'`（本机未装 Docker，该别名不可用）。

**拿到别人的 .zshrc 时：先分析依赖，再决定 clone 哪些插件**

```bash
grep -A6 '^plugins=' ~/.zshrc              # 看插件列表
grep '^ZSH_THEME=' ~/.zshrc                # 看主题（非内置主题才需要额外下载）
grep -nE '^\s*(source|\.)\s' ~/.zshrc      # 看是否 source 了外部文件
```
示例（上面那个 267 行的配置）：
```
ZSH_THEME="ys"                                          ← oh-my-zsh 内置，无需下载
plugins=(git zsh-autosuggestions zsh-syntax-highlighting z extract web-search)
                ↑ 需 clone      ↑ 需 clone       ↑ 其余为内置
source "$ZSH/oh-my-zsh.sh"                              ← 不引用外部文件
```
结论：只需 clone 两个插件，其余（`git`/`z`/`extract`/`web-search`）都是内置。

## 4. 顺序陷阱

| ❌ 做法 | 后果 |
|---|---|
| 先下载 `.zshrc`，再装 oh-my-zsh | `.zshrc` 被 oh-my-zsh 安装器的模板**覆盖** |
| 插件没 clone 就切 zsh | 报 `plugin not found`，或插件静默不生效 |
| 用 `wget` 不带 `-q`/重定向错 | 可能把错误页写进 `.zshrc` |
| `chsh` 写 `/bin/zsh` 但系统是 `/usr/bin/zsh` | 登录失败或回落到 sh。**先 `command -v zsh` 确认真实路径** |
| 只 `chsh` 不验证 | 不知道到底改成功没有 |

> **注意**：`chsh` 只影响**新登录**的会话。当前 SSH 会话仍是 bash，需要 `exec zsh` 或重新登录。

**关键验证（最关键的是真正加载一次）**：

```bash
getent passwd root | cut -d: -f7          # 默认 shell
[ -d "$HOME/.oh-my-zsh" ] && echo 已装 || echo 缺失
for p in zsh-autosuggestions zsh-syntax-highlighting; do
  [ -d "$HOME/.oh-my-zsh/custom/plugins/$p" ] && echo "$p 已装" || echo "$p 缺失"
done
zsh -ic 'echo LOADED-OK' 2>&1 | tail -5
```

## 5. 卸载 / 回滚
```bash
chsh -s /bin/bash root                  # 切回 bash
mv ~/.oh-my-zsh ~/.oh-my-zsh.bak        # 保留配置以便回滚
mv ~/.zshrc ~/.zshrc.bak
apt-get remove --purge -y zsh           # 确认无脚本依赖 zsh 后再执行
```

> 被改动的三处：`/etc/passwd`（shell 字段）、`~/.oh-my-zsh/`、`~/.zshrc`。回滚只需还原这三处。

> 验收：`sh scripts/vps-check.sh gate`
