#!/bin/bash

# 茂亨Odoo外贸专用版管理脚本 - 优化版
# 单实例版本，支持本地模式和域名模式
# 版本: 6.2
# GitHub: https://github.com/morhon-tech/morhon-odoo
# 
# 功能特性:
# - 自动检测现有实例（脚本管理/手动部署）
# - 支持本地模式和域名模式部署
# - 自动SSL证书获取和配置
# - 完整的备份和恢复功能
# - 手动实例迁移到脚本管理
# - 性能优化配置
# - 安全加固设置

set -e

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DIR="/opt/morhon-odoo"
BACKUP_DIR="/var/backups/morhon-odoo"
LOG_DIR="/var/log/morhon-odoo"

# 固定卷名
DB_VOLUME_NAME="morhon-pg"
ODOO_VOLUME_NAME="morhon-odoo"

# 固定镜像配置
ODOO_IMAGE="registry.cn-hangzhou.aliyuncs.com/morhon_hub/mh_odoosaas_v17:latest"
POSTGRES_IMAGE="registry.cn-hangzhou.aliyuncs.com/morhon_hub/postgres:latest"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局状态变量
DETECTED_INSTANCE_TYPE=""  # none, script, manual
DETECTED_ODOO_CONTAINER=""
DETECTED_DB_CONTAINER=""
DETECTED_DOMAIN=""
DETECTED_DB_PASSWORD=""

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_DIR/morhon-odoo.log"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_DIR/morhon-odoo.log" >&2
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_DIR/morhon-odoo.log"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_DIR/morhon-odoo.log"
}

# 检查是否为sudo用户
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "此脚本需要root权限，请使用sudo运行"
        exit 1
    fi
}

# 一次性检测所有信息
detect_environment() {
    log_info "检测系统环境..."
    
    # 创建必要目录
    mkdir -p "$INSTANCE_DIR" "$BACKUP_DIR" "$LOG_DIR"
    
    # 1. 检测脚本管理的实例
    if [ -f "$INSTANCE_DIR/docker-compose.yml" ]; then
        DETECTED_INSTANCE_TYPE="script"
        log "检测到脚本管理的实例: $INSTANCE_DIR"
        return 0
    fi
    
    # 2. 检测手动部署的实例
    local odoo_container=$(find_container_by_image "$ODOO_IMAGE" "morhon" "odoo")
    
    if [ -n "$odoo_container" ]; then
        DETECTED_INSTANCE_TYPE="manual"
        DETECTED_ODOO_CONTAINER="$odoo_container"
        
        # 获取数据库容器
        DETECTED_DB_CONTAINER=$(find_container_by_image "postgres" "postgres" "db")
        
        # 尝试从容器获取域名和密码
        extract_instance_info
        log "检测到手动部署的实例: $DETECTED_ODOO_CONTAINER"
        return 0
    fi
    
    # 3. 无实例
    DETECTED_INSTANCE_TYPE="none"
    log "未检测到现有实例"
    
    return 0
}

# 通过镜像或名称查找容器
find_container_by_image() {
    local primary_image="$1"
    shift
    
    # 首先通过镜像查找
    local container=$(docker ps -a --filter "ancestor=$primary_image" --format "{{.Names}}" 2>/dev/null | head -1)
    
    # 如果未找到，通过名称查找
    if [ -z "$container" ]; then
        for name_filter in "$@"; do
            container=$(docker ps -a --filter "name=$name_filter" --format "{{.Names}}" 2>/dev/null | head -1)
            [ -n "$container" ] && break
        done
    fi
    
    echo "$container"
}

# 从手动部署实例提取信息
extract_instance_info() {
    log_info "从手动部署实例提取信息..."
    
    # 1. 尝试从odoo容器获取odoo.conf内容
    if [ -n "$DETECTED_ODOO_CONTAINER" ]; then
        extract_odoo_config_info
    fi
    
    # 2. 尝试从数据库容器获取密码
    if [ -n "$DETECTED_DB_CONTAINER" ]; then
        extract_db_password
    fi
    
    # 3. 尝试从Nginx配置获取域名
    if [ -z "$DETECTED_DOMAIN" ]; then
        extract_nginx_domain
    fi
    
    return 0
}

# 提取Odoo配置信息
extract_odoo_config_info() {
    local odoo_conf_content=$(docker exec "$DETECTED_ODOO_CONTAINER" cat /etc/odoo/odoo.conf 2>/dev/null || docker exec "$DETECTED_ODOO_CONTAINER" cat /odoo/config/odoo.conf 2>/dev/null || true)
    
    if [ -n "$odoo_conf_content" ]; then
        # 提取数据库名（可能是域名）
        local db_name=$(echo "$odoo_conf_content" | grep "^db_name" | cut -d'=' -f2 | sed 's/[[:space:]]*//g')
        if [[ "$db_name" == *.* ]]; then
            DETECTED_DOMAIN=$(echo "$db_name" | awk -F'.' '{print $(NF-1)"."$NF}')
            log "从数据库名提取到域名: $DETECTED_DOMAIN"
        fi
    fi
    
    # 尝试从容器环境变量获取域名
    if [ -z "$DETECTED_DOMAIN" ]; then
        local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true)
        DETECTED_DOMAIN=$(echo "$env_vars" | grep -E "DOMAIN|HOSTNAME" | cut -d'=' -f2 | head -1)
    fi
}

# 提取数据库密码
extract_db_password() {
    DETECTED_DB_PASSWORD=$(docker exec "$DETECTED_DB_CONTAINER" env 2>/dev/null | grep "POSTGRES_PASSWORD" | cut -d'=' -f2 || echo "odoo")
    log "提取到数据库密码"
}

# 提取Nginx域名配置
extract_nginx_domain() {
    if [ -d "/etc/nginx/sites-enabled" ]; then
        local nginx_domain=$(grep -r "server_name" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "_" | head -1 | awk '{print $2}' | sed 's/;//')
        if [[ "$nginx_domain" == *.* ]] && [ "$nginx_domain" != "localhost" ]; then
            DETECTED_DOMAIN="$nginx_domain"
            log "从Nginx配置提取到域名: $DETECTED_DOMAIN"
        fi
    fi
}

# 获取服务器IP地址
get_server_ip() {
    local ip=""
    
    # 方法1: 使用ip命令
    ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || true)
    
    # 方法2: 使用hostname
    if [ -z "$ip" ] || [[ "$ip" == *" "* ]] || [[ "$ip" == "127.0.0.1" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    if [ -z "$ip" ] || [[ "$ip" == *" "* ]]; then
        ip="127.0.0.1"
    fi
    
    echo "$ip"
}

# 初始化环境 - 专用服务器优化
init_environment() {
    log "初始化专用服务器环境..."
    
    # 更新系统
    log "更新系统包..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    
    # 安装系统依赖
    log "安装系统依赖..."
    apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        tar \
        gzip \
        python3 \
        python3-pip \
        postgresql-client \
        certbot \
        python3-certbot-nginx \
        nginx \
        ufw \
        net-tools \
        htop \
        iotop \
        sysstat \
        bc \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        install_docker
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        install_docker_compose
    fi
    
    # 专用服务器系统优化
    optimize_system_for_odoo
    
    # 配置防火墙
    configure_firewall
    
    # 配置Nginx
    configure_nginx
    
    log "专用服务器环境初始化完成"
    return 0
}

# 专用服务器系统优化
optimize_system_for_odoo() {
    log "执行专用服务器系统优化..."
    
    # 获取系统资源信息
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    
    # 内核参数优化 - 外贸管理系统专用
    log "优化内核参数（外贸管理系统专用）..."
    cat > /etc/sysctl.d/99-morhon-odoo.conf << EOF
# 茂亨Odoo外贸管理系统内核优化

# 网络优化（外贸管理系统需要处理大量并发连接）
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# 内存管理优化（外贸管理系统大数据处理）
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.overcommit_memory = 1
vm.overcommit_ratio = 80
vm.vfs_cache_pressure = 50

# 文件系统优化（外贸管理系统文档处理）
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# 进程优化
kernel.pid_max = 4194304
kernel.threads-max = 4194304

# 安全优化
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
EOF
    
    # 应用内核参数
    sysctl -p /etc/sysctl.d/99-morhon-odoo.conf
    
    # 系统限制优化
    log "优化系统限制..."
    cat > /etc/security/limits.d/99-morhon-odoo.conf << EOF
# 茂亨Odoo专用服务器限制优化
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
root soft nofile 65536
root hard nofile 65536
www-data soft nofile 65536
www-data hard nofile 65536
EOF
    
    # Docker优化
    log "优化Docker配置..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 65536,
            "Soft": 65536
        },
        "nproc": {
            "Name": "nproc",
            "Hard": 32768,
            "Soft": 32768
        }
    }
}
EOF
    
    # 重启Docker服务
    systemctl restart docker
    
    # 磁盘I/O优化
    log "优化磁盘I/O..."
    # 检测磁盘类型并优化
    for disk in $(lsblk -d -o name | grep -E '^[sv]d[a-z]$|^nvme'); do
        if [ -b "/dev/$disk" ]; then
            # SSD优化
            echo noop > /sys/block/$disk/queue/scheduler 2>/dev/null || \
            echo none > /sys/block/$disk/queue/scheduler 2>/dev/null || true
            echo 0 > /sys/block/$disk/queue/rotational 2>/dev/null || true
            echo 1 > /sys/block/$disk/queue/iosched/fifo_batch 2>/dev/null || true
        fi
    done
    
    # 日志轮转优化
    log "配置日志轮转..."
    cat > /etc/logrotate.d/morhon-odoo << EOF
/var/log/morhon-odoo/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
}

/var/log/nginx/morhon-odoo-*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 www-data www-data
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
EOF
    
    # 定时任务优化 - 外贸管理系统专用
    log "配置系统维护任务（外贸管理系统专用）..."
    cat > /etc/cron.d/morhon-odoo-maintenance << EOF
# 茂亨Odoo外贸管理系统维护任务

# 每天凌晨2点清理系统缓存（避开工作时间）
0 2 * * * root sync && echo 3 > /proc/sys/vm/drop_caches

# 每周日凌晨3点清理Docker（周末维护）
0 3 * * 0 root docker system prune -f --volumes

# 每天凌晨4点备份数据库索引统计
0 4 * * * root docker exec morhon-odoo-db psql -U odoo -d postgres -c "ANALYZE;" >/dev/null 2>&1

# 每天上午6点检查磁盘空间
0 6 * * * root df -h | awk '\$5 > 85 {print "Warning: " \$0}' | mail -s "Disk Space Warning" root 2>/dev/null || true

# 每天检查外贸管理系统关键进程
*/30 * * * * root systemctl is-active docker nginx >/dev/null || systemctl restart docker nginx

# 每周清理Nginx日志（保留30天）
0 1 * * 1 root find /var/log/nginx/ -name "*.log" -mtime +30 -delete

