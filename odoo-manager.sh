#!/bin/bash

# 茂亨Odoo外贸专用版管理脚本 - 优化版
# 单实例版本，支持本地模式和域名模式
# 版本: 6.0
# GitHub: https://github.com/morhon-tech/morhon-odoo

set -e

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DIR="/opt/morhon-odoo"
BACKUP_DIR="/var/backups/morhon-odoo"
LOG_DIR="/var/log/morhon-odoo"

# 固定卷名
DB_VOLUME_NAME="odoo-db-data"
ODOO_VOLUME_NAME="odoo-web-data"

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
HAS_LOCAL_BACKUP=false

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
    # 查找使用茂亨镜像的容器
    local odoo_container=$(docker ps -a --filter "ancestor=$ODOO_IMAGE" --format "{{.Names}}" 2>/dev/null | head -1)
    
    if [ -z "$odoo_container" ]; then
        # 查找名称包含morhon或odoo的容器
        odoo_container=$(docker ps -a --filter "name=morhon" --format "{{.Names}}" 2>/dev/null | head -1)
        [ -z "$odoo_container" ] && odoo_container=$(docker ps -a --filter "name=odoo" --format "{{.Names}}" 2>/dev/null | head -1)
    fi
    
    if [ -n "$odoo_container" ]; then
        DETECTED_INSTANCE_TYPE="manual"
        DETECTED_ODOO_CONTAINER="$odoo_container"
        
        # 获取数据库容器
        DETECTED_DB_CONTAINER=$(docker ps -a --filter "name=postgres" --format "{{.Names}}" 2>/dev/null | head -1)
        [ -z "$DETECTED_DB_CONTAINER" ] && DETECTED_DB_CONTAINER=$(docker ps -a --filter "name=db" --format "{{.Names}}" 2>/dev/null | head -1)
        
        # 尝试从容器获取域名和密码
        extract_instance_info
        log "检测到手动部署的实例: $DETECTED_ODOO_CONTAINER"
        return 0
    fi
    
    # 3. 无实例，检查脚本目录下是否有备份文件
    DETECTED_INSTANCE_TYPE="none"
    
    # 检查备份文件（.tar.gz格式）
    local backup_files=($(find "$SCRIPT_DIR" -maxdepth 1 -name "*.tar.gz" -type f))
    if [ ${#backup_files[@]} -gt 0 ]; then
        HAS_LOCAL_BACKUP=true
        log "检测到脚本目录下的备份文件: ${#backup_files[@]}个"
    fi
    
    return 0
}

# 从手动部署实例提取信息
extract_instance_info() {
    log_info "从手动部署实例提取信息..."
    
    # 1. 尝试从odoo容器获取odoo.conf内容
    if [ -n "$DETECTED_ODOO_CONTAINER" ]; then
        # 获取odoo.conf配置文件内容
        local odoo_conf_content=$(docker exec "$DETECTED_ODOO_CONTAINER" cat /etc/odoo/odoo.conf 2>/dev/null || docker exec "$DETECTED_ODOO_CONTAINER" cat /odoo/config/odoo.conf 2>/dev/null || true)
        
        if [ -n "$odoo_conf_content" ]; then
            # 提取管理员密码
            local admin_passwd=$(echo "$odoo_conf_content" | grep "^admin_passwd" | cut -d'=' -f2 | sed 's/[[:space:]]*//g')
            [ -n "$admin_passwd" ] && log "提取到管理员密码"
            
            # 提取数据库名（可能是域名）
            local db_name=$(echo "$odoo_conf_content" | grep "^db_name" | cut -d'=' -f2 | sed 's/[[:space:]]*//g')
            if [[ "$db_name" == *.* ]]; then
                # 从数据库名中提取域名（例如 trade.morhon.com -> morhon.com）
                DETECTED_DOMAIN=$(echo "$db_name" | awk -F'.' '{print $(NF-1)"."$NF}')
                log "从数据库名提取到域名: $DETECTED_DOMAIN (原始: $db_name)"
            fi
        fi
        
        # 尝试从容器环境变量获取域名
        if [ -z "$DETECTED_DOMAIN" ]; then
            local env_vars=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true)
            DETECTED_DOMAIN=$(echo "$env_vars" | grep -E "DOMAIN|HOSTNAME" | cut -d'=' -f2 | head -1)
        fi
    fi
    
    # 2. 尝试从数据库容器获取密码
    if [ -n "$DETECTED_DB_CONTAINER" ]; then
        DETECTED_DB_PASSWORD=$(docker exec "$DETECTED_DB_CONTAINER" env 2>/dev/null | grep "POSTGRES_PASSWORD" | cut -d'=' -f2 || echo "odoo")
        log "提取到数据库密码"
    fi
    
    # 3. 尝试从Nginx配置获取域名
    if [ -z "$DETECTED_DOMAIN" ]; then
        if [ -d "/etc/nginx/sites-enabled" ]; then
            local nginx_domain=$(grep -r "server_name" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "_" | head -1 | awk '{print $2}' | sed 's/;//')
            if [[ "$nginx_domain" == *.* ]] && [ "$nginx_domain" != "localhost" ]; then
                DETECTED_DOMAIN="$nginx_domain"
                log "从Nginx配置提取到域名: $DETECTED_DOMAIN"
            fi
        fi
    fi
    
    return 0
}

