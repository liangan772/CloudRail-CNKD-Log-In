import Controller from "@ember/controller";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

// CNKD 一证通行 · 后台设置页面（.gjs）。
//
// ⚠️ 本文件是 .gjs（Glimmer 模板标签格式），不是 .hbs。
// Discourse 自 2026.3 起弃用 .hbs，2026.7 ESR 是最后一个支持它的版本，
// 2026.8.0-latest 起计划移除；残留 .hbs 会给管理员弹警告横幅。
// 详见 https://meta.discourse.org/t/398896
//
// ── .gjs 与 .hbs 的四个关键差异（迁移时最容易踩的坑）──
//   1. 组件/helper 必须**显式 import**，不再有全局解析。
//      核心组件的路径走 ui-kit，例：
//          import DButton from "discourse/ui-kit/d-button";
//          import DPageSubheader from "discourse/ui-kit/d-page-subheader";
//          import dIcon from "discourse/ui-kit/helpers/d-icon";
//   2. 严格模式：模板里引用控制器属性必须写 `this.x`；
//      不再支持字符串 action `{{action "foo"}}`，要用 `{{this.foo}}`
//      或 `{{on "click" this.foo}}`。
//   3. 模板写在 class 内的 `<template>` 标签块里，与 JS 同文件。
//   4. `{{i18n ...}}` 仍然可用（需从 discourse-i18n import i18n）。
//
// 路径约定同样来自官方：
//   admin/assets/javascripts/discourse/templates/admin-plugins/show/cnkd-login/index.gjs
// 前缀 admin-plugins/show/ 对应共享的 adminPlugins.show 路由
// （由 plugin.rb 里 use_new_show_route: true 启用）。
//
// 这个页面做三件事，对应 CNKD 接入里最容易出错的三类问题：
//   1. 集中展示设置 —— 不用去 /admin/site_settings 里搜 "cnkd" 一项项找，
//      并标出哪些是客户端可见、哪些只在服务端生效。
//   2. 配置自检 —— 打开页面即列出 ERROR / WARNING / OK，
//      把「等用户点登录才报错」提前到「管理员打开后台就看见」。
//   3. 握手预览 —— 不发真实请求，把三步 OAuth 报文渲染出来，
//      方便对着 CNKD 后台登记值逐字符核对。
//
// 数据来源是插件自己的 /cnkd-login/preview 接口（只读、需管理员）。
export default class AdminPluginsShowCnkdLoginIndex extends Controller {
  // 自检结果、当前配置与握手预览，首次渲染后从服务端拉取
  @tracked status = null;
  @tracked loading = true;

  // 握手预览当前展开到第几步；null 表示全部收起
  @tracked expandedStep = null;

  // 回调地址刚被复制的提示
  @tracked copied = false;

  // 控制器由 Ember 实例化，用 init 钩子拉数据
  // （组件才用 constructor(...arguments)，控制器没有该语义）。
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
    // 顺手补一个 1 起的序号。
    //
    // 不在模板里用 {{inc index}} —— .gjs 严格模式下所有 helper 都要
    // 有明确来源，而序号纯属展示，在 JS 里算好最稳妥（也省一个依赖）。
    return (this.status?.preview ?? []).map((step, index) => ({
      ...step,
      number: index + 1,
    }));
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

  // ------------------------------------------------------------ 邮箱直通

  // 后端返回的当前生效配置。
  get settingsMap() {
    return this.status?.settings ?? {};
  }

  // 当前值是否「打开」。
  //
  // 后端把设置值原样序列化过来：布尔设置就是 true / false。
  // 这里统一成语义化的判断，模板里就不用关心类型了。
  _enabled(key) {
    return this.settingsMap[key]?.value === true;
  }

  // 本次授权是否申请了邮箱明文范围（决定 /userinfo 会不会带回邮箱）
  //
  // 优先用后端显式给出的 email_scope_enabled，避免前端去猜测
  // scopes 数组的内容；旧版本接口没有该字段时回落到数组判断。
  get emailScopeRequested() {
    if (typeof this.status?.email_scope_enabled === "boolean") {
      return this.status.email_scope_enabled;
    }
    return (this.status?.scopes ?? []).includes("email.address");
  }

