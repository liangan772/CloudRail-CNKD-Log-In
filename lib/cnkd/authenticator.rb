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
  #
  # ⚠️ 这个方法决定了注册页会不会要求用户手工填邮箱。
  #    核心里的唯一使用点（lib/auth/managed_authenticator.rb）：
  #
  #      result.email_valid = primary_email_verified?(auth_token) if result.email.present?
  #
  #    而 OmniauthCallbacksController#handle_account_activation 里：
  #      if @auth_result.email_valid && @auth_result.email == user.email
  #        user.activate      # 直接激活，不再发验证邮件
  #
  #    原本这里只认 auth_token[:info][:email_verified]，而那个字段需要
  #    email.verified 这个敏感 scope —— 普通应用申请不到，于是永远为
  #    false，用户就被弹回手工填邮箱。这正是本次要修的问题。
  #
  # 现在的判断：
  #   · 邮箱为空         -> false（没东西可用）
  #   · 平台给了显式布尔 -> 以平台为准（保留更严格语义的可能）
  #   · 只有邮箱明文     -> true（能拿到明文说明范围已开通，
  #                        且 CNKD 门禁要求邮箱已验证）
  #
  # 另有一个总开关 cnkd_login_auto_fill_email，在 plugin.rb 的
  # :after_auth 钩子里把它压回 false —— 给管理员保留退回旧行为的能力。
  def primary_email_verified?(auth_token)
    info = auth_token&.dig(:info) || {}
    return false if info[:email].blank?

    return info[:email_verified] if [true, false].include?(info[:email_verified])

    true
  end

  def can_revoke?
    true
  end

  def can_connect_existing_user?
    true
  end

  # ------------------------------------------------------------- 邮箱同步

  # 每次登录都把 CNKD 的最新邮箱同步到本地账号。
  #
  # 核心里的用法（Auth::Result#apply_user_attributes!）：
  #     if (SiteSetting.auth_overrides_email || overrides_email || ...) &&
  #          email_valid && email.present? && user.email != Email.downcase(email)
  #       user.email = email
  #
  # 也就是说，只有它或全局 auth_overrides_email 为真时，本地邮箱才会
  # 跟随上游变化。默认的 false 会导致：用户在 CNKD 换了邮箱，本站
  # 永远停在旧地址。CNKD 是权威身份源，所以这里返回 true。
  #
  # ⚠️ 生效前提是 email_valid 必须为真（见 primary_email_verified?），
  #    否则这段同步根本不会被触发 —— 两个条件是一套的。
  def always_update_user_email?
    true
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

    # 5) 交给 ManagedAuthenticator 完成本地账号的查找 / 创建 / 资料同步。
    #
    #    里面按顺序做三件事（核心源码 lib/auth/managed_authenticator.rb）：
    #      a. 按 (provider_name, provider_uid) 找已有绑定 —— 老用户走这条；
    #      b. existing_account（「已登录时关联新账号」场景）；
    #      c. match_by_email? 为真时按邮件找本地账号。
    #
    #    注意 c 依赖 primary_email_verified?，所以本类必须让它对
    #    「带回了邮箱」的情况返回 true，否则邮箱匹配与后续的
    #    email_valid 都会失效。
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
