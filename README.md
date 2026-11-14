# LongOS —— OpenWrt 软路由固件（VLAN 多 WAN + accel-ppp 双栈 + 爱快风格面板）

面向 PVE 虚拟机 / x86 物理机，基于 OpenWrt 定制：

- **多线路 WAN**：物理网卡 + VLAN 混合接入，支持 PPPoE / DHCP / 静态 IP / 混合（PPPoE+DHCP）
- **PPPoE 服务端**：accel-ppp，替代原生 rp-pppoe，本地账号密码、IPv4 + IPv6 双栈与 IPv6 PD
- **分流**：mwan3 权重负载均衡 + 按源/目标网段指定出口
- **流控**：每条 WAN 的 CAKE/TBF 上下行限速，按账号限速，LAN 侧 SQM
- **网关功能**：DHCPv4、DHCPv6/RA、DNS、DMZ、端口映射、NAT
- **监控**：线路 IPv4/IPv6 延迟与丢包、30 分钟流量趋势、PPPoE 在线会话与速率
- **面板**：LuCI 自定义应用（深色爱快风格），全部操作写入 UCI 后由后端脚本生成原生配置
- **麻雀云 trea**：配置生成、服务托管、启停与日志查看

> 说明：`trea` 不是 Linux/OpenWrt 原生命令，而是麻雀云提供的调度客户端。本固件只负责
> 它的安装位置（`/usr/bin/trea`）、配置生成（`/etc/trea.conf`）与进程托管。

---

## 一、目录结构

```
softrouter/
├── build/
│   ├── build-firmware.sh          # 完整源码编译固件
│   ├── build-iso.sh               # 磁盘镜像封装为可引导 ISO
│   ├── config.seed                # x86_64 编译基线（包选择）
│   └── package/accel-ppp/         # accel-ppp 的 OpenWrt 打包
├── overlay/                       # 直接覆盖到固件根文件系统
│   ├── etc/config/srouter         # 面板唯一配置源（UCI）
│   ├── etc/accel-ppp/             # 会话上下线钩子（登记在线、按账号限速）
│   ├── etc/init.d/srouter         # 监控采集守护进程
│   ├── etc/init.d/trea            # trea 托管
│   ├── etc/uci-defaults/          # 首启初始化
│   ├── etc/sr-version
│   ├── usr/lib/srouter/sr.sh      # 后端核心：配置生成 + 状态采集
│   ├── usr/lib/srouter/monitor.sh # 速率历史 + 延迟探测
│   ├── usr/sbin/srouter           # 命令行入口
│   ├── usr/share/luci/menu.d/     # 面板菜单
│   ├── usr/share/rpcd/acl.d/      # 面板执行权限
│   └── www/luci-static/resources/ # 面板页面与样式
└── README.md
```

配置链路（单向）：

```
面板 → UCI(/etc/config/srouter) → sr.sh 生成
        ├── /etc/config/network
        ├── /etc/config/dhcp
        ├── /etc/config/mwan3
        ├── /etc/config/firewall（仅 sr_* 段）
        ├── /etc/config/sqm
        ├── /etc/accel-ppp.conf + chap-secrets + limits
        └── /etc/trea.conf
```

---

## 二、编译

构建机要求 Debian 12 / Ubuntu 22.04（Linux，x86_64），磁盘 ≥ 30GB：

```bash
sudo apt update
sudo apt install -y build-essential git make gcc g++ libncurses-dev zlib1g-dev gawk unzip file wget rsync \
                    python3 python3-setuptools python3-pip libelf-dev libssl-dev bison flex pkg-config cmake \
                    xorriso isolinux syslinux-common

cd softrouter/build
bash build-firmware.sh              # 默认 OpenWrt v24.10.4
JOBS=8 bash build-firmware.sh       # 指定并行度
OPENWRT_VERSION=v23.05.5 bash build-firmware.sh
```

产物：`softrouter/out/openwrt-x86-64-generic-squashfs-combined.img.gz`

生成 ISO（可选，BIOS/SeaBIOS 启动）：

```bash
bash build-iso.sh out/openwrt-x86-64-generic-squashfs-combined.img.gz
```

> PVE 更推荐直接导入磁盘镜像；ISO 依赖 memdisk 将整盘载入内存，虚拟机内存需大于镜像体积。

### 云端编译（GitHub Actions，无需本地 Linux）

