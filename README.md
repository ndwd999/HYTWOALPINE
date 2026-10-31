# Hysteria 2 一键安装脚本 · Alpine 优化版

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

```bash
# Alpine 需要先装 bash
apk add --no-cache bash curl

curl -fsSLO https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/hysteria.sh
chmod +x hysteria.sh
./hysteria.sh
```

> 建议先看一眼脚本再执行。不要长期 `curl | bash` 线上版本 —— 仓库一旦被篡改，你会静默执行新代码。

菜单：

```
1) 安装 Hysteria 2
2) 卸载 Hysteria 2
3) 启动 / 停止 / 重启 / 状态
4) 修改配置（端口 / 密码 / 伪装站点）
5) 显示客户端配置与分享链接
6) 更新内核
0) 退出
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

### v1.1.0 — 安全重写

修复（对应审计发现）：

1. 内核下载后**强制 SHA256 校验**（原版无任何校验，直接 root 执行）
2. 私钥 / 配置权限 `644 → 600`，目录 `700`（原版私钥同机任意用户可读）
3. 移除 `curl -k`（原版查询 IP 时关闭 TLS 校验，IP 可被中间人伪造）
4. 移除 GitHub API 依赖（原版未认证调用，限流后直接报"无法获取最新版本"退出）
5. 修复改端口后客户端配置被写成 `server: :port`（原版依赖未定义的 `last_ip`）
6. 修复密码含 `&` `/` 时改密码**静默失败**（原版 `sed` 拼接）
7. 端口输入增加校验（原版可用 `1/;e id;#` 触发 `sed` 的 `e` 命令执行）
8. 删除原 `hysteria.sh` 第 314 行来路不明的 ` drowsiness continues:`
9. 新增：架构自适应、OpenRC 服务与开机自启、配置原子渲染、状态查看、伪装站点可改、单实例探测

> v1.0.4 旧脚本已移除 —— 它带着同样的全部问题，留在仓库里只会误导用户。

## 许可与致谢

- 原脚本作者：[Misaka-blog](https://github.com/Misaka-blog)，思路与默认参数来自其项目
- 内核：[apernet/hysteria](https://github.com/apernet/hysteria)（现迁移至 HyNetworks）
- 本项目以 MIT 许可证发布，见 [LICENSE](LICENSE)

> 本项目与 Hysteria 官方、原作者的仓库无隶属关系。脚本会修改系统配置并以 root 运行，请自行评估后再使用。
