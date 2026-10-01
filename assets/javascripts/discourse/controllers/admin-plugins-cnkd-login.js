import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

// CNKD 一证通行 · 后台设置页面。
//
// 文件路径 `controllers/admin-plugins-cnkd-login.js` 是 Discourse 的约定：
// 路由 admin.adminPlugins → cnkd-login 对应的控制器名就是
// admin-plugins-cnkd-login。模板同理（templates/admin/plugins-cnkd-login.hbs）。
//
// 这个页面做三件事，对应 CNKD 接入里最容易出错的三类问题：
//
//   1. 集中展示设置 —— 不用去 /admin/site_settings 里搜 "cnkd" 一项项找，
//      并标出哪些是客户端可见、哪些只在服务端生效。
//   2. 配置自检 —— 打开页面即列出 ERROR / WARNING / OK，
//      把「等用户点登录才报错」提前到「管理员打开后台就看见」。
//   3. 握手预览 —— 不发真实请求，把三步 OAuth 报文渲染出来，
//      方便对着 CNKD 后台登记值逐字符核对。
//
// 数据来源是插件自己的 /cnkd-login/preview 接口（只读、需管理员）。
export default class AdminPluginsCnkdLoginController extends Controller {
  // 自检结果、当前配置与握手预览，首次渲染后从服务端拉取
  @tracked status = null;
  @tracked loading = true;

  // 握手预览当前展开到第几步；null 表示全部收起
  @tracked expandedStep = null;

  // 回调地址刚被复制的提示
  @tracked copied = false;

  // 把初始化改到 init 钩子里 —— 控制器由 Ember 负责实例化，
  // 拿不到组件那样的 constructor(...arguments) 语义。
  init() {
    super.init(...arguments);
    this.loadStatus();
  }

  // 设置本身在站点设置页里编辑。
  //
  // 这里刻意不自建表单：站点设置的类型校验、权限、变更审计、多站点
  // 隔离都由 Discourse 核心负责，自建表单等于把这些重新实现一遍，
  // 而且升级时更容易踩坑。本页面负责的是「看得懂 + 查得出问题」。
  get settingsUrl() {
    return "/admin/site_settings/category/discourse_cnkd_login";
  }

  // -------------------------------------------------------------- 基础数据

  get callbackUrl() {
    return this.status?.callback_url;
  }

  get checks() {
    return this.status?.checks ?? [];
  }

  get previewSteps() {
    return this.status?.preview ?? [];
  }

  get configured() {
    return this.status?.configured ?? false;
  }

  get errorCount() {
    return this.checks.filter((c) => c.level === "error").length;
  }

  get warningCount() {
    return this.checks.filter((c) => c.level === "warning").length;
  }

  // ------------------------------------------------------------ 状态总览

  // 顶部总状态：区分「加载中」「没配全」「配置有错」「只是有提醒」「一切正常」
  get overallLevel() {
    if (!this.status) {
      return "loading";
    }
    if (!this.configured || !this.status.healthy) {
      return "error";
    }
    return this.warningCount > 0 ? "warning" : "ok";
  }

  get overallMessage() {
    switch (this.overallLevel) {
      case "loading":
        return i18n("cnkd_login.status.loading");
      case "error":
        return this.configured
          ? i18n("cnkd_login.status.has_errors")
          : i18n("cnkd_login.status.not_configured");
      case "warning":
        return i18n("cnkd_login.status.has_warnings");
      default:
        return i18n("cnkd_login.status.ok");
    }
  }

  get configuredLabel() {
    return i18n(
      this.configured
        ? "cnkd_login.status.label_yes"
        : "cnkd_login.status.label_no"
    );
  }

  get copyLabel() {
    return i18n(
      this.copied ? "cnkd_login.callback.copied" : "cnkd_login.callback.copy"
    );
  }

  // ------------------------------------------------------------ 当前配置表

  // 把后端返回的 settings map 摊平成表格行。
  //
  // secret 类设置由 Discourse 返回 "******" 占位符，这里直接展示即
  // 可 —— 页面不需要、也不应该拿到密钥原文。
  get settingRows() {
    const settings = this.status?.settings;
    if (!settings) {
      return [];
    }

    return Object.entries(settings).map(([key, meta]) => ({
      key,
      display: this._formatValue(meta.value),
      scopeClass: meta.client_visible ? "client" : "server",
      scopeLabel: i18n(
        meta.client_visible
          ? "cnkd_login.settings.scope_client"
          : "cnkd_login.settings.scope_server"
      ),
    }));
  }

  // ------------------------------------------------------------ 动作

  @action
  async loadStatus() {
    this.loading = true;
    try {
      this.status = await ajax("/cnkd-login/preview");
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  toggleStep(step) {
    this.expandedStep = this.expandedStep === step ? null : step;
  }

  @action
  openSettings() {
    window.location = this.settingsUrl;
  }

  @action
  async copyCallback() {
    const url = this.callbackUrl;
    if (!url) {
      return;
    }

    try {
      await navigator.clipboard.writeText(url);
      this.copied = true;
      // 提示 2 秒后自动收回
      setTimeout(() => (this.copied = false), 2000);
    } catch {
      // 非 HTTPS 环境下 clipboard API 不可用，用户手动选中即可 ——
      // 地址本身已经用 user-select: all 让单击就能全选。
      this.copied = false;
    }
  }

  // ------------------------------------------------------------ 模板辅助

  // 后端产出的 message 是 i18n key，这里翻成当前语言
  checkMessage(check) {
    return check.message ? i18n(check.message) : "";
  }

  stepTitle(step) {
    return i18n(step.title);
  }

  stepSubtitle(step) {
    return i18n(step.subtitle);
  }

  stepNote(step) {
    return step.note ? i18n(step.note) : "";
  }

  // 请求头逐行展示 —— 后端给的是 hash，模板里直接输出会变成
  // "[object Object]"，必须在 JS 侧序列化。
  headersText(step) {
    if (!step.headers) {
      return "";
    }
    return Object.entries(step.headers)
      .map(([k, v]) => `${k}: ${v}`)
      .join("\n");
  }

  levelClass(level) {
    return `cnkd-login-check--${level}`;
  }

  levelIcon(level) {
    switch (level) {
      case "ok":
        return "circle-check";
      case "warning":
        return "triangle-exclamation";
      default:
        return "circle-exclamation";
    }
  }

  overallIcon() {
    switch (this.overallLevel) {
      case "ok":
        return "circle-check";
      case "warning":
        return "triangle-exclamation";
      case "loading":
        return "spinner";
      default:
        return "circle-exclamation";
    }
  }

  chevronIcon(step) {
    return this.expandedStep === step ? "chevron-up" : "chevron-down";
  }

  _formatValue(value) {
    if (value === null || value === undefined || value === "") {
      return null;
    }
    if (value === true) {
      return "true";
    }
    if (value === false) {
      return "false";
    }
    return String(value);
  }
}