# 获取服务器IP地址
get_server_ip() {
    local ip=""
    
    # 方法1: 使用ip命令
    ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || true)
    
    # 方法2: 使用curl
    if [ -z "$ip" ] || [[ "$ip" == *" "* ]] || [[ "$ip" == "127.0.0.1" ]]; then
        ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || true)
    fi
    
    # 方法3: 使用hostname
    if [ -z "$ip" ] || [[ "$ip" == *" "* ]] || [[ "$ip" == "127.0.0.1" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    if [ -z "$ip" ] || [[ "$ip" == *" "* ]]; then
        ip="127.0.0.1"
    fi
    
    echo "$ip"
}

# 初始化环境
init_environment() {
    log "初始化环境..."
    
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
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log "安装Docker..."
        # 添加Docker官方GPG密钥
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        log "Docker安装完成"
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log "安装Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # 配置防火墙
    configure_firewall
    
    # 配置Nginx
    configure_nginx
    
    log "环境初始化完成"
    return 0
}

# 配置防火墙
configure_firewall() {
    log "配置防火墙..."
    
    # 重置防火墙规则
    ufw --force reset
    
    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH
    ufw allow 22/tcp
    log "已允许SSH端口 (22/tcp)"
    
    # 允许HTTP
    ufw allow 80/tcp
    log "已允许HTTP端口 (80/tcp)"
    
    # 允许HTTPS
    ufw allow 443/tcp
    log "已允许HTTPS端口 (443/tcp)"
    
    # 启用UFW
    ufw --force enable
    
    log "防火墙配置完成"
}

# 配置Nginx
configure_nginx() {
    log "配置Nginx..."
    
    # 备份原始配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    
    # 创建优化的nginx配置
    tee /etc/nginx/nginx.conf > /dev/null << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    # 基本设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # 限制请求大小
    client_max_body_size 100M;
    client_body_timeout 120s;
    
    # Gzip压缩
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
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # SSL设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    
    # 包含其他配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 创建站点目录
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    # 测试配置
    nginx -t
    
    # 重启Nginx
    systemctl restart nginx
    
    log "Nginx配置完成"
}

# 创建Docker卷
create_docker_volumes() {
    log "创建Docker卷..."
    
    if ! docker volume ls | grep -q "$DB_VOLUME_NAME"; then
        docker volume create "$DB_VOLUME_NAME"
        log "创建数据库卷: $DB_VOLUME_NAME"
    else
        log "数据库卷已存在: $DB_VOLUME_NAME"
    fi
    
    if ! docker volume ls | grep -q "$ODOO_VOLUME_NAME"; then
        docker volume create "$ODOO_VOLUME_NAME"
        log "创建Odoo文件卷: $ODOO_VOLUME_NAME"
    else
        log "Odoo文件卷已存在: $ODOO_VOLUME_NAME"
    fi
    
    log "Docker卷创建完成"
}

# 拉取Docker镜像
get_docker_image() {
    local image_name="$1"
    
    log "拉取Docker镜像: $image_name"
    
    # 先尝试直接拉取
    if docker pull "$image_name" >/dev/null 2>&1; then
        log "镜像拉取成功: $image_name"
        return 0
    fi
    
    log_warn "镜像拉取失败，尝试使用备用源..."
    
    # 尝试官方镜像源
    if [[ "$image_name" == *"morhon_hub"* ]]; then
        # 如果是茂亨镜像，尝试不同标签
        local backup_image="morhon_hub/mh_odoosaas_v17:latest"
        log "尝试备用镜像: $backup_image"
        if docker pull "$backup_image" >/dev/null 2>&1; then
            log "备用镜像拉取成功: $backup_image"
            docker tag "$backup_image" "$image_name"
            return 0
        fi
    fi
    
    log_error "无法拉取镜像，请检查网络连接"
    return 1
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
    local workers=4
    [ $cpu_cores -ge 8 ] && workers=8
    [ $cpu_cores -ge 4 ] && workers=6
    [ $cpu_cores -ge 2 ] && workers=4
    [ $cpu_cores -eq 1 ] && workers=2
    
    # 创建目录结构
    mkdir -p "$INSTANCE_DIR/config"
    mkdir -p "$INSTANCE_DIR/backups"
    mkdir -p "$INSTANCE_DIR/logs"
    
    # 创建odoo配置文件
    cat > "$INSTANCE_DIR/config/odoo.conf" << EOF
[options]
admin_passwd = \${ADMIN_PASSWORD}
addons_path = /mnt/extra-addons,/mnt/odoo/addons
data_dir = /var/lib/odoo
without_demo = all
proxy_mode = True
workers = $workers
limit_memory_hard = $((total_mem * 256))M
limit_memory_soft = $((total_mem * 192))M
max_cron_threads = $((workers / 2))
db_name = postgres
list_db = False
EOF
    
    # 创建docker-compose.yml
    cat > "$INSTANCE_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  db:
    image: $POSTGRES_IMAGE
    container_name: morhon-odoo-db
    restart: always
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - $DB_VOLUME_NAME:/var/lib/postgresql/data/pgdata
      - $INSTANCE_DIR/backups:/backups
    networks:
      - morhon-network

  odoo:
    image: $ODOO_IMAGE
    container_name: morhon-odoo
    restart: always
    depends_on:
      - db
    environment:
      HOST: db
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      DB_NAME: postgres
      ADMIN_PASSWORD: \${ADMIN_PASSWORD}
    volumes:
      - $INSTANCE_DIR/config/odoo.conf:/etc/odoo/odoo.conf
      - $ODOO_VOLUME_NAME:/var/lib/odoo
      - $INSTANCE_DIR/logs:/var/log/odoo
    ports:
      - "127.0.0.1:8069:8069"
      - "127.0.0.1:8072:8072"
    networks:
      - morhon-network

networks:
  morhon-network:
    external: false
    name: morhon-network

volumes:
  $DB_VOLUME_NAME:
    external: true
  $ODOO_VOLUME_NAME:
    external: true
EOF
    
    # 创建环境变量文件
    local db_password="${DETECTED_DB_PASSWORD:-$(openssl rand -base64 32)}"
    cat > "$INSTANCE_DIR/.env" << EOF
# 茂亨Odoo环境变量
DB_PASSWORD=$db_password
ADMIN_PASSWORD=$(openssl rand -base64 24)
DEPLOYMENT_TYPE=$deployment_type
DOMAIN=$domain
USE_WWW=$use_www
EOF
    
    # 根据部署类型创建Nginx配置
    if [ "$deployment_type" = "domain" ]; then
        create_nginx_domain_config "$domain" "$use_www"
    else
        create_nginx_local_config
    fi
    
    log "配置文件生成完成"
}

# 创建Nginx域名配置
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
# 茂亨Odoo域名模式 - $domain

# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $server_name;
    
    # Certbot验证
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    # 重定向到HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS服务器
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_name;
    
    # SSL证书（Certbot会自动配置）
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    
    # 安全头部
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
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
    
    log "Nginx域名配置创建完成"
}

