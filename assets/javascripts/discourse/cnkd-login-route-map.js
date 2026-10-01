// 后台设置页的路由映射。
//
// Discourse 用「route map」让插件往 Ember 路由树里挂路由，而不是让插件
// 自己写 Glimmer 的 Route 类 —— 后者在 admin 命名空间下几乎必然对不上
// 实际的嵌套结构（admin.adminPlugins 是 resource + path 两层）。
//
// 文件名 `*-route-map.js` 是约定：构建系统会扫描 assets/javascripts/discourse/
// 下所有以 -route-map.js 结尾的文件并自动载入，无需 register_asset。
//
// 结构说明：
//   resource: "admin.adminPlugins"  —— 挂在 admin 插件区下
//   path: "/plugins"                —— 与 core 的 /admin/plugins 对齐
//   this.route("cnkd-login")        —— 生成 /admin/plugins/cnkd-login
//
// 路由名 `cnkd-login` 必须与 plugin.rb 里 add_admin_route 的第二个参数
// 以及模板文件名（plugins-cnkd-login.hbs）严格对应。
export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("cnkd-login");
  },
};
