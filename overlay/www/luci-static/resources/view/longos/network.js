'use strict';
'require view';
'require longos.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }
function cb(box, n) { var e = box.querySelector('[data-f="' + n + '"] input[type="checkbox"]'); return !!(e && e.checked); }

return view.extend({
	load: function() {
		return Promise.all([ api.call('wans'), api.call('lan'), api.call('leases'), api.call('status') ]);
	},

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-lo]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('longos/lo.css'), 'data-lo': '1' }));

		this.wans = ((res[3] || {}).wans) || [];
		this.lan = res[1] || {};
		this.leases = res[2] || {};
		this.ifaces = ((res[3] || {}).ifaces || []).filter(function(i) {
			return i.name !== 'br-lan';
		});

		this.elWan = E('div', {});
		this.elLease = E('div', {});

		var lanBox = E('div', {}, [
			E('div', { 'class': 'lo-two' }, [
				api.field('LAN 网关地址', api.input({ 'data-f': 'lan_ip', 'value': this.lan.ip || '' })),
				api.field('子网掩码', api.input({ 'data-f': 'lan_mask', 'value': this.lan.mask || '' }))
			]),
			api.field('LAN 桥接网卡（空格分隔）', api.input({ 'data-f': 'lan_ports', 'value': this.lan.ports || '' }), '例如 eth0 eth2；改动会重建 br-lan'),
			E('div', { 'class': 'lo-two' }, [
				api.field('DHCP 起始地址', api.input({ 'data-f': 'dhcp_start', 'value': this.lan.dhcp_start || '' })),
				api.field('DHCP 结束地址', api.input({ 'data-f': 'dhcp_end', 'value': this.lan.dhcp_end || '' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('租约时间', api.input({ 'data-f': 'dhcp_lease', 'value': this.lan.dhcp_lease || '12h' })),
				api.field('启用 DHCPv4 服务', api.switchBox(!!this.lan.dhcp_enable, 'dhcp_enable'))
			]),
			E('div', { 'class': 'lo-toolbar' }, [
				api.btn('保存 LAN 设置', 'cbi-button-action', function() {
					api.call('lan_save', {
						ip: v(lanBox, 'lan_ip'), mask: v(lanBox, 'lan_mask'), ports: v(lanBox, 'lan_ports'),
						dhcp_start: v(lanBox, 'dhcp_start'), dhcp_end: v(lanBox, 'dhcp_end'),
						dhcp_lease: v(lanBox, 'dhcp_lease'), dhcp_enable: cb(lanBox, 'dhcp_enable')
					}).then(function() { api.notify('LAN 配置已应用（地址变更后需重新访问）', 'info'); })
					  .catch(function(e) { api.notify(e.message, 'error'); });
				})
			])
		]);

		var root = E('div', { 'class': 'lo-wrap' }, [
			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ 'WAN 线路', api.badge('VLAN / PPPoE / DHCP / 静态 / 混合', 'info') ]),
				E('p', { 'class': 'lo-desc' }, [ '混合模式 = 同一 VLAN 下同时发起 PPPoE 拨号与 DHCP 获取（运营商双栈常见）。' ]),
				E('div', { 'class': 'lo-toolbar' }, [
					api.btn('+ 新增 WAN 线路', 'cbi-button-action', function() { self.editWan(null); }),
					E('span', { 'class': 'grow' }),
					api.btn('刷新', '', function() { self.reload(); })
				]),
				this.elWan
			]),
			E('div', { 'class': 'lo-card' }, [ E('h3', {}, [ 'LAN 与 DHCPv4' ]), lanBox ]),
			E('div', { 'class': 'lo-card' }, [
				E('h3', {}, [ 'DHCP 静态绑定', api.badge('MAC → IP', 'info') ]),
				E('div', { 'class': 'lo-toolbar' }, [
					api.btn('+ 新增绑定', 'cbi-button-action', function() { self.editLease(null); })
				]),
				this.elLease
			])
		]);

		this.renderWans();
		this.renderLeases();
		return root;
	},

	reload: function() {
		var self = this;
		Promise.all([ api.call('status'), api.call('lan'), api.call('leases') ]).then(function(r) {
			self.wans = ((r[0] || {}).wans) || [];
			self.lan = r[1] || {};
			self.leases = r[2] || {};
			self.renderWans();
			self.renderLeases();
		});
	},

	renderWans: function() {
		var self = this;
		var rows = this.wans.map(function(w) {
			var rt = w.rt || {};
			return E('tr', {}, [
				E('td', {}, [
					E('div', {}, [ w.name || w.id ]),
					E('div', { 'class': 'lo-mono lo-muted' }, [ w.id ])
				]),
				E('td', { 'class': 'lo-mono' }, [ w.device + (Number(w.vlan) > 0 ? '.' + w.vlan : '') ]),
				E('td', {}, [ (w.mode || '').toUpperCase() ]),
				E('td', { 'class': 'lo-mono' }, [ w.mode === 'pppoe' || w.mode === 'mixed' ? (w.user || '--') : (w.ip || 'DHCP') ]),
				E('td', {}, [
					api.statusDot(!!rt.up),
					E('span', { 'style': 'margin-left:6px;color:' + (rt.up ? '#22c55e' : '#94a3b8') }, [ rt.up ? (rt.ipv4 || '已连接') : (w.enabled ? '未连接' : '已停用') ])
				]),
				E('td', { 'class': 'lo-mono' }, [ rt.ipv6 || rt.ipv6_prefix || '--' ]),
				E('td', {}, [
					api.btn('编辑', '', function() { self.editWan(w); }),
					' ',
					api.btn(w.enabled ? '停用' : '启用', '', function() {
						api.call('wan_toggle', { id: w.id, enabled: !w.enabled }).then(function() { self.reload(); });
					}),
					' ',
					api.btn('删除', 'cbi-button-negative', function() {
						api.confirm('删除线路 ' + (w.name || w.id) + '？', function() {
							api.call('wan_del', { id: w.id }).then(function() { self.reload(); });
						});
					})
				])
			]);
		});
		this.elWan.textContent = '';
		this.elWan.appendChild(api.table(
			[ '名称', '网卡', '模式', '账号 / 静态 IP', '状态', 'IPv6', '操作' ], rows, '暂无 WAN 线路'));
	},

	editWan: function(w) {
		var self = this;
		var isNew = !w;
		w = w || { mode: 'pppoe', vlan: 0, weight: 1, mtu: 1500, enabled: true, v6: true, mask: '255.255.255.0' };
		var devOpts = this.ifaces.map(function(i) { return { value: i.name, label: i.name + (i.state === 'up' ? ' (已连接)' : '') }; });
		if (w.device && !devOpts.filter(function(o) { return o.value === w.device; }).length)
			devOpts.unshift({ value: w.device, label: w.device });

		var box = E('div', { 'class': 'lo-modal' }, [
			E('div', { 'class': 'lo-two' }, [
				api.field('线路名称', api.input({ 'data-f': 'name', 'value': w.name || '' })),
				api.field('物理网卡', api.sel(devOpts, w.device || (devOpts[0] && devOpts[0].value), { 'data-f': 'device' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('VLAN ID（0 为不打标签）', api.input({ 'data-f': 'vlan', 'type': 'number', 'value': w.vlan || 0 })),
				api.field('接入模式', api.sel([
					{ value: 'pppoe', label: 'PPPoE 拨号' },
					{ value: 'dhcp', label: 'DHCP 自动获取' },
					{ value: 'static', label: '静态 IP' },
					{ value: 'mixed', label: '混合（PPPoE + DHCP）' }
				], w.mode || 'pppoe', { 'data-f': 'mode' }))
			]),
			api.field('宽带账号', api.input({ 'data-f': 'user', 'value': w.user || '' }), 'PPPoE / 混合模式使用'),
			api.field('宽带密码', api.input({ 'data-f': 'pass', 'type': 'password', 'value': w.pass || '' })),
			E('div', { 'class': 'lo-two' }, [
				api.field('静态 IP', api.input({ 'data-f': 'ip', 'value': w.ip || '', 'placeholder': '静态模式填写' })),
				api.field('子网掩码', api.input({ 'data-f': 'mask', 'value': w.mask || '255.255.255.0' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('默认网关', api.input({ 'data-f': 'gw', 'value': w.gw || '' })),
				api.field('MTU', api.input({ 'data-f': 'mtu', 'type': 'number', 'value': w.mtu || 1500 }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('首选 DNS', api.input({ 'data-f': 'dns1', 'value': w.dns1 || '' })),
				api.field('备用 DNS', api.input({ 'data-f': 'dns2', 'value': w.dns2 || '' }))
			]),
			E('div', { 'class': 'lo-two' }, [
				api.field('分流权重', api.input({ 'data-f': 'weight', 'type': 'number', 'value': w.weight || 1 }), '权重越大承载流量越多'),
				api.field('IPv6 双栈', api.switchBox(!!w.v6, 'v6'), '关闭后该线路只跑 IPv4')
			]),
			api.field('启用该线路', api.switchBox(!!w.enabled, 'enabled'))
		]);

		api.modal(isNew ? '新增 WAN 线路' : '编辑 WAN 线路', [ box ], function() {
			return api.call('wan_save', {
				id: w.id || '',
				name: v(box, 'name'), device: v(box, 'device'), vlan: v(box, 'vlan'),
				mode: v(box, 'mode'), user: v(box, 'user'), pass: v(box, 'pass'),
				ip: v(box, 'ip'), mask: v(box, 'mask'), gw: v(box, 'gw'),
				mtu: v(box, 'mtu'), dns1: v(box, 'dns1'), dns2: v(box, 'dns2'),
				weight: v(box, 'weight'), dl: w.dl || 0, ul: w.ul || 0,
				enabled: cb(box, 'enabled'), v6: cb(box, 'v6')
			}).then(function() {
				api.notify('线路已保存并应用', 'info');
				self.reload();
			});
		});
	},

	renderLeases: function() {
		var self = this;
		var hosts = (this.leases.leases || []).map(function(l) {
			return E('tr', {}, [
				E('td', {}, [ l.name || '--' ]),
				E('td', { 'class': 'lo-mono' }, [ l.mac ]),
				E('td', { 'class': 'lo-mono' }, [ l.ip ]),
				E('td', {}, [
					api.btn('编辑', '', function() { self.editLease(l); }),
					' ',
					api.btn('删除', 'cbi-button-negative', function() {
						api.call('lease_del', { id: l.id }).then(function() { self.reload(); });
					})
				])
			]);
		});
		var active = (this.leases.active || []).slice(0, 30).map(function(l) {
			return E('tr', {}, [
				E('td', { 'class': 'lo-mono' }, [ l.mac ]),
				E('td', { 'class': 'lo-mono' }, [ l.ip ]),
				E('td', {}, [ l.name || '--' ]),
				E('td', {}, [ l.expire ? new Date(Number(l.expire) * 1000).toLocaleString() : '--' ])
			]);
		});

		this.elLease.textContent = '';
		this.elLease.appendChild(api.table([ '名称', 'MAC', 'IP', '操作' ], hosts, '暂无静态绑定'));
		this.elLease.appendChild(E('h3', { 'style': 'margin-top:16px' }, [ '当前租约' ]));
		this.elLease.appendChild(api.table([ 'MAC', 'IP', '主机名', '到期时间' ], active, '暂无在线租约'));
	},

	editLease: function(l) {
		var self = this;
		l = l || {};
		var box = E('div', { 'class': 'lo-modal' }, [
			api.field('主机名', api.input({ 'data-f': 'name', 'value': l.name || '' })),
			api.field('MAC 地址', api.input({ 'data-f': 'mac', 'value': l.mac || '', 'placeholder': 'aa:bb:cc:dd:ee:ff' })),
			api.field('固定 IP', api.input({ 'data-f': 'ip', 'value': l.ip || '', 'placeholder': '192.168.100.50' }))
		]);
		api.modal(l.id ? '编辑静态绑定' : '新增静态绑定', [ box ], function() {
			return api.call('lease_save', {
				id: l.id || '', name: v(box, 'name'), mac: v(box, 'mac'), ip: v(box, 'ip')
			}).then(function() {
				api.notify('静态绑定已保存', 'info');
				self.reload();
			});
		});
	}
});