# 创建Nginx本地配置
create_nginx_local_config() {
    local config_file="/etc/nginx/sites-available/morhon-odoo"
    local server_ip=$(get_server_ip)
    
    tee "$config_file" > /dev/null << EOF
# 茂亨Odoo本地模式 - 通过IP访问

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
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
    
    log "Nginx本地配置创建完成"
    log "将通过IP地址访问: http://$server_ip"
}

# 获取SSL证书
get_ssl_certificate() {
    local domain="$1"
    local use_www="$2"
    
    log "获取SSL证书..."
    
    # 创建Certbot目录
    mkdir -p /var/www/certbot
    
    # 根据是否使用www生成域名列表
    local domains
    if [ "$use_www" = "yes" ]; then
        domains="$domain www.$domain"
    else
        domains="$domain"
    fi
    
    # 临时配置Nginx用于验证
    local temp_config="/etc/nginx/sites-available/certbot-temp"
    tee "$temp_config" > /dev/null << EOF
server {
    listen 80;
    server_name $domains;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 404;
    }
}
EOF
    
    ln -sf "$temp_config" "/etc/nginx/sites-enabled/certbot-temp"
    systemctl reload nginx
    
    # 获取证书
    if certbot certonly --webroot \
        -w /var/www/certbot \
        -d $domains \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain" \
        --force-renewal; then
        log "SSL证书获取成功"
        # 清理临时配置
        rm -f /etc/nginx/sites-enabled/certbot-temp
        rm -f "$temp_config"
        return 0
    else
        log_warn "无法获取SSL证书，将使用HTTP"
        # 清理临时配置
        rm -f /etc/nginx/sites-enabled/certbot-temp
        rm -f "$temp_config"
        return 1
    fi
}

