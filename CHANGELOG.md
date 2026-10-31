# 变更日志

本项目的所有重要变更都记录在此文件。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [1.1.1] - 2026-10-31

### 新增

- 新增 `http_get()` 统一网络请求入口：**curl 优先，wget 回退**，兼容 Alpine 默认的 busybox wget
- 依赖检查改为 `curl` / `wget` **二选一**，Alpine 上不再强制安装 curl
- 公网 IP 查询、`acme.sh` 下载均改走 `http_get`，无 curl 环境也能完成安装

### 文档

- README 快速开始补充 `wget -O` 安装方式，并说明 `-O` / `-o` 在 busybox 下的语义差异
- README 新增"客户端配置怎么用""日常运维"两节
- 新增 `SECURITY.md`、`CONTRIBUTING.md`、Issue / PR 模板与 `.gitattributes`

### 修复

- 修复 `wget -O` 下载中断留下 0 字节文件、`bash -n` 却返回成功导致"执行无反应"的误导问题（文档层给出 `[ -s ]` 检查）

## [1.1.0] - 2026-10-31

安全重写，针对原移植版本的审计发现逐条修复。

### 修复

1. 内核下载后**强制 SHA256 校验**（原版无任何校验，直接以 root 执行下载所得二进制）
2. 私钥 / 配置权限 `644 → 600`，目录 `700`（原版私钥同机任意用户可读）
3. 移除 `curl -k`（原版查询公网 IP 时关闭 TLS 校验，IP 可被中间人伪造）
4. 移除 GitHub API 依赖，改用 `releases/latest/download`（原版未认证调用，触发限流后直接报"无法获取最新版本"退出）
5. 修复改端口后客户端配置被写成 `server: :port`（原版依赖未定义的 `last_ip`）
6. 修复密码含 `&` `/` 时改密码**静默失败**（原版用 `sed` 拼接）
7. 端口输入增加校验（原版可用 `1/;e id;#` 触发 `sed` 的 `e` 命令执行）
8. 删除原 `hysteria.sh` 第 314 行来路不明的 ` drowsiness continues:`

### 新增

- 架构自适应：amd64 / arm64 / arm / 386 / loong64 / riscv64 / s390x / mipsle
- OpenRC 服务与开机自启，无 OpenRC 时回退 `nohup`
- 配置**原子渲染**：服务端、客户端、分享链接由同一份 `node.conf` 生成
- 输入白名单校验：端口 / 密码 / 域名 / 伪装站点
- 状态查看、端口占用探测、伪装站点可改、单实例探测
- 非交互参数 `-h` / `-V`

### 移除

- 删除 `hysteria-v1.0.4.sh`。该文件带着与 `hysteria.sh` 相同的全部问题，保留只会误导用户。

## [1.0.5] 及更早

上游 [Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install) 派生的历史版本，
未在本仓库保留。如需追溯，请查阅上游仓库。

[未发布]: https://github.com/ndwd999/HYTWOALPINE/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/ndwd999/HYTWOALPINE/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/ndwd999/HYTWOALPINE/releases/tag/v1.1.0
