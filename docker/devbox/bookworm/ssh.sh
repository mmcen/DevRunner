#!/bin/bash
#
# SSH 一键配置脚本（交互式菜单 + 命令行模式）
# 功能：安装/配置 SSH，管理公钥，修改用户密码，自动测试与回滚，重装 SSH 服务
# 支持发行版：Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, openSUSE, Alpine (OpenRC)
# 依赖：bash, sed, grep, awk, cat, (可选) systemctl/service/rc-service, chpasswd/passwd
#
# 版本：2.0 (新增重装 SSH 服务)
#

set -e

# 全局变量
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SUFFIX=".backup.$(date +%Y%m%d%H%M%S)"
SSHD_SERVICE=""
CONFIG_CHANGED=false
BACKUP_FILE=""

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
print_title() { echo -e "${BLUE}==== $1 ====${NC}"; }

# 检测操作系统和包管理器
detect_os() {
    if command -v apt &>/dev/null; then
        PKG_INSTALL="apt install -y"
        PKG_UPDATE="apt update"
        PKG_REMOVE="apt remove -y"
        PKG_LIST="openssh-server"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update"
        PKG_REMOVE="dnf remove -y"
        PKG_LIST="openssh-server"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update"
        PKG_REMOVE="yum remove -y"
        PKG_LIST="openssh-server"
    elif command -v apk &>/dev/null; then
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
        PKG_REMOVE="apk del"
        PKG_LIST="openssh-server"
    elif command -v pacman &>/dev/null; then
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
        PKG_REMOVE="pacman -R --noconfirm"
        PKG_LIST="openssh"
    elif command -v zypper &>/dev/null; then
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
        PKG_REMOVE="zypper remove -y"
        PKG_LIST="openssh"
    else
        print_error "不支持的操作系统或包管理器，请手动安装 openssh-server。"
    fi
}

# 检查并安装 SSH 服务
install_ssh() {
    if command -v sshd &>/dev/null; then
        print_info "sshd 已安装，跳过安装步骤。"
        return
    fi
    print_info "正在安装 openssh-server ..."
    eval "$PKG_UPDATE" || true
    eval "$PKG_INSTALL $PKG_LIST" || print_error "安装失败，请手动安装。"
    print_info "安装完成。"
}

# 检测服务名称
detect_service() {
    # 优先检测 OpenRC (Alpine)
    if [ -x "/etc/init.d/sshd" ] && command -v rc-service &>/dev/null; then
        SSHD_SERVICE="sshd"
        return
    elif [ -x "/etc/init.d/ssh" ] && command -v rc-service &>/dev/null; then
        SSHD_SERVICE="ssh"
        return
    fi

    # 其次 systemd
    if systemctl list-units --type=service 2>/dev/null | grep -q 'sshd.service'; then
        SSHD_SERVICE="sshd"
    elif systemctl list-units --type=service 2>/dev/null | grep -q 'ssh.service'; then
        SSHD_SERVICE="ssh"
    # 传统 init.d
    elif [ -x "/etc/init.d/sshd" ]; then
        SSHD_SERVICE="sshd"
    elif [ -x "/etc/init.d/ssh" ]; then
        SSHD_SERVICE="ssh"
    else
        SSHD_SERVICE=""
    fi
}

# 重启 sshd
restart_sshd() {
    # 优先使用 OpenRC
    if command -v rc-service &>/dev/null && [ -n "$SSHD_SERVICE" ]; then
        rc-service "$SSHD_SERVICE" restart 2>/dev/null && return
        print_warn "rc-service 重启失败，尝试其他方式。"
    fi

    if [ -z "$SSHD_SERVICE" ]; then
        if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || print_warn "重启服务失败，请手动重启。"
        elif command -v service &>/dev/null; then
            service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || print_warn "重启服务失败，请手动重启。"
        else
            /etc/init.d/sshd restart 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null || print_warn "重启服务失败，请手动重启。"
        fi
    else
        if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
            systemctl restart "$SSHD_SERVICE" || print_warn "重启 $SSHD_SERVICE 失败，请手动重启。"
        elif command -v service &>/dev/null; then
            service "$SSHD_SERVICE" restart || print_warn "重启 $SSHD_SERVICE 失败，请手动重启。"
        else
            /etc/init.d/"$SSHD_SERVICE" restart || print_warn "重启 $SSHD_SERVICE 失败，请手动重启。"
        fi
    fi
}