# 迁移手动部署实例到脚本管理
migrate_manual_instance() {
    log "开始迁移手动部署实例..."
    
    # 确认迁移
    echo ""
    echo -e "${YELLOW}迁移操作将执行以下步骤:${NC}"
    echo "  1. 备份现有数据"
    echo "  2. 停止并删除旧容器"
    echo "  3. 创建脚本管理实例"
    echo "  4. 恢复数据到新实例"
    echo ""
    read -p "是否继续？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "取消迁移"
        return 1
    fi
    
    # 备份现有数据
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/migration_$backup_timestamp"
    mkdir -p "$backup_path"
    
    log "备份现有数据..."
    
    # 备份数据库
    if [ -n "$DETECTED_DB_CONTAINER" ]; then
        docker exec "$DETECTED_DB_CONTAINER" pg_dumpall -U postgres | gzip > "$backup_path/database.sql.gz" 2>/dev/null || \
        docker exec "$DETECTED_DB_CONTAINER" pg_dumpall -U odoo | gzip > "$backup_path/database.sql.gz" 2>/dev/null || \
        log_warn "数据库备份失败"
    fi
    
    # 询问部署模式
    local deployment_type="local"
    local domain=""
    local use_www="no"
    
    if [ -n "$DETECTED_DOMAIN" ]; then
        echo "检测到现有域名: $DETECTED_DOMAIN"
        read -p "是否使用此域名？(Y/n): " use_domain
        if [[ ! "$use_domain" =~ ^[Nn]$ ]]; then
            deployment_type="domain"
            domain="$DETECTED_DOMAIN"
            
            read -p "是否同时支持www.$domain？(y/N): " use_www_choice
            [[ "$use_www_choice" =~ ^[Yy]$ ]] && use_www="yes"
        fi
    fi
    
    # 如果没有域名，询问是否使用域名模式
    if [ -z "$domain" ]; then
        read -p "是否使用域名模式？(y/N): " use_domain
        if [[ "$use_domain" =~ ^[Yy]$ ]]; then
            deployment_type="domain"
            read -p "请输入域名: " domain
            [ -z "$domain" ] && deployment_type="local"
        fi
    fi
    
    # 停止并删除旧容器
    log "清理旧容器..."
    [ -n "$DETECTED_ODOO_CONTAINER" ] && docker stop "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_DB_CONTAINER" ] && docker stop "$DETECTED_DB_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_ODOO_CONTAINER" ] && docker rm "$DETECTED_ODOO_CONTAINER" 2>/dev/null || true
    [ -n "$DETECTED_DB_CONTAINER" ] && docker rm "$DETECTED_DB_CONTAINER" 2>/dev/null || true
    
    # 创建新的脚本管理实例
    log "创建新实例..."
    
    # 创建Docker卷
    create_docker_volumes
    
    # 生成配置文件
    generate_docker_compose "$deployment_type" "$domain" "$use_www"
    
    # 如果是域名模式，获取SSL证书
    if [ "$deployment_type" = "domain" ]; then
        get_ssl_certificate "$domain" "$use_www"
    fi
    
    # 拉取Docker镜像
    get_docker_image "$POSTGRES_IMAGE"
    get_docker_image "$ODOO_IMAGE"
    
    # 启动服务
    cd "$INSTANCE_DIR"
    docker-compose up -d
    
    # 等待数据库启动
    sleep 10
    
    # 恢复数据库（如果有备份）
    if [ -f "$backup_path/database.sql.gz" ]; then
        log "恢复数据库..."
        gunzip -c "$backup_path/database.sql.gz" | docker exec -i morhon-odoo-db psql -U odoo postgres 2>/dev/null || \
        log_warn "数据库恢复失败，新实例将使用空数据库"
    fi
    
    # 重启Nginx
    systemctl reload nginx
    
    log "迁移完成！"
    log "实例目录: $INSTANCE_DIR"
    log "备份文件: $backup_path"
    
    if [ "$deployment_type" = "domain" ]; then
        log "访问地址: https://$domain"
    else
        local server_ip=$(get_server_ip)
        log "访问地址: http://$server_ip"
    fi
    
    return 0
}

