# 🚀 茂亨外贸Odoo (Trade Odoo 17) 一键部署管理器

## 📖 项目简介

`odoo-manager.sh` 是一个功能强大的自动化部署与管理脚本，专为在 Linux VPS 上快速部署和管理 **茂亨外贸专用版 Odoo (Trade Odoo 17)** 系统而设计。它采用 Docker 容器化技术，集成了智能镜像源选择、系统优化、安全加固和日常运维功能，让 Odoo 的部署变得简单高效。

**核心价值**：无需掌握复杂的 Docker 和服务器运维知识，通过简单的命令行交互或一键命令，即可为企业搭建一个生产级、高性能、安全的外贸业务管理平台。

## ✨ 核心特性

- **🧠 智能部署**：支持**域名模式**（自动HTTPS）和**本地模式**两种部署方式，满足从内网测试到对外生产的全场景需求。
- **🚀 开箱即用**：预配置茂亨外贸专用版 (Trade Odoo 17)，深度优化外贸业务流程。
- **🌐 网络智能优化**：自动检测服务器网络环境，智能选择最快的 Docker 镜像源（优先Docker官方源，自动切换国内镜像）。
- **⚙️ 性能自动调优**：根据服务器 CPU 核心数和内存大小，自动计算并配置 Odoo Workers、数据库缓存等关键参数。
- **🔒 安全加固**：自动配置 UFW 防火墙基础规则、设置安全的 HTTP 头部、管理数据库访问权限。
- **📦 全栈管理**：提供从初始化、部署、启动/停止、备份/恢复到日志查看和系统监控的完整生命周期管理。
- **🔄 自动化运维**：自动设置定时任务（数据库备份、日志清理、SSL证书自动续期）。

## 📋 系统要求

- **操作系统**：Ubuntu 20.04/22.04 LTS（推荐），其他 Debian 系发行版可能兼容。
- **服务器配置**：最低 **1核 CPU， 2GB 内存，20GB 存储**。生产环境请参考下方推荐配置。
- **权限要求**：需要具有 `sudo` 权限的用户运行脚本。

### 💡 VPS 配置推荐表
| 企业规模 | 预估用户数 | 推荐配置 | 适用场景 |
|:---|:---|:---|:---|
| **微型/初创** | 1-5人 | 1-2核 CPU， 2GB 内存， 40GB SSD | 个人SOHO或小团队，处理基础客户和订单。 |
| **小型企业** | 5-15人 | 2核 CPU， 4GB 内存， 60GB SSD | 有稳定订单流，需管理库存、采购和初步财务。 |
| **中型企业** | 15-30人 | 4核 CPU， 8GB 内存， 100GB SSD | 多部门协作，订单量大，需要多仓库及深入分析。 |
| **中大型企业** | 30-50人 | 8核 CPU， 16GB 内存， 200GB SSD | 业务复杂，需要高并发处理和外部系统集成。 |
| **大型企业** | 50人以上 | 建议集群部署或联系茂亨技术团队定制方案。 | 对性能、高可用性和安全有极高要求。 |

> **提示**：“预估用户数”主要指“同时在线操作系统的用户数”，通常远小于公司总人数。起步可从**小型企业**配置开始，云服务器大多支持后期升级。

## 🚦 快速开始

### 步骤1：获取脚本
登录您的 VPS，使用以下命令下载最新版脚本：
```bash
wget https://raw.githubusercontent.com/morhon-tech/morhon-odoo/main/odoo-manager.sh
chmod +x odoo-manager.sh
```

### 步骤2：初始化服务器环境（仅需一次）
此步骤将安装 Docker、Nginx、配置防火墙和优化系统参数。
```bash
sudo ./odoo-manager.sh init
```

### 步骤3：部署您的 Odoo 实例
- **方式一：快速本地部署**（适合内网测试或快速启动）
    ```bash
    # 将 `my-company` 替换为您喜欢的实例名
    sudo ./odoo-manager.sh deploy my-company
    ```
    部署完成后，通过 `http://<您的服务器IP>:8069` 访问。

- **方式二：交互式高级部署**（推荐用于生产环境）
    ```bash
    sudo ./odoo-manager.sh deploy
    ```
    跟随向导选择“域名模式”，输入您的域名，脚本将自动为您配置 Nginx 反向代理并申请 Let‘s Encrypt SSL 证书，实现 `https://` 安全访问。

## 📖 详细使用指南

### 1. 主要命令一览
脚本支持命令行参数和交互式菜单两种操作方式。

