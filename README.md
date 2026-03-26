# oneproxy

`oneproxy` 是一个面向服务器的一键反代脚本，底层使用 `Nginx + Certbot`。

目标只有一个：

执行一条命令，自动完成域名检查、Nginx 反代配置、HTTPS 证书申请、80 跳 443，并在失败时尽量自动回滚，不留下半成品配置。

## 用法

无交互：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000 --email admin@example.com
```

交互：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash
```

## 参数

```text
--domain, -d   反代域名，多个域名用英文逗号分隔
--to, -t       源站地址，例如 127.0.0.1:3000 或 http://127.0.0.1:3000
--email, -e    可选，HTTPS 证书通知邮箱
--help, -h     查看帮助
```

## 脚本流程

1. 检测系统包管理器
2. 检测并安装 `curl`
3. 检测并安装 `nginx`
4. 检测并安装 `certbot`
5. 读取域名、源站地址、邮箱
6. 检查域名是否解析到当前服务器 IP
7. 检查源站是否可连通
8. 只有检查通过时才写入 Nginx HTTP 配置
9. 校验并启动 Nginx
10. 自动申请 HTTPS 证书
11. 自动配置 `80 -> 443`
12. 做最终访问验证
13. 清理旧版残留文件

## 失败与回滚

- 域名解析失败：不写入 HTTP 配置
- 源站连通失败：不写入 HTTP 配置
- 写入配置后任一步骤异常：自动回滚站点配置
- HTTPS 申请失败：自动回滚刚写入的 HTTP 配置
- 如果存在同名旧配置：会先备份，再覆盖；异常时恢复旧配置

## 成功后保留的内容

- `nginx`
- `certbot`
- `/etc/nginx/sites-available/*.conf`
- `/etc/nginx/sites-enabled/*.conf`
- `/etc/letsencrypt/`

## 卸载单个站点

```bash
sudo bash uninstall.sh your-domain.com
```

## 说明

- 域名校验会同时参考服务器内网 IP 和公网 IP，减少 NAT 或容器环境下的误判
- HTTPS 申请依赖 80 端口可被 Let’s Encrypt 访问
- 最终访问验证失败时，脚本会给出警告，但不会自动删除已经成功配置的 HTTPS 站点
- 当前仓库主入口就是仓库根目录下的 `install.sh`，不再依赖旧 Node 方案

- Linux.do 社区 [<sup>1</sup>](https://linux.do/)