# 从本地备份恢复
restore_from_backup() {
    log "从本地备份恢复..."
    
    # 列出备份文件
    local backup_files=($(find "$SCRIPT_DIR" -maxdepth 1 -name "*.tar.gz" -type f))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        log_error "未找到备份文件"
        return 1
    fi
    
    echo "发现备份文件:"
    for i in "${!backup_files[@]}"; do
        echo "$((i+1))) $(basename "${backup_files[$i]}")"
    done
    
    read -p "选择要恢复的备份文件 (1-${#backup_files[@]}) [默认: 1]: " choice
    choice=${choice:-1}
    
    if [ $choice -lt 1 ] || [ $choice -gt ${#backup_files[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local backup_file="${backup_files[$((choice-1))]}"
    log "正在恢复: $(basename "$backup_file")"
    
    # 询问域名
    echo ""
    echo "请输入域名（直接回车将使用本地模式）:"
    read -p "域名: " domain
    
    local deployment_type="local"
    local use_www="no"
    
    if [ -n "$domain" ]; then
        deployment_type="domain"
        read -p "是否同时支持www.$domain？(y/N): " use_www_choice
        [[ "$use_www_choice" =~ ^[Yy]$ ]] && use_www="yes"
    fi
    
    # 解压备份
    local temp_dir="/tmp/restore_$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$temp_dir"
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # 查找备份数据
    local backup_data=$(find "$temp_dir" -name "database.sql.gz" -type f | head -1)
    if [ -z "$backup_data" ]; then
        log_error "备份文件中未找到数据库文件"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 创建Docker卷
    create_docker_volumes
    
    # 生成配置文件
    generate_docker_compose "$deployment_type" "$domain" "$use_www"
    
    # 如果是域名模式，获取SSL证书
    if [ "$deployment_type" = "domain" ]; then
        get_ssl_certificate "$domain" "$use_www"
    fi
    
    # 拉取Docker镜像
    get_docker_image "$POSTGRES_IMAGE"
    get_docker_image "$ODOO_IMAGE"
    
    # 启动数据库
    cd "$INSTANCE_DIR"
    docker-compose up -d db
    
    # 等待数据库启动
    sleep 10
    
    # 恢复数据库
    log "恢复数据库..."
    gunzip -c "$backup_data" | docker exec -i morhon-odoo-db psql -U odoo postgres 2>/dev/null || \
    log_warn "数据库恢复失败，将使用空数据库"
    
    # 启动所有服务
    docker-compose up -d
    
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
    
    return 0
}

# 全新部署
deploy_new_instance() {
    log "全新部署茂亨Odoo..."
    
    # 询问域名
    echo ""
    echo "请输入域名（直接回车将使用本地模式）:"
    read -p "域名: " domain
    
    local deployment_type="local"
    local use_www="no"
    
    if [ -n "$domain" ]; then
        deployment_type="domain"
        read -p "是否同时支持www.$domain？(y/N): " use_www_choice
        [[ "$use_www_choice" =~ ^[Yy]$ ]] && use_www="yes"
    fi
    
    # 初始化环境（如果需要）
    if ! command -v docker &> /dev/null || ! command -v nginx &> /dev/null; then
        read -p "检测到缺少依赖，是否初始化环境？(Y/n): " init_env
        if [[ ! "$init_env" =~ ^[Nn]$ ]]; then
            init_environment
        fi
    fi
    
    # 创建Docker卷
    create_docker_volumes
    
    # 生成配置文件
    generate_docker_compose "$deployment_type" "$domain" "$use_www"
    
    # 如果是域名模式，获取SSL证书
    if [ "$deployment_type" = "domain" ]; then
        get_ssl_certificate "$domain" "$use_www"
    fi
    
    # 拉取Docker镜像
    get_docker_image "$POSTGRES_IMAGE"
    get_docker_image "$ODOO_IMAGE"
    
    # 启动服务
    cd "$INSTANCE_DIR"
    docker-compose up -d
    
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

# 管理脚本部署的实例
manage_script_instance() {
    echo ""
    echo -e "${GREEN}脚本管理实例菜单${NC}"
    echo "实例目录: $INSTANCE_DIR"
    echo ""
    echo "1) 查看实例状态"
    echo "2) 重启实例"
    echo "3) 查看日志"
    echo "4) 备份实例"
    echo "5) 修改配置"
    echo "6) 返回主菜单"
    echo ""
    read -p "请选择操作 (1-6): " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${CYAN}实例状态:${NC}"
            cd "$INSTANCE_DIR"
            docker-compose ps
            echo ""
            echo -e "${CYAN}卷状态:${NC}"
            docker volume ls | grep -E "($DB_VOLUME_NAME|$ODOO_VOLUME_NAME)"
            ;;
        2)
            echo ""
            cd "$INSTANCE_DIR"
            docker-compose restart
            systemctl reload nginx
            log "实例已重启"
            ;;
        3)
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
            ;;
        4)
            echo ""
            backup_name="backup_$(date '+%Y%m%d_%H%M%S')"
            backup_path="$BACKUP_DIR/$backup_name"
            mkdir -p "$backup_path"
            
            cd "$INSTANCE_DIR"
            docker-compose exec -T db pg_dump -U odoo postgres | gzip > "$backup_path/database.sql.gz"
            
            cp -r "$INSTANCE_DIR/config" "$backup_path/"
            cp "$INSTANCE_DIR/docker-compose.yml" "$backup_path/"
            cp "$INSTANCE_DIR/.env" "$backup_path/"
            
            cd "$BACKUP_DIR"
            tar -czf "${backup_name}.tar.gz" "$backup_name"
            rm -rf "$backup_path"
            
            log "备份完成: $BACKUP_DIR/${backup_name}.tar.gz"
            ;;
        5)
            echo ""
            echo "1) 修改管理员密码"
            echo "2) 修改数据库密码"
            echo "3) 修改Nginx配置"
            read -p "选择操作 (1-3): " config_choice
            case $config_choice in
                1)
                    read -p "输入新管理员密码: " new_pass
                    sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$new_pass/" "$INSTANCE_DIR/.env"
                    cd "$INSTANCE_DIR" && docker-compose restart odoo
                    log "管理员密码已更新"
                    ;;
                2)
                    read -p "输入新数据库密码: " new_pass
                    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$new_pass/" "$INSTANCE_DIR/.env"
                    cd "$INSTANCE_DIR" && docker-compose restart
                    log "数据库密码已更新"
                    ;;
                3)
                    nano /etc/nginx/sites-available/morhon-odoo
                    nginx -t && systemctl reload nginx
                    log "Nginx配置已更新"
                    ;;
                *) log_error "无效选择" ;;
            esac
            ;;
        6)
            return 1  # 返回主菜单
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
    
    return 0  # 继续显示管理菜单
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}   茂亨Odoo管理脚本 v6.0${NC}"
    echo -e "${PURPLE}================================${NC}"
    echo ""
    
    # 根据检测结果显示不同菜单
    case "$DETECTED_INSTANCE_TYPE" in
        "script")
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
            ;;
            
        "manual")
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
                2)
                    echo ""
                    docker ps -a | grep -E "($DETECTED_ODOO_CONTAINER|$DETECTED_DB_CONTAINER)"
                    echo ""
                    echo "Odoo配置:"
                    docker exec "$DETECTED_ODOO_CONTAINER" cat /etc/odoo/odoo.conf 2>/dev/null || echo "无法读取配置"
                    ;;
                3) exit 0 ;;
                *) log_error "无效选择" ;;
            esac
            ;;
            
        "none")
            echo -e "${BLUE}○ 未检测到现有实例${NC}"
            echo ""
            
            if [ "$HAS_LOCAL_BACKUP" = true ]; then
                echo "检测到本地备份文件"
                echo "1) 从备份恢复"
                echo "2) 全新部署"
                echo "3) 退出"
                echo ""
                read -p "请选择 (1-3): " choice
                
                case $choice in
                    1) restore_from_backup ;;
                    2) deploy_new_instance ;;
                    3) exit 0 ;;
                    *) log_error "无效选择" ;;
                esac
            else
                echo "1) 全新部署"
                echo "2) 退出"
                echo ""
                read -p "请选择 (1-2): " choice
                
                case $choice in
                    1) deploy_new_instance ;;
                    2) exit 0 ;;
                    *) log_error "无效选择" ;;
                esac
            fi
            ;;
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
                backup_name="backup_$(date '+%Y%m%d_%H%M%S')"
                backup_path="$BACKUP_DIR/$backup_name"
                mkdir -p "$backup_path"
                
                cd "$INSTANCE_DIR"
                docker-compose exec -T db pg_dump -U odoo postgres | gzip > "$backup_path/database.sql.gz"
                
                cp -r "$INSTANCE_DIR/config" "$backup_path/"
                cp "$INSTANCE_DIR/docker-compose.yml" "$backup_path/"
                cp "$INSTANCE_DIR/.env" "$backup_path/"
                
                cd "$BACKUP_DIR"
                tar -czf "${backup_name}.tar.gz" "$backup_name"
                rm -rf "$backup_path"
                
                log "备份完成: $BACKUP_DIR/${backup_name}.tar.gz"
            else
                log_error "仅支持脚本管理的实例备份"
            fi
            exit 0
            ;;
        "help"|"--help"|"-h")
            echo "茂亨Odoo管理脚本 v6.0"
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)   启动交互式菜单"
            echo "  init       初始化环境（安装依赖）"
            echo "  backup     备份脚本管理的实例"
            echo "  help       显示帮助"
            echo ""
            echo "运行逻辑:"
            echo "  1. 检测是否已有实例"
            echo "  2. 脚本实例 → 管理菜单"
            echo "  3. 手动实例 → 迁移菜单"
            echo "  4. 无实例 → 检查备份 → 恢复/全新部署"
            echo ""
            echo "部署模式:"
            echo "  • 本地模式: 通过IP地址访问，无需端口"
            echo "  • 域名模式: 通过域名访问，强制HTTPS"
            exit 0
            ;;
    esac
fi

# 执行主函数
main "$@"
