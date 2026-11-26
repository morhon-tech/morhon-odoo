# MORHON Odoo 19 — 新实例安装 v8.3

`morhon-odoo19.sh` 用于 **Linux amd64 全新实例**，固定 Odoo 19 整包和 PostgreSQL 15 镜像摘要。它不升级 Odoo 17，不接管现有数据库，不修改 trade，也不运行全模块更新。

原 Odoo 17 入口 `morhon-odoo.sh` 保留原样；其说明见 `README-odoo17-legacy.md`。请勿将两个入口、数据库或卷混用。

## 准备与安装

先在隔离测试机准备 Python 3、Docker Engine、Docker Compose v2；本脚本不会安装系统软件、改防火墙或 Docker daemon、重启其它服务或运行全局清理。

网络无法访问镜像仓库时，可从可信来源离线加载**本版完全相同**的三份镜像，再在首次 `prepare` 时显式加 `--offline-images`。该模式按固定 linux/amd64 镜像内容 ID 校验，不自动改用其它标签、镜像站或代理；缺件、错误内容或平台不符即停止。普通模式仍使用下面列出的仓库摘要。离线选项不接管已存在的数据库或卷。

经典 Docker 存储以配置摘要识别镜像；Docker 29 的 containerd 存储使用 manifest 摘要。后者须在首次准备时明确加 `--offline-images --image-store containerd`；随后按安装元数据锁定整套身份，不自动切换。本版网页镜像使用已从仓库实际拉取核验的 manifest 身份；数据库和转接镜像沿用原已核验归档的身份。本次未提供新的离线镜像包，也不承诺所有导入转换方式都生成相同身份。其它转换生成不同 manifest 时仍拒绝；没有本版可信离线包时使用正常仓库模式，不自行伪造或替换摘要。

```bash
chmod +x morhon-odoo19.sh
sudo ./morhon-odoo19.sh prepare --root /opt/morhon-odoo19
sudo ./morhon-odoo19.sh install --root /opt/morhon-odoo19
sudo ./morhon-odoo19.sh status --root /opt/morhon-odoo19
```

普通安装的管理员登录名为 `admin`；随机初始密码只存于安装目录的 `admin-password`。目录权限为 0700。**普通安装不使用公开 Demo 密码。** 凭据只在初次准备时生成；重复准备、重新初始化已有业务库会被拒绝。

应用只监听本机 `127.0.0.1:18069`，WebSocket 为 `127.0.0.1:18072`。对外使用时由管理员配置本实例的 HTTPS 反向代理；本脚本不改已有 Nginx 站点或自动签证书。数据库不发布主机端口，应用数据库角色无超级用户、建库或建角色权限。

普通安装同样默认不运行常驻 cron，并关闭原生首次公司自动补全和线索自动 enrichment。正式使用前应另行配置并验收邮件、任务执行器及各外部平台；没有 AI 服务商时不能使用 AI 功能。新实例安装通过不代表迁移、财务、本地化和所有业务场景都已验收。修改受管文件后，固定安装器会拒绝未核验变更；自定义配置须另行保全并使用本实例 Compose 受控管理。

```bash
sudo ./morhon-odoo19.sh stop --root /opt/morhon-odoo19
sudo ./morhon-odoo19.sh start --root /opt/morhon-odoo19
sudo ./morhon-odoo19.sh backup --root /opt/morhon-odoo19
```

备份仅暂停本实例网页服务，生成数据库、filestore 与配置的私有副本及摘要；不会暂停其它网站或主机数据库。**v8.3 不提供自动恢复、在线升级或跨大版本迁移命令**；备份文件应在隔离目标验证后再用于恢复。初始化失败时保留卷和日志；只有尚无任何业务表、序列或视图的受管目标可显式使用 `install --resume-empty`，不会自动删除重建。

## 公共 Demo 模式

Demo 必须单独使用新目录、项目名、数据库与端口：

```bash
sudo ./morhon-odoo19.sh prepare --demo \
  --root /opt/morhon-odoo19-demo --project morhon19demo --database morhon19demo \
  --http-port 18069 --bus-port 18072 --url https://demo.example.com
sudo ./morhon-odoo19.sh install --root /opt/morhon-odoo19-demo
```

