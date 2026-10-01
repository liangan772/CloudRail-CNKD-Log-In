# frozen_string_literal: true

# name: discourse-cnkd-login
# about: Login to Discourse with a CNKD 一证通行 account (OAuth 2.0 Authorization Code + S256 PKCE).
# meta_topic_id: 0
# version: 1.0.0
# authors: CNKD Integration
# url: https://cloud.cnkd.fun
# required_version: 3.2.0
# transpile_js: true

enabled_site_setting :cnkd_login_enabled

# 后台设置页面的资源。
#
# Discourse 会自动收录 assets/javascripts/** 与 assets/stylesheets/** 下的
# 文件，路径规则是 `assets/` 之后的部分，所以这里写的是相对 assets/ 的路径。
#
# 样式只在 admin 里用，但仍放 common/ —— 因为 admin 构建同样会读 common，
# 而放 desktop/ 会导致移动端后台看不到样式。
register_asset "stylesheets/common/cnkd-login-admin.scss"

# 页面组件。type: :admin 让它只进 admin bundle，
# 普通用户不会下载这段 JS。
register_asset "javascripts/discourse/admin/cnkd-login.js", type: :admin

# 客户端 i18n（登录按钮文案 + 后台页面文案）由 config/locales/client.*.yml
# 提供，键挂在 js.login.cnkd.* 与 js.admin.cnkd_login.* 下。

# CNKD 一证通行 · Discourse 登录插件
#
# 事实依据：
#   - 《CNKD 一证通行系统 · 完整接口与接入文档 v2.0》(2026-09-27)
#   - 《新增授权范围 email.address 补充说明 v1.0》(2026-09-28)
#
# 关键约束（务必遵守，否则会被平台拒绝）：
#   1. redirect_uri 必须与 CNKD 后台登记的地址逐字符完全一致
#      Discourse 的回调地址固定为：https://<discourse-host>/auth/cnkd/callback
#   2. CNKD 的令牌接口要求 application/json 请求体，而 OAuth2 规范默认发
#      form-urlencoded —— 见 lib/omniauth/strategies/cnkd.rb，那里完整接管了
#      令牌请求（自建 JSON body）与响应解析（自行拆 { ok, data } 信封）。
#   3. 令牌是不透明字符串（opaque），不得本地解析，必须通过 /userinfo 校验。
#   4. 唯一身份键是 `sub`（UUID），不得用 username / 昵称 / 邮箱当唯一键。
#   5. access_token 仅 60 分钟，refresh_token 30 天且每次刷新轮换。
#      Discourse 不使用长期第三方令牌，因此本插件默认不申请 refresh_token。
#   6. 所有接口都在站点根下：授权页在 /account/oauth/*，
#      其余接口带 /api-control 前缀 —— 见下方各 *_PATH 常量。