仓库已内置 [build-firmware.yml](file:///c:/Users/45321/Documents/Trae-CN/default/softrouter/.github/workflows/build-firmware.yml)。
把 **`softrouter/` 目录作为仓库根目录**推送到 GitHub 即可：

```bash
cd softrouter
git init -b main
git add .
git commit -m "LongOS: OpenWrt firmware with accel-ppp + LuCI panel"
git remote add origin git@github.com:<你的账号>/softrouter.git
git push -u origin main
```

触发方式：

- **手动**：Actions → `Build LongOS Firmware` → `Run workflow`，可填 OpenWrt 版本与并行度
- **打 tag**：`git tag v1.0.0 && git push origin v1.0.0`，构建成功后自动创建 Release 并附上镜像
- 每次构建都会上传 `img.gz`、`iso` 与 `SHA256SUMS` 三个产物，保留 30 天

工作流要点：清理 runner 磁盘 → 装依赖 → 缓存 `openwrt/dl` → 克隆指定版本 → 注入 `package/accel-ppp` 与 `overlay` → 用 `config.seed` 生成 `.config` → 编译 → 校验产物 → 打包 ISO → 上传。

> GitHub 托管 runner 单任务上限 6 小时，工作流已设 350 分钟超时。首次全量编译通常 1~3 小时，
> 有 `dl` 缓存后二次构建会明显加快。


---

## 三、部署到 PVE

### 1. 导入磁盘（推荐）

```bash
gzip -d openwrt-x86-64-generic-squashfs-combined.img.gz
qm create 200 --name LongOS --memory 4096 --cores 4 --cpu host \
  --net0 virtio,bridge=vmbr0 --net1 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci --ostype l26
qm importdisk 200 openwrt-x86-64-generic-squashfs-combined.img local-lvm
qm set 200 --scsi0 local-lvm:vm-200-disk-0 --boot order=scsi0
qm set 200 --serial0 socket --vga serial0
qm start 200
```

### 2. ISO 启动

```bash
qm set 200 --ide2 local:iso/softrouter.iso,media=cdrom --boot order=ide2
```

### 3. PVE 桥接 VLAN（关键）

多 VLAN 混合 WAN 时，PVE 的 Linux Bridge 必须开启 VLAN 感知，否则 VLAN 标签丢失、PPPoE 拨号失败：

```bash
# /etc/network/interfaces
auto vmbr0
iface vmbr0 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

然后：

```bash
ifreload -a
```

虚拟机网卡使用 VirtIO（不要 e1000），WAN 口在面板中选择对应网卡并填 VLAN ID 即可。

### 4. 首次登录

- 地址：`http://<LAN IP>`（面板菜单：**服务 → LongOS**）
- 默认 root 密码：`admin`（可在 `build` 时用 `/etc/sr-defaults` 覆盖，登录后请立即修改）
- 首次使用顺序：**线路与网络** 添加 WAN → **PPPoE 服务端** 设置入口与账号 → **流控与分流**

---

## 四、面板功能

| 页面 | 能力 |
| --- | --- |
| 运行概览 | CPU/内存/连接数、WAN 状态与速率、IPv4/IPv6 探测、流量趋势、在线拨号用户 |
| 线路与网络 | WAN 增删改（VLAN/PPPoE/DHCP/静态/混合）、权重、IPv6 开关、LAN 与 DHCPv4、静态绑定 |
| PPPoE 服务端 | accel-ppp 入口/VLAN/地址池/IPv6 PD、账号增删改、按账号限速、在线会话踢下线 |
| 流控与分流 | 每条 WAN 上下行限速、mwan3 策略分流（源/目标网段 → 出口）、LAN 侧 SQM |
| DMZ 与端口映射 | DMZ 主机、DNAT 端口映射 |
| 线路监控 | IPv4/IPv6 延迟与丢包、30 分钟历史流量、IPv6 地址/前缀/PD、物理网卡状态 |
| 系统与 trea | 主机名/DNS/探测目标、管理员密码、trea 配置与启停、日志、重启 |

面板所有动作最终都通过 `/usr/lib/srouter/sr.sh` 执行，可脱离面板用命令行复现与会话排查。

### 为什么选 LuCI 而不是自研前后端

- 底层全部是 UCI / netifd / procd，LuCI 原生适配，省掉一套配置持久化与权限体系；
- 单进程 uhttpd + rpcd，资源占用低，适合软路由长期运行；
- 表格、弹窗、轮询、图表都由本仓库的 `api.js` 封装，页面仍是标准 LuCI 视图；
- 后续若要做独立 App/小程序，直接复用 `sr.sh` 的 JSON 命令即可，无需改底层。

---

## 五、底层命令手册

### 1. VLAN 子接口 + WAN 侧 PPPoE 客户端

```bash
# 手工建 VLAN（面板会自动生成同样的 UCI）
ip link add link eth0 name eth0.10 type vlan id 10
ip link set eth0.10 up

# UCI 方式（等价于面板「新增 WAN 线路」）
uci set network.wan1=interface
uci set network.wan1.device='eth0.10'
uci set network.wan1.proto='pppoe'
uci set network.wan1.username='宽带账号'
uci set network.wan1.password='宽带密码'
uci set network.wan1.ipv6='1'
uci set network.wan1.metric='10'
uci set network.wan1.peerdns='0'
uci add_list network.wan1.dns='223.5.5.5'
uci commit network
/etc/init.d/network reload

# 查看拨号结果
ifstatus wan1 | jq '{up, l3_device, "ipv4-address", "ipv6-address", "ipv6-prefix", "ipv6-prefix-assignment"}'
logread -e pppd | tail -30
```

多 WAN 规则：`metric` 递增、`peerdns 0` 统一 DNS、由 mwan3 接管选路（见第 6 节）。

### 2. accel-ppp 服务端（IPv4 + IPv6 PD）

面板会生成 `/etc/accel-ppp.conf`，核心片段：

```ini
[modules]
pppoe
auth_pap
auth_chap_md5
auth_mschap_v1
auth_mschap_v2
chap-secrets
ippool
sigchld
pppd_compat
ipv6pool
ipv6_dhcp
ipv6_nd

[pppoe]
interface=br-lan                # 或 eth1.100
ac-name=LongOS
service-name=sparrow
ip-pool=srv4
ipv6-pool=srv6                  # 有链路前缀时才下发
ipv6-pool-delegate=srv6pd       # 有 PD 池时才下发

[ppp]
mtu=1492
ipv4=require
ipv6=allow
ipv6-intf-id=random             # 固定标识会让所有会话共用同一个接口标识
ipv6-peer-intf-id=random

[ip-pool]                       # 注意：不是 [ipv4]
gw-ip-address=192.168.200.1
192.168.200.100-192.168.200.200

[dns]                           # DNS 单独成段，不在 [ip-pool] 里
dns1=223.5.5.5
dns2=119.29.29.29

[chap-secrets]
chap-secrets=/etc/accel-ppp/chap-secrets

[pppd-compat]
ip-up=/etc/accel-ppp/ip-up.sh
ip-down=/etc/accel-ppp/ip-down.sh

[ipv6-nd]
AdvManagedFlag=0
AdvOtherConfigFlag=1

[ipv6-pool]
fd00:1::/64,64,name=srv6                      # 链路地址用独立 ULA，不占用 PD 池
delegate=2408:8207:1234::/56,64,name=srv6pd   # 整个 /56 全部用于委派

[ipv6-dhcp]                     # 真正下发 PD 的模块（RFC 3633）
route-via-gw=1
```

账号文件 `/etc/accel-ppp/chap-secrets`：

```
"user1" * "pass123" *
"user2" * "pass456" 192.168.200.150
```

常用命令：

```bash
/etc/init.d/accel-ppp restart
accel-cmd show sessions
accel-cmd show sessions username
accel-cmd terminate if ppp0
accel-cmd terminate username user1
tail -f /var/log/accel-ppp/core.log
```

> IPv6 PD 前提：上游 WAN 必须拿到委派前缀（`ifstatus wan1 | jq '."ipv6-prefix-assignment"'`）。
> 面板「使用检测到的 WAN 前缀」只填 PD 池，**链路前缀保持为空**——若把 PD 池里的第一个 /64
> 同时用作 PPP 链路前缀，它会和委派给第一个客户端的 /64 重叠，服务端会认为该前缀直连，
> 导致客户端 LAN 不通。确实需要链路全局地址时，用一段独立的 ULA（如 `fd00:1::/64`）。
> 客户端侧 PD 由 `[ipv6-dhcp]`（模块名 `ipv6_dhcp`）通过 DHCPv6 下发，客户端路由器
> 需开启 DHCPv6-PD 客户端（OpenWrt 里是 `reqprefix auto`）。这里的 `ipv6-pool=` 只影响
> PPP 接口自身地址，留空不影响 PD 委派。

### 3. DHCPv4 / DHCPv6 / RA

面板生成 `/etc/config/dhcp`：`dnsmasq` 负责 DHCPv4，`odhcpd` 负责 DHCPv6 与 RA：

```bash
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

# 查看租约
cat /tmp/dhcp.leases

# 查看 LAN 的 IPv6 前缀分配
ifstatus lan | jq '."ipv6-prefix-assignment"'
```

### 4. DMZ 与端口映射

面板写入 `firewall` 的 `sr_*` 段，等价命令：

```bash
uci set firewall.sr_dmz=redirect
uci set firewall.sr_dmz.name='SR-DMZ'
uci set firewall.sr_dmz.src='wan'
uci set firewall.sr_dmz.dest='lan'
uci set firewall.sr_dmz.dest_ip='192.168.100.100'
uci set firewall.sr_dmz.proto='all'
uci set firewall.sr_dmz.target='DNAT'

uci set firewall.sr_dmz_fwd=rule
uci set firewall.sr_dmz_fwd.src='wan'
uci set firewall.sr_dmz_fwd.dest='lan'
uci set firewall.sr_dmz_fwd.dest_ip='192.168.100.100'
uci set firewall.sr_dmz_fwd.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
```

端口映射同理（`redirect` + 对应 `rule`），面板会自动补齐放行规则。

### 5. tc / CAKE 流控

面板按 WAN 下发（`ul` 为上行、`dl` 为下行，单位 Kbps）：

```bash
# 上行（出接口方向）限速
tc qdisc replace dev pppoe-wan1 root cake bandwidth 50000kbit nat dual-ack

# 下行（入接口方向）限速
tc qdisc add dev pppoe-wan1 handle ffff: ingress
tc filter add dev pppoe-wan1 parent ffff: protocol all prio 1 u32 match u32 0 0 \
  police rate 500000kbit burst 64k drop flowid :1

# 查看
tc -s qdisc show dev pppoe-wan1
tc -s filter show dev pppoe-wan1 parent ffff:
```

按账号限速由 `/etc/accel-ppp/ip-up.sh` 在会话上线时读取 `/etc/srouter/limits` 并下发。

### 6. mwan3 分流

面板生成 `/etc/config/mwan3`：每条 WAN 一个 `interface` + `member`，默认 `balanced` 策略按权重，
自定义规则按 `src_ip` / `dest_ip` 指定成员。

```bash
mwan3 status
mwan3 interfaces
cat /var/run/mwan3.status
```

源地址策略分流也可用路由表实现：

```bash
ip route add default via 10.10.10.1 table 100
ip rule add from 192.168.100.0/24 table 100 priority 100
```

### 7. 线路监控

```bash
# IPv4 / IPv6 探测
ping -c 3 -W 2 -I pppoe-wan1 223.5.5.5
ping6 -c 3 -W 2 -I pppoe-wan1 2400:3200::1

# 本固件监控进程
/etc/init.d/srouter status
cat /tmp/sr_line.json
tail -5 /tmp/sr_hist.tsv
```

### 8. 麻雀云 trea

```bash
# 放置官方二进制
wget -O /usr/bin/trea <麻雀云官方下载地址>
chmod +x /usr/bin/trea

# 配置由面板「系统与 trea」生成，也可手工编辑
vi /etc/trea.conf

# 服务管理
/etc/init.d/trea enable
/etc/init.d/trea start
/etc/init.d/trea restart
/etc/init.d/trea stop
tail -f /var/log/trea.log

# 前台调试
trea -c /etc/trea.conf
```

`/etc/trea.conf` 示例（字段以麻雀云官方文档为准）：

```ini
server = "https://sparrow.example.com"
token = "节点令牌"
iface = "pppoe-wan1"
interval = 60
```

> trea 只负责上报/调度，不负责 PPPoE 拨号；多线路场景建议在面板中显式绑定出站线路，
> 并放行 trea 到平台地址的出站流量（默认 wan→lan 放行即可）。

### 9. 命令行入口

```bash
srouter status | jq .
srouter wans | jq .
srouter pppoe | jq .
srouter monitor | jq .
srouter apply          # 按 UCI 重新生成全部原生配置
```

---

## 六、关键约束与排查

1. **PVE 桥必须 vlan-aware**，且虚拟机网卡用 VirtIO，否则 VLAN WAN 不通。
2. **同一台机器只应有一个 PPPoE 服务端实例**；入口网卡与 LAN 网桥不要重复绑定。
3. **IPv6 PD 依赖上游委派**；未获取到前缀时，先排查 `ifstatus <wan>` 的 `ipv6-prefix*` 字段。
4. **cake 带宽按运营商实际速率填写**，填高会加剧 bufferbloat；上行建议为实测值的 90%~95%。
5. **accel-ppp 段名/模块名区分**：段用连字符（`[ip-pool]`、`[ipv6-pool]`、`[ipv6-nd]`、
   `[ipv6-dhcp]`、`[pppd-compat]`），模块用下划线（`ipv6pool`、`ipv6_nd`、`ipv6_dhcp`、
   `pppd_compat`）。写错时 accel-ppp 会忽略整段，表现是「能拨号但拿不到地址」。启动失败或
   行为异常先看 `/var/log/accel-ppp/core.log`，再执行 `accel-cmd show sessions` 核对会话。
6. **升级固件保留配置**：`/etc/config/srouter` 是唯一配置源，升级后执行 `srouter apply` 即可恢复。
7. **端口 80/443** 由 LuCI 使用；如需公网访问面板，请改端口并配置防火墙，不建议直接暴露。
8. 本仓库未在 Windows 上编译验证（无 Linux 内核/工具链），构建脚本以 Debian 12 为基准。