# 停止 sshd（用于重装）
stop_sshd() {
    if command -v rc-service &>/dev/null && [ -n "$SSHD_SERVICE" ]; then
        rc-service "$SSHD_SERVICE" stop 2>/dev/null && return
        print_warn "rc-service 停止失败，尝试其他方式。"
    fi

    if [ -z "$SSHD_SERVICE" ]; then
        if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
            systemctl stop sshd 2>/dev/null || systemctl stop ssh 2>/dev/null || print_warn "停止服务失败，请手动停止。"
        elif command -v service &>/dev/null; then
            service sshd stop 2>/dev/null || service ssh stop 2>/dev/null || print_warn "停止服务失败，请手动停止。"
        else
            /etc/init.d/sshd stop 2>/dev/null || /etc/init.d/ssh stop 2>/dev/null || print_warn "停止服务失败，请手动停止。"
        fi
    else
        if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
            systemctl stop "$SSHD_SERVICE" || print_warn "停止 $SSHD_SERVICE 失败，请手动停止。"
        elif command -v service &>/dev/null; then
            service "$SSHD_SERVICE" stop || print_warn "停止 $SSHD_SERVICE 失败，请手动停止。"
        else
            /etc/init.d/"$SSHD_SERVICE" stop || print_warn "停止 $SSHD_SERVICE 失败，请手动停止。"
        fi
    fi
}

# 备份配置文件（如果未备份则执行）
backup_config() {
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE="${SSHD_CONFIG}${BACKUP_SUFFIX}"
        cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
        print_info "已备份 $SSHD_CONFIG 为 $BACKUP_FILE"
    fi
}

# 获取当前配置值（从 sshd_config 提取最后一个有效值）
get_config_value() {
    local key="$1"
    local file="${2:-$SSHD_CONFIG}"
    grep -i "^[[:space:]]*$key[[:space:]]" "$file" 2>/dev/null | tail -1 | awk '{print $2}'
}

# 设置配置项（如果键存在则替换，否则追加）
set_config() {
    local key="$1"
    local value="$2"
    local file="${3:-$SSHD_CONFIG}"
    local escaped_key
    escaped_key=$(printf '%s\n' "$key" | sed 's/[.[\*^$()+?{|]/\\&/g')

    if grep -q "^[[:space:]#]*$escaped_key[[:space:]]" "$file"; then
        sed -i "s/^[[:space:]#]*$escaped_key[[:space:]]\+.*/$key $value/" "$file"
    else
        echo "$key $value" >> "$file"
    fi
    CONFIG_CHANGED=true
}

# 测试 sshd 配置语法
test_config() {
    if command -v sshd &>/dev/null; then
        sshd -t -f "$SSHD_CONFIG" 2>/dev/null
    else
        return 0
    fi
}

