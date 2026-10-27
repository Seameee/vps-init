# =============================================================================
# 1. 基础环境变量设置 (Environment Variables)
# =============================================================================
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

typeset -U path PATH
path=(
    "$HOME/bin"
    "$HOME/.local/bin"
    /usr/local/sbin
    /usr/local/bin
    /usr/sbin
    /usr/bin
    /sbin
    /bin
    $path
)
export PATH

# =============================================================================
# 2. Oh My Zsh 核心配置 (Oh My Zsh Configuration)
# =============================================================================
export ZSH="$HOME/.oh-my-zsh"

# 主题设置
ZSH_THEME="ys"

# 插件列表 (添加新插件在此处修改)
plugins=(git zsh-autosuggestions zsh-syntax-highlighting z extract web-search)

# 加载 Oh My Zsh
source "$ZSH/oh-my-zsh.sh"

# =============================================================================
# 3. 登录与系统初始化环境 (Login & System Initialization)
# =============================================================================
if [[ -o login ]] && [[ -z "$ZPROFILE_LOADED" ]]; then
    export ZPROFILE_LOADED=1

    # 辅助函数：根据包管理器自动安装系统信息查看工具
    install_info_tools() {
        echo "Installing system information tool..."

        # root / sudo 兼容处理
        run_pkg_cmd() {
            if (( EUID == 0 )); then
                "$@"
            elif command -v sudo >/dev/null 2>&1; then
                sudo "$@"
            else
                echo "ERROR: 需要 root 权限，但系统中没有 sudo。请手动执行：$*"
                return 1
            fi
        }

        # Debian/Ubuntu 系列
        if command -v apt-get >/dev/null 2>&1; then
            echo "Checking for fastfetch in repositories..."
            if apt-cache search fastfetch 2>/dev/null | grep -q fastfetch; then
                echo "Installing fastfetch..."
                run_pkg_cmd apt-get update && run_pkg_cmd apt-get install -y fastfetch
                return $?
            fi

            echo "fastfetch not found in repositories, trying neofetch..."
            run_pkg_cmd apt-get update && run_pkg_cmd apt-get install -y neofetch
            return $?

        # RHEL/CentOS 系列
        elif command -v yum >/dev/null 2>&1; then
            echo "Using yum package manager..."
            if yum search fastfetch 2>/dev/null | grep -q fastfetch; then
                echo "Installing fastfetch..."
                run_pkg_cmd yum install -y fastfetch
                return $?
            else
                echo "Installing neofetch..."
                run_pkg_cmd yum install -y neofetch
                return $?
            fi

        # Arch Linux 系列
        elif command -v pacman >/dev/null 2>&1; then
            echo "Using pacman package manager..."
            if pacman -Ss fastfetch 2>/dev/null | grep -q fastfetch; then
                echo "Installing fastfetch..."
                run_pkg_cmd pacman -Sy --noconfirm fastfetch
                return $?
            else
                echo "Installing neofetch..."
                run_pkg_cmd pacman -Sy --noconfirm neofetch
                return $?
            fi

        # openSUSE 系列
        elif command -v zypper >/dev/null 2>&1; then
            echo "Using zypper package manager..."
            if zypper search fastfetch 2>/dev/null | grep -q fastfetch; then
                echo "Installing fastfetch..."
                run_pkg_cmd zypper install -y fastfetch
                return $?
            else
                echo "Installing neofetch..."
                run_pkg_cmd zypper install -y neofetch
                return $?
            fi

        # Alpine Linux
        elif command -v apk >/dev/null 2>&1; then
            echo "Using apk package manager..."
            if apk search 2>/dev/null | grep -q '^fastfetch$'; then
                echo "Installing fastfetch..."
                run_pkg_cmd apk add fastfetch
                return $?
            fi

            echo "fastfetch not found in repositories, trying neofetch..."
            run_pkg_cmd apk add neofetch
            return $?

        else
            echo "ERROR: Unsupported package manager. Please install fastfetch or neofetch manually."
            echo "Visit https://github.com/fastfetch-cli/fastfetch or https://github.com/dylanaraps/neofetch"
            return 1
        fi
    }

    # 设置登录 Shell 的 ulimit (文件描述符限制) - 仅当当前值偏低时尝试调高
    current_nofile=$(ulimit -Sn 2>/dev/null)
    if [[ "$current_nofile" != "unlimited" ]] && [[ "$current_nofile" =~ '^[0-9]+$' ]] && (( current_nofile < 65535 )); then
        if (( EUID == 0 )); then
            ulimit -SHn 65535 2>/dev/null || true
        else
            ulimit -Sn 65535 2>/dev/null || true
        fi
    fi

    # 交互式终端：检查、安装并显示系统信息
    if [[ -o interactive ]]; then
        if ! command -v fastfetch >/dev/null 2>&1 && ! command -v neofetch >/dev/null 2>&1; then
            echo "System information tools not found. Attempting to install..."

            if install_info_tools; then
                echo "Installation successful!"
                sleep 1
            else
                echo "ERROR: Failed to install system information tools."
                echo "Please install manually:"
                echo "  Debian/Ubuntu: sudo apt install neofetch"
                echo "  RHEL/CentOS:   sudo yum install neofetch"
                echo "  Arch:          sudo pacman -S neofetch"
                echo "  Alpine:        apk add neofetch"
                echo "  For fastfetch: Visit https://github.com/fastfetch-cli/fastfetch"
                echo ""
                echo "System information will not be displayed on login."
            fi
        fi

        if command -v fastfetch >/dev/null 2>&1; then
            FASTFETCH_CONFIG="${XDG_CONFIG_HOME}/fastfetch/config.jsonc"

            # 若无配置则自动生成并过滤 IP 信息
            if [[ ! -f "$FASTFETCH_CONFIG" ]]; then
                echo "Generating fastfetch config..."
                mkdir -p "$(dirname "$FASTFETCH_CONFIG")"
                fastfetch --gen-config "$FASTFETCH_CONFIG"

                if [[ -f "$FASTFETCH_CONFIG" ]]; then
                    sed -i -E '/"(LocalIP|localip|PublicIP|publicip)"/d' "$FASTFETCH_CONFIG"
                    echo "IP display disabled in config."
                fi
            fi

            # 始终使用同一份配置，避免不同系统默认路径差异
            fastfetch -c "$FASTFETCH_CONFIG"
        elif command -v neofetch >/dev/null 2>&1; then
            neofetch
        fi
    fi
