# oneproxy

这个项目现在的目标只有一个：

在服务器执行一条命令，按流程把域名反代上去；成功后不在服务器残留整套项目文件，只保留真正需要的 Caddy 配置和系统依赖。

## 使用方式

推荐直接这样执行：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000
```

也可以不传参数，直接执行后按提示输入：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash
```

## 脚本流程

执行后会按顺序完成：

1. 检测系统包管理器
2. 检测并安装 `curl`、`git`
3. 检测并安装 `node`
4. 检测并安装 `caddy`
5. 询问或读取域名、源站地址
6. 自动写入 Caddy 反代配置
7. 自动重启 Caddy
8. 自动检查域名是否解析到本机
9. 自动检查源站是否可连通
10. 清理旧版本残留的项目目录和无用文件

## 执行结果

成功后服务器上只保留这些真正有用的内容：

- `caddy`
- `/etc/caddy/Caddyfile`
- `/etc/caddy/sites-enabled/*.caddy`

不会要求你再执行 `sudo oneproxy`，也不会默认把整个项目长期留在服务器上。

## 参数

```text
--domain, -d   反代域名，多个域名用英文逗号分隔
--to, -t       源站地址，例如 127.0.0.1:3000
--email, -e    可选，证书通知邮箱
--help, -h     查看帮助
```

示例：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- \
  --domain a.com,b.com \
  --to http://127.0.0.1:3000 \
  --email admin@example.com
```

## 说明

- 域名必须先解析到服务器公网 IP，Caddy 才能正常申请 HTTPS 证书
- 如果源站没启动、端口没监听、或防火墙没放行，脚本会提示异常
- 如果你后续还要新增别的域名，重新执行同一条命令即可
