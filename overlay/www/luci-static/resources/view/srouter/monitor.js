'use strict';
'require view';
'require poll';
'require dom';
'require srouter.api as api';

return view.extend({
	load: function() { return Promise.all([ api.call('monitor'), api.call('status') ]); },

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-sr]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('srouter/sr.css'), 'data-sr': '1' }));

		this.elLines = E('div', {});
		this.elV6 = E('div', {});
		this.elIf = E('div', {});
		this.canvas = E('canvas', { 'class': 'sr-canvas' });

		var root = E('div', { 'class': 'sr-wrap' }, [
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ 'WAN 总流量（历史）', api.badge('最近 30 分钟', 'info') ]),
				E('div', { 'class': 'sr-toolbar' }, [
					E('span', { 'style': 'color:#38bdf8;font-size:12px' }, [ '■ 下行' ]),
					E('span', { 'style': 'color:#fb7185;font-size:12px' }, [ '■ 上行' ])
				]),
				this.canvas
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '线路探测', api.badge('IPv4 / IPv6 延迟与丢包', 'live') ]),
				this.elLines
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ 'IPv6 状态', api.badge('地址 / 前缀 / PD', 'info') ]),
				this.elV6
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '物理网卡' ]),
				this.elIf
			])
		]);

		this.update(res[0] || {}, res[1] || {});
		poll.add(function() {
			return Promise.all([ api.call('monitor'), api.call('status') ]).then(function(r) {
				self.update(r[0] || {}, r[1] || {});
			}).catch(function() {});
		}, 5);

		return root;
	},

	update: function(m, st) {
		var lines = m.lines || [];
		var rows = lines.map(function(l) {
			var p = l.probe || {};
			return E('tr', {}, [
				E('td', {}, [
					api.statusDot(!!l.up),
					E('span', { 'style': 'margin-left:6px' }, [ l.name || l.id ])
				]),
				E('td', { 'class': 'sr-mono' }, [ l.iface || '--' ]),
				E('td', { 'class': 'sr-mono' }, [ l.ipv4 || '--' ]),
				E('td', {}, [ api.probe(p.ipv4) ]),
				E('td', { 'class': 'sr-mono' }, [ l.ipv6 || '--' ]),
				E('td', {}, [ api.probe(p.ipv6) ]),
				E('td', {}, [ (l.proto || '').toUpperCase() ])
			]);
		});
		dom.content(this.elLines, api.table(
			[ '线路', '接口', 'IPv4 地址', 'IPv4 探测', 'IPv6 地址', 'IPv6 探测', '协议' ], rows, '暂无线路'));

		var wans = st.wans || [];
		var v6rows = wans.map(function(w) {
			var rt = w.rt || {};
			return E('tr', {}, [
				E('td', {}, [ w.name || w.id ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6 || '--' ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6_prefix || '--' ]),
				E('td', { 'class': 'sr-mono' }, [ rt.ipv6_pd || '--' ])
			]);
		});
		dom.content(this.elV6, api.table([ '线路', 'IPv6 地址', 'WAN 前缀', 'PD 委派' ], v6rows, '暂无 IPv6 信息'));

		var ifs = st.ifaces || [];
		var irows = ifs.map(function(i) {
			return E('tr', {}, [
				E('td', { 'class': 'sr-mono' }, [ i.name ]),
				E('td', {}, [ api.badge(i.state || 'unknown', i.state === 'up' ? 'ok' : 'off') ]),
				E('td', { 'class': 'sr-mono' }, [ i.mac || '--' ]),
				E('td', {}, [ i.speed ? i.speed + ' Mbps' : '--' ])
			]);
		});
		dom.content(this.elIf, api.table([ '网卡', '状态', 'MAC', '协商速率' ], irows, '暂无网卡'));

		var h = m.history || [];
		if (h.length > 1) {
			if (this.canvas.offsetParent) {
				api.chart(this.canvas, [
					{ data: h.map(function(x) { return Number(x.rx) || 0; }), color: '#38bdf8', fill: 'rgba(56,189,248,0.12)' },
					{ data: h.map(function(x) { return Number(x.tx) || 0; }), color: '#fb7185', fill: 'rgba(251,113,133,0.10)' }
				], h.length);
			}
		}
	}
});
