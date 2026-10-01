// CNKD 一证通行 · 后台页面路由映射。
//
// ⚠️ 这里的 resource 必须是 "admin.adminPlugins.show"（带 .show）。
//
// 原因：plugin.rb 里用的是 `add_admin_route ..., use_new_show_route: true`，
// 该选项会让 Discourse 把 full_location 从 adminPlugins.<location>
// 改成 adminPlugins.show —— 也就是核心提供的**共享 show 路由**
// （见 lib/plugin/instance.rb 的 full_admin_route / default_admin_route）。
// 共享路由负责渲染 DPageHeader + 顶部标签导航，插件只需提供各标签对应的页面。
//
// 这也意味着：不再有「插件私有的 templates/admin/plugins-<name>.hbs」，
// 页面改由 .gjs 提供（见 templates/admin-plugins/show/cnkd-login/index.gjs）。
//
// 路由名 cnkd-login 必须与：
//   - plugin.rb 里 add_admin_route 的第二个参数
//   - 模板目录名 templates/admin-plugins/show/cnkd-login/
//   - 顶部导航里 api.addAdminPluginConfigurationNav 的 route 前缀
// 三处严格对应。
export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",
  map() {
    this.route("cnkd-login");
  },
};
