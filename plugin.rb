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

# ⚠️ 不要调用 register_asset 注册 assets/javascripts/ 下的文件。
#
# Discourse 的 `register_asset` 对 .js 文件**直接 raise**（见
# lib/plugin/instance.rb）：
#     "[...] Javascript files under assets/javascripts are automatically
#      included in JS bundles. Manual register_asset calls should be removed."
# .hbs 同理也会 raise。
#
# 这一点在本插件上曾经造成过一次真实故障：plugin.rb 在 `rake db:migrate`
# 期间也会被加载（Plugin::Instance#activate! 把插件目录加入迁移路径），
# 于是这里一 raise，迁移就以 exit 1 失败，表现为
# `Pups::ExecError: ... 'bundle exec rake db:migrate' failed` 与
# `FAILED TO BOOTSTRAP`。
#
# 结论：assets/javascripts/** 与 assets/stylesheets/** 都由构建系统按
# 目录约定自动收录，plugin.rb 里不需要、也不应该注册它们。
#
# 前端文件布局（全部遵循官方约定，见 developer-docs 04-plugins/05）：
#   assets/javascripts/discourse/cnkd-login-route-map.js         路由映射
#   assets/javascripts/discourse/controllers/admin-plugins-cnkd-login.js
#   assets/javascripts/discourse/templates/admin/plugins-cnkd-login.hbs
#   assets/stylesheets/common/cnkd-login-admin.scss
#
# 客户端 i18n 由 config/locales/client.*.yml 提供，
# 键挂在 js.login.cnkd.* 与 js.cnkd_login.* 下。

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
# 第一个参数是**完整的 i18n key**（不是域名）——
# 官方 developer-docs 的写法就是 `add_admin_route 'purple_tentacle.title', 'purple-tentacle'`，
# 这个 key 会在 /admin/plugins 插件列表里作为「设置」链接的标题显示。
#
# 第二个参数是前端路由名，必须与 route-map 里的
# `this.route("cnkd-login")` 以及模板名 plugins-cnkd-login.hbs 严格对应。
add_admin_route "cnkd_login.admin.title", "cnkd-login"

# 服务端路由。
#
# 前端路由需要一个服务端对应项：用户直接在地址栏访问
# /admin/plugins/cnkd-login 时，Rails 得能返回点什么（否则 404）。
# 官方示例复用 `admin/plugins#index` 返回骨架，前端 Ember 接手渲染 ——
# 数据走我们自己下面的 /cnkd-login/preview 接口。
#
# StaffConstraint 保证只有员工能访问，与 admin 区的可见性一致。
Discourse::Application.routes.append do
  get "/admin/plugins/cnkd-login" => "admin/plugins#index", constraints: StaffConstraint.new

  # 自检 + 握手预览数据接口。
  #
  # 只读取站点设置、不发任何外网请求，因此没有 SSRF 面；
  # 响应里 client_secret 已被 PreviewRenderer 掩码，不会外泄原文。
  get "/cnkd-login/preview" => "discourse_cnkd_login/admin#preview"
end


# 后台设置页面的控制器。
#
# ⚠️ 控制器类不要写在 plugin.rb 的顶层。
#
# 顶层 `class Foo < ::Admin::AdminController` 会在 plugin.rb 被 eval 的
# 瞬间定义类体，此时 Rails 的自动加载尚未就绪（迁移期尤其如此），
# 容易踩到常量未定义的坑。正确做法是在 after_initialize 里
# require_dependency 一个独立文件 —— 这是 Discourse 官方插件通用的写法。

after_initialize do
  require_dependency File.expand_path("app/controllers/discourse_cnkd_login/admin_controller.rb", __dir__)

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