# 应用配置（测试 + 重启）
apply_config() {
    if [ "$CONFIG_CHANGED" = false ]; then
        print_info "没有需要应用的更改。"
        return
    fi
    if test_config; then
        print_info "配置语法通过，正在重启 sshd ..."
        restart_sshd
        print_info "配置已应用。"
        CONFIG_CHANGED=false
        [ -n "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE" && BACKUP_FILE=""
    else
        print_error "配置语法错误，正在回滚..."
        if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
            cp -f "$BACKUP_FILE" "$SSHD_CONFIG"
            print_info "已回滚至备份版本。"
        fi
        CONFIG_CHANGED=false
        BACKUP_FILE=""
    fi
}

# ------------------------------------------------------------
# 公钥管理函数
# ------------------------------------------------------------
list_keys() {
    local user="$1"
    local auth_file
    auth_file=$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys
    if [ ! -f "$auth_file" ]; then
        echo "用户 $user 没有 authorized_keys 文件。"
        return
    fi
    echo "用户 $user 的已授权公钥："
    nl -w2 -s'. ' "$auth_file"
}

add_public_key() {
    local user_key="$1"
    local user="${user_key%%:*}"
    local key="${user_key#*:}"
    if [ -z "$user" ] || [ -z "$key" ]; then
        print_error "公钥格式错误，应为 user:public_key_string"
    fi
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    local ssh_dir="$home_dir/.ssh"
    local auth_file="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chown "$user":"$user" "$ssh_dir"
    chmod 700 "$ssh_dir"
    if grep -qF "$key" "$auth_file" 2>/dev/null; then
        print_warn "公钥已存在，跳过添加。"
    else
        echo "$key" >> "$auth_file"
        chown "$user":"$user" "$auth_file"
        chmod 600 "$auth_file"
        print_info "公钥已添加到 $auth_file"
    fi
}

delete_public_key() {
    local user="$1"
    local line_num="$2"
    local auth_file
    auth_file=$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys
    if [ ! -f "$auth_file" ]; then
        print_error "用户 $user 没有 authorized_keys 文件。"
    fi
    sed -i "${line_num}d" "$auth_file"
    print_info "已删除第 $line_num 行公钥。"
}

# ------------------------------------------------------------
# 密码管理函数
# ------------------------------------------------------------
# 交互式修改密码（调用 passwd）
change_password_interactive() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    print_info "正在为用户 $user 修改密码（请按提示输入两次新密码）"
    passwd "$user"
    if [ $? -eq 0 ]; then
        print_info "密码修改成功！"
    else
        print_error "密码修改失败。"
    fi
}

# 随机生成密码并设置
change_password_random() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    # 生成 16 位随机密码（包含大小写字母、数字、特殊字符）
    local password
    password=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom 2>/dev/null | head -c 16)
    if [ -z "$password" ]; then
        # 如果 /dev/urandom 不可用，使用 openssl 或 date 备用
        if command -v openssl &>/dev/null; then
            password=$(openssl rand -base64 12 | tr -d '\n' | cut -c1-16)
        else
            password="$(date +%s%N | sha256sum | base64 | head -c 16)"
        fi
    fi
    # 设置密码
    if command -v chpasswd &>/dev/null; then
        echo "$user:$password" | chpasswd
    elif command -v passwd &>/dev/null && passwd --help 2>&1 | grep -q -- '--stdin'; then
        echo "$password" | passwd --stdin "$user"
    else
        # 最后尝试用 printf + passwd（某些系统支持）
        printf "%s\n%s\n" "$password" "$password" | passwd "$user" 2>/dev/null
    fi
    if [ $? -eq 0 ]; then
        print_info "密码已随机生成并设置。"
        echo -e "${YELLOW}新密码（请立即保存）：${GREEN}$password${NC}"
    else
        print_error "设置随机密码失败，请尝试交互式修改。"
    fi
}

