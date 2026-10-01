# frozen_string_literal: true

# CNKD 一证通行的 Discourse 认证器。
#
# 继承 Auth::ManagedAuthenticator，由 Discourse 核心负责
# user_associated_accounts 的读写与本地账号匹配；本类只处理 CNKD 特有的部分：
#
#   * 中间件注册（含多站点安全的 setup lambda）
#   * PKCE (S256) 参数注入 —— 由 oauth2 gem 生成，策略侧配置
#   * 用 /userinfo 的 sub 覆盖 OmniAuth 的 uid（令牌是不透明的，取不到 sub）
#   * 账号状态 / 风控校验
#   * 撤销远端授权（用户解绑或登出时）
class DiscourseCnkdLogin::Authenticator < Auth::ManagedAuthenticator
  # 必须与 OmniAuth 策略的 option :name、以及回调路径 /auth/:provider 一致
  def name
    "cnkd"
  end

  def display_name
    SiteSetting.cnkd_login_button_title.presence || "CNKD"
  end

  def provider_url
    DiscourseCnkdLogin.site_url
  end

  def enable_setting
    :cnkd_login_enabled
  end

  # 未配置这些设置时，插件不会启用（Auth::Authenticator#enabled? 会返回 false）
  def required_settings
    %i[cnkd_login_client_id]
  end

  # CNKD 的门禁已强制要求邮箱验证，返回的邮箱必然可信。
  # 但对外部合作方（partner）默认拿不到邮箱原文，因此这个判断只在
  # 应用被授予 email.address 时才可能为真。
  def primary_email_verified?(auth_token)
    auth_token.dig(:info, :email_verified) == true
  end

  def can_revoke?
    true
  end

  def can_connect_existing_user?
    true
  end

  # Discourse 不使用长期第三方令牌，access_token 60 分钟后就失效，
  # 因此不需要 refresh_token（CNKD 默认 allowRefreshToken=true，
  # 但我们主动不申请，见文档 6.4 / 9.4）。
  def always_update_user_email?
    false
  end

  # ---------------------------------------------------------------- 中间件注册

  def register_middleware(omniauth)
    # setup 接收 rack env，在其中读取 SiteSetting。
    # 不能在方法外固化配置值 —— 否则多站点环境下会串号
    # （官方文档 authentication-method 明确要求）。
    setup =
      lambda do |env|
        opts = env["omniauth.strategy"].options
        apply_strategy_options(opts)
      end

    omniauth.provider :cnkd, setup: setup
  end

  # 供 plugin.rb 启动体检复用
  def public_client?
    SiteSetting.cnkd_login_client_type.to_s == "public"
  end

  def pkce_enabled?
    # public 应用平台强制 PKCE，不可关闭（文档 4.1）
    return true if public_client?
    SiteSetting.cnkd_login_enable_pkce
  end

  private

  def apply_strategy_options(opts)
    opts[:client_id] = SiteSetting.cnkd_login_client_id
    opts[:client_secret] = client_secret

    opts[:client_options] = {
      authorize_url: DiscourseCnkdLogin.authorize_url,
      token_url: DiscourseCnkdLogin.token_endpoint,
      # CNKD 令牌接口只接受 POST（文档 7.4）
      token_method: :post,
      # 不透明令牌，没有 JWT 可供 gem 解析
      auth_scheme: :request_body,
    }

    opts[:authorize_options] = %i[scope state]
    opts[:scope] = DiscourseCnkdLogin.requested_scopes

    # PKCE：public 应用被平台强制 S256；confidential 应用也强烈建议启用。
    # oauth2 gem 的 PKCE 实现就是 RFC 7636 S256。
    if pkce_enabled?
      opts[:pkce] = true
      opts[:pkce_options] = {
        code_challenge_method: "S256",
        code_challenge:
          proc do |verifier|
            Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
          end,
      }
    end
  end

  # public 应用不传 client_secret；confidential 应用必须传
  def client_secret
    return nil if public_client?
    SiteSetting.cnkd_login_client_secret.presence
  end

  public

  # ------------------------------------------------------- 认证后处理（核心）

  def after_authenticate(auth_token, existing_account: nil)
    # 1) 用 /userinfo 校验令牌并取回资料。
    #    这一步同时完成 CNKD 侧的全部实时校验（同意状态、应用状态、
    #    账号状态、风控、邮箱验证），是唯一可信的校验途径。
    access_token = auth_token.dig(:credentials, :token)
    return failure(:token_missing) if access_token.blank?

    result = ::DiscourseCnkdLogin::UserinfoClient.fetch(access_token)
    unless result.ok?
      log_platform_error(result)
      return failure(
        ::DiscourseCnkdLogin::ErrorMessages.resolve(result.error_message),
        detail: result.error_message,
        request_id: result.request_id,
      )
    end

    profile = result.data

    # 2) sub 必须是 UUID 形态且存在，否则拒绝（文档 7.6 唯一键要求）
    if profile["sub"].blank?
      return failure(:sub_missing)
    end

    # 3) 账号状态 / 风控校验
    begin
      ::DiscourseCnkdLogin::AccountMatcher.ensure_loginable!(profile)
    rescue ::DiscourseCnkdLogin::AccountMatcher::Blocked => e
      return failure(e.i18n_key)
    end

    # 4) 用 sub 覆盖 uid —— 这是关联本地账号的唯一键。
    #    OmniAuth 策略返回的 uid 为 nil（不透明令牌无法解析出 sub）。
    auth_token[:uid] = profile["sub"]
    auth_token[:info] = (auth_token[:info] || {}).merge(
      ::DiscourseCnkdLogin::AccountMatcher.build_info(profile),
    )
    auth_token[:extra] = (auth_token[:extra] || {}).merge(
      ::DiscourseCnkdLogin::AccountMatcher.build_extra(profile),
    )

    # 5) 交给 ManagedAuthenticator 完成本地账号的查找 / 创建 / 资料同步
    super(auth_token, existing_account: existing_account)
  end

  # ------------------------------------------------------------ 远端撤销

  # 用户在 Discourse 解除 CNKD 绑定时调用（文档 7.7）。
  # 撤销任一令牌即同时撤销 access + refresh（同一条记录）。
  def revoke(user, skip_remote: false)
    association =
      UserAssociatedAccount.find_by(provider_name: name, user_id: user.id)
    raise Discourse::NotFound if association.nil?

    unless skip_remote
      token = association.credentials&.dig("token")
      if token.present?
        begin
          revoke_remote(token)
        rescue StandardError => e
          # 远端撤销失败不应阻塞本地解绑，但要留下日志便于排查
          Rails.logger.warn(
            "[#{::DiscourseCnkdLogin::PLUGIN_NAME}] 远端撤销失败: #{e.class} #{e.message}",
          )
          return :remote_failed
        end
      end
    end

    association.destroy!
    true
  end

  private

  def revoke_remote(token)
    conn = Faraday.new(url: DiscourseCnkdLogin.site_url) do |f|
      f.request :json
      f.response :raise_error
      f.adapter FinalDestination::FaradayAdapter
      f.options.timeout = 10
      f.options.open_timeout = 5
    end

    payload = { token: token, client_id: SiteSetting.cnkd_login_client_id }
    payload[:client_secret] = client_secret unless public_client?

    conn.post(DiscourseCnkdLogin::REVOKE_PATH.to_s, payload)
  end

  # 构造失败结果，并把友好文案推进 i18n key
  def failure(key, detail: nil, request_id: nil)
    log("[after_authenticate] 失败 key=#{key} detail=#{detail} requestId=#{request_id}")

    result = Auth::Result.new
    result.failed = true
    result.authenticator_name = name
    result.failed_reason =
      I18n.t(
        "login.cnkd.errors.#{key}",
        default: I18n.t("login.cnkd.errors.unknown"),
        detail: detail.to_s,
      )
    result
  end

  # 平台错误写入日志时必须记录 requestId，报障时要提供给 CNKD（文档 8.4）。
  # 注意：绝不记录令牌、授权码等敏感值。
  def log_platform_error(result)
    Rails.logger.warn(
      "[#{::DiscourseCnkdLogin::PLUGIN_NAME}] userinfo 失败 " \
        "code=#{result.error_code} message=#{result.error_message} requestId=#{result.request_id}",
    )
  end

  def log(message)
    return unless SiteSetting.cnkd_login_verbose_logging
    Rails.logger.warn("[#{::DiscourseCnkdLogin::PLUGIN_NAME}] #{message}")
  end

  public

  # 显示在 /my/preferences/account 的「已关联账号」。
  #
  # ⚠️ 注意参数类型：基类 Auth::ManagedAuthenticator#description_for_auth_hash
  # 接收的是 UserAssociatedAccount 记录对象（基类内部调用 `auth_token.info`），
  # 不是 OmniAuth 的 auth hash。早期版本的官方文档把它描述成 hash，容易踩坑。
  def description_for_auth_hash(associated_account)
    return if associated_account&.info.nil?
    info = associated_account.info
    info["nickname"] || info["name"] || associated_account.extra&.dig("cnkd_sub")
  end
end
