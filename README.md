# oneproxy

这个项目使用 `Nginx` 做域名反代。

目标很简单：

在服务器执行一条命令，按流程把域名反代上去；成功后不在服务器残留整套项目文件，只保留真正需要的 Nginx 配置和系统依赖。

## 使用方式

无交互：

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000
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
4. 询问或读取域名、源站地址
5. 自动写入 Nginx 反代配置
6. 先校验配置，再启动 Nginx
7. 自动检查域名是否解析到本机
8. 自动检查源站是否可连通
9. 清理旧版本残留的项目目录和无用文件

如果域名解析检查或源站连通性检查失败，脚本会返回失败状态，不会把这次执行标记为“部署完成”。

## 执行结果

成功后服务器上只保留这些真正有用的内容：

- `nginx`
- `/etc/nginx/sites-available/*.conf`
- `/etc/nginx/sites-enabled/*.conf`

## 参数

```text
--domain, -d   反代域名，多个域名用英文逗号分隔
--to, -t       源站地址，例如 127.0.0.1:3000
--help, -h     查看帮助
```

## 说明

- 当前脚本默认写入 `80` 端口的 Nginx 反代配置
- 如果 Nginx 配置或启动有问题，脚本会优先给出中文错误归纳和建议，再附上 `systemctl/journalctl` 原始摘要
- 如果源站没启动、端口没监听、或防火墙没放行，脚本会提示异常
- 如果你后续还要新增别的域名，重新执行同一条命令即可
