#!/bin/sh

# SOCKS5 代理安装/卸载/查看/修改/重启脚本，适用于 Debian 10/11/12
# 使用 Dante Server

# 定义颜色变量
red="\033[0;31m"
green="\033[0;32m"
plain="\033[0m"

# 脚本版本
sh_ver="1.0.0"
# 脚本更新日期
up_date="2025.07.24"

# --- 配置变量 (这些现在可以在安装或修改时被覆盖) ---
# 脚本默认值，如果用户在安装时未输入，将使用这些值
PROXY_PORT="1080" # 默认 SOCKS5 端口
PROXY_USER="your_socks_user" # SOCKS5 认证的默认用户名
PROXY_PASSWORD="your_socks_password" # SOCKS5 认证的默认密码

# 建议将日志输出到文件，如果希望输出到 stderr，请注释掉下一行
LOG_OUTPUT="/var/log/danted.log"

CONFIG_FILE="/etc/danted.conf"
IPTABLES_RULES_FILE="/etc/iptables/rules.v4" # iptables 持久化规则文件，需要安装 iptables-persistent

# --- 函数 ---

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 显示错误并退出
die() {
    echo "错误：$1" >&2
    exit 1
}

# 如果未设置密码，则生成一个随机密码
generate_random_password() {
    head /dev/urandom | tr -dc A-Za-z0-9_ | head -c 16
}

# 获取当前外部网络接口
get_default_interface() {
    ip route | grep default | awk '{print $5}' | head -n 1
}

# 从配置文件读取当前配置 (用于修改和查看功能)
# 注意: 密码不会从配置文件读取，因为它不以明文存储
load_current_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 尝试从配置文件中读取端口和外部接口
        # 内部端口可能被指定为 internal: 0.0.0.0 port=XXXX 或 internal: eth0 port=XXXX
        PORT_FROM_CONFIG=$(grep 'internal:' "$CONFIG_FILE" | awk -F'port=' '{print $2}' | awk '{print $1}' | head -n 1)
        INTERFACE_FROM_CONFIG=$(grep 'external:' "$CONFIG_FILE" | awk '{print $2}' | head -n 1)
        LOG_FROM_CONFIG=$(grep 'logoutput:' "$CONFIG_FILE" | awk '{print $2}' | head -n 1)

        [ -n "$PORT_FROM_CONFIG" ] && PROXY_PORT="$PORT_FROM_CONFIG"
        # 对于用户名，Dante 配置中不直接存储用户名，所以我们保持使用脚本变量的当前值或默认值
        # PROXY_USER 保留脚本变量或上次设置的值
        # PROXY_PASSWORD 始终由脚本管理，不从配置文件读取

        # 更新日志路径，如果配置文件中有指定
        [ -n "$LOG_FROM_CONFIG" ] && LOG_OUTPUT="$LOG_FROM_CONFIG"
    fi
}


