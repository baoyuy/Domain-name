# oneproxy

这个项目使用 `Nginx + Certbot` 做域名反代和 HTTPS。

目标很简单：

在服务器执行一条命令，按流程把域名反代上去；成功后不在服务器残留整套项目文件，只保留真正需要的 Nginx 配置、证书和系统依赖。

## 使用方式

无交互：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000 --email admin@example.com
```

交互：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash
```

## 脚本流程

执行后会按顺序完成：

1. 检测系统包管理器
2. 检测并安装 `curl`
3. 检测并安装 `nginx`
4. 检测并安装 `certbot`
5. 询问或读取域名、源站地址、邮箱
6. 自动检查域名是否解析到服务器 IP
7. 自动检查源站是否可连通
8. 只有检查通过时才写入 Nginx HTTP 反代配置
9. 先校验配置，再启动 Nginx
10. 自动申请 HTTPS 证书
11. 自动配置 `80 -> 443`
12. 清理旧版本残留的项目目录和无用文件

## 失败与回滚

- 如果域名解析检查失败，不会写入 HTTP 配置
- 如果源站连通性检查失败，不会写入 HTTP 配置
- 如果 HTTPS 证书申请失败，会自动回滚刚写入的 HTTP 配置，避免残留半成品站点

## 执行结果

成功后服务器上只保留这些真正有用的内容：

- `nginx`
- `certbot`
- `/etc/nginx/sites-available/*.conf`
- `/etc/nginx/sites-enabled/*.conf`
- `/etc/letsencrypt/`

## 参数

```text
--domain, -d   反代域名，多个域名用英文逗号分隔
--to, -t       源站地址，例如 127.0.0.1:3000
--email, -e    可选，HTTPS 证书通知邮箱
--help, -h     查看帮助
```

## 说明

- 当前脚本会先做校验，再写入 `80` 端口 Nginx 配置，再通过 Certbot 自动签发证书并切到 HTTPS
- 域名校验会同时参考服务器内网 IP 和公网 IP，避免 NAT 或容器环境下误判
- 如果 Nginx 配置或启动有问题，脚本会优先给出中文错误归纳和建议，再附上 `systemctl/journalctl` 原始摘要
- 如果 HTTPS 申请失败，脚本会输出 Certbot 的友好错误提示和原始错误摘要
- 如果源站没启动、端口没监听、或防火墙没放行，脚本会提示异常