# 每月第一天清理Redis过期键
0 5 1 * * root docker exec morhon-odoo-redis redis-cli --scan --pattern "*" | head -1000 | xargs docker exec morhon-odoo-redis redis-cli del >/dev/null 2>&1 || true
EOF
    
    # 禁用不必要的服务（外贸管理系统安全加固）
    log "禁用不必要的服务（外贸管理系统安全加固）..."
    local services_to_disable=(
        "snapd"
        "bluetooth"
        "cups"
        "avahi-daemon"
        "ModemManager"
        "whoopsie"
        "apport"
        "accounts-daemon"
        "fwupd"
        "packagekit"
    )
    
    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            systemctl disable "$service" >/dev/null 2>&1 || true
            systemctl stop "$service" >/dev/null 2>&1 || true
            log "已禁用服务: $service"
        fi
    done
    
    # 安装并配置安全工具
    log "安装安全工具..."
    apt-get install -y fail2ban rkhunter chkrootkit unattended-upgrades
    
    # 配置自动安全更新
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    # 启用自动更新
    systemctl enable unattended-upgrades
    
    # 配置SSH安全
    if [ -f "/etc/ssh/sshd_config" ]; then
        log "加固SSH配置..."
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        
        # SSH安全配置
        sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
        sed -i 's/#ClientAliveInterval 0/ClientAliveInterval 300/' /etc/ssh/sshd_config
        sed -i 's/#ClientAliveCountMax 3/ClientAliveCountMax 2/' /etc/ssh/sshd_config
        
        # 重启SSH服务
        systemctl restart sshd
    fi
    
    # 优化启动服务
    log "优化系统启动..."
    systemctl enable docker
    systemctl enable nginx
    
    log "专用服务器系统优化完成"
}

# 安装Docker
install_docker() {
    log "安装Docker..."
    
    # 检查系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统类型"
        return 1
    fi
    
    case $OS in
        ubuntu|debian)
            # 添加Docker官方GPG密钥
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        centos|rhel|fedora)
            # CentOS/RHEL/Fedora
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            systemctl start docker
            systemctl enable docker
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            return 1
            ;;
    esac
    
    # 启动Docker服务
    systemctl start docker
    systemctl enable docker
    
    # 添加当前用户到docker组（如果不是root）
    if [ "$EUID" -ne 0 ] && [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
        log "已将用户 $SUDO_USER 添加到docker组，请重新登录以生效"
    fi
    
    log "Docker安装完成"
}

# 安装Docker Compose
install_docker_compose() {
    log "安装Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log "Docker Compose安装完成"
}

# 配置防火墙 - 生产环境安全加固
configure_firewall() {
    log "配置防火墙（生产环境安全加固）..."
    
    # 重置防火墙规则
    ufw --force reset
    
    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH（限制连接数）
    ufw limit 22/tcp comment 'SSH with rate limiting'
    log "已配置SSH端口 (22/tcp) 带连接限制"
    
    # 允许HTTP（内网和公网都需要）
    ufw allow 80/tcp comment 'HTTP for Odoo'
    log "已允许HTTP端口 (80/tcp)"
    
    # 允许HTTPS（公网必需，内网可选）
    ufw allow 443/tcp comment 'HTTPS for Odoo'
    log "已允许HTTPS端口 (443/tcp)"
    
    # 拒绝常见攻击端口（生产环境安全）
    ufw deny 23/tcp comment 'Block Telnet'
    ufw deny 135/tcp comment 'Block RPC'
    ufw deny 139/tcp comment 'Block NetBIOS'
    ufw deny 445/tcp comment 'Block SMB'
    ufw deny 1433/tcp comment 'Block MSSQL'
    ufw deny 3389/tcp comment 'Block RDP'
    ufw deny 5432/tcp comment 'Block PostgreSQL direct access'
    ufw deny 6379/tcp comment 'Block Redis direct access'
    ufw deny 8069/tcp comment 'Block Odoo direct access'
    ufw deny 8072/tcp comment 'Block Odoo longpolling direct access'
    
    # 配置日志记录
    ufw logging on
    
    # 启用UFW
    ufw --force enable
    
    # 创建fail2ban配置（如果安装了）
    if command -v fail2ban-server &> /dev/null; then
        configure_fail2ban
    else
        log "建议安装fail2ban增强安全防护"
    fi
    
    log "防火墙配置完成（生产环境安全加固）"
    log "注意: 已阻止Odoo和数据库的直接访问，仅允许通过Nginx代理"
}

# 配置fail2ban（如果可用）
configure_fail2ban() {
    log "配置fail2ban..."
    
    cat > /etc/fail2ban/jail.d/morhon-odoo.conf << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
EOF

    systemctl restart fail2ban 2>/dev/null || true
    log "fail2ban配置完成"
}

# 配置Nginx - 专用服务器优化
configure_nginx() {
    log "配置Nginx（专用服务器优化）..."
    
    # 备份原始配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    
    # 获取系统资源信息
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    
    # 专用服务器优化参数
    local worker_processes=$cpu_cores
    local worker_connections=$((cpu_cores * 2048))  # 每个CPU核心2048连接
    local worker_rlimit_nofile=$((worker_connections * 2))
    
    # 创建专用服务器优化的nginx配置
    tee /etc/nginx/nginx.conf > /dev/null << EOF
# 茂亨Odoo专用服务器Nginx配置
user www-data;
worker_processes $worker_processes;
worker_rlimit_nofile $worker_rlimit_nofile;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections $worker_connections;
    multi_accept on;
    use epoll;
    accept_mutex off;
}

http {
    # 基本设置
    sendfile on;
    sendfile_max_chunk 1m;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 75s;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    
    # 专用服务器优化
    open_file_cache max=10000 inactive=60s;
    open_file_cache_valid 120s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式优化
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main buffer=64k flush=5s;
    error_log /var/log/nginx/error.log warn;
    
    # 外贸管理系统优化 - 大文件支持
    client_max_body_size 500M;
    client_body_buffer_size 128k;
    client_header_buffer_size 4k;
    large_client_header_buffers 8 16k;
    client_body_timeout 300s;
    client_header_timeout 60s;
    send_timeout 300s;
    
    # 代理优化
    proxy_connect_timeout 60s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    proxy_buffer_size 64k;
    proxy_buffers 32 64k;
    proxy_busy_buffers_size 128k;
    proxy_temp_file_write_size 128k;
    proxy_max_temp_file_size 1024m;
    
    # Gzip压缩优化
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        text/csv
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        application/rdf+xml
        application/rss+xml
        application/geo+json
        application/ld+json
        application/manifest+json
        application/x-web-app-manifest+json
        image/svg+xml;
    
    # 缓存优化
    proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:100m max_size=1g inactive=60m use_temp_path=off;
    
    # SSL优化
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    
    # 连接限制 - 外贸管理系统防护
    limit_conn_zone \$binary_remote_addr zone=conn_limit_per_ip:10m;
    limit_req_zone \$binary_remote_addr zone=req_limit_per_ip:10m rate=20r/s;
    
    # 包含其他配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 创建缓存目录
    mkdir -p /var/cache/nginx/odoo
    chown -R www-data:www-data /var/cache/nginx/odoo
    
    # 创建站点目录
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    # 测试配置
    nginx -t
    
    # 重启Nginx
    systemctl restart nginx
    
    log "Nginx专用服务器配置完成"
}

# 创建Docker卷 - 包含Redis
create_docker_volumes() {
    log "创建Docker卷（包含Redis缓存）..."
    
    create_volume "$DB_VOLUME_NAME" "数据库卷"
    create_volume "$ODOO_VOLUME_NAME" "Odoo文件卷"
    create_volume "morhon-redis" "Redis缓存卷"
    
    log "Docker卷创建完成（包含Redis缓存支持）"
}

# 创建Docker卷（辅助函数）
create_volume() {
    local volume_name="$1"
    local description="$2"
    
    if ! docker volume ls | grep -q "$volume_name"; then
        docker volume create "$volume_name"
        log "创建$description: $volume_name"
    else
        log "$description已存在: $volume_name"
    fi
}

# 拉取Docker镜像（专有镜像，无备用源）
get_docker_image() {
    local image_name="$1"
    
    log "拉取Docker镜像: $image_name"
    
    if docker pull "$image_name"; then
        log "镜像拉取成功: $image_name"
        return 0
    else
        log_error "镜像拉取失败: $image_name"
        log_error "请检查网络连接和镜像仓库权限"
        return 1
    fi
}

# 生成docker-compose文件
generate_docker_compose() {
    local deployment_type="$1"  # domain 或 local
    local domain="$2"
    local use_www="${3:-no}"
    
    # 获取系统信息用于优化
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    
    # 计算workers数量
    local workers=$(calculate_workers "$cpu_cores" "$total_mem")
    
    # 创建目录结构
    mkdir -p "$INSTANCE_DIR/config"
    mkdir -p "$INSTANCE_DIR/backups"
    mkdir -p "$INSTANCE_DIR/logs"
    
    # 创建odoo配置文件
    create_odoo_config "$workers" "$total_mem"
    
    # 创建docker-compose.yml
    create_docker_compose_config
    
    # 创建环境变量文件
    create_env_file "$deployment_type" "$domain" "$use_www"
    
    # 根据部署类型创建Nginx配置
    if [ "$deployment_type" = "domain" ]; then
        create_nginx_domain_config "$domain" "$use_www"
    else
        create_nginx_local_config
    fi
    
    log "配置文件生成完成"
}

# 计算workers数量 - 专用服务器优化
calculate_workers() {
    local cpu_cores="$1"
    local total_mem="$2"
    local workers
    
    # 专用服务器配置：更激进的worker分配
    if [ "$cpu_cores" -ge 16 ]; then
        workers=$((cpu_cores * 2))  # 16核以上：2倍CPU核心数
    elif [ "$cpu_cores" -ge 8 ]; then
        workers=$((cpu_cores + 4))  # 8-15核：CPU核心数+4
    elif [ "$cpu_cores" -ge 4 ]; then
        workers=$((cpu_cores * 2))  # 4-7核：2倍CPU核心数
    elif [ "$cpu_cores" -ge 2 ]; then
        workers=$((cpu_cores + 2))  # 2-3核：CPU核心数+2
    else
        workers=3  # 单核：最少3个worker
    fi
    
    # 根据内存限制调整（每个worker大约需要512MB内存）
    local max_workers_by_mem=$((total_mem * 1024 / 512))
    [ "$workers" -gt "$max_workers_by_mem" ] && workers="$max_workers_by_mem"
    
    # 最少保证4个worker，最多不超过32个
    [ "$workers" -lt 4 ] && workers=4
    [ "$workers" -gt 32 ] && workers=32
    
    echo "$workers"
}