# ------------------------------------------------------------
# 重装 SSH 服务函数
# ------------------------------------------------------------
reinstall_ssh() {
    clear
    print_title "重装 SSH 服务"
    echo -e "${RED}警告：此操作将停止 SSH 服务并卸载 openssh-server 软件包。${NC}"
    echo -e "${RED}如果您通过 SSH 远程连接，执行后连接将中断！${NC}"
    read -p "确认继续？(y/n): " confirm
    [[ $confirm != [yY] ]] && return

    # 1. 备份配置
    read -p "是否备份当前配置？(y/n, 默认 y): " bak_confirm
    if [[ -z "$bak_confirm" || $bak_confirm == [yY] ]]; then
        backup_config
    fi

    # 2. 停止服务
    print_info "正在停止 SSH 服务..."
    stop_sshd

    # 3. 卸载软件包
    print_info "正在卸载 $PKG_LIST ..."
    eval "$PKG_REMOVE $PKG_LIST" || print_error "卸载失败，请手动处理。"

    # 4. 询问是否彻底删除配置文件（清除）
    read -p "是否删除现有配置文件 ($SSHD_CONFIG)？(y/n, 默认 n): " clean_confirm
    if [[ $clean_confirm == [yY] ]]; then
        if [ -f "$SSHD_CONFIG" ]; then
            rm -f "$SSHD_CONFIG"
            print_info "已删除 $SSHD_CONFIG"
        fi
        # 可选删除其他可能残留（如 sshd_config.d 等），保留主要
    fi

    # 5. 重新安装
    print_info "正在重新安装 $PKG_LIST ..."
    install_ssh   # 此函数会检测是否已安装，若不存在则安装

    # 6. 恢复配置（如果有备份且用户选择）
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        read -p "是否恢复之前备份的配置文件？(y/n, 默认 n): " restore_confirm
        if [[ $restore_confirm == [yY] ]]; then
            cp -f "$BACKUP_FILE" "$SSHD_CONFIG"
            print_info "已恢复配置 $BACKUP_FILE"
            CONFIG_CHANGED=true
        else
            print_info "使用默认配置。"
            # 如果用户不恢复，但之前备份文件存在，删除备份以免干扰
            rm -f "$BACKUP_FILE"
            BACKUP_FILE=""
        fi
    else
        print_info "没有可恢复的备份，使用默认配置。"
    fi

    # 7. 重启服务
    print_info "正在重启 SSH 服务..."
    restart_sshd

    print_info "SSH 服务重装完成。"
    read -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 菜单功能
# ------------------------------------------------------------
show_current_config() {
    clear
    print_title "当前 SSH 配置（有效值）"
    echo "------------------------------------------------"
    echo "Port:               $(get_config_value Port)"
    echo "Protocol:           $(get_config_value Protocol)"
    echo "AddressFamily:      $(get_config_value AddressFamily)"
    echo "ListenAddress:      $(get_config_value ListenAddress)"
    echo "PermitRootLogin:    $(get_config_value PermitRootLogin)"
    echo "PasswordAuthentication: $(get_config_value PasswordAuthentication)"
    echo "PubkeyAuthentication:   $(get_config_value PubkeyAuthentication)"
    echo "ChallengeResponseAuthentication: $(get_config_value ChallengeResponseAuthentication)"
    echo "KerberosAuthentication: $(get_config_value KerberosAuthentication)"
    echo "GSSAPIAuthentication: $(get_config_value GSSAPIAuthentication)"
    echo "PermitEmptyPasswords: $(get_config_value PermitEmptyPasswords)"
    echo "LoginGraceTime:     $(get_config_value LoginGraceTime)"
    echo "MaxAuthTries:       $(get_config_value MaxAuthTries)"
    echo "MaxSessions:        $(get_config_value MaxSessions)"
    echo "ClientAliveInterval: $(get_config_value ClientAliveInterval)"
    echo "ClientAliveCountMax: $(get_config_value ClientAliveCountMax)"
    echo "AllowUsers:         $(get_config_value AllowUsers)"
    echo "DenyUsers:          $(get_config_value DenyUsers)"
    echo "AllowGroups:        $(get_config_value AllowGroups)"
    echo "DenyGroups:         $(get_config_value DenyGroups)"
    echo "Banner:             $(get_config_value Banner)"
    echo "Subsystem:          $(get_config_value Subsystem)"
    echo "AllowTcpForwarding: $(get_config_value AllowTcpForwarding)"
    echo "PrintMotd:          $(get_config_value PrintMotd)"
    echo "PrintLastLog:       $(get_config_value PrintLastLog)"
    echo "UseDNS:             $(get_config_value UseDNS)"
    echo "------------------------------------------------"
    read -p "按回车键返回菜单..."
}

menu_basic() {
    while true; do
        clear
        print_title "基本设置"
        echo "1. 设置端口 (当前: $(get_config_value Port))"
        echo "2. 设置协议版本 (当前: $(get_config_value Protocol))"
        echo "3. 设置地址族 (当前: $(get_config_value AddressFamily))"
        echo "4. 设置监听地址 (当前: $(get_config_value ListenAddress))"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1) read -p "输入新端口号: " val; set_config Port "$val" ;;
            2) read -p "输入协议 (1/2/2,1): " val; set_config Protocol "$val" ;;
            3) read -p "输入地址族 (any/inet/inet6): " val; set_config AddressFamily "$val" ;;
            4) read -p "输入监听地址 (如 0.0.0.0): " val; set_config ListenAddress "$val" ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_auth() {
    while true; do
        clear
        print_title "认证设置"
        echo "1. 允许 root 登录 (当前: $(get_config_value PermitRootLogin))"
        echo "2. 密码认证 (当前: $(get_config_value PasswordAuthentication))"
        echo "3. 公钥认证 (当前: $(get_config_value PubkeyAuthentication))"
        echo "4. 质询响应认证 (当前: $(get_config_value ChallengeResponseAuthentication))"
        echo "5. Kerberos 认证 (当前: $(get_config_value KerberosAuthentication))"
        echo "6. GSSAPI 认证 (当前: $(get_config_value GSSAPIAuthentication))"
        echo "7. 允许空密码 (当前: $(get_config_value PermitEmptyPasswords))"
        echo "8. 返回主菜单"
        read -p "请选择 [1-8]: " choice
        case $choice in
            1) read -p "输入 (yes/no/prohibit-password/without-password/forced-commands-only): " val; set_config PermitRootLogin "$val" ;;
            2) read -p "输入 (yes/no): " val; set_config PasswordAuthentication "$val" ;;
            3) read -p "输入 (yes/no): " val; set_config PubkeyAuthentication "$val" ;;
            4) read -p "输入 (yes/no): " val; set_config ChallengeResponseAuthentication "$val" ;;
            5) read -p "输入 (yes/no): " val; set_config KerberosAuthentication "$val" ;;
            6) read -p "输入 (yes/no): " val; set_config GSSAPIAuthentication "$val" ;;
            7) read -p "输入 (yes/no): " val; set_config PermitEmptyPasswords "$val" ;;
            8) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_access() {
    while true; do
        clear
        print_title "访问控制"
        echo "1. 允许用户 (当前: $(get_config_value AllowUsers))"
        echo "2. 拒绝用户 (当前: $(get_config_value DenyUsers))"
        echo "3. 允许组 (当前: $(get_config_value AllowGroups))"
        echo "4. 拒绝组 (当前: $(get_config_value DenyGroups))"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1) read -p "输入允许的用户列表 (空格分隔): " val; set_config AllowUsers "$val" ;;
            2) read -p "输入拒绝的用户列表: " val; set_config DenyUsers "$val" ;;
            3) read -p "输入允许的组列表: " val; set_config AllowGroups "$val" ;;
            4) read -p "输入拒绝的组列表: " val; set_config DenyGroups "$val" ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_other() {
    while true; do
        clear
        print_title "其他选项"
        echo "1. 登录超时 (LoginGraceTime) (当前: $(get_config_value LoginGraceTime))"
        echo "2. 最大认证尝试次数 (当前: $(get_config_value MaxAuthTries))"
        echo "3. 最大会话数 (当前: $(get_config_value MaxSessions))"
        echo "4. 客户端保活间隔 (秒) (当前: $(get_config_value ClientAliveInterval))"
        echo "5. 保活失败最大次数 (当前: $(get_config_value ClientAliveCountMax))"
        echo "6. 登录 Banner 文件 (当前: $(get_config_value Banner))"
        echo "7. 子系统 (当前: $(get_config_value Subsystem))"
        echo "8. 显示 MOTD (当前: $(get_config_value PrintMotd))"
        echo "9. 显示上次登录 (当前: $(get_config_value PrintLastLog))"
        echo "10. 使用 DNS (当前: $(get_config_value UseDNS))"
        echo "11. 开启端口转发 AllowTcpForwarding (当前: $(get_config_value AllowTcpForwarding))"
        echo "12. 返回主菜单"
        read -p "请选择 [1-12]: " choice
        case $choice in
            1) read -p "输入秒数 (0 表示无限制): " val; set_config LoginGraceTime "$val" ;;
            2) read -p "输入次数: " val; set_config MaxAuthTries "$val" ;;
            3) read -p "输入会话数: " val; set_config MaxSessions "$val" ;;
            4) read -p "输入秒数 (0 禁用): " val; set_config ClientAliveInterval "$val" ;;
            5) read -p "输入次数 (0 禁用): " val; set_config ClientAliveCountMax "$val" ;;
            6) read -p "输入 Banner 文件路径: " val; set_config Banner "$val" ;;
            7) read -p "输入子系统 (如 sftp /usr/lib/openssh/sftp-server): " val; set_config Subsystem "$val" ;;
            8) read -p "输入 (yes/no): " val; set_config PrintMotd "$val" ;;
            9) read -p "输入 (yes/no): " val; set_config PrintLastLog "$val" ;;
            10) read -p "输入 (yes/no): " val; set_config UseDNS "$val" ;;
            11) read -p "输入 (yes/no, 回车默认 yes 开启): " val; [ -z "$val" ] && val="yes"; set_config AllowTcpForwarding "$val" ;;
            12) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_keys() {
    while true; do
        clear
        print_title "公钥管理"
        echo "1. 为某用户添加公钥（输入公钥内容）"
        echo "2. 从文件为某用户添加公钥"
        echo "3. 查看某用户的公钥列表"
        echo "4. 删除某用户的指定公钥（按行号）"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1)
                read -p "输入用户名: " user
                read -p "输入公钥内容: " key
                add_public_key "$user:$key"
                read -p "按回车继续..."
                ;;
            2)
                read -p "输入用户名: " user
                read -p "输入公钥文件路径: " keyfile
                if [ -f "$keyfile" ]; then
                    key=$(cat "$keyfile" | tr -d '\n')
                    add_public_key "$user:$key"
                else
                    print_error "文件不存在。"
                fi
                read -p "按回车继续..."
                ;;
            3)
                read -p "输入用户名: " user
                list_keys "$user"
                read -p "按回车继续..."
                ;;
            4)
                read -p "输入用户名: " user
                list_keys "$user"
                read -p "输入要删除的行号: " line
                delete_public_key "$user" "$line"
                read -p "按回车继续..."
                ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# 密码管理菜单
