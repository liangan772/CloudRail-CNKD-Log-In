# frozen_string_literal: true

# CNKD 一证通行 · 后台设置页面的数据接口。
#
# 只暴露一个只读动作：把「配置体检结果 + 当前设置值 + OAuth 握手预览」
# 一次性发给页面。不发任何外网请求，因此没有 SSRF 面；
# client_secret 由 PreviewRenderer 掩码，不会外泄原文。
#
# 继承 ::Admin::AdminController 即获得 requires_login + ensure_admin
# 两道校验，无需自己写权限判断。
module ::DiscourseCnkdLogin
  class AdminController < ::Admin::AdminController
    # 插件被禁用时抛 PluginDisabled，经 rescue_from 落成 404，
    # 与「设置项不可见」的状态保持一致。
    requires_plugin DiscourseCnkdLogin::PLUGIN_NAME

    def preview
      checks = DiscourseCnkdLogin::HealthCheck.run

      render_json_dump(
        callback_url: DiscourseCnkdLogin.callback_url,
        site_url: DiscourseCnkdLogin.site_url,
        client_type: SiteSetting.cnkd_login_client_type,
        pkce: DiscourseCnkdLogin::Authenticator.new.pkce_enabled?,
        scopes: DiscourseCnkdLogin.requested_scopes,
        # 邮箱直通状态：页面据此判断「注册时还要不要手工填邮箱」。
        # 两项都要传到，缺一项页面的四态判断就会失真。
        email_scope_enabled: DiscourseCnkdLogin.email_scope_enabled?,
        auto_fill_email: SiteSetting.cnkd_login_auto_fill_email,
        configured: DiscourseCnkdLogin::HealthCheck.configured?,
        healthy: !DiscourseCnkdLogin::HealthCheck.error?(checks),
        checks: checks.map { |check| serialize_check(check) },
        preview: DiscourseCnkdLogin::PreviewRenderer.steps,
        settings: serialize_settings,
      )
    end

    private

    # 把 11 项设置的值一并发给页面，让管理员在这个页面上
    # 就能看到「当前生效的值是多少」，不用来回跳转到站点设置。
    #
    # secret 类是唯一例外：SiteSetting 返回的是 "******" 占位符而不是原文
    # （这是 Discourse 核心的行为），正合适 —— 页面只需要知道「填了没有」。
    def serialize_settings
      DiscourseCnkdLogin.admin_setting_keys.index_with do |key|
        {
          value: SiteSetting.public_send(key),
          client_visible: DiscourseCnkdLogin.client_visible_setting?(key),
        }
      end
    end

    # message 是 i18n key，交给前端本地化 ——
    # 同一份 check 数据也会被写进服务端日志，保持「后端产出 key、
    # 展示层负责翻译」这条线不破，两边就不会各写一套文案。
    def serialize_check(check)
      {
        id: check[:id],
        level: check[:level],
        message: check[:message],
        detail: check[:detail],
      }
    end
  end
end