# --- 安装函数 ---
install_proxy() {
    echo "--- 开始安装 SOCKS5 代理 ---"

    # 提示用户输入配置
    echo ""
    echo "请设置 SOCKS5 代理的配置："
    read -p "请输入 SOCKS5 端口 (默认: $PROXY_PORT): " input_port
    # 如果用户未输入，则使用默认值
    PROXY_PORT=${input_port:-$PROXY_PORT} 

    read -p "请输入 SOCKS5 用户名 (默认: $PROXY_USER): " input_user
    # 如果用户未输入，则使用默认值
    PROXY_USER=${input_user:-$PROXY_USER} 

    # 密码输入特殊处理，避免在屏幕上显示
    unset input_password
    prompt_for_password=true
    # 检查是否是初始的占位符密码，如果不是，则询问是否使用已设置的密码
    if [ -n "$PROXY_PASSWORD" ] && [ "$PROXY_PASSWORD" != "your_socks_password" ]; then
        read -p "检测到已设置密码。是否使用此密码？(y/N，输入 n 将设置新密码): " use_existing_password
        if [ "$use_existing_password" = "y" ] || [ "$use_existing_password" = "Y" ]; then
            prompt_for_password=false
            echo "将使用现有密码。"
        fi
    fi

    if [ "$prompt_for_password" = true ]; then
        echo -n "请输入 SOCKS5 密码 (如果留空将自动生成): "
        # 禁用回显
        stty -echo
        read input_password
        stty echo
        echo "" # 换行
        if [ -z "$input_password" ]; then
            PROXY_PASSWORD=$(generate_random_password)
            echo "密码留空，已生成一个随机密码。"
        else
            PROXY_PASSWORD="$input_password"
        fi
    fi

    echo ""
    echo "确认以下配置："
    echo "端口: $PROXY_PORT"
    echo "用户名: $PROXY_USER"
    echo "密码: (已设置，出于安全考虑不显示)"
    read -p "按任意键继续安装，或 Ctrl+C 取消..." -n 1
    echo ""

    # 1. 更新软件包索引并安装 Dante 服务器
    echo "正在更新软件包索引并安装 dante-server..."
    apt update -y || die "更新软件包索引失败。"
    apt install dante-server -y || die "安装 dante-server 失败。"

    # 2. 创建 SOCKS5 用户并设置密码
    echo "正在创建 SOCKS5 用户 '$PROXY_USER'..."
    if ! id "$PROXY_USER" &>/dev/null; then
        # 在 Debian 上使用 useradd 创建系统用户，不创建主目录，不提供shell登录
        useradd -r -s /usr/sbin/nologin "$PROXY_USER" || die "创建 SOCKS5 用户失败。"
    else
        echo "用户 '$PROXY_USER' 已存在。跳过用户创建。"
    fi

    # 为 SOCKS5 用户设置密码
    echo "$PROXY_USER:$PROXY_PASSWORD" | chpasswd || die "为 SOCKS5 用户设置密码失败。"
    
    # 3. 配置 Dante 服务器
    echo "正在配置 Dante 服务器，配置文件路径：$CONFIG_FILE..."

    # 如果存在，则备份现有配置
    if [ -f "$CONFIG_FILE" ]; then
        echo "正在备份现有配置到 ${CONFIG_FILE}.bak"
        mv "$CONFIG_FILE" "${CONFIG_FILE}.bak" || die "备份现有配置失败。"
    fi

    # 确定外部接口（尽力而为）
    DEFAULT_INTERFACE=$(get_default_interface)
    if [ -z "$DEFAULT_INTERFACE" ]; then
        echo "无法动态确定外部接口。默认使用 'eth0'。请检查 $CONFIG_FILE。"
        DEFAULT_INTERFACE="eth0" # 回退到 eth0
    fi
    echo "检测到的外部接口：$DEFAULT_INTERFACE"

    # 生成 danted 配置文件
    cat << EOF > "$CONFIG_FILE"
logoutput: $LOG_OUTPUT
# 如果不需要日志文件，请使用以下行并注释掉上面的 logoutput 行
# logoutput: stderr

internal: 0.0.0.0 port=$PROXY_PORT
external: $DEFAULT_INTERFACE

socksmethod: username none
clientmethod: none

user.privileged: root
user.notprivileged: nobody

# SOCKS5 请求认证
# 允许来自任何源 IP (0.0.0.0/0) 的访问
# 要求使用 'username' 方法对 SOCKS5 流量进行认证
# 'username' 要求系统中定义用户
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    # 只允许经过认证的用户进行 SOCKS5 代理
    socksmethod: username
    log: error connect disconnect
}

# 默认阻止所有其他流量（可选，良好的安全实践）
client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF

    echo "Dante 配置完成。"

    # 4. 启用并启动 Dante 服务
    echo "正在启用并启动 danted 服务..."
    # 使用 systemctl 管理服务
    systemctl enable danted || die "将 danted 添加到启动项失败。"
    systemctl start danted || die "启动 danted 服务失败。"

    # 5. 打开防火墙端口（如果使用 iptables/nftables）
    echo "正在检查并打开防火墙端口 $PROXY_PORT..."
    if command_exists iptables; then
        # 确保安装 iptables-persistent 来持久化规则
        echo "正在安装 iptables-persistent 以持久化 iptables 规则..."
        apt install iptables-persistent -y || echo "警告：安装 iptables-persistent 失败。您可能需要手动持久化 iptables 规则。"

        # 允许流量流向外部接口上的代理端口
        iptables -A INPUT -i "$DEFAULT_INTERFACE" -p tcp --dport "$PROXY_PORT" -j ACCEPT || echo "警告：添加 iptables 规则失败。请检查您的防火墙。"
        
        # 持久化 iptables 规则
        echo "正在持久化 iptables 规则..."
        netfilter-persistent save || die "持久化 iptables 规则失败。"
        echo "iptables 规则已持久化。"
    elif command_exists nft; then
        echo "检测到 nftables。请手动添加规则以允许 TCP 端口 $PROXY_PORT。"
        echo "示例：nft add rule ip filter input tcp dport $PROXY_PORT accept"
    else
        echo "未找到常见的防火墙管理工具 (iptables/nft)。请确保端口 $PROXY_PORT 已手动打开。"
    fi

    echo "--- SOCKS5 代理安装完成！ ---"
    # 安装成功后显示连接信息
    echo "SOCKS5 代理现在正在端口 $PROXY_PORT 上运行。"
    echo "您可以使用以下凭据进行连接："
    echo "  SOCKS5 地址: $(hostname -I | awk '{print $1}') (或服务器IP)"
    echo "  SOCKS5 端口: $PROXY_PORT"
    echo "  用户名:      $PROXY_USER"
    echo "  密码:        $PROXY_PASSWORD"
    echo ""
    echo "请记住这些凭据！"
    echo ""
    echo "如果遇到连接问题，请仔细检查 $CONFIG_FILE 中的 'external' 接口"
    echo "并确保您的服务器防火墙允许端口 $PROXY_PORT 的入站连接。"
}