module ::DiscourseCnkdLogin
  PLUGIN_NAME = "discourse-cnkd-login"

  # CNKD 平台端点
  DEFAULT_SITE_URL = "https://cloud.cnkd.fun"

  # 授权页在站点根下（人类浏览器访问）
  AUTHORIZE_PATH = "/account/oauth/authorize"
  # 其余接口在 /api-control 下（服务端调用）
  TOKEN_PATH = "/api-control/account/oauth/token"
  REVOKE_PATH = "/api-control/account/oauth/revoke"
  USERINFO_PATH = "/api-control/account/oauth/userinfo"

  # 合作方（ownerType=partner）实际可申请的 scope 上限，见文档 6.2
  SCOPE_PROFILE_BASIC = "profile.basic"
  SCOPE_PROFILE_STATUS = "profile.status"
  # 敏感 scope：仅 ownerType=cnkd_internal 且 trustedLevel>=4 的自有应用可申请
  SCOPE_EMAIL_VERIFIED = "email.verified"
  SCOPE_QQ_SUMMARY = "qq.summary"

  # 回调路径。Discourse 挂载 OmniAuth 的路由是 /auth/:provider/callback，
  # provider 名必须是 cnkd —— 改这里必须同步改 Authenticator#name。
  CALLBACK_PATH = "/auth/cnkd/callback"

  # 站点根地址（可在后台改为私有化部署 / 联调环境），去掉尾部斜杠
  def self.site_url
    (SiteSetting.cnkd_login_site_url.presence || DEFAULT_SITE_URL).chomp("/")
  end

  def self.authorize_url
    "#{site_url}#{AUTHORIZE_PATH}"
  end

  def self.token_endpoint
    "#{site_url}#{TOKEN_PATH}"
  end

  def self.userinfo_endpoint
    "#{site_url}#{USERINFO_PATH}"
  end

  def self.revoke_endpoint
    "#{site_url}#{REVOKE_PATH}"
  end

  # 完整回调地址，用于提示管理员登记到 CNKD 后台（文档 5.1 要求逐字符一致）
  def self.callback_url
    "#{Discourse.base_url_no_prefix}#{CALLBACK_PATH}"
  end

  # 组装最终请求的 scope 列表。
  #
  # profile.basic / profile.status 对所有合作方开放（文档 6.2），始终申请。
  # 其余两项属敏感范围，仅 CNKD 自有应用（ownerType=cnkd_internal 且
  # trustedLevel>=4）可申请，外部合作方开启会被平台 400 拒绝。
  def self.requested_scopes
    scopes = [SCOPE_PROFILE_BASIC, SCOPE_PROFILE_STATUS]
    scopes << SCOPE_EMAIL_VERIFIED if SiteSetting.cnkd_login_request_email_verified
    scopes << SCOPE_QQ_SUMMARY if SiteSetting.cnkd_login_request_qq_summary
    scopes
  end

  # 后台设置页面用到的全部设置名。
  #
  # 用白名单而不是 `SiteSetting.all_settings` 过滤前缀，是为了让
  # 「页面上能改哪些设置」这件事一眼可查 —— 加新设置时如果忘了往这里补，
  # spec 里的对称性测试会失败。
  ADMIN_SETTING_KEYS = %w[
    cnkd_login_enabled
    cnkd_login_client_id
    cnkd_login_client_secret
    cnkd_login_client_type
    cnkd_login_enable_pkce
    cnkd_login_site_url
    cnkd_login_button_title
    cnkd_login_request_email_verified
    cnkd_login_request_qq_summary
    cnkd_login_verbose_logging
    cnkd_login_require_verified_email
  ].freeze

  def self.admin_setting_keys
    ADMIN_SETTING_KEYS
  end

  # 某个设置能否由客户端读取（client: true）。secret / 纯服务端开关
  # 不会下发到前端，页面需要据此把它们渲染成只读或标记为「仅服务端可见」。
  def self.client_visible_setting?(name)
    SiteSetting.client_settings.include?(name.to_sym)
  end
end

require_relative "lib/omniauth/strategies/cnkd"
require_relative "lib/cnkd/account_matcher"
require_relative "lib/cnkd/error_messages"
require_relative "lib/cnkd/userinfo_client"
require_relative "lib/cnkd/health_check"
require_relative "lib/cnkd/preview_renderer"
require_relative "lib/cnkd/authenticator"

# 注册认证提供方。
#
# 官方文档明确要求：必须早于 after_initialize 注册，否则 OmniAuth 中间件
# 不会挂载。这里直接在文件顶层调用。
#
# 按钮文案走 i18n（config/locales/client.*.yml 的 js.login.cnkd.title），
# 所以不需要 title / title_setting / pretty_name 选项。
#
# 关于 icon：Auth::AuthProvider.auth_attributes 只接受 authenticator /
# custom_url / frame_height / frame_width / icon / icon_setting /
# pretty_name / pretty_name_setting / title / title_setting。
# 不传的项都是 nil，序列化到前端后 icon 会回落到默认的 "user"。
#
# ⚠️ 不要设置 custom_url。
# 前端 login-method.js 的逻辑是：
#     if (this.custom_url) { window.location = this.custom_url; return; }
# 一旦存在 custom_url，就会**直接跳转并跳过**后续的
# reconnect / signup 参数与 destination_url cookie，导致：
#   - 用户回到站内后无法跳回原页面
#   - 「已登录时关联新账号」失效
#   - 按钮会跳到 /auth/cnkd/callback 而不是 /auth/cnkd，直接认证失败
# 标准 OmniAuth provider 应交给默认流程走 POST /auth/cnkd。
auth_provider authenticator: DiscourseCnkdLogin::Authenticator.new

