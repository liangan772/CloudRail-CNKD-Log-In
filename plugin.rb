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
end

require_relative "lib/omniauth/strategies/cnkd"
require_relative "lib/cnkd/account_matcher"
require_relative "lib/cnkd/error_messages"
require_relative "lib/cnkd/userinfo_client"
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

after_initialize do
  # 启动时做一次配置体检，把「能提前发现」的错误尽早暴露到日志里，
  # 而不是等用户点了登录按钮才报错。
  #
  # 注意：这里直接执行，不要挂到 DiscourseEvent 上。
  # DiscourseEvent.on 对未注册的事件名是静默接受的（不报错），
  # 但永远不会有对应的 trigger，等于死代码。
  if SiteSetting.cnkd_login_enabled
    authenticator = DiscourseCnkdLogin::Authenticator.new

    if SiteSetting.cnkd_login_client_id.blank?
      Rails.logger.warn(
        "[#{DiscourseCnkdLogin::PLUGIN_NAME}] 已启用但未配置 cnkd_login_client_id",
      )
    end

    if authenticator.public_client?
      if SiteSetting.cnkd_login_client_secret.present?
        Rails.logger.warn(
          "[#{DiscourseCnkdLogin::PLUGIN_NAME}] client_type=public 时不应配置 " \
            "client_secret，请清空",
        )
      end
    elsif SiteSetting.cnkd_login_client_secret.blank?
      Rails.logger.warn(
        "[#{DiscourseCnkdLogin::PLUGIN_NAME}] client_type=confidential 但未配置 client_secret",
      )
    end

    Rails.logger.info(
      "[#{DiscourseCnkdLogin::PLUGIN_NAME}] CNKD 回调地址（须逐字符登记到平台）：" \
        "#{DiscourseCnkdLogin.callback_url}",
    )
  end
end
