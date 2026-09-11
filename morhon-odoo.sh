#!/bin/bash

# 茂亨Odoo外贸专用版部署脚本 - Ubuntu专用版
# 单实例版本，支持本地模式和域名模式
# 版本: 7.0
# 系统要求: 推荐Ubuntu 24.04 LTS，支持20.04+ LTS
# GitHub: https://github.com/morhon-tech/morhon-odoo
#
# 这个脚本只做一件事：把茂亨Odoo部署起来，并让它能长期运行。
#
# 功能:
# - 全新部署（内网 IP 模式 / 域名 + HTTPS 模式）
# - 升级（拉取新镜像并应用更新）
# - 备份与恢复
# - 状态查看
# - 仅支持Ubuntu系统
#
# 7.0 去掉了什么，以及为什么
# ========================
# 6.x 还会替客户做服务器运维：改内核参数与 ulimit、重写 /etc/docker/daemon.json、
# 重置 ufw 防火墙、改 sshd_config 并重启 sshd、禁用十个系统服务、装
# fail2ban/rkhunter/chkrootkit、开启 unattended-upgrades、**整份覆盖**
# /etc/nginx/nginx.conf、写一批系统维护 cron，另外还带手动实例迁移和健康检查菜单。
#
# 那些都不是"部署这套系统"需要做的事，而且改的全是全局配置 —— 客户的服务器上往往
# 还跑着别的东西，这些动作破坏性强且难以回退。其中两条尤其危险，已随之移除：
#
#   * `docker system prune -f --volumes` 每周日执行一次 —— 维护时只要停过容器，
#     客户的数据库卷就可能被删掉；
#   * `systemctl is-active docker nginx || systemctl restart docker nginx` 每 30
#     分钟一次，而判断本身是错的（任一不活跃就重启**两个**），等于随时可能重启
#     docker，把机器上全部容器一起带下去。
#
# Nginx 现在只往 /etc/nginx/conf.d/ 加一份 http 级片段，再加一份站点配置，不碰客户
# 的 nginx.conf（理由见 create_nginx_shared_snippet 的说明）。
#
# 客户自己的服务器加固、内核调优、防火墙策略，交回给客户或他的运维决定。

set -e

# 配置变量
# 版本号只在这里写一次：菜单标题、help、备份信息文件都读它。
# 以前这三处各写一份字面量，改版本时漏掉两处 —— 备份文件里于是长期记着旧版本号，
# 而备份信息正是出事时用来判断"这份备份是哪一版脚本做的"的依据。
SCRIPT_VERSION="7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DIR="/opt/morhon-odoo"
BACKUP_DIR="/var/backups/morhon-odoo"
LOG_DIR="/var/log/morhon-odoo"

# 固定卷名
DB_VOLUME_NAME="morhon-pg"
ODOO_VOLUME_NAME="morhon-odoo"

# 固定镜像配置
ODOO_IMAGE="registry.cn-hangzhou.aliyuncs.com/morhon_hub/morhon_odoo:17"
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
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line="${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo -e "$line"
    echo -e "$line" >> "$LOG_DIR/morhon-odoo.log" 2>/dev/null || true
}

log_error() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line="${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
    echo -e "$line" >&2
    echo -e "$line" >> "$LOG_DIR/morhon-odoo.log" 2>/dev/null || true
}

log_info() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line="${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
    echo -e "$line"
    echo -e "$line" >> "$LOG_DIR/morhon-odoo.log" 2>/dev/null || true
}

log_warn() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line="${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
    echo -e "$line"
    echo -e "$line" >> "$LOG_DIR/morhon-odoo.log" 2>/dev/null || true
}

