'use strict';
'require view';
'require srouter.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }
function cb(box, n) { var e = box.querySelector('[data-f="' + n + '"] input[type="checkbox"]'); return !!(e && e.checked); }

return view.extend({
	load: function() { return Promise.all([ api.call('qos'), api.call('wans') ]); },

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-sr]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('srouter/sr.css'), 'data-sr': '1' }));

		this.q = res[0] || {};
		this.wans = (res[1] && res[1].wans) || [];
		this.elRules = E('div', {});
		this.elShaping = E('div', {});

		var q = this.q;
		var sqmBox = E('div', {}, [
			api.field('启用 LAN 侧整体流控（SQM / CAKE）', api.switchBox(!!q.enabled, 'enabled'), '对 br-lan 的上下行总量限速，缓解缓冲膨胀；仅影响 LAN 侧转发'),
			E('div', { 'class': 'sr-two' }, [
				api.field('限速接口', api.input({ 'data-f': 'iface', 'value': q.iface || 'br-lan' })),
				api.field('队列算法', api.sel([ 'cake', 'fq_codel' ], q.qdisc || 'cake', { 'data-f': 'qdisc' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('下行总带宽（Kbps）', api.input({ 'data-f': 'download', 'type': 'number', 'value': q.download || 0 })),
				api.field('上行总带宽（Kbps）', api.input({ 'data-f': 'upload', 'type': 'number', 'value': q.upload || 0 }))
			]),
			E('div', { 'class': 'sr-toolbar' }, [
				api.btn('保存 LAN 流控', 'cbi-button-action', function() {
					api.call('qos_save', {
						enabled: cb(sqmBox, 'enabled'), iface: v(sqmBox, 'iface'),
						download: v(sqmBox, 'download'), upload: v(sqmBox, 'upload'), qdisc: v(sqmBox, 'qdisc')
					}).then(function() { api.notify('LAN 流控已应用', 'info'); })
					  .catch(function(e) { api.notify(e.message, 'error'); });
				})
			])
		]);

		var root = E('div', { 'class': 'sr-wrap' }, [
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '线路流控（按 WAN 限速）', api.badge('CAKE / TBF + ingress police', 'info') ]),
				E('p', { 'class': 'sr-desc' }, [ '上行填运营商实际上行带宽，下行填实际下行带宽；0 表示不限速。数值单位为 Kbps。' ]),
				this.elShaping
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '策略分流（按源/目标网段指定出口）', api.badge('mwan3', 'info') ]),
				E('p', { 'class': 'sr-desc' }, [ '未命中规则的流量按各线路权重负载均衡；规则按源地址优先匹配。' ]),
				E('div', { 'class': 'sr-toolbar' }, [
					api.btn('+ 新增分流规则', 'cbi-button-action', function() { self.editRule(null); }),
					E('span', { 'class': 'grow' }),
					api.btn('刷新', '', function() { self.reload(); })
				]),
				this.elRules
			]),
			E('div', { 'class': 'sr-card' }, [ E('h3', {}, [ 'LAN 整体流控' ]), sqmBox ])
		]);

		this.renderShaping();
		this.renderRules();
		return root;
	},

	reload: function() {
		var self = this;
		Promise.all([ api.call('qos'), api.call('wans') ]).then(function(r) {
			self.q = r[0] || {};
			self.wans = (r[1] && r[1].wans) || [];
			self.renderShaping();
			self.renderRules();
		});
	},

	renderShaping: function() {
		var self = this;
		var map = {};
		(this.q.shaping || []).forEach(function(s) { map[s.id] = s; });

		var rows = this.wans.map(function(w) {
			var s = map[w.id] || { dl: 0, ul: 0 };
			var dl = api.input({ 'type': 'number', 'value': s.dl || 0, 'style': 'width:110px' });
			var ul = api.input({ 'type': 'number', 'value': s.ul || 0, 'style': 'width:110px' });
			return E('tr', {}, [
				E('td', {}, [ w.name || w.id ]),
				E('td', { 'class': 'sr-mono' }, [ w.device + (Number(w.vlan) > 0 ? '.' + w.vlan : '') ]),
				E('td', {}, [ dl ]),
				E('td', {}, [ ul ]),
				E('td', {}, [ w.enabled ? api.badge('参与分流', 'ok') : api.badge('未启用', 'off') ]),
				E('td', {}, [ api.btn('保存', '', function() {
					api.call('wan_shaping', { id: w.id, dl: dl.value, ul: ul.value }).then(function() {
						api.notify('线路流控已更新', 'info');
					}).catch(function(e) { api.notify(e.message, 'error'); });
				}) ])
			]);
		});
		this.elShaping.textContent = '';
		this.elShaping.appendChild(api.table(
			[ '线路', '网卡', '下行带宽 Kbps', '上行带宽 Kbps', '状态', '操作' ], rows, '暂无 WAN 线路'));
	},

	renderRules: function() {
		var self = this;
		var wans = this.wans;
		var rows = (this.q.rules || []).map(function(r) {
			var target = wans.filter(function(w) { return w.id === r.policy; })[0];
			return E('tr', {}, [
				E('td', { 'class': 'sr-mono' }, [ r.src || '0.0.0.0/0' ]),
				E('td', { 'class': 'sr-mono' }, [ r.dest || '0.0.0.0/0' ]),
				E('td', {}, [ target ? (target.name || target.id) : r.policy ]),
				E('td', {}, [
					api.btn('删除', 'cbi-button-negative', function() {
						api.call('rule_del', { id: r.id }).then(function() { self.reload(); });
					})
				])
			]);
		});
		this.elRules.textContent = '';
		this.elRules.appendChild(api.table([ '源地址', '目标地址', '出口线路', '操作' ], rows, '暂无分流规则，默认按权重负载均衡'));
	},

	editRule: function(r) {
		var self = this;
		r = r || {};
		if (!this.wans.length) { api.notify('请先添加 WAN 线路', 'warning'); return; }
		var box = E('div', { 'class': 'sr-modal' }, [
			api.field('源地址 / 网段', api.input({ 'data-f': 'src', 'value': r.src || '', 'placeholder': '192.168.100.0/24' }), '留空表示全部来源'),
			api.field('目标地址 / 网段', api.input({ 'data-f': 'dest', 'value': r.dest || '', 'placeholder': '8.8.8.8/32' }), '留空表示全部目标'),
			api.field('出口线路', api.sel(this.wans.map(function(w) {
				return { value: w.id, label: w.name || w.id };
			}), r.policy || this.wans[0].id, { 'data-f': 'policy' }))
		]);
		api.modal(r.id ? '编辑分流规则' : '新增分流规则', [ box ], function() {
			return api.call('rule_save', {
				id: r.id || '', src: v(box, 'src'), dest: v(box, 'dest'), policy: v(box, 'policy')
			}).then(function() {
				api.notify('分流规则已应用', 'info');
				self.reload();
			});
		});
	}
});
