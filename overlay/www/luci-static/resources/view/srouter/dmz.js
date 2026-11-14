'use strict';
'require view';
'require srouter.api as api';

function v(box, n) { var e = box.querySelector('[data-f="' + n + '"]'); return e ? e.value.trim() : ''; }
function cb(box, n) { var e = box.querySelector('[data-f="' + n + '"] input[type="checkbox"]'); return !!(e && e.checked); }

return view.extend({
	load: function() { return Promise.all([ api.call('dmz'), api.call('forwards') ]); },

	render: function(res) {
		var self = this;
		if (!document.querySelector('link[data-sr]'))
			document.head.appendChild(E('link', { 'rel': 'stylesheet', 'href': L.resource('srouter/sr.css'), 'data-sr': '1' }));

		this.d = res[0] || {};
		this.forwards = (res[1] && res[1].forwards) || [];
		this.elFwd = E('div', {});

		var box = E('div', {}, [
			api.field('启用 DMZ 主机', api.switchBox(!!this.d.enabled, 'enabled'), '开启后，未被端口映射占用的外网访问将全部转发到该内网主机'),
			api.field('DMZ 主机内网 IP', api.input({ 'data-f': 'ip', 'value': this.d.ip || '', 'placeholder': '192.168.100.100' })),
			E('div', { 'class': 'sr-toolbar' }, [
				api.btn('保存并应用', 'cbi-button-action', function() {
					api.call('dmz_save', { enabled: cb(box, 'enabled'), ip: v(box, 'ip') })
						.then(function() { api.notify('DMZ 配置已应用', 'info'); })
						.catch(function(e) { api.notify(e.message, 'error'); });
				})
			])
		]);

		var root = E('div', { 'class': 'sr-wrap' }, [
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ 'DMZ 主机', api.badge('全端口映射', 'info') ]),
				box,
				E('ul', { 'class': 'sr-list' }, [
					E('li', {}, [ 'DMZ 会把该主机的全部端口暴露到公网，请确保主机自身防火墙已开启。' ]),
					E('li', {}, [ '多条 WAN 时，DMZ 对全部 WAN 生效。' ]),
					E('li', {}, [ '只需开放个别端口时，请使用下方端口映射。' ])
				])
			]),
			E('div', { 'class': 'sr-card' }, [
				E('h3', {}, [ '端口映射', api.badge('DNAT', 'info') ]),
				E('div', { 'class': 'sr-toolbar' }, [
					api.btn('+ 新增端口映射', 'cbi-button-action', function() { self.editForward(null); })
				]),
				this.elFwd
			])
		]);

		this.renderForwards();
		return root;
	},

	reload: function() {
		var self = this;
		Promise.all([ api.call('dmz'), api.call('forwards') ]).then(function(r) {
			self.d = r[0] || {};
			self.forwards = (r[1] && r[1].forwards) || [];
			self.renderForwards();
		});
	},

	renderForwards: function() {
		var self = this;
		var rows = this.forwards.map(function(f) {
			return E('tr', {}, [
				E('td', {}, [ f.name || f.id ]),
				E('td', {}, [ (f.proto || '').toUpperCase() ]),
				E('td', { 'class': 'sr-mono' }, [ f.ext_port ]),
				E('td', { 'class': 'sr-mono' }, [ f.int_ip + ':' + (f.int_port || f.ext_port) ]),
				E('td', {}, [ f.enabled ? api.badge('启用', 'ok') : api.badge('停用', 'off') ]),
				E('td', {}, [
					api.btn('编辑', '', function() { self.editForward(f); }),
					' ',
					api.btn('删除', 'cbi-button-negative', function() {
						api.confirm('删除映射 ' + (f.name || f.id) + '？', function() {
							api.call('forward_del', { id: f.id }).then(function() { self.reload(); });
						});
					})
				])
			]);
		});
		this.elFwd.textContent = '';
		this.elFwd.appendChild(api.table(
			[ '名称', '协议', '外部端口', '内部地址', '状态', '操作' ], rows, '暂无端口映射'));
	},

	editForward: function(f) {
		var self = this;
		f = f || { proto: 'tcp', enabled: true };
		var box = E('div', { 'class': 'sr-modal' }, [
			api.field('规则名称', api.input({ 'data-f': 'name', 'value': f.name || '' })),
			E('div', { 'class': 'sr-two' }, [
				api.field('协议', api.sel([ 'tcp', 'udp', 'tcp udp' ], f.proto || 'tcp', { 'data-f': 'proto' })),
				api.field('外部端口', api.input({ 'data-f': 'ext_port', 'value': f.ext_port || '', 'placeholder': '8080' }))
			]),
			E('div', { 'class': 'sr-two' }, [
				api.field('内部 IP', api.input({ 'data-f': 'int_ip', 'value': f.int_ip || '', 'placeholder': '192.168.100.10' })),
				api.field('内部端口', api.input({ 'data-f': 'int_port', 'value': f.int_port || '' }))
			]),
			api.field('启用', api.switchBox(!!f.enabled, 'enabled'))
		]);
		api.modal(f.id ? '编辑端口映射' : '新增端口映射', [ box ], function() {
			return api.call('forward_save', {
				id: f.id || '', name: v(box, 'name'), proto: v(box, 'proto'),
				ext_port: v(box, 'ext_port'), int_ip: v(box, 'int_ip'), int_port: v(box, 'int_port'),
				enabled: cb(box, 'enabled')
			}).then(function() {
				api.notify('端口映射已保存', 'info');
				self.reload();
			});
		});
	}
});