# 检查系统兼容性 - 仅支持 Ubuntu 20.04 以上
#
# 原来这里按 24.04 / 22.04 / 20.04 / 18.04 分了五个分支，各配一段推荐升级的说明文字。
# 判断结果其实只有两种：够新就继续，太旧就退出 —— 那些文字不影响部署，反而藏了一个
# 真错误：`[[ "$os_version" < "20.04" ]]` 是**字符串**比较（shellcheck SC2072）。
# 现在按 major.minor 拆成整数比，一个分支说清楚。
check_system_compatibility() {
    log_info "检查系统兼容性..."

    if [ ! -f /etc/os-release ]; then
        log_error "无法检测操作系统版本；本脚本仅支持 Ubuntu"
        exit 1
    fi

    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
        log_error "不支持的操作系统: ${ID:-未知}；本脚本仅支持 Ubuntu"
        log_error "推荐 Ubuntu 24.04 LTS，最低 20.04 LTS"
        exit 1
    fi

    local major="${VERSION_ID%%.*}"
    local minor="${VERSION_ID##*.}"
    # 去掉可能的前导零，免得 08 被当成八进制（`10#` 强制十进制）。
    major=$((10#${major:-0}))
    minor=$((10#${minor:-0}))

    if [ "$major" -lt 20 ] || { [ "$major" -eq 20 ] && [ "$minor" -lt 4 ]; }; then
        log_error "Ubuntu 版本过旧: ${VERSION_ID}；最低要求 20.04 LTS"
        log_error "升级命令: sudo do-release-upgrade"
        exit 1
    fi

    log "✓ Ubuntu ${VERSION_ID}"
    if [ "$major" -lt 24 ]; then
        log_warn "建议使用 Ubuntu 24.04 LTS（支持周期更长）"
    fi
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
    # -f2- : base64 密码以 '=' 结尾，-f2 会截断它（见 create_odoo_config 的说明）
    DETECTED_DB_PASSWORD=$(docker exec "$DETECTED_DB_CONTAINER" env 2>/dev/null | grep "POSTGRES_PASSWORD" | cut -d'=' -f2- || echo "")
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
    log "安装部署依赖..."

    # 只 update，不 upgrade。
    #
    # 原来这里有 `apt-get upgrade -y`，会把客户整台机器的包全升一遍。那不是安装
    # 我们系统需要做的事，而且在生产机上是有风险的动作：内核、数据库客户端、客户
    # 自己跑的别的服务都可能被带着走。什么时候升级系统由客户决定。
    log "刷新软件包索引..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    # 依赖只留部署真正用到的：
    #   nginx            反向代理（本地模式和域名模式都要）
    #   certbot + 插件   域名模式签证书与续期
    #   postgresql-client 备份与恢复用 pg_dump / pg_restore
    #   openssl          create_env_file 生成数据库和管理员密码
    #   curl/gnupg/lsb-release/ca-certificates  install_docker 加官方源要用
    #   tar/gzip/unzip   镜像与备份文件解包
    #
    # 去掉的：ufw、fail2ban、rkhunter、chkrootkit、unattended-upgrades、htop、
    # iotop、sysstat、bc、net-tools、git、python3-pip、software-properties-common、
    # apt-transport-https。那些是给服务器做运维和加固的，装我们的系统不需要，
    # 而配套那些工具的配置动作（改内核参数、重置防火墙、改 sshd_config、禁用系统
    # 服务）在客户已有用途的机器上是破坏性的。
    log "安装系统依赖..."
    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        tar \
        gzip \
        unzip \
        openssl \
        postgresql-client \
        nginx \
        certbot \
        python3-certbot-nginx

    if ! command -v docker &> /dev/null; then
        install_docker
    fi

    # compose 插件是硬要求，不是提示：下面 create_docker_compose_config 生成的
    # docker-compose.yml 全靠 `docker compose` 起。以前这里只 log_warn 一句就继续，
    # 于是失败点被推到很后面，报错看起来和 compose 没关系。
    if ! docker compose version &> /dev/null; then
        log_error "docker compose 插件不可用；请确认 docker-compose-plugin 已安装"
        return 1
    fi

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl enable nginx  >/dev/null 2>&1 || true

    # Nginx 只往 conf.d 加一份片段，不改客户的 nginx.conf（理由见该函数说明）。
    create_nginx_shared_snippet

    log "部署依赖安装完成"
    return 0
}

# 安装Docker - 仅支持Ubuntu
install_docker() {
    log "安装Docker..."
    
    # 确保是Ubuntu系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            log_error "不支持的操作系统，仅支持Ubuntu"
            return 1
        fi
        
        log "在 Ubuntu ${VERSION_ID} 上安装 Docker..."
    else
        log_error "无法检测操作系统类型"
        return 1
    fi
    
    # 安装Docker（仅Ubuntu）
    # 添加Docker官方GPG密钥
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
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

# Nginx 的 http 级片段：只往 conf.d 加一份文件，不改客户的 nginx.conf
#
# 为什么不再改写 /etc/nginx/nginx.conf
# --------------------------------
# 原来的 configure_nginx() 会**整份覆盖** /etc/nginx/nginx.conf。在一台只跑我们
# 系统的机器上看不出问题，但客户的服务器上常常还有别的站点，覆盖等于把别人的配置
# 一起换掉，而且是不可逆的（只留一份 .backup）。
#
# Ubuntu 自带的 nginx.conf 在 http 段里本来就有
# `include /etc/nginx/conf.d/*.conf;`，所以我们把需要的 http 级指令放成 conf.d 下
# 的一份文件 —— 加进去，而不是换掉。
#
# 这份片段不是可选的美化，缺了 nginx 直接起不来
# ------------------------------------------
# create_nginx_domain_config / create_nginx_local_config 生成的站点配置里用了
# `limit_conn conn_limit_per_ip`、`limit_req zone=req_limit_per_ip`、
# `proxy_cache odoo_cache`，而 zone 和 cache 只能在 **http 级**声明。
# 删掉这份片段，`nginx -t` 会直接报 unknown zone / no such cache。
create_nginx_shared_snippet() {
    log "写入 Nginx http 级片段: /etc/nginx/conf.d/morhon-odoo.conf"

    mkdir -p /etc/nginx/conf.d /var/cache/nginx/odoo
    chown -R www-data:www-data /var/cache/nginx/odoo

    cat > /etc/nginx/conf.d/morhon-odoo.conf << 'NGINX_SHARED'
# 茂亨Odoo —— Nginx http 级片段。由 morhon-odoo.sh 生成，请勿手工修改。
# 站点配置 sites-available/morhon-odoo 引用这里声明的 zone 与 cache。

proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:100m max_size=1g inactive=60m use_temp_path=off;
limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;
limit_req_zone  $binary_remote_addr zone=req_limit_per_ip:10m rate=20r/s;

# 站点配置里写着 `access_log ... main`，而 Ubuntu 自带的 nginx.conf 只有默认的
# combined 格式，没有 main —— 少了这段 nginx 会 emerg: unknown log format "main"。
# 带上游耗时是有用的：排查"Odoo 慢"时能直接分开是 nginx 等后端还是后端本身慢。
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for" '
                'rt=$request_time uct="$upstream_connect_time" '
                'uht="$upstream_header_time" urt="$upstream_response_time"';

# 大附件：外贸单据常带图纸和报关文件。站点配置里也设了同样的值，这里留一份兜底，
# 免得漏配时 nginx 用 1M 默认值把上传截断（表现是保存附件失败，不易联想到 nginx）。
client_max_body_size 500M;
client_body_timeout 300s;
send_timeout 300s;
NGINX_SHARED

    if ! nginx -t; then
        log_error "Nginx 配置检查未通过，请看上面的输出"
        return 1
    fi
    # 首次安装时 nginx 可能还没起来，reload 会失败 —— 那种情况下 start 一下。
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

# 创建Docker卷
create_docker_volumes() {
    log "创建Docker卷..."
    
    create_volume "$DB_VOLUME_NAME" "数据库卷"
    create_volume "$ODOO_VOLUME_NAME" "Odoo文件卷"
    
    log "Docker卷创建完成"
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
    
    # 顺序是有讲究的：先 .env，再 odoo.conf。
    #
    # create_odoo_config() **读** .env 拿数据库和管理员密码，而且刻意不带兜底弱口令
    # （理由写在那个函数里）。原来的顺序是先 odoo.conf 再 .env —— 全新安装时 .env
    # 还不存在，于是那个守卫正确地拒绝，整个全新部署走不下去：
    #
    #   ERROR: 无法从 /opt/morhon-odoo/.env 读取 DB_PASSWORD / ADMIN_PASSWORD
    #   ERROR: 拒绝用默认弱口令生成 odoo.conf
    #
    # 守卫是对的，顺序是错的。在一台干净的 Ubuntu 24.04 上实测复现过。
    create_env_file "$deployment_type" "$domain" "$use_www"

    # 创建odoo配置文件
    create_odoo_config "$workers" "$total_mem"

    # 创建docker-compose.yml
    create_docker_compose_config
    
    # 根据部署类型创建 Nginx 配置
    #
    # 域名模式在这一步**只能**上 HTTP 配置，不能上带 SSL 的那份。
    #
    # 带 SSL 的配置里 `ssl_certificate` 指向 /etc/letsencrypt/live/$domain/…，
    # 而此刻证书还没签出来 —— 那份配置 nginx 根本加载不了。而 certbot --webroot
    # 又要靠一个**正在运行的** nginx 把 /.well-known/acme-challenge/ 送出去，
    # 才能签下证书。先上 SSL 配置就把自己锁死了。
    #
    # 正确顺序（标准 webroot 流程）：HTTP 配置 -> reload -> 签证书 -> 换成 SSL 配置
    # -> reload。后三步在 create_new_instance 里，那里才知道证书签成功了没有。
    if [ "$deployment_type" = "domain" ]; then
        create_nginx_http_config "$domain" "$use_www"
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
    
    # 密码只能来自 .env（create_env_file 用 openssl rand 生成并写入）。
    #
    # 这里绝不能有兜底默认口令。admin_passwd 是 Odoo 的主密码，能创建、删除、
    # 还原任意数据库；一旦 .env 缺失就静默降级成弱口令写进配置，等于把整台实例
    # 交出去，而且没有任何提示，没人会发现。宁可装不上，也不要装成一个弱口令。
    #
    # cut 用 -f2- 而不是 -f2：openssl rand -base64 32 产生的值以 '=' 结尾
    # （base64 填充），-f2 会把末尾的 '=' 截掉，于是 .env 里是完整密码、
    # odoo.conf 里是残缺密码，Odoo 连不上数据库。
    local db_password=""
    local admin_password=""
    if [ -f "$INSTANCE_DIR/.env" ]; then
        db_password=$(grep "^DB_PASSWORD=" "$INSTANCE_DIR/.env" | cut -d'=' -f2-)
        admin_password=$(grep "^ADMIN_PASSWORD=" "$INSTANCE_DIR/.env" | cut -d'=' -f2-)
    fi
    if [ -z "$db_password" ] || [ -z "$admin_password" ]; then
        log_error "无法从 $INSTANCE_DIR/.env 读取 DB_PASSWORD / ADMIN_PASSWORD"
        log_error "拒绝用默认弱口令生成 odoo.conf。请确认该文件存在且包含这两个键。"
        exit 1
    fi
    
    # 内存限制（Odoo 17 使用字节）
    local memory_hard_bytes=$((total_mem * 450 * 1024 * 1024))  # ~450MB per GB RAM
    local memory_soft_bytes=$((total_mem * 350 * 1024 * 1024))  # ~350MB per GB RAM
    
    # 确保最小值
    [ "$memory_hard_bytes" -lt $((1536 * 1024 * 1024)) ] && memory_hard_bytes=$((1536 * 1024 * 1024))
    [ "$memory_soft_bytes" -lt $((1024 * 1024 * 1024)) ] && memory_soft_bytes=$((1024 * 1024 * 1024))
    
    # 数据库连接池
    local db_maxconn=$((workers * 2 + 4))
    local db_maxconn_gevent=$((workers * 2))
    local max_cron_threads=$((workers > 8 ? 4 : workers > 4 ? 3 : 2))
    
    cat > "$INSTANCE_DIR/config/odoo.conf" << EOF
[options]
# 基本配置
admin_passwd = $admin_password
addons_path = /mnt/extra-addons,/mnt/odoo/addons
data_dir = /var/lib/odoo
without_demo = all
proxy_mode = True
list_db = False

# 网络配置（容器内监听所有接口，由 docker ports 限制为 127.0.0.1）
http_port = 8069
gevent_port = 8072

# Worker 配置
workers = $workers
max_cron_threads = $max_cron_threads

# 内存限制（字节）
limit_memory_hard = $memory_hard_bytes
limit_memory_soft = $memory_soft_bytes

# 时间限制（秒）
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 3600
limit_request = 65536

# 数据库配置
db_host = db
db_port = 5432
db_user = odoo
db_password = $db_password
db_name = postgres
db_maxconn = $db_maxconn
db_maxconn_gevent = $db_maxconn_gevent
db_sslmode = prefer
db_template = template0

# 临时记录清理（小时，替代旧版 osv_memory_age_limit）
transient_age_limit = 2.0
osv_memory_count_limit = 0

# 日志配置
log_level = warn
log_handler = :WARNING,odoo.addons.mail_advance:INFO
logfile = /var/log/odoo/odoo.log
log_db = False
syslog = False

# 安全配置
server_wide_modules = base,web
unaccent = True

# 语言
load_language = zh_CN,en_US

# 报表压缩
reportgz = True

# 数据库工具路径
pg_path = /usr/bin
EOF
}

# 创建docker-compose配置文件 - 外贸管理系统优化
create_docker_compose_config() {
    # 获取系统资源信息
    local cpu_cores=$(nproc)
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    
    # 外贸管理系统资源分配策略
    local db_memory="${total_mem}g"
    local db_shared_buffers=$((total_mem * 256))  # 25% 内存作为shared_buffers
    local db_effective_cache_size=$((total_mem * 768))  # 75% 内存作为effective_cache_size
    
    cat > "$INSTANCE_DIR/docker-compose.yml" << EOF

services:
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
    environment:
      HOST: db
      PORT: 5432
      USER: odoo
      PASSWORD: \${DB_PASSWORD}
      DB_NAME: postgres
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
EOF
}

# 创建环境变量文件
create_env_file() {
    local deployment_type="$1"
    local domain="$2"
    local use_www="$3"
    # 已有 .env 就沿用里面的密码，不重新生成。
    #
    # 重新生成 DB_PASSWORD 会把客户锁在自己的数据库外面：Postgres 数据卷里存的仍是
    # 旧密码，而 .env 换成了新的，Odoo 于是连不上一个数据完好的库 —— 现象是"重装/
    # 恢复之后系统打不开了"，而真正原因从报错里看不出来。
    #
    # cut 用 -f2- 而不是 -f2：openssl rand -base64 的值以 '=' 结尾，-f2 会截断它。
    local db_password="" admin_password=""
    if [ -f "$INSTANCE_DIR/.env" ]; then
        db_password=$(grep "^DB_PASSWORD=" "$INSTANCE_DIR/.env" | cut -d'=' -f2-)
        admin_password=$(grep "^ADMIN_PASSWORD=" "$INSTANCE_DIR/.env" | cut -d'=' -f2-)
        if [ -n "$db_password" ]; then
            log "沿用 .env 中已有的密码（不重新生成，避免连不上已有数据库）"
        fi
    fi
    if [ -z "$db_password" ]; then
        db_password="${DETECTED_DB_PASSWORD:-$(openssl rand -base64 32)}"
    fi
    if [ -z "$admin_password" ]; then
        admin_password="$(openssl rand -base64 24)"
    fi
    
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

# 版本信息（写进 .env 是为了以后能看出这套实例是哪一版脚本部署的）
SCRIPT_VERSION=$SCRIPT_VERSION
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

# Upstream 定义
upstream odoo_backend {
    server 127.0.0.1:8069;
}

upstream odoo_longpolling {
    server 127.0.0.1:8072;
}

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
    
    location ~* /web/static/.*\.(py|pyc|pyo|xml)\$ {
        deny all;
        return 403;
    }
    
    # 阻止常见攻击路径
    location ~* \\.(git|svn|env|htaccess|htpasswd)\$ {
        deny all;
        return 403;
    }
    
    # WebSocket / 长轮询
    location /websocket {
        proxy_pass http://odoo_longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    
    # 兼容旧版 longpolling 路径
    location /longpolling {
        proxy_pass http://odoo_longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    
    # 静态文件缓存
    location ~* /web/static/ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_cache;
        proxy_cache_valid 200 302 7d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_lock on;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # 文件上传/下载
    location ~* /web/(binary|content)/ {
        proxy_pass http://odoo_backend;
        client_max_body_size 500M;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
    
    # 报表生成（耗时较长）
    location ~* /report/ {
        proxy_pass http://odoo_backend;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }
    
    # 主请求处理
    location / {
        proxy_pass http://odoo_backend;
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
    local snippet="/etc/nginx/snippets/morhon-odoo-app.conf"
    local server_ip=$(get_server_ip)

    # 让 443 也能用。内网 IP 拿不到公信证书（Let's Encrypt 不给私网地址签，
    # 也没有域名可验），所以只能自签 —— 浏览器会提示不受信任，点继续即可。
    create_self_signed_cert "$server_ip"

    # 80 和 443 共用的那一大段（连接限制、安全头、代理参数、全部 location、日志）
    # 抽成 include 片段，两个 server 块各 include 一次。
    #
    # 不复制两份：复制迟早分叉，而分叉的表现是「HTTP 能传大附件、HTTPS 不能」
    # 这种只在一半场景出现、又很难联想到 nginx 的怪毛病。
    mkdir -p /etc/nginx/snippets
    tee "$snippet" > /dev/null << EOF
# 茂亨Odoo —— 80/443 共用的 server 级配置。由 morhon-odoo.sh 生成，请勿手工修改。
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
    
    # 禁止访问敏感路径
    location ~* /(web|api)/database/ {
        deny all;
        return 403;
    }
    
    location ~* /web/static/.*\\.(py|pyc|pyo|xml)\$ {
        deny all;
        return 403;
    }
    
    # WebSocket / 长轮询
    location /websocket {
        proxy_pass http://odoo_longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    
    location /longpolling {
        proxy_pass http://odoo_longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    
    # 静态文件缓存
    location ~* /web/static/ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_cache;
        proxy_cache_valid 200 302 7d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_lock on;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status;
    }
    
    # 文件上传/下载
    location ~* /web/(binary|content)/ {
        proxy_pass http://odoo_backend;
        client_max_body_size 500M;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
    
    # 报表生成
    location ~* /report/ {
        proxy_pass http://odoo_backend;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }
    
    # 主请求处理
    location / {
        proxy_pass http://odoo_backend;
        proxy_redirect off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
    
    # 生产环境日志优化
    access_log /var/log/nginx/morhon-odoo-access.log main buffer=64k flush=5s;
    error_log /var/log/nginx/morhon-odoo-error.log;
EOF

    tee "$config_file" > /dev/null << EOF
# 茂亨Odoo内网生产环境配置 - 通过IP访问
# 由 morhon-odoo.sh 生成，请勿手工修改

# Upstream 定义
upstream odoo_backend {
    server 127.0.0.1:8069;
}

upstream odoo_longpolling {
    server 127.0.0.1:8072;
}

# HTTP —— 主入口，直接用 IP 打开就是这个。
#
# 刻意**不**跳转到 HTTPS：内网只有自签证书，强制跳转会让每个人每次访问都先
# 撞一次浏览器警告，等于把「输个 IP 就能用」这件事弄坏。要加密的人自己走 https。
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    include $snippet;
}

# HTTPS —— 可选。自签证书，浏览器会提示「不安全」，属于预期现象。
# 想要不报警的证书需要一个真实域名，用域名模式部署即可（那条路会签 Let's Encrypt）。
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;

    ssl_certificate     $INSTANCE_DIR/ssl/fullchain.pem;
    ssl_certificate_key $INSTANCE_DIR/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    include $snippet;
}
EOF

    # 启用站点
    ln -sf "$config_file" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default

    log "Nginx内网生产环境配置创建完成"
    log "内网访问地址: http://$server_ip"
    log "            https://$server_ip（自签证书，浏览器会提示不受信任）"
    log "注意: 这是生产环境配置，请确保内网安全策略"
}

# 自签 SSL 证书（内网 IP 模式用）
#
# 为什么只能自签：Let's Encrypt 不给私网 IP 签证书（无法做域名验证），而内网
# 部署本来就没有域名。要「不报警」的证书只有两条路 —— 用域名模式部署，或者客户
# 自己买一张证书替换掉这里的两个文件。
#
# 有效期给 10 年：自签证书没有续期机制，给短了就等着某天悄悄过期。它本来就不
# 被信任，有效期长短不影响浏览器的提示。
create_self_signed_cert() {
    local ip="$1"
    local dir="$INSTANCE_DIR/ssl"

    mkdir -p "$dir"

    # 已有且离到期还有 30 天以上就不动 —— 重跑部署不该换掉证书
    # （换了的话已经点过「信任」的浏览器又要再来一次）。
    if [ -f "$dir/fullchain.pem" ] \
       && openssl x509 -checkend 2592000 -noout -in "$dir/fullchain.pem" >/dev/null 2>&1; then
        log "自签证书已存在且有效，沿用"
        return 0
    fi

    log "生成自签 SSL 证书（CN=$ip）..."
    if ! openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
            -subj "/CN=$ip" \
            -addext "subjectAltName=IP:$ip,DNS:localhost" >/dev/null 2>&1; then
        log_error "自签证书生成失败；将只提供 HTTP 访问"
        return 1
    fi
    chmod 600 "$dir/privkey.pem"
    chmod 644 "$dir/fullchain.pem"
    log "自签证书已生成: $dir/fullchain.pem（10 年有效）"
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
        --email "admin@$domain"; then
        # 去掉了 --force-renewal。它的作用是"即使证书还没到期也重新签一张"，
        # 而 Let's Encrypt 对**完全相同的域名组合**限制每周 5 张。客户重装或重试
        # 几次就会撞上 "too many certificates already issued"，那时连正常部署都
        # 签不出证书，而错误信息完全看不出是自己刷掉的。certbot 默认就是幂等的：
        # 已有有效证书会直接复用。
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
# 设置SSL自动续期
#
# 关键点：reload nginx 必须挂在 **deploy hook** 上，不能靠我们自己 cron 里的 --post-hook。
#
# 原来这里写的是：
#     0 2 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
#
# 而 --post-hook 只在**本次调用真的续期了**才执行。Ubuntu 的 certbot 包自带
# certbot.timer（每天跑两次）和 /etc/cron.d/certbot —— 它们会先把证书续掉，于是我们
# 凌晨 2 点这条发现"未到期"，post-hook 根本不触发，nginx 永远不 reload。
#
# 后果很隐蔽：第 60 天证书在磁盘上换成新的，nginx 内存里还是旧的；到第 90 天浏览器开始
# 报证书过期，而 `certbot certificates` 显示一切正常，排查方向完全被带偏。
#
# renewal-hooks/deploy/ 下的脚本在**任何一次成功续期之后**都会执行，不管是谁触发的。
setup_ssl_renewal() {
    local domain="$1"
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"

    mkdir -p "$hook_dir"
    cat > "$hook_dir/10-reload-nginx.sh" << 'HOOK'
#!/bin/sh
# 由 morhon-odoo.sh 生成。证书每次成功续期后由 certbot 自动执行。
# 不加 --quiet 之类的判断：这里只做一件事，让 nginx 用上新证书。
systemctl reload nginx 2>/dev/null || systemctl restart nginx
HOOK
    chmod +x "$hook_dir/10-reload-nginx.sh"

    # 续期本身交给 certbot 自带的定时器。多一条我们自己的 cron 只会让"谁先跑"变得
    # 不确定，而正是那个不确定让旧的 --post-hook 失效。
    if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
        rm -f /etc/cron.d/certbot-renewal
        log "证书续期: certbot.timer（每日两次），续期后由 deploy hook 自动 reload nginx"
    elif [ -f /etc/cron.d/certbot ]; then
        rm -f /etc/cron.d/certbot-renewal
        log "证书续期: certbot 自带 cron，续期后由 deploy hook 自动 reload nginx"
    else
        # 没有自带定时器（certbot 用别的方式装的），才保留我们自己这条 ——
        # 否则删掉它就等于完全没有续期了。
        cat > /etc/cron.d/certbot-renewal << 'CRON'
# 每天凌晨 2 点检查续期。reload 由 renewal-hooks/deploy 负责，这里不再用 --post-hook。
0 2 * * * root certbot renew --quiet
CRON
        log "未发现 certbot 自带定时器，已写入 /etc/cron.d/certbot-renewal"
    fi
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
    
    # 域名模式：先让 HTTP 配置生效，签下证书，再切到 HTTPS 配置
    #
    # 顺序是有代价换来的（另一半说明在 generate_docker_compose 里）：上一步只写了
    # HTTP 配置，这里必须先 reload 让它真的生效 —— certbot --webroot 要靠一个
    # **正在运行的** nginx 把 /.well-known/acme-challenge/ 下的挑战文件送出去。
    #
    # 原来的代码在这里直接调 certbot，而此刻 nginx 还跑着 Ubuntu 的 default 站点
    # （挑战路径 404，因为刚写的配置还没 reload）。于是签证书必然失败，静默回落成
    # HTTP，最后却打印一句 "访问地址: https://…" —— 域名模式从来没真正拿到过 HTTPS。
    if [ "$deployment_type" = "domain" ]; then
        log "启用 HTTP 配置以便完成 ACME 域名验证..."
        systemctl reload nginx 2>/dev/null || systemctl restart nginx

        if get_ssl_certificate "$domain" "$use_www"; then
            log "证书就绪，切换到 HTTPS 配置..."
            create_nginx_domain_config "$domain" "$use_www"
            if nginx -t 2>/dev/null; then
                systemctl reload nginx
            else
                # 走到这里说明证书签出来了但 HTTPS 配置有问题。保住可用的 HTTP，
                # 不要留下一个 nginx 加载不了的配置把站点整个弄掉。
                log_error "HTTPS 配置检查未通过，回退到 HTTP 配置"
                create_nginx_http_config "$domain" "$use_www"
                systemctl reload nginx 2>/dev/null || true
            fi
        fi
    fi
    
    log "新实例创建完成"
}
    
# 启动服务并等待就绪
start_services() {
    log "启动服务..."
    cd "$INSTANCE_DIR"
    
    # 启动服务
    docker compose up -d
    
    # 等待数据库就绪
    log "等待数据库启动..."
    local db_ready=false
    for i in {1..30}; do
        if docker compose exec -T db pg_isready -U odoo -d postgres >/dev/null 2>&1; then
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
    # 同上：nameref 要传变量名而不是值（见 deploy_new_instance 里的说明）。
    get_restore_deployment_info deployment_type domain use_www
    
    # 解压备份
    local temp_dir="/tmp/restore_$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$temp_dir"
    
    log "解压备份文件: $(basename "$backup_file")"
    if [ ! -f "$backup_file" ]; then
        # 这一条是上面那个 stdout 污染 bug 留下的教训：当时 $backup_file 里混进了
        # 整段菜单文本，tar 的报错是一大团转义字符，看不出真正的原因。先检查文件
        # 存在，报一句人能看懂的话。
        log_error "备份文件不存在或路径异常: $backup_file"
        rm -rf "$temp_dir"
        return 1
    fi
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
        local backup_admin_pass=$(grep "^ADMIN_PASSWORD=" "$backup_env" | cut -d'=' -f2-)
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
    # 这几条建议要跟着菜单一起改。v7.0 删掉了「系统状态检查」和「修改配置」两项，
    # 而这里还在让人去选它们 —— 指着不存在的入口，比不给建议更让人困惑。
    echo "后续操作建议:"
    echo "1. 检查实例状态: 重新运行本脚本 -> 管理实例 -> 查看实例状态"
    echo "2. 修改管理员密码: 登录 Odoo 后在「设置 -> 用户」里改"
    echo "3. 核对访问是否正常，再确认数据是否完整"
    echo "4. 立即做一次新备份: sudo $0 backup"
    echo ""
}

# 选择备份文件
#
# 这个函数用 stdout 返回选中的文件路径，所以**给人看的东西一律走 stderr**。
#
# 原来菜单是 `echo` 到 stdout 的，而调用方是
# `local backup_file=$(select_backup_file "${backup_files[@]}")` —— 于是整段菜单文本
# 连同 log 行都被当成了返回值。实测现象：
#
#   解压备份文件: backup_20260911_045159.tar.gz
#   tar (child): \n发现备份文件\:\n====================\n1) backup_...\n…: Cannot open
#
# 也就是说**恢复功能整个不可用** —— 而客户用到恢复的时候，通常已经出事了。
select_backup_file() {
    local backup_files=("$@")

    {
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
    } >&2

    # read -p 的提示本来就走 stderr，不用额外重定向。
    read -p "选择要恢复的备份文件 (1-${#backup_files[@]}) [默认: 1]: " choice
    choice=${choice:-1}

    # 用 case 而不是 `[ "$choice" -lt 1 ]`：输入非数字时 -lt 会报
    # "integer expression expected"，而脚本开头是 set -e。
    case "$choice" in
        ''|*[!0-9]*) log_error "无效选择: $choice" >&2; return 1 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        log_error "无效选择: $choice" >&2
        return 1
    fi

    local backup_file="${backup_files[$((choice-1))]}"
    log "选择恢复: $(basename "$backup_file")" >&2
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
    
    # 询问部署模式与域名
    #
    # 传**变量名**，不能传值。get_deployment_info_interactive 用 `local -n x=$1`
    # 声明 nameref，nameref 要的是名字；写成 "$deployment_type" 传过去的是空值，
    # bash 报 `local: '': not a valid identifier`，而这句错误不会中止脚本
    # （set -e 对函数内 local 失败不生效），于是三个变量全是空的 —— 客户选了
    # 「公网域名模式」也会被静默部署成内网 IP 模式：没有 SSL、nginx 用的是 local
    # 站点配置，最后还打印一句域名为空的 "访问地址: https://"。
    local deployment_type domain use_www
    get_deployment_info_interactive deployment_type domain use_www
    
    # 初始化环境（如果需要）
    check_and_init_environment
    
    # 创建新实例
    create_new_instance "$deployment_type" "$domain" "$use_www"
    
    # 重启Nginx
    # reload 失败不该让整个部署脚本因为 set -e 直接退出。
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    
    log "部署完成！"
    
    if [ "$deployment_type" = "domain" ]; then
        # 按**实际有没有证书**报地址，不按客户当初选了什么。
        #
        # 原来这里无条件打印 https://，而证书没签成时站点只有 80 端口在听 ——
        # 客户照着提示访问 https 打不开，看起来像整个部署都失败了。
        if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
            log "访问地址: https://$domain"
        else
            log_warn "SSL 证书未签发成功，当前仅 HTTP 可用"
            log "访问地址: http://$domain"
            log "解决域名解析或 80 端口可达性之后，重跑一次部署即可切到 HTTPS"
        fi
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
        read -p "请选择操作 (1-6): " choice

        case $choice in
            1) show_instance_status ;;
            2) restart_instance ;;
            3) show_logs ;;
            4) backup_instance ;;
            5) upgrade_instance ;;
            6) return 1 ;;  # 返回主菜单
            *) log_error "无效选择" ;;
        esac

        # 用字符串比较而不是 -eq：输入非数字时 `[ abc -eq 6 ]` 会报错，
        # 而脚本开头是 set -e，于是一次手滑就把整个脚本带退出。
        [ "$choice" = "6" ] && break
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
    echo "5) 升级（拉取新镜像并应用更新）"
    echo "6) 返回主菜单"
    echo ""
}

# 升级实例（拉取新镜像并应用更新）
# 仅重建 Odoo 容器，数据库容器保持不动；模块升级由镜像 entrypoint 在镜像版本
# 变化时以单进程方式自动完成（含翻译重导），普通重启则秒级启动、不升级。
upgrade_instance() {
    echo ""
    echo -e "${CYAN}升级茂亨Odoo（拉取新镜像并应用更新）${NC}"
    echo "================================================"
    echo ""
    echo "此操作将："
    echo "  1. 先备份当前实例（数据库 + 配置）"
    echo "  2. 仅拉取最新 Odoo 镜像（数据库镜像不动）"
    echo "  3. 仅重建 Odoo 容器，启动时自动单进程应用模块更新"
    echo ""
    echo "说明：数据库容器不会被重建，数据安全；升级期间 Odoo 会短暂停机，首次升级可能耗时几分钟。"

    if ! confirm_action "确认开始升级？建议在业务低峰执行。"; then
        log "已取消升级"
        return 0
    fi

    if [ ! -f "$INSTANCE_DIR/docker-compose.yml" ]; then
        log_error "未找到实例配置：$INSTANCE_DIR/docker-compose.yml"
        return 1
    fi

    # 1. 升级前备份
    log "升级前备份实例..."
    backup_instance || log_warn "备份未完成，仍继续升级（请确认风险）"

    cd "$INSTANCE_DIR" || { log_error "无法进入实例目录"; return 1; }

    # 2. 仅拉取 Odoo 镜像（数据库镜像保持不变，避免 PG 大版本变化撞坏数据）
    # 2. 仅拉取 Odoo 镜像（数据库镜像保持不变，避免 PG 大版本变化撞坏数据）
    #
    # 记下拉取前后的镜像 ID：一样就说明本地已是最新，容器不会被重建。原来无论如何都
    # 打印"重建 Odoo 容器…"，而 compose 实际输出的是 "Container morhon-odoo Running"
    # （没动），两句话对不上，客户以为升级做了而其实什么都没发生。
    local img_before img_after
    img_before=$(docker image inspect -f '{{.Id}}' "$ODOO_IMAGE" 2>/dev/null || echo none)
    log "拉取最新 Odoo 镜像..."
    if ! docker compose pull odoo; then
        log_error "镜像拉取失败，已中止升级（实例未改动）"
        return 1
    fi

    # 3. 仅重建 Odoo 容器（不动数据库）。镜像 entrypoint 会在镜像版本变化时
    #    以单进程方式自动执行模块升级，普通重启则秒级启动。
    img_after=$(docker image inspect -f '{{.Id}}' "$ODOO_IMAGE" 2>/dev/null || echo none)
    if [ "$img_before" = "$img_after" ]; then
        log "镜像与本地一致，已是最新版本 —— 容器无需重建"
    else
        log "镜像已更新，重建 Odoo 容器并应用更新（容器内自动单进程升级，可能需几分钟）..."
    fi
    if ! docker compose up -d --no-deps odoo; then
        log_error "Odoo 容器重建失败，请检查：cd $INSTANCE_DIR && docker compose logs odoo"
        return 1
    fi

    # 4. 等待服务就绪（首次升级需跑完单进程 -u all，耗时较长）
    # 等待服务就绪：看**容器健康状态**，不看日志横幅
    #
    # 原来是 `docker compose logs --tail 100 odoo | grep "HTTP service (werkzeug) running"`。
    # 那个横幅只在启动时打一次，容器跑了一阵之后早就不在最后 100 行里了 —— 于是当
    # 镜像已是最新、容器**没有**被重建时，这个判断永远匹配不到，白等 5 分钟然后报一句
    # "等待超时"，而实例其实一直是健康的。实测复现（容器已运行 25 分钟）。
    #
    # 健康状态是更准的信号：镜像的 entrypoint 会先跑完单进程模块升级、再启动 HTTP，
    # 而 healthcheck 探的是 HTTP —— 所以 healthy 就意味着升级已经做完了。
    log "等待 Odoo 就绪（最多约 5 分钟）..."
    local ready=false
    local cid health i
    cid=$(docker compose ps -q odoo 2>/dev/null | head -1)
    for i in $(seq 1 60); do
        if [ -z "$cid" ]; then
            cid=$(docker compose ps -q odoo 2>/dev/null | head -1)
        fi
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealthcheck{{end}}' \
                 "$cid" 2>/dev/null || echo unknown)
        case "$health" in
            healthy)
                ready=true; break ;;
            nohealthcheck)
                # 镜像没定义 healthcheck 时才退回看日志，并且**不加 --tail**，
                # 否则又会因为横幅滚出窗口而误判。
                if docker compose logs odoo 2>/dev/null | grep -q "HTTP service (werkzeug) running"; then
                    ready=true; break
                fi ;;
        esac
        sleep 5
    done

    echo ""
    if [ "$ready" = true ]; then
        log "✓ 升级完成，Odoo 已就绪"
    else
        log_warn "等待超时：升级可能仍在进行（首次升级耗时较长）。可用以下命令继续观察："
        echo "  cd $INSTANCE_DIR && docker compose logs -f odoo"
    fi

    echo ""
    docker compose ps
    return 0
}

# 显示实例状态
show_instance_status() {
    echo ""
    echo -e "${CYAN}实例状态:${NC}"
    cd "$INSTANCE_DIR"
    docker compose ps
    echo ""
    echo -e "${CYAN}卷状态:${NC}"
    docker volume ls | grep -E "($DB_VOLUME_NAME|$ODOO_VOLUME_NAME)"
}

# 重启实例
restart_instance() {
    echo ""
    cd "$INSTANCE_DIR"
    docker compose restart
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
        1) cd "$INSTANCE_DIR" && docker compose logs -f odoo ;;
        2) cd "$INSTANCE_DIR" && docker compose logs -f db ;;
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
    if docker compose exec -T db pg_dump -U odoo postgres | gzip > "$backup_path/database.sql.gz"; then
        log "数据库备份完成"
    else
        log_error "数据库备份失败"
        return 1
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
脚本版本: $SCRIPT_VERSION
实例目录: $INSTANCE_DIR
备份类型: 完整备份

包含内容:
- 数据库完整备份 (database.sql.gz)
- Odoo配置文件 (config/)
- Docker Compose配置 (docker-compose.yml)
- 环境变量 (.env)
- Nginx配置 (nginx-config)
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

# 显示主菜单
show_main_menu() {
    # 清屏失败不该中止部署。没有 TTY（或 TERM=unknown）时 `clear` 返回非零，
    # 而脚本开头是 set -e —— 于是在 CI、nohup、`ssh 主机 "命令"` 这类没有终端的
    # 场景下，脚本会在显示菜单之前就静默退出。实测踩到过。
    clear 2>/dev/null || true
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}   茂亨Odoo部署脚本 v${SCRIPT_VERSION}${NC}"
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
    echo "这台机器上的实例不是本脚本部署的，脚本不接管它 —— 只能看信息。"
    echo "要交给脚本管理，请先备份数据，再用「全新部署」重建。"
    echo ""
    echo "1) 查看容器信息"
    echo "2) 退出"
    echo ""
    read -p "请选择 (1-2): " choice

    case $choice in
        1) show_container_info ;;
        2) exit 0 ;;
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
    
    # 检查系统兼容性
    check_system_compatibility
    
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
            # 交互式入口会先查系统，这个子命令以前直接跳过了 —— 于是在非 Ubuntu 上
            # 会一路 apt-get 到失败才报错。先查再装。
            check_system_compatibility
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
                show_instance_status
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
        "upgrade")
            check_sudo
            detect_environment
            if [ "$DETECTED_INSTANCE_TYPE" = "script" ]; then
                upgrade_instance
            else
                log_error "仅支持脚本管理的实例升级"
            fi
            exit 0
            ;;
        "help"|"--help"|"-h")
            echo "茂亨Odoo部署脚本 v${SCRIPT_VERSION}"
            echo "专为外贸企业设计的Odoo部署工具"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)   启动交互式菜单"
            echo "  init       安装部署依赖（Docker、Nginx、certbot）"
            echo "  backup     备份脚本管理的实例"
            echo "  restore    从备份恢复（自动检测同目录备份文件）"
            echo "  upgrade    升级到最新镜像（拉取新镜像并应用更新，仅脚本实例）"
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
                                    echo "  • Docker卷映射，防止插件冲突"
            echo ""
            echo "运行逻辑:"
            echo "  1. 检测现有实例类型"
            echo "  2. 脚本实例 → 管理菜单（状态、备份、配置等）"
            echo "  3. 手动实例 → 只显示容器信息（脚本不接管非自己部署的实例）"
            echo "  4. 无实例 → 全新部署菜单（选择内网或公网模式）"
            echo ""
            echo "重要说明:"
            echo "  • 推荐使用本地部署或二级域名部署"
            echo "  • 专注于企业管理功能，不推荐使用网站功能"
            echo "  • 网站功能建议使用WordPress等专业系统"
            echo "  • 数据卷映射：防止用户误操作和插件冲突"
            echo "  • 禁止自装插件：避免系统不稳定和安全风险"
            echo ""
            echo "系统要求:"
            echo "  • 支持系统: 仅支持Ubuntu系统"
            echo "  • 推荐版本: Ubuntu 24.04 LTS（首选）/ 22.04 LTS / 20.04 LTS"
            echo "  • 最低配置: 4核CPU, 8GB内存, 80GB存储"
            echo "  • 推荐配置: 6核CPU, 16GB内存, 160GB SSD"
            echo "  • 网络要求: 稳定互联网连接，5Mbps以上带宽"
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
