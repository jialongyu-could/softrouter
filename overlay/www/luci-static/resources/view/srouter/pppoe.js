'use strict';
'require view';
'require poll';
'require dom';
'require srouter.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }
function cb(box, n) { var e = box.querySelector('[data-f="' + n + '"] input[type="checkbox"]'); return !!(e && e.checked); }

return view.extend({
	load: function() {
		return Promise.all([ api.call('pppoe'), api.call('ifaces'), api.call('status') ]);
	},

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-sr]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('srouter/sr.css'), 'data-sr': '1' }));

		this.d = res[0] || {};
		this.ifaces = ((res[1] || {}).ifaces || []);
		this.status = res[2] || {};

		this.elAcc = E('div', {});
		this.elOnline = E('div', {});
		this.elState = E('div', {});

		var d = this.d;
		var devOpts = this.ifaces.map(function(i) { return { value: i.name, label: i.name }; });
		if (devOpts.filter(function(o) { return o.value === 'br-lan'; }).length === 0)
			devOpts.unshift({ value: 'br-lan', label: 'br-lan (LAN 网桥)' });
		if (d.device && !devOpts.filter(function(o) { return o.value === d.device; }).length)
			devOpts.push({ value: d.device, label: d.device });

		this.box = E('div', {}, [
			E('div', { 'class': 'sr-two' }, [
				api.field('服务端入口网卡', api.sel(devOpts, d.device || 'br-lan', { 'data-f': 'device' }), '下游设备从这个网卡（或 VLAN）发起拨号'),
				api.field('VLAN ID（0 为不打标签）', api.input({ 'data-f': 'vlan', 'type': 'number', 'value': d.vlan || 0 }), '填 100 时自动创建 ethX.100 作为拨号入口')
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('AC 名称', api.input({ 'data-f': 'ac_name', 'value': d.ac_name || 'LongOS' })),
				api.field('Service 名称', api.input({ 'data-f': 'service_name', 'value': d.service_name || 'sparrow' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('服务端网关地址', api.input({ 'data-f': 'localip', 'value': d.localip || '192.168.200.1' })),
				api.field('IPv4 掩码', api.input({ 'data-f': 'netmask', 'value': d.netmask || '255.255.255.0' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('IPv4 地址池起始', api.input({ 'data-f': 'pool_start', 'value': d.pool_start || '' })),
				api.field('IPv4 地址池结束', api.input({ 'data-f': 'pool_end', 'value': d.pool_end || '' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('首选 DNS', api.input({ 'data-f': 'dns1', 'value': d.dns1 || '' })),
				api.field('备用 DNS', api.input({ 'data-f': 'dns2', 'value': d.dns2 || '' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('MTU', api.input({ 'data-f': 'mtu', 'type': 'number', 'value': d.mtu || 1492 })),
				api.field('最大会话数（仅展示上限）', api.input({ 'data-f': 'maxsessions', 'type': 'number', 'value': d.maxsessions || 200 }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('LCP 探测间隔（秒）', api.input({ 'data-f': 'lcp_interval', 'type': 'number', 'value': d.lcp_interval || 20 })),
				api.field('LCP 失败次数', api.input({ 'data-f': 'lcp_failure', 'type': 'number', 'value': d.lcp_failure || 3 }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('IPv6 双栈', api.switchBox(d.v6 !== false, 'v6')),
				api.field('启用 PPPoE 服务端', api.switchBox(!!d.enabled, 'enabled'))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('IPv6 链路前缀（/64，可留空）', api.input({ 'data-f': 'v6_link', 'value': d.v6_link || '', 'placeholder': 'fd00:1::/64' }), '留空即可；填 PD 池内的前缀会与委派前缀重叠'),
				api.field('IPv6 委派池（PD）', api.input({ 'data-f': 'v6_prefix', 'value': d.v6_prefix || '', 'placeholder': '2408:8207:1234::/56' }), '优先从 WAN 自动检测，可手动改')
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('每条会话委派长度', api.input({ 'data-f': 'v6_prefix_len', 'type': 'number', 'value': d.v6_prefix_len || 64 }), '上游 PD 为 /56 时通常委派 64'),
				api.field('IPv6 模块', E('p', { 'class': 'sr-desc' }, [ 'ipv6pool / ipv6_dhcp / ipv6_nd 随 IPv6 双栈开关自动加载' ]))
			]),
			E('div', { 'class': 'sr-toolbar' }, [
				api.btn('保存并应用', 'cbi-button-action', function() { self.save(); }),
				api.btn('使用检测到的 WAN 前缀', '', function() {
					var s = d.prefix_suggest || '';
					if (!s) { api.notify('未从 WAN 检测到委派前缀，请确认上游 IPv6 已下发', 'warning'); return; }
					var box = self.box;
					box.querySelector('[data-f="v6_prefix"]').value = s;
					box.querySelector('[data-f="v6_link"]').value = '';
					api.notify('已填入 PD 池 ' + s + '；链路前缀已清空，避免与委派出去的 /64 重叠', 'info');
				}),
				E('span', { 'class': 'grow' }),
				api.badge(d.running ? 'accel-ppp 运行中' : 'accel-ppp 未运行', d.running ? 'ok' : 'warn')
			])
		]);

		var root = E('div', { 'class': 'sr-wrap' }, [
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ 'PPPoE 服务端（accel-ppp）', api.badge('IPv4 + IPv6 PD', 'info') ]),
				E('p', { 'class': 'sr-desc' }, [
					'本机作为 PPPoE 服务端，下游设备使用下方账号拨号，可获得 IPv4 地址与 IPv6 委派前缀。',
					'账号与限速同样由本页管理，保存后立即生效。'
				]),
				this.elState,
				this.box
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '拨号账号', api.badge('本地 chap-secrets', 'info') ]),
				E('div', { 'class': 'sr-toolbar' }, [
					api.btn('+ 新增账号', 'cbi-button-action', function() { self.editAccount(null); })
				]),
				this.elAcc
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '在线会话', api.badge('自动刷新', 'live') ]),
				this.elOnline
			])
		]);

		this.renderAccounts();
		this.renderOnline();
		poll.add(function() {
			return api.call('pppoe').then(function(x) {
				self.d = x;
				self.renderOnline(x.online || []);
			}).catch(function() {});
		}, 5);

		return root;
	},

	save: function() {
		var self = this, box = this.box;
		api.call('pppoe_save', {
			enabled: cb(box, 'enabled'), device: v(box, 'device'), vlan: v(box, 'vlan'),
			ac_name: v(box, 'ac_name'), service_name: v(box, 'service_name'),
			localip: v(box, 'localip'), netmask: v(box, 'netmask'),
			pool_start: v(box, 'pool_start'), pool_end: v(box, 'pool_end'),
			dns1: v(box, 'dns1'), dns2: v(box, 'dns2'), mtu: v(box, 'mtu'),
			maxsessions: v(box, 'maxsessions'), lcp_interval: v(box, 'lcp_interval'),
			lcp_failure: v(box, 'lcp_failure'), v6: cb(box, 'v6'),
			v6_link: v(box, 'v6_link'), v6_prefix: v(box, 'v6_prefix')
		}).then(function() {
			api.notify('PPPoE 服务端配置已应用', 'info');
			window.setTimeout(function() { location.reload(); }, 800);
		}).catch(function(e) { api.notify(e.message, 'error'); });
	},

	renderAccounts: function() {
		var self = this;
		var rows = (this.d.accounts || []).map(function(a) {
			return E('tr', {}, [
				E('td', {}, [ a.user ]),
				E('td', { 'class': 'sr-mono' }, [ a.pass ? '••••••' : '--' ]),
				E('td', { 'class': 'sr-mono' }, [ a.ip || '动态分配' ]),
				E('td', {}, [ a.down ? api.kbps(a.down) : '不限' ]),
				E('td', {}, [ a.up ? api.kbps(a.up) : '不限' ]),
				E('td', {}, [ a.enabled ? api.badge('启用', 'ok') : api.badge('停用', 'off') ]),
				E('td', {}, [
					api.btn('编辑', '', function() { self.editAccount(a); }),
					' ',
					api.btn('删除', 'cbi-button-negative', function() {
						api.confirm('删除账号 ' + a.user + '？', function() {
							api.call('account_del', { id: a.id }).then(function() {
								api.notify('账号已删除', 'info');
								self.reloadAccounts();
							});
						});
					})
				])
			]);
		});
		this.elAcc.textContent = '';
		this.elAcc.appendChild(api.table(
			[ '账号', '密码', '绑定 IPv4', '下行限速', '上行限速', '状态', '操作' ], rows, '暂无拨号账号'));
	},

	reloadAccounts: function() {
		var self = this;
		api.call('pppoe').then(function(d) {
			self.d = d;
			self.renderAccounts();
			self.renderOnline(d.online || []);
		});
	},

	editAccount: function(a) {
		var self = this;
		a = a || { enabled: true, down: 0, up: 0 };
		var box = E('div', { 'class': 'sr-modal' }, [
			api.field('拨号账号', api.input({ 'data-f': 'user', 'value': a.user || '' })),
			api.field('拨号密码', api.input({ 'data-f': 'pass', 'type': 'text', 'value': a.pass || '' })),
			api.field('绑定固定 IPv4（留空动态分配）', api.input({ 'data-f': 'ip', 'value': a.ip || '' })),
			E('div', { 'class': 'sr-two' }, [
				api.field('下行限速（Kbps，0 不限）', api.input({ 'data-f': 'down', 'type': 'number', 'value': a.down || 0 })),
				api.field('上行限速（Kbps，0 不限）', api.input({ 'data-f': 'up', 'type': 'number', 'value': a.up || 0 }))
			]),
			api.field('备注', api.input({ 'data-f': 'note', 'value': a.note || '' })),
			api.field('启用账号', api.switchBox(!!a.enabled, 'enabled'))
		]);
		api.modal(a.id ? '编辑拨号账号' : '新增拨号账号', [ box ], function() {
			return api.call('account_save', {
				id: a.id || '', user: v(box, 'user'), pass: v(box, 'pass'), ip: v(box, 'ip'),
				down: v(box, 'down'), up: v(box, 'up'), note: v(box, 'note'),
				enabled: cb(box, 'enabled')
			}).then(function() {
				api.notify('账号已保存', 'info');
				self.reloadAccounts();
			});
		});
	},

	renderOnline: function(list) {
		var self = this;
		list = list || [];
		var rows = list.map(function(u) {
			return E('tr', {}, [
				E('td', {}, [ u.user ]),
				E('td', { 'class': 'sr-mono' }, [ u.ip ]),
				E('td', { 'class': 'sr-mono' }, [ u.ipv6 || '--' ]),
				E('td', { 'class': 'sr-mono' }, [ u.iface ]),
				E('td', {}, [ api.dur(u.uptime) ]),
				E('td', { 'style': 'color:#38bdf8' }, [ api.rate(u.rx) ]),
				E('td', { 'style': 'color:#fb7185' }, [ api.rate(u.tx) ]),
				E('td', {}, [
					api.btn('下线', 'cbi-button-negative', function() {
						api.call('kick', { iface: u.iface, user: u.user }).then(function() {
							api.notify('已踢下线 ' + u.user, 'info');
							self.reloadAccounts();
						});
					})
				])
			]);
		});
		dom.content(this.elOnline, api.table(
			[ '账号', 'IPv4', 'IPv6', '接口', '在线时长', '下行速率', '上行速率', '操作' ], rows, '当前无在线拨号用户'));
	}
});