# --- 卸载函数 ---
uninstall_proxy() {
    echo "--- 开始卸载 SOCKS5 代理 ---"

    # 停止并禁用 Dante 服务
    if systemctl is-active --quiet danted; then
        echo "正在停止并禁用 danted 服务..."
        systemctl stop danted
        systemctl disable danted
    else
        echo "danted 服务未运行或未启用。"
    fi

    # 删除 Dante 配置文件
    if [ -f "$CONFIG_FILE" ]; then
        echo "正在删除 Dante 配置文件：$CONFIG_FILE"
        rm "$CONFIG_FILE"
    fi
    if [ -f "${CONFIG_FILE}.bak" ]; then
        echo "正在删除 Dante 备份配置文件：${CONFIG_FILE}.bak"
        rm "${CONFIG_FILE}.bak"
    fi

    # 删除 SOCKS5 用户
    if id "$PROXY_USER" &>/dev/null; then
        echo "正在删除 SOCKS5 用户 '$PROXY_USER'..."
        deluser "$PROXY_USER" || echo "警告：删除用户 '$PROXY_USER' 失败，请手动删除。"
    else
        echo "SOCKS5 用户 '$PROXY_USER' 不存在。"
    fi

    # 删除 Dante 软件包
    if dpkg -s dante-server >/dev/null 2>&1; then
        echo "正在卸载 dante-server 软件包..."
        apt remove --purge dante-server -y || die "卸载 dante-server 失败。"
        apt autoremove --purge -y # 清理不再需要的依赖
    else
        echo "dante-server 软件包未安装。"
    fi

    # 移除防火墙规则
    echo "正在尝试移除防火墙规则..."
    if command_exists iptables; then
        DEFAULT_INTERFACE=$(get_default_interface)
        if [ -n "$DEFAULT_INTERFACE" ]; then
            # 尝试删除添加的 INPUT 规则
            iptables -D INPUT -i "$DEFAULT_INTERFACE" -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null
            echo "尝试删除 iptables 规则。"
            if command_exists netfilter-persistent; then
                netfilter-persistent save || echo "警告：持久化 iptables 规则失败，可能需要手动处理。"
                echo "iptables 规则已更新并持久化。"
            else
                echo "未找到 netfilter-persistent。您可能需要手动持久化 iptables 规则。"
            fi
        else
            echo "无法确定默认接口，请手动检查并清理 iptables 规则。"
        fi
    elif command_exists nft; then
        echo "nftables 检测到。请手动移除相关 nftables 规则。"
    else
        echo "未找到常见的防火墙管理工具。请手动检查防火墙设置。"
    fi

    # 删除日志文件
    if [ -f "$LOG_OUTPUT" ]; then
        echo "正在删除日志文件：$LOG_OUTPUT"
        rm "$LOG_OUTPUT"
    fi

    echo "--- SOCKS5 代理卸载完成！ ---"
}

