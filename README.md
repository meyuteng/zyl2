# L2TP 服务端一键部署（accel-ppp）

在 Ubuntu 上一条命令搭起 L2TP VPN 服务端。**不启用 IPsec。**

用 [accel-ppp](https://github.com/accel-ppp/accel-ppp) 而不是常见的 `xl2tpd`，因为
xl2tpd 的数据面在用户态：pppd 挂在 pty 上，每个包要在用户态/内核态之间来回拷贝。
实测 **2 个会话就能吃掉单核 20%**，每秒 3 万多次系统调用；换成 accel-ppp
（数据面交给内核 L2TP + 内核 PPP）后，同样流量下主进程 CPU 占用 **0.0%**，
2 秒内只有 1 次系统调用。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/install.sh | bash
```

或者克隆下来再跑：

```bash
git clone https://github.com/<你的用户名>/<仓库名>.git
cd <仓库名>
sudo bash install.sh
```

装完直接打印连接信息。默认：

| 项 | 值 |
|---|---|
| 账号 | `123` |
| 密码 | `123` |
| 端口 | `1701/udp` |
| 来源限制 | 允许任意 IP |
| 地址池 | `172.28.42.10-250`，网关 `172.28.42.1` |
| MTU / MRU | `1400` |
| DNS | `8.8.8.8` / `8.8.4.4` |
| IPsec | **不使用** |

## 改配置

安装时用环境变量覆盖，不用改脚本：

```bash
sudo L2TP_USER=myuser L2TP_PASS='强口令' bash install.sh
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `L2TP_USER` / `L2TP_PASS` | `123` / `123` | 客户端账号密码 |
| `L2TP_PORT` | `1701` | 服务端口 |
| `GW_IP` | `172.28.42.1` | 隧道网关（服务端侧地址） |
| `POOL_RANGE` | `172.28.42.10-250` | 分配给客户端的地址池 |
| `PPP_MTU` | `1400` | 无 IPsec 时可以调到 `1450`，越大包数越少 |
| `DNS1` / `DNS2` | `8.8.8.8` / `8.8.4.4` | 下发给客户端的 DNS |
| `ALLOW_ALL` | `1` | `0` 时改用 `CLIENT_ALLOW` 做白名单 |
| `CLIENT_ALLOW` | `0.0.0.0/0` | `ALLOW_ALL=0` 时生效，如 `1.2.3.0/24` |
| `REPO_RAW` | 自动拼装 | 预编译包的下载基址 |
| `GITHUB_USER` / `GITHUB_REPO` | 需修改 | 你 fork/上传后的仓库 |

> `install.sh` 顶部的 `GITHUB_USER` / `GITHUB_REPO` 是占位符，
> **上传到自己的 GitHub 后记得改成实际值**，否则预编译包下载会失败
> （会退化成源码编译，仍然能装成功）。

## 客户端怎么连

- 类型选 **L2TP**，**不要**勾选 IPsec / 预共享密钥。
- Windows 默认强制走 L2TP/IPsec，需要改注册表放行纯 L2TP：
  ```
  HKLM\SYSTEM\CurrentControlSet\Services\RasMan\Parameters
  ProhibitIpSec (DWORD) = 1
  ```
  改完重启。
- macOS / iOS / Android 一般直接选 L2TP 即可。

## 支持的版本

预编译包用 **Ubuntu 20.04 + 静态链接 OpenSSL** 编译，因此：

| 系统 | 说明 |
|---|---|
| Ubuntu 22.04 / 24.04 / 26.04 | 直接使用预编译包 |
| Ubuntu 20.04 | 直接使用预编译包 |
| Ubuntu 18.04 及更低 | 预编译包跑不起来，`install.sh` 会**自动降级为源码编译**（需联网，几分钟） |

为什么静态链接 OpenSSL：accel-ppp 默认按库名链接，Ubuntu 20.04 上是
`libcrypto.so.1.1`，而 22.04 起系统只提供 `libcrypto.so.3`，动态链接会导致
预编译包在新系统上直接 `not found`。静态链接后，产物只依赖 glibc。

`install.sh` 装了预编译包后会**真正启动一次做探测**，跑不起来才退回源码编译，
所以不会出现「装上了但用不了」的情况。

> 仅支持 x86_64。ARM 机器请直接用 `install.sh` 的源码编译路径（脚本会自动走到）。

## 自己重新生成预编译包

```bash
sudo bash build.sh
```

**必须在 Ubuntu 20.04 上跑**才能保证兼容性（glibc 向后兼容）。
脚本会编译、校验静态链接、打包到 `dist/`，然后你 commit push 即可。

## 卸载

```bash
sudo bash uninstall.sh            # 保留配置和日志
sudo bash uninstall.sh --purge    # 全删
```

## 常用运维命令

```bash
# 查看当前会话
printf 'show sessions\r\n' | timeout 3 nc 127.0.0.1 2000

# 服务状态
systemctl status accel-ppp

# 实时日志
tail -f /var/log/accel-ppp/accel-ppp.log

# 改完 /etc/accel-ppp.conf 后热加载（不断开已有会话）
systemctl reload accel-ppp

# 查看内核 L2TP 加速是否生效
lsmod | grep l2tp_ppp
```

`accel-cmd` 需要连 `tcp=127.0.0.1:2001`，配置里已写好；如果刚改完配置
它连不上，重启一次服务即可（热加载不会新开监听端口）。

## 目录结构

```
├── install.sh     一键部署
├── uninstall.sh   卸载
├── build.sh       重新生成预编译包（在 Ubuntu 20.04 上跑）
└── dist/
    ├── accel-ppp-1.14.0-ubuntu20.04-x86_64.tar.gz
    └── SHA256SUMS
```

---

## ⚠️ 安全提醒

默认配置是「**不加密 + 允许任意来源 + 弱口令 123/123**」：

- L2TP 本身不加密，隧道内容可被链路上的人看到；
- `1701/udp` 对全网开放，账号又是 `123/123`，会被扫描器直接爆破成功。

这套配置适合**自用中转**。如果要长期对公网开放，至少做到：

1. 换强口令：`sudo L2TP_USER=xxx L2TP_PASS='<长随机串>' bash install.sh`
2. 客户端 IP 相对固定时收紧白名单：
   `sudo ALLOW_ALL=0 CLIENT_ALLOW='1.2.3.0/24' bash install.sh`
3. 需要加密就套一层 IPsec，或者干脆换 WireGuard。

另：本机 CLI（`127.0.0.1:2000`）无密码但有会话管理权限，仅监听本机。
如果机器上还跑着其他可被攻破的服务，建议在 `/etc/accel-ppp.conf` 的 `[cli]`
段加 `password=`。