  // 是否开启了「邮箱直通」（把返回的邮箱标记为已验证）
  //
  // 同样优先用后端字段，回落到设置表里的值。
  get autoFillEmail() {
    if (typeof this.status?.auto_fill_email === "boolean") {
      return this.status.auto_fill_email;
    }
    return this._enabled("cnkd_login_auto_fill_email");
  }

  // 用户注册时还需不需要手工填邮箱 —— 一句话结论。
  get emailFlowLevel() {
    if (this.emailScopeRequested && this.autoFillEmail) {
      return "ok";
    }
    if (this.emailScopeRequested || this.autoFillEmail) {
      return "warning";
    }
    return "error";
  }

  get emailFlowIcon() {
    return this.levelIcon(this.emailFlowLevel);
  }

  get emailFlowMessage() {
    if (this.emailScopeRequested && this.autoFillEmail) {
      return i18n("cnkd_login.email.state_auto");
    }
    // 只申请了范围、但没开「已验证标记」：邮箱带得回来，仍要用户手工填
    if (this.emailScopeRequested) {
      return i18n("cnkd_login.email.state_scope_only");
    }
    // 开了标记、却没申请范围：拿不到邮箱原文，开关无从生效
    if (this.autoFillEmail) {
      return i18n("cnkd_login.email.state_fill_only");
    }
    return i18n("cnkd_login.email.state_manual");
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

  get overallIcon() {
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

  stepChevron(step) {
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

  <template>
    <DPageSubheader
      @titleLabel="cnkd_login.page.heading"
      @descriptionLabel="cnkd_login.page.subheading"
    />

    <div class="cnkd-login-admin">
      {{! ----------------------------------------------------- 状态总览 }}
      <div class="cnkd-login-status cnkd-login-status--{{this.overallLevel}}">
        <div class="cnkd-login-status__icon">
          {{dIcon this.overallIcon}}
        </div>
        <div class="cnkd-login-status__body">
          <div class="cnkd-login-status__title">{{this.overallMessage}}</div>
          <div class="cnkd-login-status__meta">
            {{#if this.status}}
              {{i18n
                "cnkd_login.status.summary"
                configured=this.configuredLabel
                errors=this.errorCount
                warnings=this.warningCount
              }}
            {{/if}}
          </div>
        </div>
        <DButton
          @icon="rotate"
          @label="cnkd_login.status.refresh"
          @action={{this.loadStatus}}
          @disabled={{this.loading}}
          class="btn-default"
        />
      </div>

      {{! --------------------------------------------- 回调地址（重点） }}
      <div class="cnkd-login-callback">
        <label>{{i18n "cnkd_login.callback.label"}}</label>
        <p class="cnkd-login-callback__hint">
          {{i18n "cnkd_login.callback.hint"}}
        </p>
        <div class="cnkd-login-callback__row">
          {{#if this.callbackUrl}}
            <code>{{this.callbackUrl}}</code>
          {{else}}
            <code>{{i18n "cnkd_login.callback.unavailable"}}</code>
          {{/if}}
          <DButton
            @icon="copy"
            @label={{this.copyLabel}}
            @action={{this.copyCallback}}
            @disabled={{not this.callbackUrl}}
            class="btn-default"
          />
        </div>
      </div>

      {{! ----------------------------------------------------- 邮箱直通状态 }}
      {{!
        这一块专门回答「用户注册时还要不要手工填邮箱」这一个问题。
        它是本次需求的核心，所以单独成块而不是塞进设置表里。
      }}
      <div
        class="cnkd-login-email cnkd-login-email--{{this.emailFlowLevel}}"
      >
        <div class="cnkd-login-email__head">
          {{dIcon this.emailFlowIcon}}
          <span class="cnkd-login-email__title">
            {{i18n "cnkd_login.email.heading"}}
          </span>
        </div>
        <p class="cnkd-login-email__body">
          {{this.emailFlowMessage}}
        </p>
        {{#if this.emailScopeRequested}}
          <div class="cnkd-login-email__kw">
            <span>{{i18n "cnkd_login.email.scope_label"}}</span>
            <code>email.address</code>
          </div>
        {{/if}}
      </div>

      {{! ----------------------------------------------------- 自检清单 }}
      <div class="cnkd-login-checks">
        <h3>{{i18n "cnkd_login.checks.heading"}}</h3>

        {{#if this.loading}}
          <div class="cnkd-login-loading">{{i18n "cnkd_login.status.loading"}}</div>
        {{else}}
          {{#each this.checks as |check|}}
            <div class="cnkd-login-check {{this.levelClass check.level}}">
              <div class="cnkd-login-check__icon">
                {{dIcon (this.levelIcon check.level)}}
              </div>
              <div class="cnkd-login-check__body">
                <div>{{this.checkMessage check}}</div>
                {{#if check.detail}}
                  <div class="cnkd-login-check__detail">{{check.detail}}</div>
                {{/if}}
              </div>
            </div>
          {{/each}}
        {{/if}}
      </div>

      {{! ----------------------------------------------------- 当前配置 }}
      <div class="cnkd-login-settings">
        <h3>{{i18n "cnkd_login.settings.heading"}}</h3>
        <p class="cnkd-login-settings__intro">
          {{i18n "cnkd_login.settings.intro"}}
        </p>

        {{#if this.loading}}
          <div class="cnkd-login-loading">{{i18n "cnkd_login.status.loading"}}</div>
        {{else}}
          <table class="cnkd-login-settings__table">
            <thead>
              <tr>
                <th>{{i18n "cnkd_login.settings.col.setting"}}</th>
                <th>{{i18n "cnkd_login.settings.col.value"}}</th>
                <th>{{i18n "cnkd_login.settings.col.scope"}}</th>
              </tr>
            </thead>
            <tbody>
              {{#each this.settingRows as |row|}}
                <tr>
                  <td><code>{{row.key}}</code></td>
                  <td class="cnkd-login-settings__value">
                    {{#if row.display}}
                      <code>{{row.display}}</code>
                    {{else}}
                      <span class="cnkd-login-settings__empty">
                        {{i18n "cnkd_login.settings.empty_value"}}
                      </span>
                    {{/if}}
                  </td>
                  <td>
                    <span
                      class="cnkd-login-settings__badge cnkd-login-settings__badge--{{row.scopeClass}}"
                    >
                      {{row.scopeLabel}}
                    </span>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{/if}}
      </div>

      {{! ----------------------------------------------------- 握手预览 }}
      <div class="cnkd-login-preview">
        <h3>{{i18n "cnkd_login.preview.heading"}}</h3>
        <p class="cnkd-login-preview__intro">
          {{i18n "cnkd_login.preview.intro"}}
        </p>

        {{#each this.previewSteps as |step|}}
          <div class="cnkd-login-step">
            <button
              type="button"
              class="cnkd-login-step__head"
              {{on "click" (fn this.toggleStep step.step)}}
            >
              <span class="cnkd-login-step__index">{{step.number}}</span>
              <span class="cnkd-login-step__titles">
                <span class="cnkd-login-step__title">
                  {{this.stepTitle step}}
                </span>
                <br />
                <span class="cnkd-login-step__subtitle">
                  {{this.stepSubtitle step}}
                </span>
              </span>
              <span class="cnkd-login-step__method">{{step.method}}</span>
              {{dIcon (this.stepChevron step.step)}}
            </button>

            {{#if (eq this.expandedStep step.step)}}
              <div class="cnkd-login-step__body">
                {{#if step.url}}
                  <div class="cnkd-login-step__section">
                    <h5>{{i18n "cnkd_login.preview.field.url"}}</h5>
                    <pre class="cnkd-login-step__url">{{step.url}}</pre>
                  </div>
                {{/if}}

                {{#if step.headers}}
                  <div class="cnkd-login-step__section">
                    <h5>{{i18n "cnkd_login.preview.field.headers"}}</h5>
                    <pre>{{this.headersText step}}</pre>
                  </div>
                {{/if}}

                {{#if step.body}}
                  <div class="cnkd-login-step__section">
                    <h5>{{i18n "cnkd_login.preview.field.body"}}</h5>
                    <pre>{{step.body}}</pre>
                  </div>
                {{/if}}

                {{#if step.note}}
                  <div class="cnkd-login-step__note">
                    {{this.stepNote step}}
                  </div>
                {{/if}}
              </div>
            {{/if}}
          </div>
        {{/each}}
      </div>

      {{! ----------------------------------------------------- 设置入口 }}
      <div class="cnkd-login-settings-link">
        <DButton
          @icon="gear"
          @label="cnkd_login.page.open_settings"
          @action={{this.openSettings}}
          class="btn-primary"
        />
      </div>
    </div>
  </template>
}