# 创建odoo配置文件 - 专用服务器优化
create_odoo_config() {
    local workers="$1"
    local total_mem="$2"
    
    # 外贸管理系统内存分配策略（针对大量产品和订单数据）
    local memory_hard=$((total_mem * 450))  # 外贸管理系统需要更多内存处理复杂数据
    local memory_soft=$((total_mem * 350))  # 软限制也相应提高
    
    # 确保最小值（外贸管理系统基础要求）
    [ "$memory_hard" -lt 1536 ] && memory_hard=1536  # 外贸管理系统最少1.5GB
    [ "$memory_soft" -lt 1024 ] && memory_soft=1024  # 软限制最少1GB
    
    # 数据库连接池优化（外贸管理系统多表关联查询较多）
    local db_maxconn=$((workers * 4 + 12))  # 外贸管理系统需要更多数据库连接
    local max_cron_threads=$((workers > 8 ? 6 : workers > 4 ? 4 : 3))  # 更多定时任务处理
    
    cat > "$INSTANCE_DIR/config/odoo.conf" << EOF
[options]
# 基本配置
admin_passwd = \${ADMIN_PASSWORD}
addons_path = /mnt/extra-addons,/mnt/odoo/addons
data_dir = /var/lib/odoo
without_demo = all
proxy_mode = True

# 外贸管理系统性能配置
workers = $workers
limit_memory_hard = ${memory_hard}M
limit_memory_soft = ${memory_soft}M
max_cron_threads = $max_cron_threads
limit_time_cpu = 1800
limit_time_real = 3600
limit_request = 32768

# 数据库优化配置（外贸管理系统）
db_host = db
db_port = 5432
db_user = odoo
db_password = \${DB_PASSWORD}
db_name = postgres
db_maxconn = $db_maxconn
list_db = False
db_sslmode = prefer
db_template = template0

# Redis缓存配置 - 外贸管理系统优化
enable_redis = True
redis_host = redis
redis_port = 6379
redis_db = 0
redis_pass = False
redis_expiration = 43200

# 会话管理优化（外贸管理系统用户长时间在线）
session_redis = True
session_redis_host = redis
session_redis_port = 6379
session_redis_db = 1
session_redis_prefix = odoo_session
session_timeout = 28800

# 缓存优化（外贸管理系统大数据量）
osv_memory_count_limit = 0
osv_memory_age_limit = 2.0

# 日志配置
log_level = info
log_handler = :INFO
logfile = /var/log/odoo/odoo.log
log_db = False
log_db_level = warning
syslog = False

# 安全配置
server_wide_modules = base,web
unaccent = True
list_db = False

# 邮件配置
email_from = noreply@localhost
smtp_server = localhost
smtp_port = 25
smtp_ssl = False
smtp_user = False
smtp_password = False

# 外贸管理系统专用优化
translate_modules = ['all']
load_language = zh_CN,en_US
currency_precision = 4
price_precision = 4

# 报表和导出优化（外贸管理系统单据较多）
reportgz = True
csv_internal_sep = ,
import_partial = 500
export_partial = 1000

# 外贸管理系统专用缓存策略
cache_timeout = 1800
static_cache_timeout = 604800

# 文件上传优化（外贸管理系统文档较大）
max_file_upload_size = 536870912

# 外贸管理系统业务定时任务优化
cron_workers = $((max_cron_threads))

# 数据库查询优化
pg_path = /usr/bin
EOF
}

# 创建docker-compose配置文件 - 外贸管理系统优化
create_docker_compose_config() {
    # 获取系统资源信息
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    
    # 外贸管理系统资源分配策略
    local redis_memory=$((total_mem * 1024))  # Redis使用1GB内存（外贸管理系统缓存需求大）
    local db_memory="${total_mem}g"
    local db_shared_buffers=$((total_mem * 256))  # 25% 内存作为shared_buffers
    local db_effective_cache_size=$((total_mem * 768))  # 75% 内存作为effective_cache_size
    
    cat > "$INSTANCE_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: morhon-odoo-redis
    restart: unless-stopped
    command: >
      redis-server
      --maxmemory ${redis_memory}mb
      --maxmemory-policy allkeys-lru
      --save 900 1
      --save 300 10
      --save 60 10000
      --appendonly yes
      --appendfsync everysec
      --tcp-keepalive 300
      --timeout 0
      --tcp-backlog 511
      --databases 16
      --maxclients 10000
    volumes:
      - redis-data:/data
    networks:
      - morhon-network
    deploy:
      resources:
        limits:
          memory: ${redis_memory}mb
          cpus: '1.0'
        reservations:
          memory: $((redis_memory / 2))mb
          cpus: '0.5'
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  db:
    image: $POSTGRES_IMAGE
    container_name: morhon-odoo-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
      # 外贸管理系统数据库安全配置
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - $DB_VOLUME_NAME:/var/lib/postgresql/data/pgdata
      - $INSTANCE_DIR/backups:/backups
    networks:
      - morhon-network
    deploy:
      resources:
        limits:
          memory: ${db_memory}
          cpus: '${cpu_cores}.0'
        reservations:
          memory: $((total_mem / 2))g
          cpus: '$((cpu_cores / 2)).0'
    security_opt:
      - no-new-privileges:true
    # PostgreSQL外贸管理系统优化
    command: >
      postgres
      -c shared_buffers=${db_shared_buffers}MB
      -c effective_cache_size=${db_effective_cache_size}MB
      -c maintenance_work_mem=$((total_mem * 64))MB
      -c checkpoint_completion_target=0.9
      -c wal_buffers=16MB
      -c default_statistics_target=100
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
      -c work_mem=64MB
      -c min_wal_size=2GB
      -c max_wal_size=8GB
      -c max_worker_processes=$cpu_cores
      -c max_parallel_workers_per_gather=$((cpu_cores / 2))
      -c max_parallel_workers=$cpu_cores
      -c max_parallel_maintenance_workers=$((cpu_cores / 4))
      -c log_min_duration_statement=1000
      -c log_checkpoints=on
      -c log_connections=on
      -c log_disconnections=on
      -c log_lock_waits=on
      -c deadlock_timeout=1s
      -c max_connections=200
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  odoo:
    image: $ODOO_IMAGE
    container_name: morhon-odoo
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      HOST: db
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      DB_NAME: postgres
      ADMIN_PASSWORD: \${ADMIN_PASSWORD}
      # Redis缓存配置
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_DB: 0
      # 外贸管理系统环境变量
      TZ: Asia/Shanghai
      LANG: zh_CN.UTF-8
      LC_ALL: zh_CN.UTF-8
    volumes:
      - $INSTANCE_DIR/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - $ODOO_VOLUME_NAME:/var/lib/odoo
      - $INSTANCE_DIR/logs:/var/log/odoo
      - $INSTANCE_DIR/backups:/backups:ro
    ports:
      - "127.0.0.1:8069:8069"
      - "127.0.0.1:8072:8072"
    networks:
      - morhon-network
    deploy:
      resources:
        limits:
          memory: $((total_mem * 2))g
          cpus: '${cpu_cores}.0'
        reservations:
          memory: $((total_mem / 2))g
          cpus: '$((cpu_cores / 2)).0'
    security_opt:
      - no-new-privileges:true
    # Odoo外贸管理系统优化
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
      nproc:
        soft: 32768
        hard: 32768
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8069/web/health"]
      interval: 30s
      timeout: 15s
      retries: 5
      start_period: 180s

networks:
  morhon-network:
    driver: bridge
    name: morhon-network
    driver_opts:
      com.docker.network.bridge.name: morhon-br0
    ipam:
      config:
        - subnet: 172.20.0.0/16

volumes:
  $DB_VOLUME_NAME:
    external: true
  $ODOO_VOLUME_NAME:
    external: true
  redis-data:
    driver: local
    name: morhon-redis
EOF
}

# 创建环境变量文件
create_env_file() {
    local deployment_type="$1"
    local domain="$2"
    local use_www="$3"
    local db_password="${DETECTED_DB_PASSWORD:-$(openssl rand -base64 32)}"
    local admin_password="$(openssl rand -base64 24)"
    
    cat > "$INSTANCE_DIR/.env" << EOF
# 茂亨Odoo环境变量配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# 数据库配置
DB_PASSWORD=$db_password

# 管理员配置
ADMIN_PASSWORD=$admin_password

# 部署配置
DEPLOYMENT_TYPE=$deployment_type
DOMAIN=$domain
USE_WWW=$use_www

# 版本信息
SCRIPT_VERSION=6.2
ODOO_IMAGE=$ODOO_IMAGE
POSTGRES_IMAGE=$POSTGRES_IMAGE
EOF

    # 设置文件权限
    chmod 600 "$INSTANCE_DIR/.env"
    
    log "环境变量文件已创建: $INSTANCE_DIR/.env"
    log "管理员密码: $admin_password"
}