menu_password() {
    while true; do
        clear
        print_title "用户密码管理"
        echo "1. 交互式修改指定用户密码（手动输入）"
        echo "2. 为指定用户随机生成并设置强密码"
        echo "3. 返回主菜单"
        read -p "请选择 [1-3]: " choice
        case $choice in
            1)
                read -p "输入用户名: " user
                change_password_interactive "$user"
                read -p "按回车继续..."
                ;;
            2)
                read -p "输入用户名: " user
                change_password_random "$user"
                read -p "按回车继续..."
                ;;
            3) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_backup() {
    clear
    print_title "备份管理"
    backups=$(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null)
    if [ -z "$backups" ]; then
        echo "没有找到备份文件。"
        read -p "按回车返回..."
        return
    fi
    echo "可用的备份文件："
    select backup in $backups "取消"; do
        if [ "$backup" = "取消" ] || [ -z "$backup" ]; then
            break
        elif [ -n "$backup" ] && [ -f "$backup" ]; then
            read -p "确认恢复 $backup ? (y/n): " confirm
            if [[ $confirm == [yY] ]]; then
                cp -a "$backup" "$SSHD_CONFIG"
                print_info "已恢复 $backup"
                CONFIG_CHANGED=true
                apply_config
            fi
            break
        else
            echo "无效选择。"
        fi
    done
    read -p "按回车返回..."
}

