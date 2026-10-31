# 贡献指南

欢迎提交 Issue 和 PR。这个项目只有一条硬规则：**脚本以 root 运行，任何改动都不能降低安全性**。

## 提交 Issue 前

1. 先读 [README 的故障排查](README.md#故障排查) 和 [SECURITY.md](SECURITY.md) 的"已知限制"——很多"连不上"是 UDP 未放行或自签证书导致的。
2. 确认不是重复 Issue。
3. 附上环境信息：`cat /etc/os-release`、`uname -m`、`./hysteria.sh -V`、相关日志 `tail -50 /var/log/hysteria.log`。

安全问题请走私密通道，见 [SECURITY.md](SECURITY.md)。

## 提交 PR

### 必须通过

```bash
bash -n hysteria.sh      # 语法
shellcheck -s bash hysteria.sh   # 静态检查（CI 也会跑，warning 级别）
```

CI 配置在 `.github/workflows/shellcheck.yml`，PR 会强制检查。

### 代码约定

| 项 | 约定 |
|---|---|
| 兼容性 | 面向 Alpine 的 busybox（`ash`/`bash` 子集）。不要用 GNU 独有的参数，如 `sed -i` 无备份后缀、`install`、`grep -P` |
| 依赖 | 尽量只用 busybox 已有的命令；新增外部依赖需在 `ensure_deps()` 中声明，并给出"没有该依赖时的降级路径" |
| 下载 | 一律走 `http_get()`，不要直接写 `curl` 或 `wget`，以保持"curl/wget 二选一"的兼容性 |
| 用户输入 | 必须先过 `valid_*` 校验函数；**禁止**把输入拼进 `sed` 表达式或 `eval` |
| 配置生成 | 由 `node.conf` + 固定模板渲染，不要用 `sed` 逐行修改 YAML |
| 文件权限 | 含凭据的文件一律 `600`，目录 `700`；新增文件要同步设置权限 |
| 行尾 | LF。`.gitattributes` 已强制，但提交前请自行确认 |

### 提交信息

用中文或英文都可以，建议采用前缀：

```
feat:     新功能
fix:      修复
docs:     文档
ci:       CI 配置
refactor: 重构（不改变行为）
```

## 本地测试

脚本会改系统，**不要在主力机器上直接跑测试**。用容器或隔离目录：

```bash
# 方式一：容器里跑
docker run --rm -it -v "$PWD:/w" alpine:3.20 sh -c \
  'apk add bash curl openssl && cd /w && bash hysteria.sh'

# 方式二：把绝对路径重定向到 /tmp 后 source 单个函数
sed -e 's#/etc/hysteria#/tmp/t/etc/hysteria#g' \
    -e 's#/root/hy#/tmp/t/root/hy#g' \
    -e 's#/usr/local/bin#/tmp/t/bin#g' hysteria.sh > /tmp/t/test.sh
```

涉及下载的逻辑，建议用伪造的 `curl` / `wget` 打桩（放在 `PATH` 前面），这样可以测试：

- 哈希匹配 / 不匹配两条路径
- 下载内容过小（错误页）的拦截
- `hashes.txt` 缺失时的中止
- 端口被占用时的重新询问

## 文档

改行为请同步更新：

- `README.md` — 面向用户的使用说明
- `CHANGELOG.md` — 在 `[未发布]` 下追加条目