fi

# =============================================================================
# 4. 别名与自定义函数 (Aliases & Custom Functions)
# =============================================================================
# 文件查看别名
alias ll='ls -alFh'
alias la='ls -AlFh'
alias l='ls -CF'

# 网络及工具别名
alias rustscan='docker run -it --rm --name rustscan rustscan/rustscan:latest'
alias clearproxy="unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy"
alias aptest='curl nxtrace.org/speedtest -sL | bash'

# 编辑器别名
alias nano='nano -l'
alias sudo='sudo '

# 查看 SSH 失败日志函数
lastb2() {
    local count=${1:-50}

    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u ssh -u sshd -r 2>/dev/null \
            | grep -m "$count" --color=always -E "Failed|Invalid|error|authentication failure" \
            | less -R
    elif [[ -f /var/log/auth.log ]]; then
        grep --color=always -E "Failed|Invalid|error|authentication failure" /var/log/auth.log \
            | tail -n "$count" | less -R
    elif [[ -f /var/log/secure ]]; then
        grep --color=always -E "Failed|Invalid|error|authentication failure" /var/log/secure \
            | tail -n "$count" | less -R
    elif [[ -f /var/log/messages ]]; then
        grep --color=always -iE "sshd?.*(failed|invalid|error|authentication failure)|failed password|invalid user" /var/log/messages \
            | tail -n "$count" | less -R
    else
        echo "未找到可用的 SSH 日志文件 (journalctl/auth.log/secure/messages)"
        return 1
    fi
}

# 查看 IP 地址信息函数
getip() {
    command -v wget >/dev/null 2>&1 || { echo "请先安装 wget"; return 1; }
    command -v jq >/dev/null 2>&1 || { echo "请先安装 jq"; return 1; }

    local data
    local ip="" country="" city="" asn="" org=""

    data=$(wget -qO- --timeout=2 --tries=1 https://ipinfo.cv/api/ip/card/preview 2>/dev/null)
    if ! jq -e '.ip and .country and .org' >/dev/null 2>&1 <<< "$data"; then
        data=$(wget -qO- --timeout=2 --tries=1 https://ipinfo.io 2>/dev/null)
        jq -e '.ip and .country and .org' >/dev/null 2>&1 <<< "$data" || {
            echo "获取 IP 信息失败"
            return 1
        }
    fi

    eval "$(
        jq -r '
            "ip="      + (.ip      // "" | @sh),
            "country=" + (.country // "" | @sh),
            "city="    + (.city    // "" | @sh),
            "asn="     + (.asn     // "" | @sh),
            "org="     + (.org     // "" | @sh)
        ' <<< "$data"
    )"

    if [[ -z "$asn" && -n "$org" ]]; then
        asn=$(printf '%s\n' "$org" | grep -oE 'AS[0-9]+' | head -n1)
    fi

    if [[ -n "$asn" && -n "$org" ]]; then
        org=${org#"$asn "}
    fi

    [[ -n "$ip" ]] && printf "IP       %s\n" "$ip"
    [[ -n "$country" ]] && printf "Country  %s\n" "$country"
    [[ -n "$city" ]] && printf "City     %s\n" "$city"
    [[ -n "$asn" ]] && printf "ASN      %s\n" "$asn"
    [[ -n "$org" ]] && printf "Org      %s\n" "$org"
}

# =============================================================================
# 5. Zsh 终端特性微调 (Zsh Terminal Tweaks)
# =============================================================================
# 取消自动括号粘贴模式
# unset zle_bracketed_paste