# 创建Nginx域名配置 - 公网生产环境优化
create_nginx_domain_config() {
    local domain="$1"
    local use_www="$2"
    
    local config_file="/etc/nginx/sites-available/morhon-odoo"
    
    # 根据是否使用www生成server_name
    local server_name
    if [ "$use_www" = "yes" ]; then
        server_name="$domain www.$domain"
    else
        server_name="$domain"
    fi
    
    tee "$config_file" > /dev/null << EOF
# 茂亨Odoo公网生产环境配置 - $domain

# HTTP重定向到HTTPS（公网安全要求）
server {
    listen 80;
    listen [::]:80;
    server_name $server_name;
    
    # 公网连接限制（更严格）
    limit_conn conn_limit_per_ip 30;
    limit_req zone=req_limit_per_ip burst=50 nodelay;
    
    # Certbot验证
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }
    
    # 强制HTTPS重定向
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS服务器 - 公网生产环境
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_name;
    
    # SSL证书
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    
    # 公网连接和请求限制
    limit_conn conn_limit_per_ip 30;
    limit_req zone=req_limit_per_ip burst=50 nodelay;
    
    # 公网生产环境安全头部（更严格）
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none';" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    
    # 代理设置优化
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Ssl on;
    
    # 代理缓冲优化
    proxy_buffering on;
    proxy_buffer_size 64k;
    proxy_buffers 32 64k;
    proxy_busy_buffers_size 128k;
    
    # 公网环境严格访问控制
    location ~* /(web|api)/database/ {
        deny all;
        return 403;
    }
    
    location ~* /web/static/.*\.(py|pyc|pyo|xml)$ {
        deny all;
        return 403;
    }
    
    # 阻止常见攻击路径
    location ~* \.(git|svn|env|htaccess|htpasswd)$ {
        deny all;
        return 403;
    }
    
    # 长轮询请求优化
    location /longpolling {
        proxy_pass http://127.0.0.1:8072;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
    }
    
    # 静态文件缓存优化 - 公网环境
    location ~* /web/static/ {
        proxy_pass http://127.0.0.1:8069;
        proxy_cache odoo_cache;
        proxy_cache_valid 200 302 1d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_lock on;
        expires 7d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # 文件上传优化 - 外贸文档支持
    location ~* /web/binary/ {
        proxy_pass http://127.0.0.1:8069;
        client_max_body_size 500M;
        client_body_buffer_size 128k;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 报表和导出优化
    location ~* /(web/content|report)/ {
        proxy_pass http://127.0.0.1:8069;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }
    
    # API接口优化
    location ~* /jsonrpc {
        proxy_pass http://127.0.0.1:8069;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 主请求处理
    location / {
        proxy_pass http://127.0.0.1:8069;
        proxy_redirect off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 生产环境日志优化
    access_log /var/log/nginx/morhon-odoo-access.log main buffer=64k flush=5s;
    error_log /var/log/nginx/morhon-odoo-error.log;
}
EOF
    
    # 启用站点
    ln -sf "$config_file" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    
    log "Nginx公网生产环境配置创建完成"
    log "公网访问地址: https://$domain"
    log "注意: 这是公网生产环境，已启用严格安全策略"
}

# 创建Nginx本地配置 - 内网生产环境优化
create_nginx_local_config() {
    local config_file="/etc/nginx/sites-available/morhon-odoo"
    local server_ip=$(get_server_ip)
    
    tee "$config_file" > /dev/null << EOF
# 茂亨Odoo内网生产环境配置 - 通过IP访问

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    # 内网生产环境连接限制
    limit_conn conn_limit_per_ip 100;
    limit_req zone=req_limit_per_ip burst=200 nodelay;
    
    # 生产环境安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    
    # 代理设置优化
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    
    # 代理缓冲优化
    proxy_buffering on;
    proxy_buffer_size 64k;
    proxy_buffers 32 64k;
    proxy_busy_buffers_size 128k;
    
    # 禁止访问敏感路径（生产环境安全）
    location ~* /(web|api)/database/ {
        deny all;
        return 403;
    }
    
    location ~* /web/static/.*\.(py|pyc|pyo|xml)$ {
        deny all;
        return 403;
    }
    
    # 内网IP访问控制（可选配置）
    # allow 192.168.0.0/16;
    # allow 10.0.0.0/8;
    # allow 172.16.0.0/12;
    # deny all;
    
    # 长轮询请求优化
    location /longpolling {
        proxy_pass http://127.0.0.1:8072;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
    }
    
    # 静态文件缓存优化
    location ~* /web/static/ {
        proxy_pass http://127.0.0.1:8069;
        proxy_cache odoo_cache;
        proxy_cache_valid 200 302 1d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_lock on;
        expires 7d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # 文件上传优化 - 外贸文档支持
    location ~* /web/binary/ {
        proxy_pass http://127.0.0.1:8069;
        client_max_body_size 500M;
        client_body_buffer_size 128k;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 报表和导出优化
    location ~* /(web/content|report)/ {
        proxy_pass http://127.0.0.1:8069;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }
    
    # API接口优化
    location ~* /jsonrpc {
        proxy_pass http://127.0.0.1:8069;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 主请求处理
    location / {
        proxy_pass http://127.0.0.1:8069;
        proxy_redirect off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 生产环境日志优化
    access_log /var/log/nginx/morhon-odoo-access.log main buffer=64k flush=5s;
    error_log /var/log/nginx/morhon-odoo-error.log;
}
EOF
    
    # 启用站点
    ln -sf "$config_file" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    
    log "Nginx内网生产环境配置创建完成"
    log "内网访问地址: http://$server_ip"
    log "注意: 这是生产环境配置，请确保内网安全策略"
}

# 获取SSL证书
get_ssl_certificate() {
    local domain="$1"
    local use_www="$2"
    
    log "获取SSL证书..."
    
    # 创建Certbot目录
    mkdir -p /var/www/certbot
    
    # 根据是否使用www生成域名列表
    local domain_args=""
    if [ "$use_www" = "yes" ]; then
        domain_args="-d $domain -d www.$domain"
    else
        domain_args="-d $domain"
    fi
    
    # 检查是否已有证书
    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        log "SSL证书已存在，尝试续期..."
        if certbot renew --dry-run; then
            log "SSL证书有效"
            return 0
        fi
    fi
    
    # 获取新证书
    if certbot certonly --webroot \
        -w /var/www/certbot \
        $domain_args \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain" \
        --force-renewal; then
        log "SSL证书获取成功"
        
        # 设置自动续期
        setup_ssl_renewal "$domain"
        return 0
    else
        log_warn "无法获取SSL证书，将使用HTTP模式"
        create_nginx_http_config "$domain" "$use_www"
        return 1
    fi
}

# 设置SSL证书自动续期
setup_ssl_renewal() {
    local domain="$1"
    
    # 创建续期脚本
    cat > /etc/cron.d/certbot-renewal << EOF
# 每天凌晨2点检查证书续期
0 2 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
EOF
    
    log "SSL证书自动续期已设置"
}

# 创建HTTP模式的Nginx配置（SSL获取失败时的备用方案）
create_nginx_http_config() {
    local domain="$1"
    local use_www="$2"
    
    local config_file="/etc/nginx/sites-available/morhon-odoo"
    
    # 根据是否使用www生成server_name
    local server_name
    if [ "$use_www" = "yes" ]; then
        server_name="$domain www.$domain"
    else
        server_name="$domain"
    fi
    
    tee "$config_file" > /dev/null << EOF
# 茂亨Odoo HTTP模式 - $domain (SSL获取失败备用方案)

server {
    listen 80;
    listen [::]:80;
    server_name $server_name;
    
    # Certbot验证目录
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # 代理设置
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    
    # 禁止访问数据库管理界面
    location ~* /(web|api)/database/ {
        deny all;
        return 403;
    }
    
    # 长轮询请求
    location /longpolling {
        proxy_pass http://127.0.0.1:8072;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # 静态文件
    location ~* /web/static/ {
        proxy_buffering on;
        expires 864000;
        proxy_pass http://127.0.0.1:8069;
    }
    
    # 主请求
    location / {
        proxy_pass http://127.0.0.1:8069;
        proxy_redirect off;
    }
    
    access_log /var/log/nginx/morhon-odoo-access.log;
    error_log /var/log/nginx/morhon-odoo-error.log;
}
EOF
    
    # 启用站点
    ln -sf "$config_file" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    
    log "Nginx HTTP配置创建完成（SSL备用方案）"
}

# 迁移手动部署实例到脚本管理
migrate_manual_instance() {
    log "开始迁移手动部署实例..."
    
    # 确认迁移
    if ! confirm_action "迁移操作将执行以下步骤:\n  1. 备份现有数据\n  2. 停止并删除旧容器\n  3. 创建脚本管理实例\n  4. 恢复数据到新实例"; then
        log "取消迁移"
        return 1
    fi
    
    # 备份现有数据
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/migration_$backup_timestamp"
    mkdir -p "$backup_path"
    
    log "备份现有数据..."
    backup_existing_data "$backup_path"
    
    # 询问部署模式
    local deployment_type domain use_www
    get_deployment_info "$deployment_type" "$domain" "$use_www"
    
    # 停止并删除旧容器
    log "清理旧容器..."
    cleanup_old_containers
    
    # 创建新的脚本管理实例
    log "创建新实例..."
    create_new_instance "$deployment_type" "$domain" "$use_www"
    
    # 恢复数据库（如果有备份）
    restore_database_backup "$backup_path"
    
    # 专用服务器优化
    optimize_migrated_instance
    
    # 重启Nginx
    systemctl reload nginx
    
    log "迁移完成！"
    show_deployment_info "$deployment_type" "$domain" "$backup_path"
    
    return 0
}

# 迁移实例后的专用服务器优化
optimize_migrated_instance() {
    log "执行迁移实例的专用服务器优化..."
    
    # 系统优化（如果还没有执行过）
    if [ ! -f "/etc/sysctl.d/99-morhon-odoo.conf" ]; then
        optimize_system_for_odoo
    fi
    
    # 重新生成优化的配置文件
    log "重新生成优化配置..."
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    local workers=$(calculate_workers "$cpu_cores" "$total_mem")
    
    # 更新Odoo配置
    create_odoo_config "$workers" "$total_mem"
    
    # 更新Docker Compose配置
    create_docker_compose_config
    
    # 重启容器以应用新配置
    cd "$INSTANCE_DIR"
    docker-compose down
    docker-compose up -d
    
    # 等待服务启动
    log "等待优化后的服务启动..."
    sleep 10
    
    # 数据库优化
    optimize_database_after_migration
    
    log "迁移实例专用服务器优化完成"
}

# 迁移后数据库优化
optimize_database_after_migration() {
    log "执行数据库优化..."
    
    # 等待数据库完全启动
    local db_ready=false
    for i in {1..30}; do
        if docker-compose exec -T db pg_isready -U odoo -d postgres >/dev/null 2>&1; then
            db_ready=true
            break
        fi
        sleep 2
    done
    
    if [ "$db_ready" = true ]; then
        # 执行数据库维护
        log "执行数据库维护操作..."
        docker-compose exec -T db psql -U odoo -d postgres -c "VACUUM ANALYZE;" >/dev/null 2>&1 || true
        docker-compose exec -T db psql -U odoo -d postgres -c "REINDEX DATABASE postgres;" >/dev/null 2>&1 || true
        log "数据库优化完成"
    else
        log_warn "数据库未能及时启动，跳过数据库优化"
    fi
}

# 确认操作
confirm_action() {
    local message="$1"
    echo ""
    echo -e "${YELLOW}$message${NC}"
    echo ""
    read -p "是否继续？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# 备份现有数据
backup_existing_data() {
    local backup_path="$1"
    
    # 备份数据库
    if [ -n "$DETECTED_DB_CONTAINER" ]; then
        docker exec "$DETECTED_DB_CONTAINER" pg_dumpall -U postgres | gzip > "$backup_path/database.sql.gz" 2>/dev/null || \
        docker exec "$DETECTED_DB_CONTAINER" pg_dumpall -U odoo | gzip > "$backup_path/database.sql.gz" 2>/dev/null || \
        log_warn "数据库备份失败"
    fi
}

# 获取部署信息
get_deployment_info() {
    local -n deployment_type_ref=$1
    local -n domain_ref=$2
    local -n use_www_ref=$3
    
    deployment_type_ref="local"
    domain_ref=""
    use_www_ref="no"
    
    if [ -n "$DETECTED_DOMAIN" ]; then
        echo "检测到现有域名: $DETECTED_DOMAIN"
        read -p "是否使用此域名？(Y/n): " use_domain
        if [[ ! "$use_domain" =~ ^[Nn]$ ]]; then
            deployment_type_ref="domain"
            domain_ref="$DETECTED_DOMAIN"
            
            # 自动检测是否带www
            if [[ "$domain_ref" == www.* ]]; then
                use_www_ref="yes"
            fi
            # 原手动选择已替换为自动检测
        fi
    fi
    
    # 如果没有域名，询问是否使用域名模式
    if [ -z "$domain_ref" ]; then
        read -p "是否使用域名模式？(y/N): " use_domain
        if [[ "$use_domain" =~ ^[Yy]$ ]]; then
            deployment_type_ref="domain"
            read -p "请输入域名: " domain_ref
            [ -z "$domain_ref" ] && deployment_type_ref="local"
        fi
    fi
}

# 清理旧容器
cleanup_old_containers() {
    [ -n "$DETECTED_ODOO_CONTAINER" ] && docker stop "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_DB_CONTAINER" ] && docker stop "$DETECTED_DB_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_ODOO_CONTAINER" ] && docker rm "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_DB_CONTAINER" ] && docker rm "$DETECTED_DB_CONTAINER" 2>/dev/null || true
}

# 创建新实例
create_new_instance() {
    local deployment_type="$1"
    local domain="$2"
    local use_www="$3"
    
    log "创建新实例..."
    
    # 创建Docker卷
    create_docker_volumes
    
    # 生成配置文件
    generate_docker_compose "$deployment_type" "$domain" "$use_www"
    
    # 拉取Docker镜像
    get_docker_image "$POSTGRES_IMAGE"
    get_docker_image "$ODOO_IMAGE"
    
    # 启动服务并等待就绪
    start_services
    
    # 如果是域名模式，配置SSL和Nginx
    if [ "$deployment_type" = "domain" ]; then
        get_ssl_certificate "$domain" "$use_www"
    fi
    
    log "新实例创建完成"
}
    
# 启动服务并等待就绪
start_services() {
    log "启动服务..."
    cd "$INSTANCE_DIR"
    
    # 启动服务
    docker-compose up -d
    
    # 等待数据库就绪
    log "等待数据库启动..."
    local db_ready=false
    for i in {1..30}; do
        if docker-compose exec -T db pg_isready -U odoo -d postgres >/dev/null 2>&1; then
            db_ready=true
            break
        fi
        sleep 2
        echo -n "."
    done
    echo ""
    
    if [ "$db_ready" = false ]; then
        log_error "数据库启动超时"
        return 1
    fi
    
    log "数据库已就绪"
    
    # 等待Odoo就绪
    log "等待Odoo启动..."
    local odoo_ready=false
    for i in {1..60}; do
        if curl -s http://127.0.0.1:8069/web/health >/dev/null 2>&1; then
            odoo_ready=true
            break
        fi
        sleep 3
        echo -n "."
    done
    echo ""
    
    if [ "$odoo_ready" = false ]; then
        log_warn "Odoo启动检查超时，但服务可能仍在启动中"
    else
        log "Odoo已就绪"
    fi
    
    return 0
}

# 恢复数据库备份
restore_database_backup() {
    local backup_path="$1"
    
    if [ -f "$backup_path/database.sql.gz" ]; then
        log "恢复数据库..."
        gunzip -c "$backup_path/database.sql.gz" | docker exec -i morhon-odoo-db psql -U odoo postgres 2>/dev/null || \
        log_warn "数据库恢复失败，新实例将使用空数据库"
    fi
}

# 显示部署信息
show_deployment_info() {
    local deployment_type="$1"
    local domain="$2"
    local backup_path="$3"
    
    echo ""
    echo -e "${GREEN}部署完成！${NC}"
    echo "===================="
    log "实例目录: $INSTANCE_DIR"
    [ -n "$backup_path" ] && log "备份文件: $backup_path"
    
    if [ "$deployment_type" = "domain" ]; then
        log "公网访问地址: https://$domain"
        log "部署环境: 公网生产环境"
    else
        local server_ip=$(get_server_ip)
        log "内网访问地址: http://$server_ip"
        log "部署环境: 内网生产环境"
    fi
    
    echo ""
    echo -e "${YELLOW}重要提醒:${NC}"
    echo "• 这是生产环境部署，请妥善保管管理员密码"
    echo "• 建议定期备份数据和配置文件"
    echo "• 如需技术支持，请访问: https://github.com/morhon-tech/morhon-odoo"
}

# 从本地备份恢复
restore_from_backup() {
    log "从本地备份恢复..."
    
    # 查找备份文件（优先查找脚本同目录，然后查找脚本目录）
    local backup_files=()
    
    # 首先在脚本同目录查找备份文件
    local script_backup_files=($(find "$SCRIPT_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null))
    
    # 然后在默认备份目录查找
    local default_backup_files=()
    if [ -d "$BACKUP_DIR" ]; then
        default_backup_files=($(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null))
    fi
    
    # 合并备份文件列表，脚本目录的文件优先
    backup_files=("${script_backup_files[@]}" "${default_backup_files[@]}")
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        log_error "未找到备份文件"
        log "请将备份文件(.tar.gz)放在脚本同目录下，或放在 $BACKUP_DIR 目录中"
        return 1
    fi
    
    # 选择备份文件
    local backup_file=$(select_backup_file "${backup_files[@]}")
    [ -z "$backup_file" ] && return 1
    
    # 询问域名
    local deployment_type domain use_www
    get_restore_deployment_info "$deployment_type" "$domain" "$use_www"
    
    # 解压备份
    local temp_dir="/tmp/restore_$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$temp_dir"
    
    log "解压备份文件: $(basename "$backup_file")"
    if ! tar -xzf "$backup_file" -C "$temp_dir"; then
        log_error "备份文件解压失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 查找备份数据
    local backup_data=$(find "$temp_dir" -name "database.sql.gz" -type f | head -1)
    if [ -z "$backup_data" ]; then
        log_error "备份文件中未找到数据库文件"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 检查备份完整性
    local backup_info=$(find "$temp_dir" -name "backup_info.txt" -type f | head -1)
    if [ -n "$backup_info" ]; then
        log "备份信息:"
        cat "$backup_info"
        echo ""
        
        read -p "确认恢复此备份？(y/N): " confirm_restore
        if [[ ! "$confirm_restore" =~ ^[Yy]$ ]]; then
            log "取消恢复"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    # 创建新实例
    log "创建新实例..."
    create_new_instance "$deployment_type" "$domain" "$use_www"
    
    # 等待服务完全启动
    sleep 5
    
    # 恢复数据库
    restore_from_backup_file "$backup_data"
    
    # 恢复Redis缓存（如果存在）
    local redis_backup=$(find "$temp_dir" -name "redis-dump.rdb" -type f | head -1)
    if [ -n "$redis_backup" ] && [ -f "$redis_backup" ]; then
        log "恢复Redis缓存..."
        # 等待Redis容器启动
        sleep 5
        if docker cp "$redis_backup" morhon-odoo-redis:/data/dump.rdb 2>/dev/null; then
            docker-compose restart redis >/dev/null 2>&1 || true
            log "Redis缓存恢复完成"
        else
            log_warn "Redis缓存恢复失败，系统将自动重建缓存"
        fi
    else
        log "未找到Redis备份文件，系统将自动重建缓存"
    fi
    
    # 恢复其他配置（如果存在）
    restore_additional_configs "$temp_dir"
    
    # 重启Nginx
    systemctl reload nginx
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    log "恢复完成！"
    
    if [ "$deployment_type" = "domain" ]; then
        log "访问地址: https://$domain"
    else
        local server_ip=$(get_server_ip)
        log "访问地址: http://$server_ip"
    fi
    
    # 显示恢复后的信息
    show_restore_summary "$backup_file"
    
    return 0
}

# 恢复其他配置文件
restore_additional_configs() {
    local temp_dir="$1"
    
    # 恢复环境变量（如果备份中有且当前没有冲突）
    local backup_env=$(find "$temp_dir" -name ".env" -type f | head -1)
    if [ -n "$backup_env" ] && [ -f "$backup_env" ]; then
        log "发现备份的环境变量配置"
        
        # 提取备份中的管理员密码
        local backup_admin_pass=$(grep "^ADMIN_PASSWORD=" "$backup_env" | cut -d'=' -f2)
        if [ -n "$backup_admin_pass" ]; then
            log "恢复管理员密码..."
            sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$backup_admin_pass/" "$INSTANCE_DIR/.env"
        fi
    fi
    
    # 恢复Nginx配置（如果备份中有）
    local backup_nginx=$(find "$temp_dir" -name "nginx-config" -type f | head -1)
    if [ -n "$backup_nginx" ] && [ -f "$backup_nginx" ]; then
        log "发现备份的Nginx配置，可手动参考恢复"
    fi
}

# 显示恢复摘要
show_restore_summary() {
    local backup_file="$1"
    
    echo ""
    echo -e "${GREEN}恢复摘要${NC}"
    echo "===================="
    echo "备份文件: $(basename "$backup_file")"
    echo "实例目录: $INSTANCE_DIR"
    echo "恢复时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "后续操作建议:"
    echo "1. 检查系统状态: 在脚本菜单中选择'系统状态检查'"
    echo "2. 修改密码: 建议修改管理员密码"
    echo "3. 检查配置: 确认Odoo配置是否符合当前环境"
    echo "4. 创建备份: 恢复完成后建议立即创建新备份"
    echo ""
}

# 选择备份文件
select_backup_file() {
    local backup_files=("$@")
    
    echo ""
    echo "发现备份文件:"
    echo "===================="
    
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[$i]}"
        local size=$(du -h "$file" 2>/dev/null | cut -f1)
        local date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1)
        
        # 检查是否在脚本目录
        local location="默认备份目录"
        if [[ "$file" == "$SCRIPT_DIR"* ]]; then
            location="脚本目录"
        fi
        
        echo "$((i+1))) $(basename "$file")"
        echo "    大小: $size | 日期: $date | 位置: $location"
        echo ""
    done
    
    read -p "选择要恢复的备份文件 (1-${#backup_files[@]}) [默认: 1]: " choice
    choice=${choice:-1}
    
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        log_error "无效选择"
        return
    fi
    
    local backup_file="${backup_files[$((choice-1))]}"
    log "选择恢复: $(basename "$backup_file")"
    echo "$backup_file"
}

# 获取恢复部署信息
get_restore_deployment_info() {
    local -n deployment_type_ref=$1
    local -n domain_ref=$2
    local -n use_www_ref=$3
    
    echo ""
    echo -e "${CYAN}选择恢复部署模式:${NC}"
    echo "1) 内网模式 - 恢复到内网环境，通过IP访问（生产环境）"
    echo "2) 公网模式 - 恢复到公网VPS，通过域名访问（生产环境）"
    echo ""
    read -p "请选择部署模式 (1-2): " deploy_mode
    
    case $deploy_mode in
        1)
            deployment_type_ref="local"
            domain_ref=""
            use_www_ref="no"
            log "选择恢复到内网生产环境"
            ;;
        2)
            deployment_type_ref="domain"
            echo ""
            read -p "请输入域名: " domain_ref
            if [ -z "$domain_ref" ]; then
                log_error "域名不能为空"
                deployment_type_ref="local"
                domain_ref=""
                use_www_ref="no"
            else
                # 自动检测是否带www
                if [[ "$domain_ref" == www.* ]]; then
                    use_www_ref="yes"
                fi
                log "选择恢复到公网生产环境，域名: $domain_ref"
            fi
            ;;
        *)
            log "无效选择，默认恢复到内网模式"
            deployment_type_ref="local"
            domain_ref=""
            use_www_ref="no"
            ;;
    esac
}

# 从备份文件恢复数据库
restore_from_backup_file() {
    local backup_data="$1"
    
    log "恢复数据库..."
    gunzip -c "$backup_data" | docker exec -i morhon-odoo-db psql -U odoo postgres 2>/dev/null || \
    log_warn "数据库恢复失败，将使用空数据库"
}

# 全新部署
deploy_new_instance() {
    log "全新部署茂亨Odoo..."
    
    # 询问域名
    local deployment_type domain use_www
    get_deployment_info_interactive "$deployment_type" "$domain" "$use_www"
    
    # 初始化环境（如果需要）
    check_and_init_environment
    
    # 创建新实例
    create_new_instance "$deployment_type" "$domain" "$use_www"
    
    # 重启Nginx
    systemctl reload nginx
    
    log "部署完成！"
    
    if [ "$deployment_type" = "domain" ]; then
        log "访问地址: https://$domain"
    else
        local server_ip=$(get_server_ip)
        log "访问地址: http://$server_ip"
    fi
    
    log "管理员密码: 查看 $INSTANCE_DIR/.env 文件"
    return 0
}

# 交互式获取部署信息
get_deployment_info_interactive() {
    local -n deployment_type_ref=$1
    local -n domain_ref=$2
    local -n use_www_ref=$3
    
    echo ""
    echo -e "${CYAN}选择部署模式:${NC}"
    echo "1) 内网模式 - 部署在内网环境，通过IP访问（生产环境）"
    echo "2) 公网模式 - 部署在公网VPS，通过域名访问（生产环境）"
    echo ""
    read -p "请选择部署模式 (1-2): " deploy_mode
    
    case $deploy_mode in
        1)
            deployment_type_ref="local"
            domain_ref=""
            use_www_ref="no"
            log "选择内网生产环境模式"
            ;;
        2)
            deployment_type_ref="domain"
            echo ""
            read -p "请输入域名: " domain_ref
            if [ -z "$domain_ref" ]; then
                log_error "域名不能为空"
                deployment_type_ref="local"
                domain_ref=""
                use_www_ref="no"
            else
                # 自动检测是否带www
                if [[ "$domain_ref" == www.* ]]; then
                    use_www_ref="yes"
                fi
                log "选择公网生产环境模式，域名: $domain_ref"
            fi
            ;;
        *)
            log "无效选择，默认使用内网模式"
            deployment_type_ref="local"
            domain_ref=""
            use_www_ref="no"
            ;;
    esac
}

# 检查并初始化环境
check_and_init_environment() {
    if ! command -v docker &> /dev/null || ! command -v nginx &> /dev/null; then
        read -p "检测到缺少依赖，是否初始化环境？(Y/n): " init_env
        if [[ ! "$init_env" =~ ^[Nn]$ ]]; then
            init_environment
        fi
    fi
}

# 管理脚本部署的实例
manage_script_instance() {
    local choice
    while true; do
        show_management_menu
        read -p "请选择操作 (1-8): " choice
        
        case $choice in
            1) show_instance_status ;;
            2) restart_instance ;;
            3) show_logs ;;
            4) backup_instance ;;
            5) modify_config ;;
            6) check_system_status ;;
            7) optimize_existing_instance ;;
            8) return 1 ;;  # 返回主菜单
            *) log_error "无效选择" ;;
        esac
        
        [ "$choice" -eq 8 ] && break
        echo ""
        read -p "按回车键继续..."
    done
    
    return 0
}