main_menu() {
    while true; do
        clear
        print_title "SSH 一键配置工具 - 主菜单"
        echo "1. 查看当前配置"
        echo "2. 基本设置（端口/协议/地址）"
        echo "3. 认证设置（密码/公钥/root登录）"
        echo "4. 访问控制（用户/组）"
        echo "5. 其他选项（保活/超时/DNS等）"
        echo "6. 公钥管理"
        echo "7. 用户密码管理"
        echo "8. 备份管理"
        echo "9. 应用配置并重启 SSH（测试 + 重启）"
        echo "10. 重装 SSH 服务"
        echo "11. 退出"
        echo "---------------------------------------------"
        echo -e "${YELLOW}提示：所有修改暂存于配置文件中，请执行 [9] 使生效。${NC}"
        read -p "请选择 [1-11]: " choice
        case $choice in
            1) show_current_config ;;
            2) menu_basic ;;
            3) menu_auth ;;
            4) menu_access ;;
            5) menu_other ;;
            6) menu_keys ;;
            7) menu_password ;;
            8) menu_backup ;;
            9) apply_config; read -p "按回车继续..." ;;
            10) reinstall_ssh ;;
            11)
                if [ "$CONFIG_CHANGED" = true ]; then
                    read -p "有未应用的更改，确定退出？(y/n): " confirm
                    [[ $confirm != [yY] ]] && continue
                fi
                print_info "退出。"
                exit 0
                ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# 命令行参数模式（原有功能）
