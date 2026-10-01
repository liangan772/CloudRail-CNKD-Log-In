import Route from "@ember/routing/route";

// /admin/plugins/cnkd-login
//
// 路由与模板由 add_admin_route(..., use_new_show_route: true) 在
// plugin.rb 里注册；这里提供的是路由类，把模板挂上。
//
// 页面本身是只读的（设置改在站点设置页），所以不需要 model()。
export default class AdminPluginsCnkdLoginRoute extends Route {}