# 显示管理菜单
show_management_menu() {
    echo ""
    echo -e "${GREEN}脚本管理实例菜单${NC}"
    echo "实例目录: $INSTANCE_DIR"
    echo ""
    echo "1) 查看实例状态"
    echo "2) 重启实例"
    echo "3) 查看日志"
    echo "4) 备份实例"
    echo "5) 修改配置"
    echo "6) 系统状态检查"
    echo "7) 性能优化"
    echo "8) 返回主菜单"
    echo ""
}

# 系统状态检查 - 专用服务器监控
check_system_status() {
    echo ""
    echo -e "${CYAN}茂亨Odoo专用服务器状态检查${NC}"
    echo "================================================"
    
    # 检查Docker状态
    echo -e "\n${YELLOW}Docker状态:${NC}"
    if systemctl is-active --quiet docker; then
        echo "✓ Docker服务运行正常"
        local docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        echo "  版本: $docker_version"
    else
        echo "✗ Docker服务未运行"
    fi
    
    # 检查Nginx状态
    echo -e "\n${YELLOW}Nginx状态:${NC}"
    if systemctl is-active --quiet nginx; then
        echo "✓ Nginx服务运行正常"
        local nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2)
        echo "  版本: $nginx_version"
        
        # 检查Nginx配置
        if nginx -t >/dev/null 2>&1; then
            echo "✓ Nginx配置语法正确"
        else
            echo "✗ Nginx配置存在错误"
        fi
    else
        echo "✗ Nginx服务未运行"
    fi
    
    # 检查容器状态
    echo -e "\n${YELLOW}容器状态:${NC}"
    if [ -f "$INSTANCE_DIR/docker-compose.yml" ]; then
        cd "$INSTANCE_DIR"
        docker-compose ps
        
        # 检查容器资源使用
        echo -e "\n${YELLOW}容器资源使用:${NC}"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" morhon-odoo morhon-odoo-db morhon-odoo-redis 2>/dev/null || echo "无法获取容器统计信息"
        
        # Redis缓存状态检查
        echo -e "\n${YELLOW}Redis缓存状态:${NC}"
        if docker exec morhon-odoo-redis redis-cli ping >/dev/null 2>&1; then
            echo "✓ Redis服务运行正常"
            
            # Redis内存使用
            local redis_memory=$(docker exec morhon-odoo-redis redis-cli info memory 2>/dev/null | grep "used_memory_human:" | cut -d':' -f2 | tr -d '\r')
            local redis_keys=$(docker exec morhon-odoo-redis redis-cli dbsize 2>/dev/null | tr -d '\r')
            local redis_hits=$(docker exec morhon-odoo-redis redis-cli info stats 2>/dev/null | grep "keyspace_hits:" | cut -d':' -f2 | tr -d '\r')
            local redis_misses=$(docker exec morhon-odoo-redis redis-cli info stats 2>/dev/null | grep "keyspace_misses:" | cut -d':' -f2 | tr -d '\r')
            
            echo "  内存使用: $redis_memory"
            echo "  缓存键数: $redis_keys"
            
            if [ -n "$redis_hits" ] && [ -n "$redis_misses" ] && [ "$redis_hits" -gt 0 ] && [ "$redis_misses" -gt 0 ]; then
                local hit_rate=$(( redis_hits * 100 / (redis_hits + redis_misses) ))
                echo "  命中率: ${hit_rate}%"
                
                if [ "$hit_rate" -lt 70 ]; then
                    echo "  ⚠ 缓存命中率较低，建议检查缓存策略"
                elif [ "$hit_rate" -gt 90 ]; then
                    echo "  ✓ 缓存命中率优秀"
                else
                    echo "  ✓ 缓存命中率良好"
                fi
            fi
        else
            echo "✗ Redis服务未运行"
        fi
    else
        echo "未找到Docker Compose配置文件"
    fi
    
    # 检查端口状态
    echo -e "\n${YELLOW}端口状态:${NC}"
    local ports=("80:HTTP" "443:HTTPS" "8069:Odoo" "8072:Longpolling" "6379:Redis")
    for port_info in "${ports[@]}"; do
        local port=$(echo "$port_info" | cut -d':' -f1)
        local service=$(echo "$port_info" | cut -d':' -f2)
        if [ "$port" = "6379" ]; then
            # Redis端口只在容器内部，检查容器是否运行
            if docker exec morhon-odoo-redis redis-cli ping >/dev/null 2>&1; then
                echo "✓ 端口$port ($service) 容器内运行正常"
            else
                echo "✗ 端口$port ($service) 容器未运行"
            fi
        else
            if netstat -tlnp | grep -q ":$port "; then
                echo "✓ 端口$port ($service) 已监听"
            else
                echo "✗ 端口$port ($service) 未监听"
            fi
        fi
    done
    
    # 系统资源监控
    echo -e "\n${YELLOW}系统资源:${NC}"
    
    # CPU信息
    local cpu_cores=$(nproc)
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${cpu_cores}核心, 使用率: ${cpu_usage}%"
    
    # 内存使用
    local mem_info=$(free -h | grep "Mem:")
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_percent=$(free | grep "Mem:" | awk '{printf "%.1f", $3/$2 * 100.0}')
    echo "内存: ${mem_used}/${mem_total} (${mem_percent}% 已使用)"
    
    # 磁盘空间
    echo -e "\n${YELLOW}磁盘空间:${NC}"
    df -h / | tail -1 | awk '{print "根分区: " $3 "/" $2 " (" $5 " 已使用)"}'
    
    # Docker卷空间
    if command -v docker &> /dev/null; then
        local docker_space=$(docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}" 2>/dev/null | grep -E "Images|Containers|Local Volumes" || echo "无法获取Docker空间信息")
        echo -e "\n${YELLOW}Docker存储:${NC}"
        echo "$docker_space"
    fi
    
    # 网络连接统计
    echo -e "\n${YELLOW}网络连接:${NC}"
    local connections=$(netstat -an | grep -E ":80|:443|:8069|:8072" | wc -l)
    echo "活跃连接数: $connections"
    
    # 负载平均值
    local load_avg=$(uptime | awk -F'load average:' '{print $2}')
    echo "系统负载:$load_avg"
    
    # 检查SSL证书（如果是域名模式）
    if [ -f "$INSTANCE_DIR/.env" ]; then
        local domain=$(grep "^DOMAIN=" "$INSTANCE_DIR/.env" | cut -d'=' -f2)
        if [ -n "$domain" ] && [ "$domain" != "" ]; then
            echo -e "\n${YELLOW}SSL证书状态:${NC}"
            if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
                local cert_expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" | cut -d= -f2)
                local days_left=$(( ($(date -d "$cert_expiry" +%s) - $(date +%s)) / 86400 ))
                echo "✓ SSL证书存在，到期时间: $cert_expiry"
                if [ "$days_left" -lt 30 ]; then
                    echo "⚠ 警告: SSL证书将在 $days_left 天后过期"
                else
                    echo "✓ SSL证书有效期充足 ($days_left 天)"
                fi
            else
                echo "✗ SSL证书不存在"
            fi
        fi
    fi
    
    # 系统优化状态检查
    echo -e "\n${YELLOW}系统优化状态:${NC}"
    
    # 检查内核参数优化
    if [ -f "/etc/sysctl.d/99-morhon-odoo.conf" ]; then
        echo "✓ 内核参数已优化"
    else
        echo "✗ 内核参数未优化"
    fi
    
    # 检查系统限制优化
    if [ -f "/etc/security/limits.d/99-morhon-odoo.conf" ]; then
        echo "✓ 系统限制已优化"
    else
        echo "✗ 系统限制未优化"
    fi
    
    # 检查Docker优化
    if [ -f "/etc/docker/daemon.json" ]; then
        echo "✓ Docker配置已优化"
    else
        echo "✗ Docker配置未优化"
    fi
    
    # 外贸系统安全检查
    echo -e "\n${YELLOW}外贸系统安全状态:${NC}"
    
    # 检查防火墙状态
    if ufw status | grep -q "Status: active"; then
        echo "✓ 防火墙已启用"
        local blocked_ports=$(ufw status | grep -c "DENY")
        echo "  已阻止 $blocked_ports 个危险端口"
    else
        echo "✗ 防火墙未启用"
    fi
    
    # 检查fail2ban状态
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "✓ fail2ban入侵防护已启用"
        local banned_ips=$(fail2ban-client status 2>/dev/null | grep -o "Jail list:.*" | wc -w)
        [ "$banned_ips" -gt 2 ] && echo "  监控 $((banned_ips - 2)) 个服务"
    else
        echo "⚠ fail2ban未安装或未启用"
    fi
    
    # 检查数据库安全
    if docker exec morhon-odoo-db psql -U odoo -d postgres -c "SELECT version();" >/dev/null 2>&1; then
        echo "✓ 数据库连接安全"
        local db_connections=$(docker exec morhon-odoo-db psql -U odoo -d postgres -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | grep -E "^\s*[0-9]+\s*$" | tr -d ' ')
        [ -n "$db_connections" ] && echo "  当前连接数: $db_connections"
    else
        echo "✗ 数据库连接异常"
    fi
    
    # 外贸系统性能建议
    echo -e "\n${YELLOW}外贸系统性能建议:${NC}"
    
    # CPU使用率建议
    if (( $(echo "$cpu_usage > 80" | bc -l) )); then
        echo "⚠ CPU使用率较高，建议检查Odoo worker配置或升级CPU"
    fi
    
    # 内存使用建议
    if (( $(echo "$mem_percent > 85" | bc -l) )); then
        echo "⚠ 内存使用率较高，建议优化Odoo内存配置或增加内存"
    fi
    
    # 磁盘空间建议
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt 85 ]; then
        echo "⚠ 磁盘空间不足，建议清理日志和备份文件"
    fi
    
    # Redis缓存建议
    if docker exec morhon-odoo-redis redis-cli ping >/dev/null 2>&1; then
        local redis_keys=$(docker exec morhon-odoo-redis redis-cli dbsize 2>/dev/null | tr -d '\r')
        local redis_hits=$(docker exec morhon-odoo-redis redis-cli info stats 2>/dev/null | grep "keyspace_hits:" | cut -d':' -f2 | tr -d '\r')
        local redis_misses=$(docker exec morhon-odoo-redis redis-cli info stats 2>/dev/null | grep "keyspace_misses:" | cut -d':' -f2 | tr -d '\r')
        
        if [ -n "$redis_hits" ] && [ -n "$redis_misses" ] && [ "$redis_hits" -gt 0 ] && [ "$redis_misses" -gt 0 ]; then
            local hit_rate=$(( redis_hits * 100 / (redis_hits + redis_misses) ))
            if [ "$hit_rate" -lt 70 ]; then
                echo "⚠ Redis缓存命中率较低($hit_rate%)，建议优化缓存策略"
            fi
        fi
        
        if [ "$redis_keys" -gt 100000 ]; then
            echo "⚠ Redis缓存键数量较多($redis_keys)，建议定期清理过期缓存"
        fi
    fi
    
    # 外贸业务专用建议
    local current_hour=$(date +%H)
    if [ "$current_hour" -ge 9 ] && [ "$current_hour" -le 18 ]; then
        echo "💡 当前为工作时间，建议避免进行系统维护操作"
    fi
    
    # 数据库连接建议
    if docker exec morhon-odoo-db psql -U odoo -d postgres -c "SELECT count(*) FROM pg_stat_activity;" >/dev/null 2>&1; then
        local db_connections=$(docker exec morhon-odoo-db psql -U odoo -d postgres -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | grep -E "^\s*[0-9]+\s*$" | tr -d ' ')
        if [ -n "$db_connections" ] && [ "$db_connections" -gt 150 ]; then
            echo "⚠ 数据库连接数较多($db_connections)，建议检查连接池配置"
        fi
    fi
    
    echo ""
}