# ------------------------------------------------------------
cmdline_mode() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="$2"; shift 2 ;;
            --protocol) PROTOCOL="$2"; shift 2 ;;
            --address-family) ADDRESS_FAMILY="$2"; shift 2 ;;
            --listen-address) LISTEN_ADDRESS="$2"; shift 2 ;;
            --permit-root) PERMIT_ROOT="$2"; shift 2 ;;
            --password-auth) PASSWORD_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --pubkey-auth) PUBKEY_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --challenge-response) CHALLENGE_RESPONSE="$(normalize_bool "$2")"; shift 2 ;;
            --kerberos-auth) KERBEROS_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --gssapi-auth) GSSAPI_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --permit-empty-passwords) PERMIT_EMPTY="$(normalize_bool "$2")"; shift 2 ;;
            --login-grace-time) LOGIN_GRACE_TIME="$2"; shift 2 ;;
            --max-auth-tries) MAX_AUTH_TRIES="$2"; shift 2 ;;
            --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
            --client-alive-interval) CLIENT_ALIVE_INTERVAL="$2"; shift 2 ;;
            --client-alive-count-max) CLIENT_ALIVE_COUNT_MAX="$2"; shift 2 ;;
            --allow-users) ALLOW_USERS="$2"; shift 2 ;;
            --deny-users) DENY_USERS="$2"; shift 2 ;;
            --allow-groups) ALLOW_GROUPS="$2"; shift 2 ;;
            --deny-groups) DENY_GROUPS="$2"; shift 2 ;;
            --banner) BANNER="$2"; shift 2 ;;
            --subsystem) SUBSYSTEM="$2"; shift 2 ;;
            --print-motd) PRINT_MOTD="$(normalize_bool "$2")"; shift 2 ;;
            --print-lastlog) PRINT_LASTLOG="$(normalize_bool "$2")"; shift 2 ;;
            --use-dns) USE_DNS="$(normalize_bool "$2")"; shift 2 ;;
            --allow-tcp-forwarding) ALLOW_TCP_FORWARDING="$(normalize_bool "$2")"; shift 2 ;;
            --add-key) ADD_KEY="$2"; shift 2 ;;
            --add-key-file) ADD_KEY_FILE="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) print_error "未知选项: $1" ;;
        esac
    done

    [ -n "$PORT" ] && set_config "Port" "$PORT"
    [ -n "$PROTOCOL" ] && set_config "Protocol" "$PROTOCOL"
    [ -n "$ADDRESS_FAMILY" ] && set_config "AddressFamily" "$ADDRESS_FAMILY"
    [ -n "$LISTEN_ADDRESS" ] && set_config "ListenAddress" "$LISTEN_ADDRESS"
    [ -n "$PERMIT_ROOT" ] && set_config "PermitRootLogin" "$PERMIT_ROOT"
    [ -n "$PASSWORD_AUTH" ] && set_config "PasswordAuthentication" "$PASSWORD_AUTH"
    [ -n "$PUBKEY_AUTH" ] && set_config "PubkeyAuthentication" "$PUBKEY_AUTH"
    [ -n "$CHALLENGE_RESPONSE" ] && set_config "ChallengeResponseAuthentication" "$CHALLENGE_RESPONSE"
    [ -n "$KERBEROS_AUTH" ] && set_config "KerberosAuthentication" "$KERBEROS_AUTH"
    [ -n "$GSSAPI_AUTH" ] && set_config "GSSAPIAuthentication" "$GSSAPI_AUTH"
    [ -n "$PERMIT_EMPTY" ] && set_config "PermitEmptyPasswords" "$PERMIT_EMPTY"
    [ -n "$LOGIN_GRACE_TIME" ] && set_config "LoginGraceTime" "$LOGIN_GRACE_TIME"
    [ -n "$MAX_AUTH_TRIES" ] && set_config "MaxAuthTries" "$MAX_AUTH_TRIES"
    [ -n "$MAX_SESSIONS" ] && set_config "MaxSessions" "$MAX_SESSIONS"
    [ -n "$CLIENT_ALIVE_INTERVAL" ] && set_config "ClientAliveInterval" "$CLIENT_ALIVE_INTERVAL"
    [ -n "$CLIENT_ALIVE_COUNT_MAX" ] && set_config "ClientAliveCountMax" "$CLIENT_ALIVE_COUNT_MAX"
    [ -n "$ALLOW_USERS" ] && set_config "AllowUsers" "$ALLOW_USERS"
    [ -n "$DENY_USERS" ] && set_config "DenyUsers" "$DENY_USERS"
    [ -n "$ALLOW_GROUPS" ] && set_config "AllowGroups" "$ALLOW_GROUPS"
    [ -n "$DENY_GROUPS" ] && set_config "DenyGroups" "$DENY_GROUPS"
    [ -n "$BANNER" ] && set_config "Banner" "$BANNER"
    [ -n "$SUBSYSTEM" ] && set_config "Subsystem" "$SUBSYSTEM"
    [ -n "$PRINT_MOTD" ] && set_config "PrintMotd" "$PRINT_MOTD"
    [ -n "$PRINT_LASTLOG" ] && set_config "PrintLastLog" "$PRINT_LASTLOG"
    [ -n "$USE_DNS" ] && set_config "UseDNS" "$USE_DNS"
    [ -n "$ALLOW_TCP_FORWARDING" ] && set_config "AllowTcpForwarding" "$ALLOW_TCP_FORWARDING"

    [ -n "$ADD_KEY" ] && add_public_key "$ADD_KEY"
    [ -n "$ADD_KEY_FILE" ] && add_public_key_file "$ADD_KEY_FILE"

    if [ "$CONFIG_CHANGED" = true ]; then
        if test_config; then
            print_info "配置语法通过，正在重启 sshd ..."
            restart_sshd
            print_info "命令行设置完成。"
        else
            print_error "配置语法错误，请检查。"
        fi
    else
        print_info "未更改任何配置。"
    fi
}