- 共享管理员 `admin/admin`、业务员 `user/user`。只能用于公开合成资料试用；所有访问者共享测试数据，**不要上传客户、银行资料或密钥**。
- 服务端禁止修改共享账号、密码和备用登录凭据；不授予技术管理员权限。管理员可以管理合成业务记录，这是受限业务演示管理员；技术配置和系统管理员专用的全部邮件／回收站不作为本 Demo 的开放入口。
- 为保留 Odoo 原生“至少一名管理员”的约束，另有维护身份位于隔离公司，随机凭据不公布、不写入公开文件。两个共享账号仍只属于演示业务公司；正式维护由宿主离线流程完成。
- 新库不使用 trade 数据或凭据；只生成合成公司、客户、产品、线索、报价草稿和示例附件。没有自动定期重置任务。
- Demo 数据库及网页处于独立内部 Docker 网络；只有固定网页转接容器连接前端网络并发布本机端口。只允许应用访问自己的数据库和本机报表回环地址。真实邮件发送、AI、支付、社交与 WhatsApp 外联均禁用，不伪造成功回执；cron 与队列消费关闭。
- 网页非 root、只读根文件系统，资源和日志有上限；数据库只在专用网络可见。对外代理还应阻止数据库管理、注册、密码重置及旧 XML-RPC/JSON-RPC 入口，并限制上传和请求频率。
- Demo 为数据库设置 512 MiB 写入保护、附件原件 128 MiB／两万文件保护（包含删除后尚未清理的原件）；会话使用有界临时内存，重启后重新登录。空间满时由维护人员处理合成资料，不自动删除业务记录。
- 离线初始化使用专用环境标记；带该标记而未明确 `--no-http` 的 Python 进程会立即退出，不能作为在线绕过开关。

`--cpu-shares-only` 仅用于缺少 CFS 配额支持的旧 NAS 内核，改用 CPU 权重；公共服务器应保持默认硬配额。NAS 的 PID 配额支持也应单独核实，不能据 NAS 配置通过声称服务器资源限制已验证。

## 固定载荷

- Odoo：`registry.cn-hangzhou.aliyuncs.com/morhon_hub/morhon_odoo:19-20261126-mail77-ac47711102ad@sha256:184a0992fcff8d77d02a41060d8c075c64637b11a97729a179f57850c5c9a14e`
- PostgreSQL：`docker.io/library/postgres@sha256:8a7b3318a33b4c4b366d3ada884d5339d719114e837f0d43776835ff01dec927`
- Demo 网页转接：`nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284`
- 整包包含 32 个附加模块、OCR 与既有 Python 依赖；邮件为 77、流程为 19、Molly 为 19；AI 基础库为 1.4.4，仅修复新建／切换服务商的 Odoo 19 兼容错误，未更换模型或自动开启 AI；线索分配为 10.12，**不包含尚未发布的 10.13 手动纳入候选**。
- 容器镜像包含可提取的模块源码；不包含生产数据库、客户附件、生产配置或凭据。各组件沿用各自许可。

`installer19/` 保存可读源文件；`build_release.py` 只将列明的 Demo 模块、运行保护与合成种子嵌入单文件脚本。发布前应核对脚本 SHA-256 和精确镜像摘要。

## v8.3 与已有实例

本版把公开整包同步到已上线的邮件 77、流程 19，Molly 仍为 19，线索分配仍为 10.12。保留已公开的 AI 基础库 1.4.4 修复。未纳入尚未上线的邮件 78、流程 20、Molly 20 或线索分配 10.13。

新镜像已在隔离全新数据库完成 32 个模块的原生安装，并用正常压缩界面核对无 AI 配置时的基础业务、邮件入口及按客户邮箱查找已有商机。原有业务回归和保留新增数据的恢复证据按各精确版本复用，不等于所有业务场景或外部服务均已重新验收。

**v8.3 不接管旧版目录或已有数据库。** 已有实例继续使用创建该目录的原版本脚本，可从对应固定提交取得。已有数据库升级须另走受控维护、配套备份和保留新增业务数据的恢复流程；不要更换镜像后运行全模块更新。本脚本不会自动更新 trade 或公开 Demo，真实邮箱、AI、支付和社交仍需自己的配置及联调。
