'use strict';
'require view';
'require poll';
'require dom';
'require srouter.api as api';

var hist = { rx: [], tx: [] };
var MAXP = 60;

function metric(title, value, sub, small) {
	return E('div', { 'class': 'sr-metric' }, [
		E('span', { 'class': 't' }, [ title ]),
		E('span', { 'class': 'v' + (small ? ' small' : '') }, [ value ]),
		E('span', { 'class': 's' }, [ sub || '' ])
	]);
}

function kv(k, v, cls) {
	return E('div', { 'class': 'sr-kv' }, [
		E('span', { 'class': 'k' }, [ k ]),
		E('span', { 'class': 'v ' + (cls || '') }, [ v || '--' ])
	]);
}

return view.extend({
	load: function() {
		return api.call('status');
	},

	render: function(data) {
		var self = this;
		if (!document.querySelector('link[data-sr]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('srouter/sr.css'), 'data-sr': '1' }));

		this.elTop = E('div', { 'class': 'sr-topbar' });
		this.elWan = E('div', { 'class': 'sr-grid' });
		this.elV6 = E('div', {});
		this.elPpp = E('div', {});
		this.canvas = E('canvas', { 'class': 'sr-canvas' });

		var root = E('div', { 'class': 'sr-wrap' }, [
			this.elTop,
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ 'WAN 总流量趋势', api.badge('实时', 'live') ]),
				E('div', { 'class': 'sr-toolbar' }, [
					E('span', { 'style': 'color:#38bdf8;font-size:12px' }, [ '■ 下行' ]),
					E('span', { 'style': 'color:#fb7185;font-size:12px' }, [ '■ 上行' ]),
					E('span', { 'class': 'grow' })
				]),
				this.canvas
			]),
			E('div', { 'class': 'sr-card' }, [ E('h3', {}, [ '线路状态', api.badge('IPv4 / IPv6 双栈', 'info') ]), this.elWan ]),
			E('div', { 'class': 'sr-card' }, [ E('h3', {}, [ 'IPv6 前缀与委派', api.badge('PD', 'info') ]), this.elV6 ]),
			this.elPpp
		]);

		this.update(data || {});
		poll.add(function() {
			return api.call('status').then(function(d) { self.update(d); }).catch(function() {});
		}, 3);

		return root;
	},

	update: function(d) {
		var sys = d.sys || {}, lan = d.lan || {}, wans = d.wans || [], ppp = d.pppoe || {};
		var cpu = sys.cpu || {}, mem = sys.mem || {}, line = d.line || {};

		dom.content(this.elTop, [
			metric('系统时间', (sys.time || '').split(' ')[1] || '--', sys.time || ''),
			metric('运行时长', api.dur(sys.uptime), sys.hostname || ''),
			metric('CPU 占用', (sys.cpu_usage || 0) + '%', ((cpu.model || '').replace(/\(R\)|\(TM\)|CPU|@.*/g, '').trim()) + ' · ' + (cpu.cores || 0) + '核', true),
			metric('内存占用', (mem.pct || 0) + '%', api.bytes((mem.used || 0) * 1024) + ' / ' + api.bytes((mem.total || 0) * 1024), true),
			metric('并发连接', String(sys.conn || 0), '版本 ' + (sys.version || '')),
			metric('PPPoE 在线', String((ppp.online || []).length), '上限 ' + (ppp.max || 0) + ' 个账号', true),
			metric('LAN', lan.ip || '--', '终端 ' + (lan.clients || 0) + ' 台', true)
		]);

		var totalRx = 0, totalTx = 0;
		var cards = wans.map(function(w) {
			var rt = w.rt || {}, rt6 = w.rt6 || {}, probe = line[w.id] || {};
			totalRx += Number(rt.rx || 0);
			totalTx += Number(rt.tx || 0);
			var up = !!rt.up;
			return E('div', { 'class': 'sr-wan' }, [
				E('div', { 'class': 'head' }, [
					api.statusDot(up),
					E('span', { 'class': 'name' }, [ w.name || w.id ]),
					E('span', { 'class': 'mode' }, [ (w.mode || '').toUpperCase() + (w.device ? ' · ' + w.device + (Number(w.vlan) > 0 ? '.' + w.vlan : '') : '') ]),
					E('span', { 'class': 'st', 'style': 'color:' + (up ? '#22c55e' : '#64748b') }, [ up ? '已连接' : (w.enabled ? '未连接' : '已停用') ])
				]),
				kv('IPv4 地址', rt.ipv4 ? rt.ipv4 + '/' + (rt.ipv4_mask || '') : ''),
				kv('IPv6 地址', rt.ipv6 || (rt6.ipv6 || '')),
				kv('IPv6 前缀', rt.ipv6_prefix || rt6.ipv6_prefix || '未下发'),
				kv('默认网关', rt.gw || ''),
				kv('DNS', (rt.dns || '').split(',').filter(Boolean).slice(0, 2).join(' / ')),
				kv('连接时长', up ? api.dur(rt.uptime) : '--'),
				kv('下行 / 上行', api.rate(rt.rx) + ' / ' + api.rate(rt.tx)),
				E('div', { 'class': 'sr-probe-row' }, [
					E('span', { 'class': 'k' }, [ 'IPv4 探测' ]), api.probe(probe.ipv4),
					E('span', { 'class': 'k', 'style': 'margin-left:14px' }, [ 'IPv6 探测' ]), api.probe(probe.ipv6)
				])
			]);
		});
		if (!cards.length)
			cards = [ E('div', { 'class': 'sr-empty' }, [ '暂无 WAN 线路，请到「线路与网络」添加' ]) ];
		dom.content(this.elWan, cards);

		// IPv6 / PPPoE 前缀
		var v6rows = wans.map(function(w) {
			var rt = w.rt || {};
			return E('tr', {}, [
				E('td', {}, [ w.name || w.id ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6 || '--' ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6_prefix || '未下发' ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6_pd || '未委派' ])
			]);
		});
		dom.content(this.elV6, api.table([ '线路', 'IPv6 地址', 'WAN 前缀', '委派给 LAN 的前缀' ], v6rows, '暂无线路'));

		// 流量曲线（服务端历史优先）
		var h = d.hist || [];
		if (h.length > 1) {
			hist.rx = h.map(function(x) { return Number(x.rx) || 0; });
			hist.tx = h.map(function(x) { return Number(x.tx) || 0; });
		} else {
			hist.rx.push(totalRx); hist.tx.push(totalTx);
			if (hist.rx.length > MAXP) { hist.rx.shift(); hist.tx.shift(); }
		}
		if (this.canvas.offsetParent) {
			api.chart(this.canvas, [
				{ data: hist.rx, color: '#38bdf8', fill: 'rgba(56,189,248,0.12)' },
				{ data: hist.tx, color: '#fb7185', fill: 'rgba(251,113,133,0.10)' }
			], Math.max(MAXP, hist.rx.length));
		}

		// PPPoE 在线
		var online = ppp.online || [];
		var rows = online.map(function(u) {
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
						api.confirm('确定将 ' + u.user + ' 强制下线？', function() {
							api.call('kick', { iface: u.iface, user: u.user }).then(function() {
								api.notify('已强制下线 ' + u.user, 'info');
							}).catch(function(e) { api.notify(e.message, 'error'); });
						});
					})
				])
			]);
		});

		dom.content(this.elPpp, [
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [
					'PPPoE 服务端在线用户',
					E('span', { 'class': 'sr-tag' }, [ (ppp.enabled ? '运行中' : '未启用') + ' · ' + (ppp.service || '') ]),
					E('span', { 'style': 'margin-left:auto;font-size:12px;color:#94a3b8' }, [ '在线 ' + online.length + ' / ' + (ppp.max || 0) ])
				]),
				api.table([ '账号', 'IPv4', 'IPv6', '接口', '在线时长', '下行', '上行', '操作' ], rows,
					ppp.enabled ? '当前没有拨号用户' : 'PPPoE 服务端未启用')
			])
		]);
	}
});