# --- 修改配置函数 ---
modify_proxy_config() {
    echo "--- 修改 SOCKS5 代理配置 ---"

    # 确保加载当前配置，以便显示默认值
    load_current_config

    echo ""
    echo "请输入新的 SOCKS5 配置 (留空将使用当前值):"

    # 获取当前端口
    CURRENT_PORT=$(grep 'internal:' "$CONFIG_FILE" | awk -F'port=' '{print $2}' | awk '{print $1}' | head -n 1)
    read -p "新 SOCKS5 端口 (当前: ${CURRENT_PORT:-$PROXY_PORT}): " new_port
    NEW_PROXY_PORT=${new_port:-${CURRENT_PORT:-$PROXY_PORT}}

    # 获取当前用户名（用户管理独立于Dante配置，这里主要指SOCKS认证用户）
    read -p "新 SOCKS5 用户名 (当前: $PROXY_USER): " new_user
    NEW_PROXY_USER=${new_user:-$PROXY_USER}

    # 密码输入
    unset new_password_input
    echo -n "新 SOCKS5 密码 (留空将使用当前脚本变量中的密码，或自动生成): "
    stty -echo
    read new_password_input
    stty echo
    echo "" # 换行

    if [ -z "$new_password_input" ]; then
        if [ -z "$PROXY_PASSWORD" ] || [ "$PROXY_PASSWORD" = "your_socks_password" ]; then
            NEW_PROXY_PASSWORD=$(generate_random_password)
            echo "密码留空且无有效旧密码，已生成新的随机密码。"
        else
            NEW_PROXY_PASSWORD="$PROXY_PASSWORD" # 使用脚本变量中已有的密码
            echo "密码留空，将继续使用现有密码。"
        fi
    else
        NEW_PROXY_PASSWORD="$new_password_input"
    fi

    echo ""
    echo "确认新的配置："
    echo "新端口: $NEW_PROXY_PORT"
    echo "新用户名: $NEW_PROXY_USER"
    echo "新密码: (已设置，出于安全考虑不显示)"
    read -p "按任意键继续应用修改，或 Ctrl+C 取消..." -n 1
    echo ""

    # 更新用户
    if ! id "$NEW_PROXY_USER" &>/dev/null; then
        echo "正在创建新用户 '$NEW_PROXY_USER'..."
        useradd -r -s /usr/sbin/nologin "$NEW_PROXY_USER" || die "创建新 SOCKS5 用户失败。"
    elif [ "$NEW_PROXY_USER" != "$PROXY_USER" ]; then
        echo "警告：用户 '$NEW_PROXY_USER' 已存在，但与旧用户名不同。请确保这是您想要的用户。"
    fi

    # 更新旧用户的密码，如果用户名更改则删除旧用户（但需谨慎）
    if [ "$NEW_PROXY_USER" != "$PROXY_USER" ] && id "$PROXY_USER" &>/dev/null; then
        echo "正在删除旧用户 '$PROXY_USER'..."
        deluser "$PROXY_USER" || echo "警告：删除旧用户 '$PROXY_USER' 失败，请手动删除。"
    fi

    # 为新用户或更新后的用户设置密码
    echo "$NEW_PROXY_USER:$NEW_PROXY_PASSWORD" | chpasswd || die "为 SOCKS5 用户设置密码失败。"
    echo "SOCKS5 用户名已更新为：$NEW_PROXY_USER"
    echo "SOCKS5 密码已更新。"

    # 更新Dante配置文件
    echo "正在更新 Dante 配置文件..."
    # 备份当前配置
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_modify_$(date +%Y%m%d%H%M%S)"

    # 使用sed替换端口
    sed -i "s/^internal: .*port=[0-9]*/internal: 0.0.0.0 port=$NEW_PROXY_PORT/" "$CONFIG_FILE" || die "更新配置文件中的端口失败。"

    # 更新脚本中的全局变量
    PROXY_PORT="$NEW_PROXY_PORT"
    PROXY_USER="$NEW_PROXY_USER"
    PROXY_PASSWORD="$NEW_PROXY_PASSWORD" # 更新脚本变量，以便后续查看

    echo "Dante 配置修改完成。"
    echo "请执行 '重启 SOCKS5 服务' 使更改生效。"
}


# --- 重启服务函数 ---
restart_proxy() {
    echo "--- 重启 SOCKS5 服务 ---"
    if systemctl is-active --quiet danted; then
        echo "正在重启 danted 服务..."
        systemctl restart danted || die "重启 danted 服务失败。"
        echo "danted 服务已成功重启。"
    else
        echo "danted 服务未运行或未安装，无法重启。"
        read -p "是否尝试启动 danted 服务？(y/N): " start_choice
        if [ "$start_choice" = "y" ] || [ "$start_choice" = "Y" ]; then
            systemctl start danted || die "启动 danted 服务失败。"
            echo "danted 服务已启动。"
        fi
    fi
}


