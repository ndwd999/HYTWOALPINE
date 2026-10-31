# 安全策略

## 支持范围

| 版本 | 是否接受安全修复 |
|---|---|
| 1.1.x | ✅ |
| ≤ 1.0.x（上游派生） | ❌ 请升级到 1.1.x |

## 报告漏洞

**请不要用公开 Issue 报告安全问题。**

优先使用 GitHub 的私密报告通道：
[Security Advisories → Report a vulnerability](https://github.com/ndwd999/HYTWOALPINE/security/advisories/new)

如果该通道不可用，请在 Issue 中只写"存在安全问题，需要私下沟通"，不要披露细节，维护者会主动联系你。

报告时请尽量包含：

- 受影响版本（`./hysteria.sh -V` 的输出）
- 复现步骤或 PoC（命令、输入、预期与实际结果）
- 影响评估（能否提权、能否读取凭据、是否需要本机访问）
- 你的系统环境（`cat /etc/os-release`、`uname -m`）

## 响应时间

| 阶段 | 目标 |
|---|---|
| 确认收到 | 3 个工作日内 |
| 初步评估 | 7 个工作日内 |
| 修复或缓解方案 | 视严重程度，一般 30 天内 |

## 本项目的安全边界

这个脚本**以 root 运行并修改系统配置**，因此以下事项属于"设计内行为"，不算漏洞：

- 写入 `/etc/hysteria/`、`/usr/local/bin/hysteria`、`/etc/init.d/hysteria`
- 通过 `apk` / `apt` / `dnf` 安装缺失依赖（`openssl`、`sha256sum`、`curl` 或 `wget`）
- 从 `github.com` 下载 Hysteria 内核并安装为可执行文件
- 使用 ACME 模式时向 Let's Encrypt 申请证书并写入 `~/.acme.sh`

以下才是需要报告的问题：

- 能绕过 SHA256 校验写入恶意二进制
- 用户输入能逃逸白名单造成命令注入
- 凭据文件权限放宽到其他用户可读
- 从非官方源下载内容
- 供应链替换（仓库被篡改、Release 被替换）

## 已知限制

这些是协议或部署特性，**不是缺陷**，无需报告：

1. **自签证书 + 客户端 `insecure: true`**：客户端不校验服务端身份。具备中间人位置的攻击者可以冒充节点骗取密码。生产环境请使用 ACME 证书。
2. **不配置防火墙**：脚本不会改动 `iptables` / `nftables`，UDP 端口需要自行在云安全组或 NAT 面板放行。
3. **端口跳跃未启用**：需要用户自行配置服务端 `listen` 区间与客户端 `hopInterval`。
4. **仅 UDP**：Hysteria 2 基于 QUIC，没有 TCP 回退。