# 显示实例状态
show_instance_status() {
    echo ""
    echo -e "${CYAN}实例状态:${NC}"
    cd "$INSTANCE_DIR"
    docker-compose ps
    echo ""
    echo -e "${CYAN}卷状态:${NC}"
    docker volume ls | grep -E "($DB_VOLUME_NAME|$ODOO_VOLUME_NAME|morhon-redis)"
}

# 重启实例
restart_instance() {
    echo ""
    cd "$INSTANCE_DIR"
    docker-compose restart
    systemctl reload nginx
    log "实例已重启"
}

# 显示日志
show_logs() {
    echo ""
    echo "1) Odoo日志"
    echo "2) 数据库日志"
    echo "3) Nginx日志"
    read -p "选择日志类型 (1-3): " log_type
    
    case $log_type in
        1) cd "$INSTANCE_DIR" && docker-compose logs -f odoo ;;
        2) cd "$INSTANCE_DIR" && docker-compose logs -f db ;;
        3) tail -f /var/log/nginx/error.log ;;
        *) log_error "无效选择" ;;
    esac
}

# 备份实例
backup_instance() {
    echo ""
    local backup_name="backup_$(date '+%Y%m%d_%H%M%S')"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    mkdir -p "$backup_path"
    
    log "开始备份实例..."
    
    # 备份数据库
    log "备份数据库..."
    cd "$INSTANCE_DIR"
    if docker-compose exec -T db pg_dump -U odoo postgres | gzip > "$backup_path/database.sql.gz"; then
        log "数据库备份完成"
    else
        log_error "数据库备份失败"
        return 1
    fi
    
    # 备份Redis缓存数据
    log "备份Redis缓存..."
    if docker-compose exec -T redis redis-cli --rdb /data/dump.rdb >/dev/null 2>&1; then
        docker cp morhon-odoo-redis:/data/dump.rdb "$backup_path/redis-dump.rdb" 2>/dev/null || log_warn "Redis备份复制失败"
        log "Redis缓存备份完成"
    else
        log_warn "Redis缓存备份失败，继续其他备份"
    fi
    
    # 备份配置文件
    log "备份配置文件..."
    cp -r "$INSTANCE_DIR/config" "$backup_path/" 2>/dev/null || true
    cp "$INSTANCE_DIR/docker-compose.yml" "$backup_path/" 2>/dev/null || true
    cp "$INSTANCE_DIR/.env" "$backup_path/" 2>/dev/null || true
    
    # 备份Nginx配置
    if [ -f "/etc/nginx/sites-available/morhon-odoo" ]; then
        cp "/etc/nginx/sites-available/morhon-odoo" "$backup_path/nginx-config" 2>/dev/null || true
    fi
    
    # 创建备份信息文件
    cat > "$backup_path/backup_info.txt" << EOF
备份信息
========
备份时间: $(date '+%Y-%m-%d %H:%M:%S')
脚本版本: 6.2
实例目录: $INSTANCE_DIR
备份类型: 完整备份（包含Redis缓存）

包含内容:
- 数据库完整备份 (database.sql.gz)
- Redis缓存备份 (redis-dump.rdb)
- Odoo配置文件 (config/)
- Docker Compose配置 (docker-compose.yml)
- 环境变量 (.env)
- Nginx配置 (nginx-config)

恢复方法:
1. 解压备份文件
2. 运行脚本选择"从本地备份恢复"
3. 选择此备份文件

注意事项:
- Redis缓存会在系统启动后自动重建
- 如果Redis备份文件不存在，不影响系统正常运行
EOF
    
    # 打包备份
    cd "$BACKUP_DIR"
    if tar -czf "${backup_name}.tar.gz" "$backup_name"; then
        rm -rf "$backup_path"
        log "备份完成: $BACKUP_DIR/${backup_name}.tar.gz"
        
        # 显示备份大小
        local backup_size=$(du -h "$BACKUP_DIR/${backup_name}.tar.gz" | cut -f1)
        log "备份文件大小: $backup_size"
        
        return 0
    else
        log_error "备份打包失败"
        return 1
    fi
}

