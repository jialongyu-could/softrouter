#!/bin/sh
# LongOS 控制核心
# 面板通过 rpcd file.exec 调用，子命令 + JSON 入参，统一输出 JSON
# 职责：UCI 配置 -> 生成 OpenWrt 原生配置（network/dhcp/mwan3/firewall/sqm/accel-ppp）
#       状态采集（线路速率、CPU/内存、PPPoE 在线、IPv4/IPv6 探测历史）

. /lib/functions.sh
. /lib/functions/network.sh

SR="longos"
IFSTATUS="/sbin/ifstatus"
RUNDIR="/tmp/lo_ppp"
VERSION_FILE="/etc/longos-version"
HIST="/tmp/lo_hist.tsv"
LINE_JSON="/tmp/lo_line.json"

log() { logger -t longos "$*"; }

# ---------------- JSON 辅助 ----------------

jnum() {
	case "$1" in ''|*[!0-9.-]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

jbool() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

jesc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/ /g" | tr -d '\r\n'
}

# 读取 JSON 文件，非法或空文件返回 {}
file_json() {
	if [ -s "$1" ]; then
		jq -c . "$1" 2>/dev/null || printf '{}'
	else
		printf '{}'
	fi
}

# ---------------- 配置读取 ----------------

[ -f "/etc/config/$SR" ] && config_load "$SR"

wan_ids() {
	uci -q show "$SR" 2>/dev/null | sed -n "s/^$SR\.\([^.=]*\)=wan$/\1/p"
}

account_ids() {
	uci -q show "$SR" 2>/dev/null | sed -n "s/^$SR\.\([^.=]*\)=account$/\1/p"
}

rule_ids() {
	uci -q show "$SR" 2>/dev/null | sed -n "s/^$SR\.\([^.=]*\)=rule$/\1/p"
}

forward_ids() {
	uci -q show "$SR" 2>/dev/null | sed -n "s/^$SR\.\([^.=]*\)=forward$/\1/p"
}

# PPPoE 服务端入口设备名：vlan>0 时为 device.vlan
pppoe_ifname() {
	local device="$1" vlan="$2"
	if [ "$(jnum "$vlan")" -gt 0 ] 2>/dev/null; then
		printf '%s.%s' "$device" "$vlan"
	else
		printf '%s' "$device"
	fi
}

# ---------------- 速率采样 ----------------

sample_rates() {
	local now
	now=$(date +%s)
	awk 'NR>2 { gsub(":", "", $1); print $1, $2, $10 }' /proc/net/dev > /tmp/lo_rates.now
	if [ -f /tmp/lo_rates.prev ] && [ -s /tmp/lo_rates.prev ]; then
		awk -v now="$now" '
			NR == FNR { if (FNR == 1) { pts = $1; next } prx[$1] = $2; ptx[$1] = $3; next }
			{
				if (!($1 in prx)) next
				dt = now - pts; if (dt < 1) dt = 1
				rx = ($2 - prx[$1]) * 8 / dt; tx = ($3 - ptx[$1]) * 8 / dt
				if (rx < 0 || rx > 1e11) rx = 0
				if (tx < 0 || tx > 1e11) tx = 0
				printf "%s %.0f %.0f\n", $1, rx, tx
			}' /tmp/lo_rates.prev /tmp/lo_rates.now > /tmp/lo_rates.json
	else
		: > /tmp/lo_rates.json
	fi
	{ echo "$now"; cat /tmp/lo_rates.now; } > /tmp/lo_rates.prev
}

# 返回 "rx tx"（bps）
iface_rate() {
	local ifc="$1" line
	[ -n "$ifc" ] || { printf '0 0'; return; }
	line=$(awk -v n="$ifc" '$1 == n { print $2, $3; exit }' /tmp/lo_rates.json 2>/dev/null)
	[ -n "$line" ] || { printf '0 0'; return; }
	printf '%s' "$line"
}

# ---------------- 系统信息 ----------------

cpu_usage() {
	local total idle prev_total prev_idle
	set -- $(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
	total=$1; idle=$2
	prev_total=0; prev_idle=0
	[ -f /tmp/lo_cpu.prev ] && read prev_total prev_idle < /tmp/lo_cpu.prev
	echo "$total $idle" > /tmp/lo_cpu.prev
	[ "$prev_total" -gt 0 ] 2>/dev/null || { printf '0'; return; }
	local dtotal=$((total - prev_total)) didle=$((idle - prev_idle))
	[ "$dtotal" -le 0 ] && dtotal=1
	printf '%s' $(((dtotal - didle) * 100 / dtotal))
}

cpu_info() {
	local model freq
	model=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)
	freq=$(awk -F': ' '/cpu MHz/{printf "%.0f", $2; exit}' /proc/cpuinfo)
	jq -cn --arg model "$model" --argjson cores "$(nproc)" --argjson freq "$(jnum "$freq")" \
		'{model:$model,cores:$cores,freq:$freq}'
}

mem_info() {
	awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
		if (!t) t=1;
		printf "{\"total\":%d,\"used\":%d,\"pct\":%d}", t, t-a, (t-a)*100/t
	}' /proc/meminfo
}

conn_count() {
	cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0
}