# 后台设置界面入口。
#
# add_admin_route 会在 /admin/plugins 的插件列表里挂一个「设置」按钮，
# 并注册前端路由 /admin/plugins/cnkd-login。注意必须放在顶层：
# 它的实现依赖 Discourse::Application.routes.append，放在 after_initialize
# 里虽然也能跑，但会让插件清单的「一次性注册」语义变模糊。
#
# 传的是域名（cnkd_login）而不是完整 key —— add_admin_route 内部会
# 拼成 admin_js.admin.plugins.cnkd_login.title 去找翻译。
#
# use_new_show_route: true 是 Discourse 3.2+ 的新路由格式
# （路由直接挂在 admin 命名空间下，不再需要 legacy 的 adminPlugins 包装）。
add_admin_route("cnkd_login", "cnkd-login", use_new_show_route: true)

# 自检 + 握手预览接口。
#
# 只读取站点设置、不发任何外网请求，因此没有 SSRF 面；
# 响应里 client_secret 已被 PreviewRenderer 掩码，不会外泄原文。
Discourse::Application.routes.append do
  get "/cnkd-login/preview" => "discourse_cnkd_login/admin#preview"
end

module ::DiscourseCnkdLogin
  # 挂在 /cnkd-login/preview。继承 Admin::AdminController 即完成鉴权，
  # 无需自己写权限判断。
  class AdminController < ::Admin::AdminController
    # 插件被禁用时路由直接 404，与「设置不可见」的状态保持一致
    requires_plugin DiscourseCnkdLogin::PLUGIN_NAME

    def preview
      checks = DiscourseCnkdLogin::HealthCheck.run

      render_json_dump(
        callback_url: DiscourseCnkdLogin.callback_url,
        site_url: DiscourseCnkdLogin.site_url,
        client_type: SiteSetting.cnkd_login_client_type,
        pkce: DiscourseCnkdLogin::Authenticator.new.pkce_enabled?,
        scopes: DiscourseCnkdLogin.requested_scopes,
        configured: DiscourseCnkdLogin::HealthCheck.configured?,
        healthy: !DiscourseCnkdLogin::HealthCheck.error?(checks),
        checks: checks.map { |c| serialize_check(c) },
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

# 后台设置页面的前端装配。
#
# 页面主体由 assets/javascripts/discourse/admin/templates/cnkd-login.hbs
# 提供（Ember 原生模板），路由由上面的 add_admin_route 注册。
#
# 没有用 `withPluginApi("1.x")` + appEvents 的原因：
#   插件初始化时会先做一次 setting snapshot，若在初始化**之前**就
#   import 设置类，会污染 snapshot 里的默认值（官方 developer-guides
#   明确警告过）。原生模板渲染天然避开这个坑。

after_initialize do
  # 启动时做一次配置体检，把「能提前发现」的错误尽早暴露到日志里，
  # 而不是等用户点了登录按钮才报错。
  #
  # 注意：这里直接执行，不要挂到 DiscourseEvent 上。
  # DiscourseEvent.on 对未注册的事件名是静默接受的（不报错），
  # 但永远不会有对应的 trigger，等于死代码。
  # （曾经踩过这个坑，spec 里有回归测试守着。）
  if SiteSetting.cnkd_login_enabled
    health = DiscourseCnkdLogin::HealthCheck.run

    if DiscourseCnkdLogin::HealthCheck.error?(health)
      health.each do |check|
        next unless check[:level] == DiscourseCnkdLogin::HealthCheck::ERROR
        Rails.logger.warn(
          "[#{DiscourseCnkdLogin::PLUGIN_NAME}] 配置错误 #{check[:id]} #{check[:detail]}",
        )
      end
    end

    Rails.logger.info(
      "[#{DiscourseCnkdLogin::PLUGIN_NAME}] CNKD 回调地址（须逐字符登记到平台）：" \
        "#{DiscourseCnkdLogin.callback_url}",
    )
  end
end