# 修改配置
modify_config() {
    echo ""
    echo "1) 修改管理员密码"
    echo "2) 修改数据库密码"
    echo "3) 修改Nginx配置"
    echo "4) Redis缓存管理"
    read -p "选择操作 (1-4): " config_choice
    
    case $config_choice in
        1) update_admin_password ;;
        2) update_db_password ;;
        3) update_nginx_config ;;
        4) manage_redis_cache ;;
        *) log_error "无效选择" ;;
    esac
}

# 更新管理员密码
update_admin_password() {
    read -p "输入新管理员密码: " new_pass
    sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$new_pass/" "$INSTANCE_DIR/.env"
    cd "$INSTANCE_DIR" && docker-compose restart odoo
    log "管理员密码已更新"
}

# 更新数据库密码
update_db_password() {
    read -p "输入新数据库密码: " new_pass
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$new_pass/" "$INSTANCE_DIR/.env"
    cd "$INSTANCE_DIR" && docker-compose restart
    log "数据库密码已更新"
}

# 更新Nginx配置
update_nginx_config() {
    nano /etc/nginx/sites-available/morhon-odoo
    nginx -t && systemctl reload nginx
    log "Nginx配置已更新"
}

# Redis缓存管理
manage_redis_cache() {
    echo ""
    echo -e "${CYAN}Redis缓存管理${NC}"
    echo "=================="
    
    if ! docker exec morhon-odoo-redis redis-cli ping >/dev/null 2>&1; then
        echo "Redis服务未运行"
        return 1
    fi
    
    echo "1) 查看缓存统计"
    echo "2) 清空所有缓存"
    echo "3) 清空会话缓存"
    echo "4) 查看缓存配置"
    echo "5) 返回"
    read -p "选择操作 (1-5): " redis_choice
    
    case $redis_choice in
        1) show_redis_stats ;;
        2) clear_all_cache ;;
        3) clear_session_cache ;;
        4) show_redis_config ;;
        5) return ;;
        *) log_error "无效选择" ;;
    esac
}

# 显示Redis统计信息
show_redis_stats() {
    echo ""
    echo -e "${YELLOW}Redis缓存统计:${NC}"
    
    local redis_info=$(docker exec morhon-odoo-redis redis-cli info 2>/dev/null)
    
    # 内存使用
    local used_memory=$(echo "$redis_info" | grep "used_memory_human:" | cut -d':' -f2 | tr -d '\r')
    local used_memory_peak=$(echo "$redis_info" | grep "used_memory_peak_human:" | cut -d':' -f2 | tr -d '\r')
    echo "内存使用: $used_memory (峰值: $used_memory_peak)"
    
    # 键统计
    local total_keys=$(docker exec morhon-odoo-redis redis-cli dbsize 2>/dev/null | tr -d '\r')
    echo "总键数: $total_keys"
    
    # 命中率统计
    local hits=$(echo "$redis_info" | grep "keyspace_hits:" | cut -d':' -f2 | tr -d '\r')
    local misses=$(echo "$redis_info" | grep "keyspace_misses:" | cut -d':' -f2 | tr -d '\r')
    
    if [ -n "$hits" ] && [ -n "$misses" ] && [ "$hits" -gt 0 ] && [ "$misses" -gt 0 ]; then
        local hit_rate=$(( hits * 100 / (hits + misses) ))
        echo "缓存命中: $hits 次"
        echo "缓存未命中: $misses 次"
        echo "命中率: ${hit_rate}%"
    fi
    
    # 连接数
    local connected_clients=$(echo "$redis_info" | grep "connected_clients:" | cut -d':' -f2 | tr -d '\r')
    echo "连接客户端: $connected_clients"
    
    # 各数据库键数
    echo ""
    echo "各数据库键数:"
    for db in {0..15}; do
        local db_keys=$(docker exec morhon-odoo-redis redis-cli -n $db dbsize 2>/dev/null | tr -d '\r')
        if [ "$db_keys" -gt 0 ]; then
            case $db in
                0) echo "  DB$db (应用缓存): $db_keys 键" ;;
                1) echo "  DB$db (会话数据): $db_keys 键" ;;
                *) echo "  DB$db: $db_keys 键" ;;
            esac
        fi
    done
}

# 清空所有缓存
clear_all_cache() {
    echo ""
    echo "⚠️  警告: 此操作将清空所有Redis缓存数据"
    read -p "确认清空所有缓存？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker exec morhon-odoo-redis redis-cli flushall >/dev/null 2>&1
        log "所有缓存已清空"
        echo "系统将自动重建缓存，可能会暂时影响性能"
    else
        log "取消操作"
    fi
}

# 清空会话缓存
clear_session_cache() {
    echo ""
    echo "清空会话缓存将导致所有用户需要重新登录"
    read -p "确认清空会话缓存？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker exec morhon-odoo-redis redis-cli -n 1 flushdb >/dev/null 2>&1
        log "会话缓存已清空"
        echo "所有用户需要重新登录"
    else
        log "取消操作"
    fi
}

