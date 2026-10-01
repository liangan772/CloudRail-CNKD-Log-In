import { withPluginApi } from "discourse/lib/plugin-api";

// CNKD 一证通行 · 后台插件导航注册。
//
// 新的插件 show 页（adminPlugins.show）用「顶部标签」组织插件自有的多个页面，
// 标签通过 addAdminPluginConfigurationNav 注册，而不是自己写路由壳。
//
// 官方要点（见 docs/plugin-admin-interfaces.reference.md）：
//   1. 必须只在管理员下运行 —— 普通用户不需要这段逻辑。
//   2. 插件自己的「设置」链接由核心自动加，**不要**在这里重复注册。
//   3. 优先用顶部标签，不要为新的插件 UI 引入内层侧边栏。
const PLUGIN_ID = "discourse-cnkd-login";

export default {
  name: "cnkd-login-admin-plugin-configuration-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");

    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          // route 是「路由名」而不是路径；对应 route-map 里的
          // this.route("cnkd-login")，完整名要带 adminPlugins.show 前缀。
          label: "cnkd_login.page.heading",
          route: "adminPlugins.show.cnkd-login",
          description: "cnkd_login.page.subheading",
        },
      ]);
    });
  },
};