**命令行方式（高效）**：
```bash
# 初始化环境
sudo ./odoo-manager.sh init

# 快速部署一个名为 `trade-odoo` 的本地实例
sudo ./odoo-manager.sh deploy trade-odoo

# 备份实例
sudo ./odoo-manager.sh backup

# 查看实例日志
sudo ./odoo-manager.sh logs

# 系统监控面板
sudo ./odoo-manager.sh monitor
```

**交互式菜单方式（直观）**：
直接运行脚本而不带任何参数，将进入功能齐全的交互菜单。
```bash
sudo ./odoo-manager.sh
```

### 2. 实例管理
每个 Odoo 实例都拥有独立的目录（位于 `/opt/` 下），包含其所有数据、配置和日志。

| 常用操作 | 命令（在实例目录内执行） | 说明 |
|:---|:---|:---|
| **启动** | `docker-compose start` | 启动已停止的实例。 |
| **停止** | `docker-compose stop` | 停止运行中的实例。 |
| **重启** | `docker-compose restart` | 重启实例，应用配置更改。 |
| **查看实时日志** | `docker-compose logs -f odoo` | 跟踪 Odoo 容器日志。 |
| **进入容器** | `docker exec -it <实例名>-odoo bash` | 进入 Odoo 容器内部（高级调试）。 |

### 3. 数据备份与恢复
脚本提供了完善的备份机制，备份文件位于 `/var/backups/odoo/`。

- **手动备份**：运行 `sudo ./odoo-manager.sh backup` 并选择实例。
- **自动备份**：脚本在部署时会自动设置 `cron` 任务，每天凌晨 2 点进行数据库备份。
- **恢复备份**：运行 `sudo ./odoo-manager.sh restore`，然后从列表中选择备份文件进行恢复。

## 🔧 配置详解

### 关键目录结构
```
/opt/your-instance-name/    # 实例根目录
├── addons/                 # 自定义模块目录
├── config/
│   ├── odoo.conf          # Odoo 主配置文件
│   └── postgresql.conf    # PostgreSQL 优化配置
├── data/                   # Odoo 数据文件存储
├── postgres_data/         # 数据库数据文件
├── backups/                # 实例级备份
├── logs/                   # 应用日志
└── docker-compose.yml     # Docker 服务定义
```

### 环境变量文件 (`.env`)
部署时自动生成的 `.env` 文件包含所有敏感信息和关键配置，如数据库密码、管理员密码等。**请务必妥善保管此文件**。
```bash
# 查看自动生成的管理员密码
cat /opt/your-instance-name/.env | grep ADMIN_PASSWORD
```

## 🐛 故障排查

1.  **部署时端口冲突**：脚本会自动检测并尝试其他端口，您也可以在交互式部署时手动指定。
2.  **无法拉取 Docker 镜像**：脚本内置了智能镜像源切换。如果失败，请检查服务器网络，或手动运行 `docker pull registry.cn-hangzhou.aliyuncs.com/morhon_hub/mh_odoosaas_v17:latest` 测试。
3.  **通过 IP 无法访问**：
    - 检查防火墙是否放行了对应端口 (`sudo ufw status`)。
    - 确认实例是否正在运行 (`docker ps`)。
    - 查看实例日志 (`sudo ./odoo-manager.sh logs`) 寻找错误信息。
4.  **忘记管理员密码**：密码存储在实例目录的 `.env` 文件中，可通过上文的 `cat` 命令查看。

## 🤝 贡献指南

我们欢迎并感谢所有的贡献！如果您想改进这个项目：
1.  Fork 本仓库。
2.  创建您的功能分支 (`git checkout -b feature/AmazingFeature`)。
3.  提交您的更改 (`git commit -m 'Add some AmazingFeature'`)。
4.  推送到分支 (`git push origin feature/AmazingFeature`)。
5.  开启一个 Pull Request。

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 🙏 支持与联系

- 如果您在使用脚本时遇到问题，请先查阅本文档的 **故障排查** 部分。
- 对于 **茂亨外贸版 Odoo (Trade Odoo 17)** 的产品功能咨询或业务需求，请访问 [茂亨科技官网](https://www.morhon.com)。
- 您也可以通过 GitHub 仓库的 [Issues](https://github.com/morhon-tech/morhon-odoo/issues) 页面提交 bug 或功能建议。

---
**提示**：首次登录 Odoo 系统后，请务必在 **设置** 中修改默认的管理员密码，并配置符合您公司业务的工作流。