normalize_bool() {
    case "$1" in
        yes|on|true|1) echo "yes" ;;
        no|off|false|0) echo "no" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    cat <<EOF
用法: $0 [选项]                  # 命令行模式（不带参数进入交互菜单）
选项（同菜单功能）:
  --port PORT
  --protocol PROTO
  --address-family FAMILY
  --listen-address ADDR
  --permit-root VALUE
  --password-auth VALUE
  --pubkey-auth VALUE
  --challenge-response VALUE
  --kerberos-auth VALUE
  --gssapi-auth VALUE
  --permit-empty-passwords VALUE
  --login-grace-time SECONDS
  --max-auth-tries NUM
  --max-sessions NUM
  --client-alive-interval SECONDS
  --client-alive-count-max COUNT
  --allow-users "user list"
  --deny-users "user list"
  --allow-groups "group list"
  --deny-groups "group list"
  --banner FILE
  --subsystem "cmd"
  --print-motd VALUE
  --print-lastlog VALUE
  --use-dns VALUE
  --allow-tcp-forwarding VALUE
  --add-key USER:PUBKEY
  --add-key-file USER:FILE
  --help
EOF
    exit 0
}

# ------------------------------------------------------------
# 主入口
# ------------------------------------------------------------
main() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 权限运行此脚本 (sudo $0 ...)"
    fi

    detect_os
    install_ssh
    detect_service

    if [ $# -eq 0 ]; then
        backup_config
        main_menu
    else
        cmdline_mode "$@"
    fi
}

main "$@"