iface_status_json() {
	local js
	js=$($IFSTATUS "$1" 2>/dev/null)
	[ -n "$js" ] || js='{}'
	printf '%s' "$js" | jq -c '{
		up: (.up // false),
		l3: (.l3_device // .device // ""),
		proto: (.proto // ""),
		ipv4: (."ipv4-address"[0].address // ""),
		ipv4_mask: (."ipv4-address"[0].mask // 0),
		gw: (."route"[0].nexthop // ""),
		ipv6: (."ipv6-address"[0].address // ""),
		ipv6_prefix: ((."ipv6-prefix"[0].address // "") + (if (."ipv6-prefix"[0].address) then "/" + ((."ipv6-prefix"[0].mask|tostring)) else "" end)),
		ipv6_pd: ((."ipv6-prefix-assignment"[0].address // "") + (if (."ipv6-prefix-assignment"[0].address) then "/" + ((."ipv6-prefix-assignment"[0].mask|tostring)) else "" end)),
		dns: ((."dns-server" // []) | join(",")),
		uptime: (.uptime // 0)
	}' 2>/dev/null || printf '{"up":false,"l3":"","proto":"","ipv4":"","ipv4_mask":0,"gw":"","ipv6":"","ipv6_prefix":"","ipv6_pd":"","dns":"","uptime":0}'
}

wan_runtime_json() {
	local id="$1" st l3 rx tx
	st=$(iface_status_json "$id")
	l3=$(printf '%s' "$st" | jq -r '.l3 // ""')
	[ -n "$l3" ] || l3="$id"
	set -- $(iface_rate "$l3")
	rx=$1; tx=$2
	printf '%s' "$st" | jq -c --argjson rx "$(jnum "$rx")" --argjson tx "$(jnum "$tx")" --arg iface "$l3" \
		'. + {rx:$rx, tx:$tx, iface:$iface}'
}

# 建议的上游 IPv6 委派前缀
ipv6_prefix_suggest() {
	local id st p
	for id in $(wan_ids); do
		st=$(iface_status_json "$id")
		p=$(printf '%s' "$st" | jq -r '.ipv6_pd // ""')
		[ -n "$p" ] && { printf '%s' "$p"; return; }
		p=$(printf '%s' "$st" | jq -r '.ipv6_prefix // ""')
		[ -n "$p" ] && { printf '%s' "$p"; return; }
	done
	printf ''
}

# ---------------- PPPoE 在线会话（由 ip-up/ip-down 维护） ----------------

pppoe_online_json() {
	local files="" first=1 f user ifc lip rip ts up rx tx ip6 oldifs
	mkdir -p "$RUNDIR"
	for f in "$RUNDIR"/*; do
		[ -f "$f" ] || continue
		oldifs="$IFS"
		IFS='|'
		read -r user ifc lip rip ts ip6 < "$f"
		IFS="$oldifs"
		[ -n "$ifc" ] || continue
		if [ ! -d "/sys/class/net/$ifc" ]; then rm -f "$f"; continue; fi
		up=$(( $(date +%s) - ${ts:-0} ))
		set -- $(iface_rate "$ifc")
		rx=$1; tx=$2
		[ "$first" = 1 ] || files="$files,"
		first=0
		files="$files{\"user\":\"$(jesc "$user")\",\"iface\":\"$(jesc "$ifc")\",\"ip\":\"$(jesc "$rip")\",\"ipv6\":\"$(jesc "$ip6")\",\"local\":\"$(jesc "$lip")\",\"uptime\":$up,\"rx\":$(jnum "$rx"),\"tx\":$(jnum "$tx")}"
	done
	printf '[%s]' "$files"
}

lan_client_count() {
	awk 'NR>1 {print $4}' /tmp/dhcp.leases 2>/dev/null | sort -u | wc -l
}

# ---------------- 配置生成：network ----------------

gen_network() {
	local out=/tmp/lo_network.$$ ports ip mask ip6assign
	config_load "$SR"
	config_get ip lan ip '192.168.100.1'
	config_get mask lan mask '255.255.255.0'
	config_get ports lan ports 'eth0'
	config_get ip6assign lan ip6assign '60'

	{
		cat <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option packet_steering '1'

config device 'brlan'
	option name 'br-lan'
	option type 'bridge'
	option stp '0'
	option igmp_snooping '1'
EOF
		local p
		for p in $ports; do
			echo "	list ports '$p'"
		done
		cat <<EOF

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '$ip'
	option netmask '$mask'
	option ip6assign '$ip6assign'
	option delegate '0'
EOF

		local id enabled device vlan mode user pass wip wmask gw dns1 dns2 mtu weight v6 metric devn proto
		metric=10
		for id in $(wan_ids); do
			config_get_bool enabled "$id" enabled 0
			[ "$enabled" = 1 ] || continue
			config_get device "$id" device ''
			config_get vlan "$id" vlan '0'
			config_get mode "$id" mode 'dhcp'
			config_get user "$id" user ''
			config_get pass "$id" pass ''
			config_get wip "$id" ip ''
			config_get wmask "$id" mask '255.255.255.0'
			config_get gw "$id" gw ''
			config_get dns1 "$id" dns1 ''
			config_get dns2 "$id" dns2 ''
			config_get mtu "$id" mtu '1500'
			config_get weight "$id" weight '1'
			config_get_bool v6 "$id" v6 1
			[ -n "$device" ] || continue

			devn="$device"
			if [ "$(jnum "$vlan")" -gt 0 ] 2>/dev/null; then
				devn="$device.$vlan"
				cat <<EOF

config device '${id}_dev'
	option type '8021q'
	option ifname '$device'
	option vid '$vlan'
	option name '$devn'
EOF
			fi

			proto="$mode"
			[ "$mode" = "mixed" ] && proto="pppoe"

			cat <<EOF

config interface '$id'
	option device '$devn'
	option proto '$proto'
	option metric '$metric'
EOF
			case "$proto" in
				pppoe)
					echo "	option username '$user'"
					echo "	option password '$pass'"
					echo "	option ipv6 '$v6'"
					echo "	option mtu '$mtu'"
					;;
				static)
					echo "	option ipaddr '$wip'"
					echo "	option netmask '$wmask'"
					[ -n "$gw" ] && echo "	option gateway '$gw'"
					;;
			esac
			echo "	option peerdns '0'"
			[ -n "$dns1" ] && echo "	list dns '$dns1'"
			[ -n "$dns2" ] && echo "	list dns '$dns2'"

			if [ "$mode" = "mixed" ]; then
				cat <<EOF

config interface '${id}_d'
	option device '$devn'
	option proto 'dhcp'
	option metric '$((metric + 100))'
	option peerdns '0'
EOF
				[ -n "$dns1" ] && echo "	list dns '$dns1'"
				[ -n "$dns2" ] && echo "	list dns '$dns2'"
				if [ "$v6" = 1 ]; then
					cat <<EOF

config interface '${id}_d_6'
	option device '@${id}_d'
	option proto 'dhcpv6'
	option reqaddress 'try'
	option reqprefix 'auto'
	option metric '$((metric + 100))'
EOF
				fi
			fi

			if [ "$v6" = 1 ] && [ "$proto" != "pppoe" ]; then
				cat <<EOF

config interface '${id}_6'
	option device '@${id}'
	option proto 'dhcpv6'
	option reqaddress 'try'
	option reqprefix 'auto'
	option metric '$metric'
EOF
			fi
			metric=$((metric + 10))
		done

		# PPPoE 服务端专用 VLAN 入口
		local pdevice pvlan piface
		config_get pdevice pppoe device 'br-lan'
		config_get pvlan pppoe vlan '0'
		piface=$(pppoe_ifname "$pdevice" "$pvlan")
		if [ "$(jnum "$pvlan")" -gt 0 ] 2>/dev/null; then
			cat <<EOF

config device 'pppoe_srv_dev'
	option type '8021q'
	option ifname '$pdevice'
	option vid '$pvlan'
	option name '$piface'
EOF
		fi
	} > "$out"
	mv "$out" /etc/config/network
}

# ---------------- 配置生成：DHCP / DNS / IPv6 ----------------

gen_dhcp() {
	local out=/tmp/lo_dhcp.$$ en start end lease ip mask dns1 dns2 ip6assign
	config_load "$SR"
	config_get_bool en lan dhcp_enable 1
	config_get start lan dhcp_start '192.168.100.10'
	config_get end lan dhcp_end '192.168.100.250'
	config_get lease lan dhcp_lease '12h'
	config_get ip6assign lan ip6assign '60'
	config_get dns1 settings dns1 '223.5.5.5'
	config_get dns2 settings dns2 '119.29.29.29'

	local offset limit
	offset=$(( ${start##*.} ))
	limit=$(( ${end##*.} - ${start##*.} + 1 ))
	[ "$limit" -gt 0 ] || limit=1

	{
		cat <<EOF
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
	option local '/lan/'
	option domain 'lan'
	option expandhosts '1'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option localservice '1'
	option sequential_ip '1'
	option allservers '1'
	option cachesize '2000'
	list server '$dns1'
	list server '$dns2'

config dhcp 'lan'
	option interface 'lan'
	option start '$offset'
	option limit '$limit'
	option leasetime '$lease'
	option dhcpv4 '$([ "$en" = 1 ] && echo server || echo disabled)'
	option dhcpv6 'server'
	option ra 'server'
	option ra_slaac '1'
	option ra_management '1'
	list ra_flags 'managed-config'
	list ra_flags 'other-config'
	option ndp 'disabled'
	option dynamicdhcp '$([ "$en" = 1 ] && echo 1 || echo 0)'

config dhcp 'wan'
	option interface 'wan'
	option ignore '1'

config odhcpd 'odhcpd'
	option maindhcp '0'
	option leasefile '/tmp/hosts/odhcpd'
	option leasetrigger '/usr/sbin/odhcpd-update'
	option loglevel '4'
EOF
		local id mac hip hostname
		config_load dhcp
		for id in $(uci -q show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([^.=]*\)=host$/\1/p"); do
			config_get mac "$id" mac
			config_get hip "$id" ip
			config_get hostname "$id" name "$id"
			[ -n "$mac" ] || continue
			cat <<EOF

config host
	option name '$hostname'
	option mac '$mac'
	option ip '$hip'
	option dns '1'
EOF
		done
	} > "$out"
	mv "$out" /etc/config/dhcp
}

# ---------------- 配置生成：mwan3 ----------------

gen_mwan3() {
	local out=/tmp/lo_mwan3.$$ count=0 id enabled weight members="" first=1 rid src dest policy
	config_load "$SR"

	for id in $(wan_ids); do
		config_get_bool enabled "$id" enabled 0
		[ "$enabled" = 1 ] && count=$((count + 1))
	done

	{
		echo "config globals 'globals'"
		echo "	option mmx_mask '0x3F00'"
		echo "	option rtmon_interval '5'"

		for id in $(wan_ids); do
			config_get_bool enabled "$id" enabled 0
			[ "$enabled" = 1 ] || continue
			config_get weight "$id" weight '1'
			cat <<EOF

config interface '$id'
	option enabled '1'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	option family 'ipv4'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'

config member '${id}_m'
	option interface '$id'
	option metric '1'
	option weight '$weight'
EOF
			if [ "$first" = 1 ]; then
				first=0
				members="	list use_member '${id}_m'"
			else
				members="$members
	list use_member '${id}_m'"
			fi
		done

		if [ -n "$members" ]; then
			printf "\nconfig policy 'balanced'\n"
			printf "$members\n"
			printf "\nconfig rule 'lo_default'\n	option proto 'all'\n	option dest_ip '0.0.0.0/0'\n	option use_policy 'balanced'\n"
		fi

		for rid in $(rule_ids); do
			config_get src "$rid" src ''
			config_get dest "$rid" dest ''
			config_get policy "$rid" policy ''
			[ -n "$policy" ] || continue
			printf "\nconfig rule '$rid'\n	option proto 'all'\n"
			[ -n "$dest" ] && printf "	option dest_ip '$dest'\n"
			[ -n "$src" ] && printf "	option src_ip '$src'\n"
			printf "	option use_policy '${rid}_policy'\n"
			printf "\nconfig member '${rid}_m'\n	option interface '$policy'\n	option metric '1'\n	option weight '1'\n"
			printf "\nconfig policy '${rid}_policy'\n	list use_member '${rid}_m'\n"
		done
	} > "$out"
	mv "$out" /etc/config/mwan3

	if [ "$count" -gt 1 ]; then
		/etc/init.d/mwan3 enable 2>/dev/null
	else
		/etc/init.d/mwan3 disable 2>/dev/null
	fi
}

# ---------------- 配置生成：accel-ppp（PPPoE 服务端，IPv4 + IPv6 PD） ----------------

gen_accelppp() {
	local en device vlan ac svc localip ps pe dns1 dns2 mtu lcp_i lcp_f v6 v6p v6link v6len plen iface mods
	config_load "$SR"
	config_get_bool en pppoe enabled 0
	config_get device pppoe device 'br-lan'
	config_get vlan pppoe vlan '0'
	config_get ac pppoe ac_name 'LongOS'
	config_get svc pppoe service_name 'sparrow'
	config_get localip pppoe localip '192.168.200.1'
	config_get ps pppoe pool_start '192.168.200.100'
	config_get pe pppoe pool_end '192.168.200.200'
	config_get dns1 pppoe dns1 '223.5.5.5'
	config_get dns2 pppoe dns2 '119.29.29.29'
	config_get mtu pppoe mtu '1492'
	config_get lcp_i pppoe lcp_interval '20'
	config_get lcp_f pppoe lcp_failure '3'
	config_get_bool v6 pppoe v6 1
	config_get v6p pppoe v6_prefix ''
	config_get v6link pppoe v6_link ''
	config_get v6len pppoe v6_prefix_len '64'
	# 前缀格式非法（必须含 ":" 和 "/"）时直接丢弃，避免写出坏配置
	case "$v6p" in *:*/*) ;; *) v6p='' ;; esac
	case "$v6link" in *:*/*) ;; *) v6link='' ;; esac
	# 委派长度必须为数字且不小于 PD 池掩码；相等时整池只能服务 1 个客户端
	case "$v6len" in ''|*[!0-9]*) v6len=64 ;; esac
	plen=64
	[ -n "$v6p" ] && plen=${v6p#*/}
	case "$plen" in ''|*[!0-9]*) plen=64 ;; esac
	if [ "$v6len" -lt "$plen" ] 2>/dev/null; then
		# 小于池掩码时优先回到 64，避免整池只能服务一个客户端
		if [ "$plen" -le 64 ] 2>/dev/null; then v6len=64; else v6len=$plen; fi
	fi
	iface=$(pppoe_ifname "$device" "$vlan")

	mods="pppoe
auth_pap
auth_chap_md5
auth_mschap_v1
auth_mschap_v2
chap-secrets
ippool
sigchld
pppd_compat"
	if [ "$v6" = 1 ]; then
		mods="$mods
ipv6pool
ipv6_dhcp
ipv6_nd"
	fi

	mkdir -p /etc/accel-ppp /var/log/accel-ppp /etc/longos

	# 段名/参数名严格遵循 accel-ppp 官方文档：
	# [ip-pool] [dns] [chap-secrets] [pppd-compat] [ipv6-pool] [ipv6-dhcp] [ipv6-nd]
	{
		cat <<EOF
# 由 LongOS 生成，请勿手工修改
[modules]
$mods

[core]
log-error=/var/log/accel-ppp/core.log
log-info=/var/log/accel-ppp/info.log
thread-count=2

[pppoe]
interface=$iface
ac-name=$ac
service-name=$svc
called-sid=mac
ip-pool=srv4
verbose=1
EOF
		[ "$v6" = 1 ] && [ -n "$v6link" ] && echo "ipv6-pool=srv6"
		[ "$v6" = 1 ] && [ -n "$v6p" ] && echo "ipv6-pool-delegate=srv6pd"

		cat <<EOF

[ppp]
verbose=1
min-mtu=1280
mtu=$mtu
mru=$mtu
lcp-echo-interval=$lcp_i
lcp-echo-failure=$lcp_f
ipv4=require
ipv6=$([ "$v6" = 1 ] && echo allow || echo deny)
ipv6-intf-id=random
ipv6-peer-intf-id=random

[ip-pool]
gw-ip-address=$localip
$ps-$pe

[dns]
dns1=$dns1
dns2=$dns2

[chap-secrets]
chap-secrets=/etc/accel-ppp/chap-secrets

[pppd-compat]
verbose=1
ip-up=/etc/accel-ppp/ip-up.sh
ip-down=/etc/accel-ppp/ip-down.sh
EOF

		if [ "$v6" = 1 ]; then
			cat <<EOF

[ipv6-nd]
verbose=0
AdvManagedFlag=0
AdvOtherConfigFlag=1
EOF
			if [ -n "$v6link" ] || [ -n "$v6p" ]; then
				cat <<EOF

[ipv6-pool]
EOF
				[ -n "$v6link" ] && echo "$v6link,64,name=srv6"
				[ -n "$v6p" ] && echo "delegate=$v6p,$v6len,name=srv6pd"
			fi
			if [ -n "$v6p" ]; then
				cat <<EOF

[ipv6-dhcp]
verbose=1
route-via-gw=1
EOF
			fi
		fi
	} > /etc/accel-ppp.conf
	cp /etc/accel-ppp.conf /etc/accel-ppp/accel-ppp.conf 2>/dev/null

	# 账号密码
	{
		echo "# 由 LongOS 生成：用户 服务 密码 静态IPv4"
		local aid aen au ap aip
		for aid in $(account_ids); do
			config_get_bool aen "$aid" enabled 0
			[ "$aen" = 1 ] || continue
			config_get au "$aid" user ''
			config_get ap "$aid" pass ''
			config_get aip "$aid" ip ''
			[ -n "$au" ] || continue
			echo "\"$au\" * \"$ap\" ${aip:-*}"
		done
	} > /etc/accel-ppp/chap-secrets
	cp /etc/accel-ppp/chap-secrets /etc/accel-ppp/pap-secrets 2>/dev/null
	chmod 600 /etc/accel-ppp/chap-secrets /etc/accel-ppp/pap-secrets 2>/dev/null

	# 每账号限速表：user down_kbps up_kbps
	{
		local aid aen au ad aupl
		for aid in $(account_ids); do
			config_get_bool aen "$aid" enabled 0
			[ "$aen" = 1 ] || continue
			config_get au "$aid" user ''
			config_get ad "$aid" down '0'
			config_get aupl "$aid" up '0'
			[ -n "$au" ] || continue
			[ "$(jnum "$ad")" -gt 0 ] || [ "$(jnum "$aupl")" -gt 0 ] || continue
			echo "$au $(jnum "$ad") $(jnum "$aupl")"
		done
	} > /etc/longos/limits

	if [ "$en" = 1 ]; then
		/etc/init.d/accel-ppp enable >/dev/null 2>&1
		/etc/init.d/accel-ppp restart >/dev/null 2>&1
	else
		/etc/init.d/accel-ppp stop >/dev/null 2>&1
		/etc/init.d/accel-ppp disable >/dev/null 2>&1
	fi
}

# ---------------- 配置生成：防火墙（DMZ + 端口转发） ----------------

gen_firewall() {
	local s
	for s in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\(lo_[^.=]*\)=.*/\1/p"); do
		uci -q delete "firewall.$s"
	done

	local dmz_en dmz_ip
	config_load "$SR"

	# 把全部 WAN 逻辑接口挂到 wan 防火墙区域，并确保开启 NAT
	local zone="" zid zname id en mode v6
	for zid in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p"); do
		zname=$(uci -q get "firewall.$zid.name")
		if [ "$zname" = "wan" ]; then zone="$zid"; break; fi
	done
	if [ -n "$zone" ]; then
		uci -q delete "firewall.$zone.network"
		for id in $(wan_ids); do
			config_get_bool en "$id" enabled 0
			[ "$en" = 1 ] || continue
			config_get_bool v6 "$id" v6 1
			config_get mode "$id" mode 'dhcp'
			uci add_list "firewall.$zone.network=$id"
			[ "$mode" = "mixed" ] && uci add_list "firewall.$zone.network=${id}_d"
			if [ "$v6" = 1 ]; then
				uci add_list "firewall.$zone.network=${id}_6"
				[ "$mode" = "mixed" ] && uci add_list "firewall.$zone.network=${id}_d_6"
			fi
		done
		uci set "firewall.$zone.masq=1"
		uci set "firewall.$zone.mtu_fix=1"
	fi

	config_get_bool dmz_en settings dmz_enable 0
	config_get dmz_ip settings dmz_ip ''

	if [ "$dmz_en" = 1 ] && [ -n "$dmz_ip" ]; then
		uci set firewall.lo_dmz=redirect
		uci set firewall.lo_dmz.name='LongOS-DMZ'
		uci set firewall.lo_dmz.src='wan'
		uci set firewall.lo_dmz.dest='lan'
		uci set firewall.lo_dmz.dest_ip="$dmz_ip"
		uci set firewall.lo_dmz.proto='all'
		uci set firewall.lo_dmz.target='DNAT'
		uci set firewall.lo_dmz_fwd=rule
		uci set firewall.lo_dmz_fwd.name='LongOS-DMZ-FORWARD'
		uci set firewall.lo_dmz_fwd.src='wan'
		uci set firewall.lo_dmz_fwd.dest='lan'
		uci set firewall.lo_dmz_fwd.dest_ip="$dmz_ip"
		uci set firewall.lo_dmz_fwd.proto='all'
		uci set firewall.lo_dmz_fwd.target='ACCEPT'
	fi

	local fid fen fname fproto fport fip fipport
	for fid in $(forward_ids); do
		config_get_bool fen "$fid" enabled 0
		[ "$fen" = 1 ] || continue
		config_get fname "$fid" name "$fid"
		config_get fproto "$fid" proto 'tcp'
		config_get fport "$fid" ext_port ''
		config_get fip "$fid" int_ip ''
		config_get fipport "$fid" int_port ''
		[ -n "$fport" ] && [ -n "$fip" ] || continue
		[ -n "$fipport" ] || fipport="$fport"
		uci set "firewall.lo_fwd_${fid}=redirect"
		uci set "firewall.lo_fwd_${fid}.name=$fname"
		uci set "firewall.lo_fwd_${fid}.src=wan"
		uci set "firewall.lo_fwd_${fid}.dest=lan"
		uci set "firewall.lo_fwd_${fid}.proto=$fproto"
		uci set "firewall.lo_fwd_${fid}.src_dport=$fport"
		uci set "firewall.lo_fwd_${fid}.dest_ip=$fip"
		uci set "firewall.lo_fwd_${fid}.dest_port=$fipport"
		uci set "firewall.lo_fwd_${fid}.target=DNAT"
		uci set "firewall.lo_fwd_${fid}_rule=rule"
		uci set "firewall.lo_fwd_${fid}_rule.name=LongOS-FWD-${fname}"
		uci set "firewall.lo_fwd_${fid}_rule.src=wan"
		uci set "firewall.lo_fwd_${fid}_rule.dest=lan"
		uci set "firewall.lo_fwd_${fid}_rule.proto=$fproto"
		uci set "firewall.lo_fwd_${fid}_rule.dest_ip=$fip"
		uci set "firewall.lo_fwd_${fid}_rule.dest_port=$fipport"
		uci set "firewall.lo_fwd_${fid}_rule.target=ACCEPT"
	done
	uci commit firewall
}

# ---------------- 配置生成：tc / cake 流控 ----------------

apply_shaping_dev() {
	local dev="$1" dl="$2" ul="$3"
	[ -d "/sys/class/net/$dev" ] || return 0
	tc qdisc del dev "$dev" root 2>/dev/null
	tc qdisc del dev "$dev" ingress 2>/dev/null
	if [ "$(jnum "$ul")" -gt 0 ] 2>/dev/null; then
		tc qdisc add dev "$dev" root cake bandwidth "${ul}kbit" nat dual-ack 2>/dev/null || \
			tc qdisc add dev "$dev" root tbf rate "${ul}kbit" burst 64k latency 50ms 2>/dev/null
	fi
	if [ "$(jnum "$dl")" -gt 0 ] 2>/dev/null; then
		tc qdisc add dev "$dev" handle ffff: ingress 2>/dev/null
		tc filter add dev "$dev" parent ffff: protocol all prio 1 u32 match u32 0 0 \
			police rate "${dl}kbit" burst 64k drop flowid :1 2>/dev/null
	fi
}

gen_sqm() {
	local en ifc dl ul qdisc id wdev wdl wul
	config_load "$SR"
	config_get_bool en settings sqm_enable 0
	config_get ifc settings sqm_iface 'br-lan'
	config_get dl settings sqm_dl '0'
	config_get ul settings sqm_ul '0'
	config_get qdisc settings qdisc 'cake'

	# LAN 整体 SQM（可选）
	uci -q delete sqm.lan
	if [ "$en" = 1 ] && [ "$(jnum "$dl")" -gt 0 ] 2>/dev/null; then
		uci set sqm.lan=queue
		uci set sqm.lan.enabled='1'
		uci set sqm.lan.interface="$ifc"
		uci set sqm.lan.download="$dl"
		uci set sqm.lan.upload="${ul:-0}"
		uci set sqm.lan.debug_logging='0'
		uci set sqm.lan.verbosity='5'
		uci set sqm.lan.qdisc="$qdisc"
		uci set sqm.lan.script='piece_of_cake.qos'
		uci set sqm.lan.linklayer='none'
		uci set sqm.lan.overhead='0'
		uci commit sqm
		/etc/init.d/sqm enable >/dev/null 2>&1
		/etc/init.d/sqm restart >/dev/null 2>&1
	else
		uci commit sqm
		/etc/init.d/sqm stop >/dev/null 2>&1
		/etc/init.d/sqm disable >/dev/null 2>&1
	fi

	# 每条 WAN 的上下行流控（wdl/wul 单位 kbps）
	for id in $(wan_ids); do
		config_get wdl "$id" dl '0'
		config_get wul "$id" ul '0'
		wdev=$(iface_status_json "$id" | jq -r '.l3 // ""')
		[ -n "$wdev" ] || continue
		apply_shaping_dev "$wdev" "$wdl" "$wul"
	done
}

# ---------------- 配置生成：trea 客户端 ----------------

gen_trea() {
	local en server token iface interval extra
	config_load "$SR"
	config_get_bool en trea enabled 0
	config_get server trea server ''
	config_get token trea token ''
	config_get iface trea iface ''
	config_get interval trea interval '60'
	config_get extra trea extra ''

	{
		echo "# 由 LongOS 生成，字段含义请以麻雀云 trea 官方文档为准"
		echo "server = \"$server\""
		echo "token = \"$token\""
		echo "iface = \"$iface\""
		echo "interval = $interval"
		[ -n "$extra" ] && echo "$extra"
	} > /etc/trea.conf

	if [ "$en" = 1 ]; then
		/etc/init.d/trea enable >/dev/null 2>&1
		/etc/init.d/trea restart >/dev/null 2>&1
	else
		/etc/init.d/trea stop >/dev/null 2>&1
		/etc/init.d/trea disable >/dev/null 2>&1
	fi
}

apply_all() {
	gen_network
	gen_dhcp
	gen_mwan3
	gen_firewall
	gen_trea

	# 先让 VLAN / 网桥设备生效，accel-ppp 才能绑定服务端入口
	/etc/init.d/network reload >/dev/null 2>&1
	sleep 1
	gen_accelppp

	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	[ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd restart >/dev/null 2>&1
	/etc/init.d/firewall reload >/dev/null 2>&1
	sleep 1

	# 网卡重建后再下发 tc 规则，避免规则挂在已删除的设备上
	gen_sqm

	local count=0 id en
	for id in $(wan_ids); do
		config_get_bool en "$id" enabled 0
		[ "$en" = 1 ] && count=$((count + 1))
	done
	if [ "$count" -gt 1 ]; then
		/etc/init.d/mwan3 restart >/dev/null 2>&1
	else
		/etc/init.d/mwan3 stop >/dev/null 2>&1
	fi
	log "apply done"
}

# ---------------- 业务操作：输入读取 ----------------

INPUT=""
json_get() {
	[ -n "$INPUT" ] || { printf ''; return; }
	printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}

save_wan() {
	local id name device vlan mode user pass ip mask gw dns1 dns2 mtu weight enabled v6 dl ul
	id=$(json_get '.id')
	name=$(json_get '.name')
	device=$(json_get '.device')
	vlan=$(json_get '.vlan')
	mode=$(json_get '.mode')
	user=$(json_get '.user')
	pass=$(json_get '.pass')
	ip=$(json_get '.ip')
	mask=$(json_get '.mask')
	gw=$(json_get '.gw')
	dns1=$(json_get '.dns1')
	dns2=$(json_get '.dns2')
	mtu=$(json_get '.mtu')
	weight=$(json_get '.weight')
	enabled=$(json_get '.enabled')
	v6=$(json_get '.v6')
	dl=$(json_get '.dl')
	ul=$(json_get '.ul')

	[ -n "$device" ] || { printf '{"ok":false,"msg":"请选择物理网卡"}'; return; }
	case "${mode:-dhcp}" in
		pppoe|mixed)
			[ -n "$user" ] || { printf '{"ok":false,"msg":"PPPoE 模式必须填写宽带账号"}'; return; }
			;;
		static)
			[ -n "$ip" ] || { printf '{"ok":false,"msg":"静态模式必须填写 IP 地址"}'; return; }
			;;
	esac

	if [ -z "$id" ]; then
		local n=1
		while uci -q get "$SR.wan$n" >/dev/null; do n=$((n + 1)); done
		id="wan$n"
		uci set "$SR.$id=wan"
	fi
	uci set "$SR.$id.name=${name:-$id}"
	uci set "$SR.$id.device=$device"
	uci set "$SR.$id.vlan=${vlan:-0}"
	uci set "$SR.$id.mode=${mode:-dhcp}"
	uci set "$SR.$id.user=$user"
	uci set "$SR.$id.pass=$pass"
	uci set "$SR.$id.ip=$ip"
	uci set "$SR.$id.mask=${mask:-255.255.255.0}"
	uci set "$SR.$id.gw=$gw"
	uci set "$SR.$id.dns1=$dns1"
	uci set "$SR.$id.dns2=$dns2"
	uci set "$SR.$id.mtu=${mtu:-1500}"
	uci set "$SR.$id.weight=${weight:-1}"
	uci set "$SR.$id.dl=${dl:-0}"
	uci set "$SR.$id.ul=${ul:-0}"
	uci set "$SR.$id.enabled=$([ "$enabled" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.$id.v6=$([ "$v6" = "true" ] && echo 1 || echo 0)"
	uci commit "$SR"

	INPUT=""
	apply_all
	printf '{"ok":true,"id":"%s"}' "$id"
}

save_lan() {
	uci set "$SR.lan.ip=$(json_get '.ip')"
	uci set "$SR.lan.mask=$(json_get '.mask')"
	uci set "$SR.lan.ports=$(json_get '.ports')"
	uci set "$SR.lan.dhcp_start=$(json_get '.dhcp_start')"
	uci set "$SR.lan.dhcp_end=$(json_get '.dhcp_end')"
	uci set "$SR.lan.dhcp_lease=$(json_get '.dhcp_lease')"
	uci set "$SR.lan.dhcp_enable=$([ "$(json_get '.dhcp_enable')" = "true" ] && echo 1 || echo 0)"
	uci commit "$SR"
	INPUT=""
	apply_all
	printf '{"ok":true}'
}

save_dhcp() {
	uci set "$SR.lan.dhcp_enable=$([ "$(json_get '.dhcp_enable')" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.lan.dhcp_start=$(json_get '.dhcp_start')"
	uci set "$SR.lan.dhcp_end=$(json_get '.dhcp_end')"
	uci set "$SR.lan.dhcp_lease=$(json_get '.dhcp_lease')"
	uci commit "$SR"
	INPUT=""
	gen_dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	[ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd restart >/dev/null 2>&1
	printf '{"ok":true}'
}

save_lease() {
	local id mac ip name
	id=$(json_get '.id')
	mac=$(json_get '.mac')
	ip=$(json_get '.ip')
	name=$(json_get '.name')
	[ -n "$mac" ] && [ -n "$ip" ] || { printf '{"ok":false,"msg":"MAC 与 IP 均需填写"}'; return; }
	[ -n "$id" ] || {
		local n=1
		while uci -q get "dhcp.h$n" >/dev/null; do n=$((n + 1)); done
		id="h$n"
		uci set "dhcp.$id=host"
	}
	uci set "dhcp.$id.mac=$mac"
	uci set "dhcp.$id.ip=$ip"
	uci set "dhcp.$id.name=${name:-$ip}"
	uci set "dhcp.$id.dns=1"
	uci commit dhcp
	INPUT=""
	gen_dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	printf '{"ok":true,"id":"%s"}' "$id"
}

del_lease() {
	local id
	id=$(json_get '.id')
	uci -q delete "dhcp.$id"
	uci commit dhcp
	INPUT=""
	gen_dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	printf '{"ok":true}'
}

save_pppoe() {
	local en device vlan ac svc localip netmask ps pe v6 v6p v6link v6len maxs dns1 dns2 mtu lcp_i lcp_f
	en=$(json_get '.enabled')
	device=$(json_get '.device')
	vlan=$(json_get '.vlan')
	ac=$(json_get '.ac_name')
	svc=$(json_get '.service_name')
	localip=$(json_get '.localip')
	netmask=$(json_get '.netmask')
	ps=$(json_get '.pool_start')
	pe=$(json_get '.pool_end')
	v6=$(json_get '.v6')
	v6p=$(json_get '.v6_prefix')
	v6link=$(json_get '.v6_link')
	v6len=$(json_get '.v6_prefix_len')
	maxs=$(json_get '.maxsessions')
	dns1=$(json_get '.dns1')
	dns2=$(json_get '.dns2')
	mtu=$(json_get '.mtu')
	lcp_i=$(json_get '.lcp_interval')
	lcp_f=$(json_get '.lcp_failure')

	uci set "$SR.pppoe.enabled=$([ "$en" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.pppoe.engine=accel-ppp"
	uci set "$SR.pppoe.device=${device:-br-lan}"
	uci set "$SR.pppoe.vlan=${vlan:-0}"
	uci set "$SR.pppoe.ac_name=${ac:-LongOS}"
	uci set "$SR.pppoe.service_name=${svc:-sparrow}"
	uci set "$SR.pppoe.localip=${localip:-192.168.200.1}"
	uci set "$SR.pppoe.netmask=${netmask:-255.255.255.0}"
	uci set "$SR.pppoe.pool_start=${ps:-192.168.200.100}"
	uci set "$SR.pppoe.pool_end=${pe:-192.168.200.200}"
	uci set "$SR.pppoe.v6=$([ "$v6" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.pppoe.v6_link=$v6link"
	uci set "$SR.pppoe.v6_prefix=$v6p"
	uci set "$SR.pppoe.v6_prefix_len=${v6len:-64}"
	uci set "$SR.pppoe.maxsessions=${maxs:-200}"
	uci set "$SR.pppoe.dns1=${dns1:-223.5.5.5}"
	uci set "$SR.pppoe.dns2=${dns2:-119.29.29.29}"
	uci set "$SR.pppoe.mtu=${mtu:-1492}"
	uci set "$SR.pppoe.lcp_interval=${lcp_i:-20}"
	uci set "$SR.pppoe.lcp_failure=${lcp_f:-3}"
	uci commit "$SR"
	INPUT=""
	gen_network
	/etc/init.d/network reload >/dev/null 2>&1
	sleep 1
	gen_accelppp
	printf '{"ok":true}'
}

save_account() {
	local id user pass ip down up note enabled
	id=$(json_get '.id')
	user=$(json_get '.user')
	pass=$(json_get '.pass')
	ip=$(json_get '.ip')
	down=$(json_get '.down')
	up=$(json_get '.up')
	note=$(json_get '.note')
	enabled=$(json_get '.enabled')
	[ -n "$user" ] || { printf '{"ok":false,"msg":"账号不能为空"}'; return; }
	[ -n "$pass" ] || { printf '{"ok":false,"msg":"密码不能为空"}'; return; }
	[ -n "$id" ] || {
		local n=1
		while uci -q get "$SR.acc$n" >/dev/null; do n=$((n + 1)); done
		id="acc$n"
		uci set "$SR.$id=account"
	}
	uci set "$SR.$id.user=$user"
	uci set "$SR.$id.pass=$pass"
	uci set "$SR.$id.ip=$ip"
	uci set "$SR.$id.down=${down:-0}"
	uci set "$SR.$id.up=${up:-0}"
	uci set "$SR.$id.note=$note"
	uci set "$SR.$id.enabled=$([ "$enabled" = "true" ] && echo 1 || echo 0)"
	uci commit "$SR"
	INPUT=""
	gen_accelppp
	printf '{"ok":true,"id":"%s"}' "$id"
}

del_account() {
	local id
	id=$(json_get '.id')
	uci -q delete "$SR.$id"
	uci commit "$SR"
	INPUT=""
	gen_accelppp
	printf '{"ok":true}'
}

kick_user() {
	local ifc user
	ifc=$(json_get '.iface')
	user=$(json_get '.user')
	[ -n "$ifc" ] || { printf '{"ok":false,"msg":"缺少接口"}'; return; }
	if command -v accel-cmd >/dev/null 2>&1; then
		accel-cmd terminate if "$ifc" >/dev/null 2>&1 || true
	fi
	[ -f "/var/run/ppp-$ifc.pid" ] && kill "$(cat /var/run/ppp-$ifc.pid)" 2>/dev/null
	rm -f "$RUNDIR/$ifc"
	printf '{"ok":true}'
}

save_rule() {
	local id src dest policy
	id=$(json_get '.id')
	src=$(json_get '.src')
	dest=$(json_get '.dest')
	policy=$(json_get '.policy')
	[ -n "$id" ] || {
		local n=1
		while uci -q get "$SR.rule$n" >/dev/null; do n=$((n + 1)); done
		id="rule$n"
		uci set "$SR.$id=rule"
	}
	uci set "$SR.$id.src=$src"
	uci set "$SR.$id.dest=$dest"
	uci set "$SR.$id.policy=$policy"
	uci commit "$SR"
	INPUT=""
	gen_mwan3
	/etc/init.d/mwan3 restart >/dev/null 2>&1
	printf '{"ok":true,"id":"%s"}' "$id"
}

del_rule() {
	local id
	id=$(json_get '.id')
	uci -q delete "$SR.$id"
	uci commit "$SR"
	INPUT=""
	gen_mwan3
	/etc/init.d/mwan3 restart >/dev/null 2>&1
	printf '{"ok":true}'
}

save_qos() {
	local en ifc dl ul qdisc
	en=$(json_get '.enabled')
	ifc=$(json_get '.iface')
	dl=$(json_get '.download')
	ul=$(json_get '.upload')
	qdisc=$(json_get '.qdisc')
	uci set "$SR.settings.sqm_enable=$([ "$en" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.settings.sqm_iface=${ifc:-br-lan}"
	uci set "$SR.settings.sqm_dl=${dl:-0}"
	uci set "$SR.settings.sqm_ul=${ul:-0}"
	uci set "$SR.settings.qdisc=${qdisc:-cake}"
	uci commit "$SR"
	INPUT=""
	gen_sqm
	printf '{"ok":true}'
}

save_wan_shaping() {
	local id dl ul
	id=$(json_get '.id')
	dl=$(json_get '.dl')
	ul=$(json_get '.ul')
	[ -n "$id" ] || { printf '{"ok":false}'; return; }
	uci set "$SR.$id.dl=${dl:-0}"
	uci set "$SR.$id.ul=${ul:-0}"
	uci commit "$SR"
	INPUT=""
	gen_sqm
	printf '{"ok":true}'
}

save_dmz() {
	local en ip
	en=$(json_get '.enabled')
	ip=$(json_get '.ip')
	uci set "$SR.settings.dmz_enable=$([ "$en" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.settings.dmz_ip=$ip"
	uci commit "$SR"
	INPUT=""
	gen_firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	printf '{"ok":true}'
}

save_forward() {
	local id name proto ext int_ip int_port enabled
	id=$(json_get '.id')
	name=$(json_get '.name')
	proto=$(json_get '.proto')
	ext=$(json_get '.ext_port')
	int_ip=$(json_get '.int_ip')
	int_port=$(json_get '.int_port')
	enabled=$(json_get '.enabled')
	[ -n "$ext" ] && [ -n "$int_ip" ] || { printf '{"ok":false,"msg":"外部端口与内部 IP 必填"}'; return; }
	[ -n "$id" ] || {
		local n=1
		while uci -q get "$SR.fwd$n" >/dev/null; do n=$((n + 1)); done
		id="fwd$n"
		uci set "$SR.$id=forward"
	}
	uci set "$SR.$id.name=${name:-$id}"
	uci set "$SR.$id.proto=${proto:-tcp}"
	uci set "$SR.$id.ext_port=$ext"
	uci set "$SR.$id.int_ip=$int_ip"
	uci set "$SR.$id.int_port=${int_port:-$ext}"
	uci set "$SR.$id.enabled=$([ "$enabled" = "true" ] && echo 1 || echo 0)"
	uci commit "$SR"
	INPUT=""
	gen_firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	printf '{"ok":true,"id":"%s"}' "$id"
}

del_forward() {
	local id
	id=$(json_get '.id')
	uci -q delete "$SR.$id"
	uci commit "$SR"
	INPUT=""
	gen_firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	printf '{"ok":true}'
}

save_settings() {
	local hostname dns1 dns2 p4 p6 interval
	hostname=$(json_get '.hostname')
	dns1=$(json_get '.dns1')
	dns2=$(json_get '.dns2')
	p4=$(json_get '.ping4')
	p6=$(json_get '.ping6')
	interval=$(json_get '.monitor_interval')
	[ -n "$hostname" ] && {
		uci set system.@system[0].hostname="$hostname"
		uci commit system
		echo "$hostname" > /proc/sys/kernel/hostname
	}
	[ -n "$dns1" ] && uci set "$SR.settings.dns1=$dns1"
	[ -n "$dns2" ] && uci set "$SR.settings.dns2=$dns2"
	[ -n "$p4" ] && uci set "$SR.settings.ping4=$p4"
	[ -n "$p6" ] && uci set "$SR.settings.ping6=$p6"
	[ -n "$interval" ] && uci set "$SR.settings.monitor_interval=$interval"
	uci commit "$SR"
	INPUT=""
	gen_dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	printf '{"ok":true}'
}

save_password() {
	local pw
	pw=$(json_get '.password')
	[ -n "$pw" ] || { printf '{"ok":false,"msg":"密码不能为空"}'; return; }
	echo "root:$pw" | chpasswd 2>/dev/null || printf '%s\n%s\n' "$pw" "$pw" | passwd root >/dev/null 2>&1
	printf '{"ok":true}'
}

save_trea() {
	local en server token iface interval extra
	en=$(json_get '.enabled')
	server=$(json_get '.server')
	token=$(json_get '.token')
	iface=$(json_get '.iface')
	interval=$(json_get '.interval')
	extra=$(json_get '.extra')
	uci set "$SR.trea.enabled=$([ "$en" = "true" ] && echo 1 || echo 0)"
	uci set "$SR.trea.server=$server"
	uci set "$SR.trea.token=$token"
	uci set "$SR.trea.iface=$iface"
	uci set "$SR.trea.interval=${interval:-60}"
	uci set "$SR.trea.extra=$extra"
	uci commit "$SR"
	INPUT=""
	gen_trea
	printf '{"ok":true}'
}

trea_action() {
	local act
	act=$(json_get '.action')
	case "$act" in
		start) /etc/init.d/trea start >/dev/null 2>&1 ;;
		stop) /etc/init.d/trea stop >/dev/null 2>&1 ;;
		restart) /etc/init.d/trea restart >/dev/null 2>&1 ;;
		*) printf '{"ok":false,"msg":"未知操作"}'; return ;;
	esac
	printf '{"ok":true}'
}

# ---------------- 查询命令 ----------------

wan_config_json() {
	local id="$1" enabled name device vlan mode user pass ip mask gw dns1 dns2 mtu weight v6 dl ul
	config_get_bool enabled "$id" enabled 0
	config_get name "$id" name "$id"
	config_get device "$id" device ''
	config_get vlan "$id" vlan '0'
	config_get mode "$id" mode 'dhcp'
	config_get user "$id" user ''
	config_get pass "$id" pass ''
	config_get ip "$id" ip ''
	config_get mask "$id" mask '255.255.255.0'
	config_get gw "$id" gw ''
	config_get dns1 "$id" dns1 ''
	config_get dns2 "$id" dns2 ''
	config_get mtu "$id" mtu '1500'
	config_get weight "$id" weight '1'
	config_get_bool v6 "$id" v6 1
	config_get dl "$id" dl '0'
	config_get ul "$id" ul '0'
	jq -cn \
		--arg id "$id" --arg name "$name" --arg device "$device" --arg mode "$mode" \
		--arg user "$user" --arg pass "$pass" --arg ip "$ip" --arg mask "$mask" --arg gw "$gw" \
		--arg dns1 "$dns1" --arg dns2 "$dns2" --argjson vlan "$(jnum "$vlan")" \
		--argjson mtu "$(jnum "$mtu")" --argjson weight "$(jnum "$weight")" \
		--argjson dl "$(jnum "$dl")" --argjson ul "$(jnum "$ul")" \
		--argjson enabled "$(jbool "$enabled")" --argjson v6 "$(jbool "$v6")" \
		'{id:$id,name:$name,device:$device,vlan:$vlan,mode:$mode,user:$user,pass:$pass,
		  ip:$ip,mask:$mask,gw:$gw,dns1:$dns1,dns2:$dns2,mtu:$mtu,weight:$weight,
		  dl:$dl,ul:$ul,enabled:$enabled,v6:$v6}'
}

wans_json() {
	local list="[]" id
	config_load "$SR"
	for id in $(wan_ids); do
		list=$(printf '%s' "$list" | jq -c --argjson w "$(wan_config_json "$id")" '. + [$w]')
	done
	printf '%s' "$list"
}

cmd_status() {
	sample_rates
	config_load "$SR"
	local wans="[]" id wjson
	for id in $(wan_ids); do
		wjson=$(wan_config_json "$id" | jq -c --argjson rt "$(wan_runtime_json "$id")" \
			--argjson rt6 "$(iface_status_json "${id}_6")" '. + {rt:$rt, rt6:$rt6}')
		wans=$(printf '%s' "$wans" | jq -c --argjson w "$wjson" '. + [$w]')
	done

	local ip mask ports dns1 dns2 hostname up ppp_en ppp_max ppp_svc
	config_get ip lan ip '192.168.100.1'
	config_get mask lan mask '255.255.255.0'
	config_get ports lan ports 'eth0'
	config_get dns1 settings dns1 '223.5.5.5'
	config_get dns2 settings dns2 '119.29.29.29'
	config_get hostname settings hostname 'LongOS'
	config_get_bool ppp_en pppoe enabled 0
	config_get ppp_max pppoe maxsessions '200'
	config_get ppp_svc pppoe service_name 'sparrow'
	up=$(awk '{print int($1)}' /proc/uptime)

	jq -cn \
		--arg hostname "$hostname" --argjson uptime "$up" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
		--argjson cpu_usage "$(jnum "$(cpu_usage)")" --argjson cpu "$(cpu_info)" --argjson mem "$(mem_info)" \
		--argjson conn "$(jnum "$(conn_count)")" --arg version "$(cat "$VERSION_FILE" 2>/dev/null || echo 1.0.0)" \
		--arg arch "$(uname -m)" \
		--arg ip "$ip" --arg mask "$mask" --arg ports "$ports" --argjson clients "$(jnum "$(lan_client_count)")" \
		--arg dns1 "$dns1" --arg dns2 "$dns2" \
		--argjson wans "$wans" \
		--argjson ppp_en "$(jbool "$ppp_en")" --argjson ppp_max "$(jnum "$ppp_max")" --arg ppp_svc "$ppp_svc" \
		--argjson ppp_online "$(pppoe_online_json)" \
		--argjson mono "$(file_json "$LINE_JSON")" \
		--argjson hist "$(monitor_hist_json)" \
		--argjson ifaces "$(ifaces_json)" \
		'{
		  ok:true,
		  sys:{hostname:$hostname,uptime:$uptime,time:$time,cpu_usage:$cpu_usage,cpu:$cpu,
		       mem:$mem,conn:$conn,version:$version,arch:$arch},
		  lan:{ip:$ip,mask:$mask,ports:$ports,clients:$clients},
		  dns:[$dns1,$dns2],
		  wans:$wans,
		  pppoe:{enabled:$ppp_en,max:$ppp_max,service:$ppp_svc,online:$ppp_online},
		  line:$mono,
		  hist:$hist,
		  ifaces:$ifaces
		}'
}

monitor_hist_json() {
	[ -s "$HIST" ] || { printf '[]'; return; }
	tail -n 180 "$HIST" | awk 'BEGIN{printf "["}
		{ if (NR > 1) printf ","; printf "{\"ts\":%s,\"rx\":%s,\"tx\":%s}", $1, $2, $3 }
		END{printf "]"}' 2>/dev/null || printf '[]'
}

cmd_wans() {
	printf '{"ok":true,"wans":%s}' "$(wans_json)"
}

cmd_lan() {
	config_load "$SR"
	local ip mask ports ds de dl den i6
	config_get ip lan ip
	config_get mask lan mask
	config_get ports lan ports
	config_get ds lan dhcp_start
	config_get de lan dhcp_end
	config_get dl lan dhcp_lease
	config_get_bool den lan dhcp_enable 1
	config_get i6 lan ip6assign '60'
	jq -cn --arg ip "$ip" --arg mask "$mask" --arg ports "$ports" --arg ds "$ds" --arg de "$de" \
		--arg dl "$dl" --argjson den "$(jbool "$den")" --arg i6 "$i6" \
		'{ok:true,ip:$ip,mask:$mask,ports:$ports,dhcp_start:$ds,dhcp_end:$de,dhcp_lease:$dl,dhcp_enable:$den,ip6assign:$i6}'
}

cmd_leases() {
	local list="[]" active="[]" id mac ip name
	config_load dhcp
	for id in $(uci -q show dhcp 2>/dev/null | sed -n "s/^dhcp\.\([^.=]*\)=host$/\1/p"); do
		config_get mac "$id" mac
		config_get ip "$id" ip
		config_get name "$id" name
		list=$(printf '%s' "$list" | jq -c --arg id "$id" --arg mac "$mac" --arg ip "$ip" --arg name "$name" \
			'. + [{id:$id,mac:$mac,ip:$ip,name:$name}]')
	done
	if [ -s /tmp/dhcp.leases ]; then
		active=$(awk 'BEGIN{printf "["}
			{ if (NR > 1) printf ","; printf "{\"mac\":\"%s\",\"ip\":\"%s\",\"name\":\"%s\",\"expire\":%s}", $2, $3, $4, $1 }
			END{printf "]"}' /tmp/dhcp.leases 2>/dev/null)
	fi
	[ -n "$active" ] || active="[]"
	printf '{"ok":true,"leases":%s,"active":%s}' "$list" "$active"
}

cmd_ifaces() {
	printf '{"ok":true,"ifaces":%s}' "$(ifaces_json)"
}

ifaces_json() {
	local list="[]" d mac st speed
	for d in /sys/class/net/*; do
		d=$(basename "$d")
		case "$d" in lo|*.*|ppp*|ifb*|wg*|tun*|tap*|veth*|sit*|gre*|erspan*) continue ;; esac
		mac=$(cat "/sys/class/net/$d/address" 2>/dev/null)
		st=$(cat "/sys/class/net/$d/operstate" 2>/dev/null)
		speed=$(cat "/sys/class/net/$d/speed" 2>/dev/null)
		list=$(printf '%s' "$list" | jq -c --arg name "$d" --arg mac "$mac" --arg state "$st" --argjson speed "$(jnum "$speed")" \
			'. + [{name:$name,mac:$mac,state:$state,speed:$speed}]')
	done
	printf '%s' "$list"
}

cmd_pppoe() {
	sample_rates
	config_load "$SR"
	local en device vlan ac svc localip netmask ps pe v6 v6p v6link v6len maxs dns1 dns2 mtu lcp_i lcp_f
	config_get_bool en pppoe enabled 0
	config_get device pppoe device 'br-lan'
	config_get vlan pppoe vlan '0'
	config_get ac pppoe ac_name 'LongOS'
	config_get svc pppoe service_name 'sparrow'
	config_get localip pppoe localip '192.168.200.1'
	config_get netmask pppoe netmask '255.255.255.0'
	config_get ps pppoe pool_start '192.168.200.100'
	config_get pe pppoe pool_end '192.168.200.200'
	config_get_bool v6 pppoe v6 1
	config_get v6p pppoe v6_prefix ''
	config_get v6link pppoe v6_link ''
	config_get v6len pppoe v6_prefix_len '64'
	config_get maxs pppoe maxsessions '200'
	config_get dns1 pppoe dns1 '223.5.5.5'
	config_get dns2 pppoe dns2 '119.29.29.29'
	config_get mtu pppoe mtu '1492'
	config_get lcp_i pppoe lcp_interval '20'
	config_get lcp_f pppoe lcp_failure '3'

	local accs="[]" aid aen au ap aip anote ad aupl
	for aid in $(account_ids); do
		config_get_bool aen "$aid" enabled 0
		config_get au "$aid" user ''
		config_get ap "$aid" pass ''
		config_get aip "$aid" ip ''
		config_get anote "$aid" note ''
		config_get ad "$aid" down '0'
		config_get aupl "$aid" up '0'
		[ -n "$au" ] || continue
		accs=$(printf '%s' "$accs" | jq -c --arg id "$aid" --arg user "$au" --arg pass "$ap" --arg ip "$aip" \
			--arg note "$anote" --argjson down "$(jnum "$ad")" --argjson up "$(jnum "$aupl")" \
			--argjson enabled "$(jbool "$aen")" \
			'. + [{id:$id,user:$user,pass:$pass,ip:$ip,note:$note,down:$down,up:$up,enabled:$enabled}]')
	done

	local running=0
	/etc/init.d/accel-ppp running >/dev/null 2>&1 && running=1

	jq -cn --argjson en "$(jbool "$en")" --arg address "$(pppoe_ifname "$device" "$vlan")" \
		--arg device "$device" --argjson vlan "$(jnum "$vlan")" --arg ac "$ac" --arg svc "$svc" \
		--arg localip "$localip" --arg netmask "$netmask" --arg ps "$ps" --arg pe "$pe" \
		--argjson v6 "$(jbool "$v6")" --arg v6p "$v6p" --arg v6link "$v6link" --argjson v6len "$(jnum "$v6len")" \
		--argjson maxs "$(jnum "$maxs")" --arg dns1 "$dns1" --arg dns2 "$dns2" --argjson mtu "$(jnum "$mtu")" \
		--argjson lcp_i "$(jnum "$lcp_i")" --argjson lcp_f "$(jnum "$lcp_f")" \
		--argjson accounts "$accs" --argjson online "$(pppoe_online_json)" --argjson running "$running" \
		--arg suggest "$(ipv6_prefix_suggest)" \
		'{ok:true,enabled:$en,running:$running,engine:"accel-ppp",device:$device,vlan:$vlan,interface:$address,
		  ac_name:$ac,service_name:$svc,localip:$localip,netmask:$netmask,pool_start:$ps,pool_end:$pe,
		  v6:$v6,v6_link:$v6link,v6_prefix:$v6p,v6_prefix_len:$v6len,maxsessions:$maxs,dns1:$dns1,dns2:$dns2,mtu:$mtu,
		  lcp_interval:$lcp_i,lcp_failure:$lcp_f,accounts:$accounts,online:$online,prefix_suggest:$suggest}'
}

cmd_qos() {
	config_load "$SR"
	local en ifc dl ul qdisc rules="[]" rid src dest pol
	config_get_bool en settings sqm_enable 0
	config_get ifc settings sqm_iface 'br-lan'
	config_get dl settings sqm_dl '0'
	config_get ul settings sqm_ul '0'
	config_get qdisc settings qdisc 'cake'
	for rid in $(rule_ids); do
		config_get src "$rid" src ''
		config_get dest "$rid" dest ''
		config_get pol "$rid" policy ''
		rules=$(printf '%s' "$rules" | jq -c --arg id "$rid" --arg src "$src" --arg dest "$dest" --arg policy "$pol" \
			'. + [{id:$id,src:$src,dest:$dest,policy:$policy}]')
	done
	local wans="[]" id wdl wul
	for id in $(wan_ids); do
		config_get wdl "$id" dl '0'
		config_get wul "$id" ul '0'
		wans=$(printf '%s' "$wans" | jq -c --arg id "$id" --argjson dl "$(jnum "$wdl")" --argjson ul "$(jnum "$wul")" \
			'. + [{id:$id,dl:$dl,ul:$ul}]')
	done
	jq -cn --argjson en "$(jbool "$en")" --arg iface "$ifc" --arg dl "$dl" --arg ul "$ul" --arg qdisc "$qdisc" \
		--argjson rules "$rules" --argjson shaping "$wans" \
		'{ok:true,enabled:$en,iface:$iface,download:$dl,upload:$ul,qdisc:$qdisc,rules:$rules,shaping:$shaping}'
}

cmd_dmz() {
	config_load "$SR"
	local en ip
	config_get_bool en settings dmz_enable 0
	config_get ip settings dmz_ip ''
	printf '{"ok":true,"enabled":%s,"ip":"%s"}' "$(jbool "$en")" "$(jesc "$ip")"
}

cmd_forwards() {
	local list="[]" id fen fname fproto fext fip fport
	for id in $(forward_ids); do
		config_get_bool fen "$id" enabled 0
		config_get fname "$id" name "$id"
		config_get fproto "$id" proto 'tcp'
		config_get fext "$id" ext_port ''
		config_get fip "$id" int_ip ''
		config_get fport "$id" int_port ''
		list=$(printf '%s' "$list" | jq -c --arg id "$id" --arg name "$fname" --arg proto "$fproto" \
			--arg ext_port "$fext" --arg int_ip "$fip" --arg int_port "$fport" --argjson enabled "$(jbool "$fen")" \
			'. + [{id:$id,name:$name,proto:$proto,ext_port:$ext_port,int_ip:$int_ip,int_port:$int_port,enabled:$enabled}]')
	done
	printf '{"ok":true,"forwards":%s}' "$list"
}

cmd_monitor() {
	config_load "$SR"
	local lines="[]" target4 target6
	config_get target4 settings ping4 '223.5.5.5'
	config_get target6 settings ping6 '2400:3200::1'

	local line_data
	line_data=$(file_json "$LINE_JSON")
	local id name runtime l3 ip4 ip6
	for id in $(wan_ids); do
		config_get name "$id" name "$id"
		runtime=$(iface_status_json "$id")
		l3=$(printf '%s' "$runtime" | jq -r '.l3 // ""')
		ip4=$(printf '%s' "$runtime" | jq -r '.ipv4 // ""')
		ip6=$(printf '%s' "$runtime" | jq -r 'if .ipv6 != "" then .ipv6 else .ipv6_pd end')
		local probe
		probe=$(printf '%s' "$line_data" | jq -c --arg id "$id" '.[$id] // {up:false}')
		lines=$(printf '%s' "$lines" | jq -c --argjson item "$(jq -cn --arg id "$id" --arg name "$name" --arg iface "$l3" \
			--arg ip4 "$ip4" --arg ip6 "$ip6" --argjson rt "$runtime" --argjson probe "$probe" \
			'{id:$id,name:$name,iface:$iface,ipv4:$ip4,ipv6:$ip6,up:($rt.up//false),proto:$rt.proto,probe:$probe}')" '. + [$item]')
	done

	printf '{"ok":true,"lines":%s,"history":%s,"target4":"%s","target6":"%s"}' \
		"$lines" "$(monitor_hist_json)" "$(jesc "$target4")" "$(jesc "$target6")"
}

cmd_trea() {
	config_load "$SR"
	local en server token iface interval extra running=0 pid="" ver=""
	config_get_bool en trea enabled 0
	config_get server trea server ''
	config_get token trea token ''
	config_get iface trea iface ''
	config_get interval trea interval '60'
	config_get extra trea extra ''
	pid=$(pgrep -f "trea -c /etc/trea.conf" 2>/dev/null | head -1)
	[ -n "$pid" ] && running=1
	[ -x /usr/bin/trea ] && ver=$(/usr/bin/trea -v 2>/dev/null | head -1)
	local lg=""
	[ -f /var/log/trea.log ] && lg=$(tail -n 80 /var/log/trea.log 2>/dev/null)
	jq -cn --argjson en "$(jbool "$en")" --arg server "$server" --arg token "$token" --arg iface "$iface" \
		--argjson interval "$(jnum "$interval")" --arg extra "$extra" --argjson running "$running" \
		--arg pid "$pid" --arg version "$ver" --arg log "$lg" --argjson installed "$( [ -x /usr/bin/trea ] && echo true || echo false )" \
		'{ok:true,enabled:$en,server:$server,token:$token,iface:$iface,interval:$interval,extra:$extra,
		  running:$running,pid:$pid,version:$version,log:$log,installed:$installed}'
}

cmd_settings() {
	config_load "$SR"
	local hostname dns1 dns2 p4 p6 interval tz
	config_get hostname settings hostname 'LongOS'
	config_get dns1 settings dns1 '223.5.5.5'
	config_get dns2 settings dns2 '119.29.29.29'
	config_get p4 settings ping4 '223.5.5.5'
	config_get p6 settings ping6 '2400:3200::1'
	config_get interval settings monitor_interval '5'
	tz=$(uci -q get system.@system[0].timezone)
	jq -cn --arg hostname "$hostname" --arg dns1 "$dns1" --arg dns2 "$dns2" \
		--arg p4 "$p4" --arg p6 "$p6" --argjson interval "$(jnum "$interval")" --arg tz "$tz" \
		--arg version "$(cat "$VERSION_FILE" 2>/dev/null || echo 1.0.0)" --arg arch "$(uname -m)" \
		'{ok:true,hostname:$hostname,dns1:$dns1,dns2:$dns2,ping4:$p4,ping6:$p6,monitor_interval:$interval,
		  timezone:$tz,version:$version,arch:$arch}'
}

del_wan() {
	local id
	id=$(json_get '.id')
	uci -q delete "$SR.$id"
	uci commit "$SR"
	INPUT=""
	apply_all
	printf '{"ok":true}'
}

toggle_wan() {
	local id en
	id=$(json_get '.id')
	en=$(json_get '.enabled')
	uci set "$SR.$id.enabled=$([ "$en" = "true" ] && echo 1 || echo 0)"
	uci commit "$SR"
	INPUT=""
	apply_all
	printf '{"ok":true}'
}

# ---------------- 入口 ----------------

cmd="$1"
if [ "$cmd" = "apply" ]; then
	apply_all
	printf '{"ok":true}'
	exit 0
fi

if [ -n "$2" ]; then
	INPUT="$2"
elif [ ! -t 0 ]; then
	INPUT=$(cat)
fi

case "$cmd" in
	status) cmd_status ;;
	wans) cmd_wans ;;
	lan) cmd_lan ;;
	leases) cmd_leases ;;
	pppoe) cmd_pppoe ;;
	ifaces) cmd_ifaces ;;
	qos) cmd_qos ;;
	dmz) cmd_dmz ;;
	forwards) cmd_forwards ;;
	monitor) cmd_monitor ;;
	trea) cmd_trea ;;
	settings) cmd_settings ;;
	wan_save) save_wan ;;
	wan_del|cmd_del_wan) del_wan ;;
	wan_toggle) toggle_wan ;;
	lan_save) save_lan ;;
	dhcp_save) save_dhcp ;;
	lease_save) save_lease ;;
	lease_del) del_lease ;;
	pppoe_save) save_pppoe ;;
	account_save) save_account ;;
	account_del) del_account ;;
	kick) kick_user ;;
	rule_save) save_rule ;;
	rule_del) del_rule ;;
	qos_save) save_qos ;;
	wan_shaping) save_wan_shaping ;;
	dmz_save) save_dmz ;;
	forward_save) save_forward ;;
	forward_del) del_forward ;;
	settings_save) save_settings ;;
	password_save) save_password ;;
	trea_save) save_trea ;;
	trea_action) trea_action ;;
	reboot) (sleep 1; reboot) >/dev/null 2>&1 & printf '{"ok":true}' ;;
	*) printf '{"ok":false,"msg":"unknown command: %s"}' "$(jesc "$cmd")" ;;
esac
exit 0
