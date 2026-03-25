# oneproxy

一个适合上传到 GitHub 的命令行一键反代项目。

核心功能：

- 一行命令安装
- 自动检测并安装 `node`、`git`、`curl`、`caddy`
- 使用中文命令行交互管理反代域名
- 支持新增、查看、修改、删除、批量导入
- 自动检查域名解析、本机 IP、源站连通性
- 反代由 `Caddy` 执行，稳定且自带 HTTPS

## 一行安装

上传到 GitHub 后，推荐这样安装：

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh | sudo ONEPROXY_REPO_URL=https://github.com/你的用户名/你的仓库名.git bash
```

安装完成后运行：

```bash
sudo oneproxy
```

## 交互菜单

启动后会显示：

```text
1. 新增反代
2. 查看站点
3. 修改站点
4. 删除站点
5. 批量导入
6. 重载 Caddy
7. 环境诊断
8. 站点诊断
9. 帮助
0. 退出
```

## 站点格式

新增或修改站点时，需要输入：

- 域名，例如 `example.com`
- 多域名，例如 `a.com,b.com`
- 源站，例如 `127.0.0.1:3000`
- 或带协议的源站，例如 `http://127.0.0.1:3000`

程序会自动：

- 写入 Caddy 反代配置
- 重载 Caddy
- 检查域名是否已解析到本机
- 检查源站是否可访问

## 批量导入

批量导入支持纯文本文件，每行一个站点，支持以下格式：

```text
example.com 127.0.0.1:3000
a.com,b.com => http://127.0.0.1:4000
demo.com | https://127.0.0.1:8443
```

说明：

- 空行会忽略
- 以 `#` 开头的行会忽略
- 首个域名会作为站点 ID
- 如果站点已存在，会按同 ID 更新

## 诊断能力

环境诊断会输出：

- 系统平台
- Node 版本
- Caddy 版本
- Caddy 服务状态
- 本机 IP 列表

站点诊断会输出：

- 域名解析到的 IP
- 当前服务器本机 IP
- 是否已正确解析到本机
- 源站是否可连通
- 出错时的修复建议

## 卸载

卸载脚本位于仓库根目录：

```bash
sudo bash /opt/oneproxy/uninstall.sh
```

它会移除：

- `/opt/oneproxy`
- `/usr/local/bin/oneproxy`
- `/etc/caddy/sites-enabled/*.caddy`

## 目录结构

```text
.
├── install.sh
├── uninstall.sh
├── package.json
├── README.md
└── src
    ├── cli.js
    └── lib
        ├── app.js
        ├── caddy.js
        └── store.js
```

## 默认路径

- 配置数据：`/opt/oneproxy/data/sites.json`
- Caddy 站点目录：`/etc/caddy/sites-enabled`
- Caddy 主配置：`/etc/caddy/Caddyfile`

## 使用说明

- 需要以 `root` 或 `sudo` 运行 `oneproxy`
- 域名必须先解析到服务器公网 IP，Caddy 才能自动申请 HTTPS 证书
- 如果源站没启动、端口没监听、或防火墙没放行，诊断里会提示异常
