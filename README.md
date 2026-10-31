# Hysteria 2 一键安装脚本 · Alpine 优化版

[![shellcheck](https://github.com/ndwd999/HYTWOALPINE/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/ndwd999/HYTWOALPINE/actions/workflows/shellcheck.yml)

面向 **Alpine Linux / 低配 VPS（128MB 起）** 的 Hysteria 2 部署脚本，单文件、无外部依赖、交互式菜单。
本仓库是对 [Misaka-blog](https://github.com/Misaka-blog/hysteria-install) 原脚本的**安全重写**，不是简单移植。

> **为什么重写**：原移植版本存在"下载二进制不校验哈希"、"私钥 644 全局可读"、"改端口把客户端配置写坏"等问题，另有一行来路不明的乱码。本版本逐条修复并补齐了 Alpine 上缺失的服务管理能力。详见 [变更日志](#变更日志)。

## 特性

| 能力 | 说明 |
|---|---|
| **二进制完整性校验** | 从官方 `hashes.txt` 取 SHA256 校验，**校验失败拒绝安装**，不留半成品 |
| **无需 GitHub API** | 走 `releases/latest/download`，不再因 API 限流导致"无法获取最新版本" |
| **最小权限** | 私钥、服务端配置、客户端配置一律 `600`，目录 `700`，证书 `644` |
| **输入全校验** | 端口 / 密码 / 域名 / 伪装站点白名单校验，配置文件整体重写，杜绝 sed 注入与拼接破坏 |
| **配置原子一致** | 服务端、客户端、分享链接由同一份 `node.conf` 渲染，改端口/密码不会出现三者不一致 |
| **架构自适应** | amd64 / arm64 / arm / 386 / loong64 / riscv64 / s390x / mipsle |
| **服务托管** | Alpine 上自动写入 OpenRC 服务并开机自启；无 OpenRC 时回退 `nohup` |
| **三种证书** | 自签（免域名）/ ACME 自动申请（含自动续期）/ 导入已有证书 |

## 快速开始

Alpine 自带的是 busybox 的 `wget`（**没有 curl**），并且默认没装 `bash`，先补齐：

```bash
apk add --no-cache bash ca-certificates
```

下载脚本，两种方式等价，按手头有的工具选一个：

```bash
# 方式 A：wget（Alpine 开箱即用，推荐）
wget -O hysteria.sh https://raw.githubusercontent.com/ndwd999/HYTWOALPINE/main/hysteria.sh \
  && [ -s hysteria.sh ] && echo "下载完成：$(wc -c < hysteria.sh) 字节"

# 方式 B：curl（自带失败即报错，不会留下空文件）
curl -fsSL -o hysteria.sh https://raw.githubusercontent.com/ndwd999/HYTWOALPINE/main/hysteria.sh

chmod +x hysteria.sh
./hysteria.sh
```

> `-O` 是**大写字母**，表示"保存到指定文件名"；写小写 `-o` 在 busybox 里是"日志文件"，会把网页内容写进日志而脚本是空的。
> **务必确认文件非空**：`wget -O` 在网络中断时会留下 0 字节文件，而 `bash -n` 对空文件同样返回成功，直接执行则毫无反应、容易被误认为"脚本有问题"。上面方式 A 已内置 `[ -s ]` 检查。正常大小约 30 KB。
> 若 `wget` 报 `not an http or ftp url` 或证书错误，说明该系统的 busybox 未编译 TLS 支持，改用方式 B（`apk add curl`），或临时加 `--no-check-certificate`（不推荐，仅限排障）。
>
> 不建议 `curl ... | bash` 直接管道执行 —— 仓库一旦被篡改，你会静默执行新代码，且无法先审阅。脚本也会检测到非交互输入并直接退出（菜单需要终端才能读键）。

菜单（框线宽度随终端自适应，54–70 列）：

```
  ╭──────────────────────────────────────────────────────────────╮
  │                                                              │
  │  Hysteria 2 · Alpine 一键脚本                        v1.1.2  │
  │  apernet/hysteria · OpenRC 托管 · SHA256 校验                │
  │                                                              │
  ├──────────────────────────────────────────────────────────────┤
  │                                                              │
  │  1   安装 / 重装   下载内核，生成服务端与客户端配置          │
  │  2   卸载          停止服务并删除全部文件                    │
  │                                                              │
  │  3   服务管理      启动 / 停止 / 重启 / 状态                 │
  │  4   修改配置      端口 / 密码 / 伪装站点                    │
  │  5   查看配置      客户端 YAML 与分享链接                    │
  │  6   更新内核      校验 SHA256 后替换二进制                  │
  │                                                              │
  │  0   退出                                                    │
  │                                                              │
  ╰──────────────────────────────────────────────────────────────╯
```

也支持非交互参数：`./hysteria.sh -h`、`./hysteria.sh -V`。

## 安装时的交互项

| 项目 | 说明 | 默认 |
|---|---|---|
| 证书类型 | 1 自签 / 2 ACME / 3 已有证书 | 1 |
| 端口 | 1–65535，留空随机（20000–60000） | 随机 |
| 密码 | 留空自动生成 16 位；禁止空格、引号、反斜杠、非 ASCII | 随机 |
| 伪装站点 | 不含 `https://`，填了也会自动去掉 | `www.bing.com` |

安装完成后产物：

```
/usr/local/bin/hysteria            # 内核（校验通过才写入）
/etc/hysteria/config.yaml          # 服务端配置        600
/etc/hysteria/private.key          # 私钥              600
/etc/hysteria/cert.crt             # 证书              644
/etc/hysteria/node.conf            # 节点元数据        600
/root/hy/hy-client.yaml            # 客户端配置        600
/root/hy/url.txt                   # 分享链接          600
/etc/init.d/hysteria               # OpenRC 服务（仅 Alpine）
```

## 客户端配置怎么用

装完在菜单里选 `5) 显示客户端配置与分享链接`，会打印两个东西：

```
/root/hy/hy-client.yaml   # 完整客户端配置
/root/hy/url.txt          # 一行 hysteria2:// 分享链接
```

两种导入方式，任选其一：

| 方式 | 操作 | 适合 |
|---|---|---|
| **导入链接** | 复制 `url.txt` 里整行，客户端选"从剪贴板导入" | 手机、临时设备 |
| **导入文件** | 把 `hy-client.yaml` 传到设备，客户端选"从文件导入" | 桌面、多设备复用一个节点 |

客户端下载：[hysteria.network](https://hysteria.network/zh/) 或 [GitHub Releases](https://github.com/apernet/hysteria/releases)，
支持 Windows / macOS / Android / iOS，路由器可用插件版。

> 自签证书模式下，客户端配置里是 `insecure: true` —— 这是免域名方案的必然代价，
> 客户端不校验服务端身份。**有域名就选 ACME 模式**，脚本会自动把它置为 `false`。
> 同一份 `hy-client.yaml` 可以复制到多台设备，但密码或端口一改就得重新导入。

## 日常运维

改配置走菜单 `4)`，**不要手改 `config.yaml`**：

```
1) 端口    2) 密码    3) 伪装站点
```

改完脚本会把服务端配置、客户端 yaml、分享链接**一起重写**并重启服务，
所以旧链接立刻失效，需要重新导入客户端。手改服务端配置而不改 `node.conf`，
下次改端口时会被覆盖。

常用命令：

```bash
rc-service hysteria status     # 状态
rc-service hysteria restart    # 重启
rc-update show | grep hysteria # 确认开机自启
tail -f /var/log/hysteria.log  # 日志
```

- **更新内核**：菜单 `6)`，同样会校验 SHA256 后才替换，失败保留旧二进制。
- **卸载**：菜单 `2)`，会停止服务、删二进制与配置目录、取消开机自启。

## 安全设计

- **供应链**：下载与校验清单都来自同一个 release；哈希取不到、格式异常、内容过小（<1 MB）、校验不符，一律中止。确需跳过时显式设 `HY_SKIP_VERIFY=1`。
- **本地权限**：所有含凭据的文件 `600`，`/etc/hysteria` 与 `/root/hy` 为 `700`。同机其他用户读不到私钥和密码。
- **注入面**：不再把用户输入拼进 `sed` 表达式；端口、密码、域名、站点全部走白名单校验；YAML 由固定模板整体生成。
- **TLS**：不再使用 `curl -k`，公网 IP 查询走正常证书校验。

### 已知限制（属于协议/部署特性，不是缺陷）

1. **自签证书 + `insecure: true`**：客户端不校验服务端身份，具备中间人位置的攻击者可以冒充节点骗取密码。**生产环境建议选 ACME 证书**，脚本会把 `insecure` 自动置为 `false`。
2. **NAT VPS**：脚本不碰防火墙。请自行在云安全组 / NAT 面板放行对应 UDP 端口。
3. **端口跳跃**：本脚本不启用。如需使用，服务端 `listen` 改为端口区间，客户端加 `transport.udp.hopInterval`，两者必须匹配。
4. **仅支持 UDP**：Hysteria 2 本身基于 QUIC。

## 故障排查

| 现象 | 排查 |
|---|---|
| `无法获取官方 hashes.txt` | 网络不通或被拦；确认能访问 `github.com` 后再试 |
| `SHA256 校验失败` | 下载被篡改/代理篡改，**不要**用 `HY_SKIP_VERIFY` 绕过，换网络重试 |
| 服务启动失败 | `cat /var/log/hysteria.log`；常见为端口占用、证书路径错 |
| 客户端连不上 | 确认 UDP 端口已映射到公网；自签证书必须在客户端开 `insecure` |
| ACME 申请失败 | 域名 A/AAAA 记录需已生效，且 80 端口可被外网访问 |

## 变更日志

版本历史见 [CHANGELOG.md](CHANGELOG.md)。当前版本 **v1.1.2**。

v1.1.2 只调整终端界面：修掉中文错列导致的框线断裂、菜单改为自适应宽度、安装向导分段并补「下一步」指引，安装逻辑与安全策略未变。
v1.1.0 是对原移植版本的安全重写：内核 SHA256 强制校验、凭据权限收紧、移除 `curl -k`、
修复改端口写坏客户端配置、修复密码含特殊字符静默失败、拦截 `sed` 注入等，共 8 项修复。

## 许可与致谢

- 原脚本作者：[Misaka-blog](https://github.com/Misaka-blog)，思路与默认参数来自其项目
- 内核：[apernet/hysteria](https://github.com/apernet/hysteria)（现迁移至 HyNetworks）
- 本项目以 MIT 许可证发布，见 [LICENSE](LICENSE)
- 参与贡献请遵守 [行为准则](CODE_OF_CONDUCT.md)，提交前请读 [贡献指南](CONTRIBUTING.md)

> 本项目与 Hysteria 官方、原作者的仓库无隶属关系。脚本会修改系统配置并以 root 运行，请自行评估后再使用。