# 显示Redis配置
show_redis_config() {
    echo ""
    echo -e "${YELLOW}Redis配置信息:${NC}"
    
    local redis_config=$(docker exec morhon-odoo-redis redis-cli config get "*" 2>/dev/null)
    
    echo "最大内存: $(docker exec morhon-odoo-redis redis-cli config get maxmemory 2>/dev/null | tail -1 | tr -d '\r') bytes"
    echo "内存策略: $(docker exec morhon-odoo-redis redis-cli config get maxmemory-policy 2>/dev/null | tail -1 | tr -d '\r')"
    echo "持久化: $(docker exec morhon-odoo-redis redis-cli config get save 2>/dev/null | tail -1 | tr -d '\r')"
    echo "AOF: $(docker exec morhon-odoo-redis redis-cli config get appendonly 2>/dev/null | tail -1 | tr -d '\r')"
    
    local redis_version=$(docker exec morhon-odoo-redis redis-cli info server 2>/dev/null | grep "redis_version:" | cut -d':' -f2 | tr -d '\r')
    echo "Redis版本: $redis_version"
}

# 优化现有实例
optimize_existing_instance() {
    echo ""
    echo -e "${CYAN}茂亨Odoo专用服务器优化${NC}"
    echo "================================"
    echo ""
    echo "此操作将对现有实例进行全面优化："
    echo "• 系统内核参数优化"
    echo "• Docker配置优化"
    echo "• Nginx配置优化"
    echo "• Odoo配置优化"
    echo "• 数据库性能优化"
    echo ""
    
    if ! confirm_action "确认执行专用服务器优化？这将重启相关服务"; then
        log "取消优化操作"
        return 1
    fi
    
    log "开始优化现有实例..."
    
    # 1. 系统优化
    if [ ! -f "/etc/sysctl.d/99-morhon-odoo.conf" ]; then
        log "执行系统优化..."
        optimize_system_for_odoo
    else
        log "系统优化已存在，跳过"
    fi
    
    # 2. 重新生成优化配置
    log "重新生成优化配置..."
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    local workers=$(calculate_workers "$cpu_cores" "$total_mem")
    
    # 备份现有配置
    local backup_suffix=$(date '+%Y%m%d_%H%M%S')
    cp "$INSTANCE_DIR/config/odoo.conf" "$INSTANCE_DIR/config/odoo.conf.backup.$backup_suffix" 2>/dev/null || true
    cp "$INSTANCE_DIR/docker-compose.yml" "$INSTANCE_DIR/docker-compose.yml.backup.$backup_suffix" 2>/dev/null || true
    
    # 生成新的优化配置
    create_odoo_config "$workers" "$total_mem"
    create_docker_compose_config
    
    # 3. 优化Nginx配置
    log "优化Nginx配置..."
    configure_nginx
    
    # 检查当前部署类型
    local deployment_type="local"
    local domain=""
    local use_www="no"
    
    if [ -f "$INSTANCE_DIR/.env" ]; then
        domain=$(grep "^DOMAIN=" "$INSTANCE_DIR/.env" | cut -d'=' -f2 2>/dev/null || echo "")
        if [ -n "$domain" ] && [ "$domain" != "" ]; then
            deployment_type="domain"
            if [[ "$domain" == www.* ]]; then
                use_www="yes"
            fi
        fi
    fi
    
    # 重新生成Nginx站点配置
    if [ "$deployment_type" = "domain" ]; then
        create_nginx_domain_config "$domain" "$use_www"
    else
        create_nginx_local_config
    fi
    
    # 4. 重启服务应用优化
    log "重启服务应用优化配置..."
    cd "$INSTANCE_DIR"
    
    # 停止服务
    docker-compose down
    
    # 重启Docker服务以应用新配置
    systemctl restart docker
    sleep 5
    
    # 启动优化后的服务
    docker-compose up -d
    
    # 重启Nginx
    systemctl restart nginx
    
    # 5. 等待服务启动并进行数据库优化
    log "等待服务启动..."
    sleep 15
    
    # 数据库优化
    optimize_database_after_migration
    
    # 6. 显示优化结果
    echo ""
    echo -e "${GREEN}优化完成！${NC}"
    echo "===================="
    echo "优化内容："
    echo "• CPU核心数: $cpu_cores"
    echo "• 内存总量: ${total_mem}GB"
    echo "• Odoo Workers: $workers"
    echo "• 部署模式: $deployment_type"
    [ -n "$domain" ] && echo "• 域名: $domain"
    echo ""
    echo "配置备份："
    echo "• Odoo配置: $INSTANCE_DIR/config/odoo.conf.backup.$backup_suffix"
    echo "• Docker配置: $INSTANCE_DIR/docker-compose.yml.backup.$backup_suffix"
    echo ""
    echo "建议执行系统状态检查验证优化效果"
    
    return 0
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}   茂亨Odoo管理脚本 v6.2${NC}"
    echo -e "${PURPLE}================================${NC}"
    echo ""
    
    # 根据检测结果显示不同菜单
    case "$DETECTED_INSTANCE_TYPE" in
        "script")
            show_script_instance_menu
            ;;
        "manual")
            show_manual_instance_menu
            ;;
        "none")
            show_no_instance_menu
            ;;
    esac
}

# 显示脚本实例菜单
show_script_instance_menu() {
    echo -e "${GREEN}✓ 检测到脚本管理的实例${NC}"
    echo "实例目录: $INSTANCE_DIR"
    echo ""
    echo "1) 管理实例"
    echo "2) 退出"
    echo ""
    read -p "请选择 (1-2): " choice
    
    case $choice in
        1)
            while manage_script_instance; do
                echo ""
                read -p "按回车键继续..."
            done
            ;;
        2) exit 0 ;;
        *) log_error "无效选择" ;;
    esac
}

# 显示手动实例菜单
show_manual_instance_menu() {
    echo -e "${YELLOW}⚠ 检测到手动部署的实例${NC}"
    echo "Odoo容器: $DETECTED_ODOO_CONTAINER"
    [ -n "$DETECTED_DB_CONTAINER" ] && echo "数据库容器: $DETECTED_DB_CONTAINER"
    [ -n "$DETECTED_DOMAIN" ] && echo "域名: $DETECTED_DOMAIN"
    echo ""
    echo "1) 迁移到脚本管理"
    echo "2) 查看容器信息"
    echo "3) 退出"
    echo ""
    read -p "请选择 (1-3): " choice
    
    case $choice in
        1) migrate_manual_instance ;;
        2) show_container_info ;;
        3) exit 0 ;;
        *) log_error "无效选择" ;;
    esac
}

# 显示容器信息
show_container_info() {
    echo ""
    docker ps -a | grep -E "($DETECTED_ODOO_CONTAINER|$DETECTED_DB_CONTAINER)"
    echo ""
    echo "Odoo配置:"
    docker exec "$DETECTED_ODOO_CONTAINER" cat /etc/odoo/odoo.conf 2>/dev/null || echo "无法读取配置"
}

# 显示无实例菜单
show_no_instance_menu() {
    echo -e "${BLUE}○ 未检测到现有实例${NC}"
    echo ""
    echo "1) 全新部署（内网生产环境或公网生产环境）"
    echo "2) 从备份恢复"
    echo "3) 退出"
    echo ""
    read -p "请选择 (1-3): " choice
    
    case $choice in
        1) deploy_new_instance ;;
        2) restore_from_backup ;;
        3) exit 0 ;;
        *) log_error "无效选择" ;;
    esac
}

# 主函数
main() {
    check_sudo
    
    # 一次性检测所有环境信息
    detect_environment
    
    # 显示主菜单
    show_main_menu
}

# 处理命令行参数
if [ $# -ge 1 ]; then
    case "$1" in
        "init")
            check_sudo
            init_environment
            exit 0
            ;;
        "backup")
            check_sudo
            detect_environment
            if [ "$DETECTED_INSTANCE_TYPE" = "script" ]; then
                backup_instance
            else
                log_error "仅支持脚本管理的实例备份"
            fi
            exit 0
            ;;
        "status")
            check_sudo
            detect_environment
            if [ "$DETECTED_INSTANCE_TYPE" = "script" ]; then
                check_system_status
            elif [ "$DETECTED_INSTANCE_TYPE" = "manual" ]; then
                echo "检测到手动部署实例:"
                show_container_info
            else
                echo "未检测到Odoo实例"
            fi
            exit 0
            ;;
        "restore")
            check_sudo
            detect_environment
            restore_from_backup
            exit 0
            ;;
        "help"|"--help"|"-h")
            echo "茂亨Odoo管理脚本 v6.2"
            echo "专为外贸企业设计的Odoo部署和管理工具"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)   启动交互式菜单"
            echo "  init       初始化环境（安装Docker、Nginx等依赖）"
            echo "  backup     备份脚本管理的实例"
            echo "  restore    从备份恢复（自动检测同目录备份文件）"
            echo "  status     显示实例状态"
            echo "  help       显示此帮助信息"
            echo ""
            echo "部署模式:"
            echo "  • 本地模式: 部署在内网环境，通过服务器IP访问（强烈推荐）"
            echo "    - 适用场景: 企业内网、局域网环境"
            echo "    - 访问方式: http://服务器IP"
            echo "    - 优势: 访问速度快，安全性高，维护简单"
            echo ""
            echo "  • 二级域名模式: 通过二级域名访问，专用于企业管理（推荐）"
            echo "    - 适用场景: 远程办公、多地分支"
            echo "    - 访问方式: https://erp.company.com"
            echo "    - 优势: 专业性强，便于管理，安全可控"
            echo ""
            echo "  • 主域名模式: 通过主域名访问（不推荐，与网站功能冲突）"
            echo "    - 说明: 虽然支持但不推荐用于网站功能"
            echo "    - 原因: 服务器位置无法同时优化企业管理和网站访问"
            echo ""
            echo "功能特性:"
            echo "  • 单实例部署设计，确保系统稳定性"
            echo "  • 自动检测现有实例（脚本管理/手动部署）"
            echo "  • 支持内网生产环境和公网生产环境部署"
            echo "  • 自动SSL证书获取和续期（公网模式）"
            echo "  • 完整的备份和恢复功能"
            echo "  • 手动实例迁移到脚本管理"
            echo "  • 外贸业务性能优化和安全加固"
            echo "  • Redis缓存加速和会话管理"
            echo "  • 健康检查和状态监控"
            echo "  • Docker卷映射，防止插件冲突"
            echo ""
            echo "运行逻辑:"
            echo "  1. 检测现有实例类型"
            echo "  2. 脚本实例 → 管理菜单（状态、备份、配置等）"
            echo "  3. 手动实例 → 迁移菜单（迁移到脚本管理）"
            echo "  4. 无实例 → 全新部署菜单（选择内网或公网模式）"
            echo ""
            echo "重要说明:"
            echo "  • 推荐使用本地部署或二级域名部署"
            echo "  • 专注于企业管理功能，不推荐使用网站功能"
            echo "  • 网站功能建议使用WordPress等专业系统"
            echo "  • 数据卷映射：防止用户误操作和插件冲突"
            echo "  • 禁止自装插件：避免系统不稳定和安全风险"
            echo ""
            echo "目录结构:"
            echo "  • 实例目录: /opt/morhon-odoo"
            echo "  • 备份目录: /var/backups/morhon-odoo"
            echo "  • 日志目录: /var/log/morhon-odoo"
            echo ""
            echo "技术支持: https://github.com/morhon-tech/morhon-odoo"
            exit 0
            ;;
    esac
fi

# 执行主函数
main "$@"