# --- 查看函数 ---
view_status() {
    echo "--- SOCKS5 代理状态概览 ---"

    # 尝试从配置文件加载当前端口和日志路径
    load_current_config

    # 获取服务器的第一个外部IP地址
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="未知 (请手动检查)"
    fi

    # 表格显示 SOCKS5 代理连接信息
    echo ""
    echo "SOCKS5 代理连接信息:"
    printf "%-15s %-25s\n" "项目" "值"
    printf "%s\n" "----------------------------------------"
    printf "%-15s %-25s\n" "SOCKS5 地址" "$SERVER_IP"
    printf "%-15s %-25s\n" "SOCKS5 端口" "$PROXY_PORT"
    printf "%-15s %-25s\n" "用户名" "$PROXY_USER"
    printf "%-15s %-25s\n" "密码" "********** (出于安全考虑不显示)"
    printf "%s\n" "----------------------------------------"
    echo ""

    echo "Dante Server 服务状态："
    # 使用 systemctl 检查服务状态
    systemctl status danted --no-pager || echo "Dante 服务可能未安装或未运行。"

    echo ""
    echo "Dante 配置文件的头部信息 ($CONFIG_FILE)："
    if [ -f "$CONFIG_FILE" ]; then
        head -n 20 "$CONFIG_FILE" # 显示前20行配置
    else
        echo "Dante 配置文件不存在。"
    fi

    echo ""
    echo "当前监听的 SOCKS5 端口："
    if command_exists ss; then
        ss -tuln | grep ":$PROXY_PORT" | grep LISTEN || echo "端口 $PROXY_PORT 未被监听。"
    elif command_exists netstat; then
        netstat -tuln | grep ":$PROXY_PORT" | grep LISTEN || echo "端口 $PROXY_PORT 未被监听。"
    else
        echo "未找到 ss 或 netstat 命令，无法检查端口状态。"
    fi

    echo ""
    echo "系统用户 '$PROXY_USER' 状态："
    if id "$PROXY_USER" &>/dev/null; then
        echo "用户 '$PROXY_USER' 存在。"
    else
        echo "用户 '$PROXY_USER' 不存在。"
    fi

    echo ""
    echo "防火墙规则 (iptables INPUT 链 - 仅显示相关规则)："
    if command_exists iptables; then
        iptables -L INPUT -n --line-numbers | grep "$PROXY_PORT" || echo "没有针对端口 $PROXY_PORT 的 iptables 规则被发现。"
    elif command_exists nft; then
        echo "请手动检查 nftables 规则。"
    else
        echo "未找到 iptables 或 nft 命令。"
    fi
    echo "" 

    echo "最近的 Dante 日志 (如果存在)："
    # 优先使用 journalctl 查看 systemd 管理的服务日志
    if systemctl is-active --quiet danted; then
        echo "(通过 journalctl 查看)"
        journalctl -u danted --no-pager -n 10 || echo "无法获取 journalctl 日志。"
    elif [ -f "$LOG_OUTPUT" ]; then
        echo "(通过日志文件查看)"
        tail -n 10 "$LOG_OUTPUT" || echo "无法读取日志文件。"
    else
        echo "没有找到日志文件或 journalctl 不可用/服务未运行。"
    fi

    echo "--- 状态查看完成 ---"
}


# --- 主菜单 ---
display_menu() {
    echo "
--- SOCKS5 代理管理脚本${red}[${sh_ver}]${plain} 日期：${up_date} ---
1. 安装 SOCKS5 代理
2. 卸载 SOCKS5 代理
3. 查看 SOCKS5 代理状态
4. 修改 SOCKS5 配置 (端口/用户/密码)
5. 重启 SOCKS5 服务
6. 退出
----------------------------
请输入您的选择 (1-6)：
"
}

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    die "此脚本必须以 root 权限运行。请使用 'sudo ./$(basename "$0")'。"
fi

while true; do
    display_menu
    read -p "选择操作: " choice
    case $choice in
        1)
            install_proxy
            ;;
        2)
            uninstall_proxy
            ;;
        3)
            view_status
            ;;
        4)
            modify_proxy_config
            ;;
        5)
            restart_proxy
            ;;
        6)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效的选择，请输入 1 到 6 之间的数字。"
            ;;
    esac
    echo ""
    read -p "按任意键继续..." -n 1
    echo ""
done