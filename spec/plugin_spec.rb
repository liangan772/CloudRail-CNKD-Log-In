# frozen_string_literal: true

RSpec.describe DiscourseCnkdLogin do
  before { SiteSetting.cnkd_login_enabled = true }

  let(:sub) { "3f1a2b4c-5d6e-7f80-9a1b-2c3d4e5f6071" }
  let(:userinfo_payload) do
    {
      "ok" => true,
      "data" => {
        "sub" => sub,
        "username" => "example-user",
        "displayName" => "Example User",
        "avatarUrl" => "https://oss.cnkd.xyz/avatar/xxx.png",
        "bio" => "签名",
        "accountStatus" => "active",
        "riskLevel" => "normal",
      },
    }
  end

  def stub_userinfo(status: 200, body: userinfo_payload)
    stub_request(:get, "#{SiteSetting.cnkd_login_site_url}/api-control/account/oauth/userinfo").to_return(
      status: status,
      body: body.to_json,
      headers: {
        "Content-Type" => "application/json",
      },
    )
  end

  after { Discourse.cache.clear }

  # ------------------------------------------------------------- 策略 / 端点

  describe "OmniAuth 策略" do
    it "provider 名称固定为 cnkd，决定回调地址 /auth/cnkd/callback" do
      expect(OmniAuth::Strategies::Cnkd.new(nil).options.name).to eq("cnkd")
    end

    it "授权地址指向 CNKD 托管的授权页" do
      expect(DiscourseCnkdLogin.authorize_url).to eq(
        "https://cloud.cnkd.fun/account/oauth/authorize",
      )
    end

    it "令牌地址使用 /api-control 前缀" do
      expect(DiscourseCnkdLogin.token_endpoint).to eq(
        "https://cloud.cnkd.fun/api-control/account/oauth/token",
      )
    end

    it "可由 site setting 覆盖站点地址（联调 / 私有化部署）" do
      SiteSetting.cnkd_login_site_url = "https://staging.cnkd.example/"
      expect(DiscourseCnkdLogin.authorize_url).to eq(
        "https://staging.cnkd.example/account/oauth/authorize",
      )
    end
  end

  # ------------------------------------------------------------------ scope

  describe "scope 组装" do
    it "默认只申请对外合作方开放的 profile.basic 与 profile.status" do
      expect(DiscourseCnkdLogin.requested_scopes).to eq(%w[profile.basic profile.status])
    end

    it "敏感 scope 需显式开启（仅 CNKD 自有应用可用）" do
      SiteSetting.cnkd_login_request_email_verified = true
      expect(DiscourseCnkdLogin.requested_scopes).to include("email.verified")
    end

    it "不申请 email.address —— 该 scope 外部合作方无法通过平台门禁" do
      expect(DiscourseCnkdLogin.requested_scopes).not_to include("email.address")
    end
  end

  # ------------------------------------------------------------ 应用类型

  describe "应用类型与 PKCE" do
    it "public 应用强制启用 S256 PKCE 且不传密钥" do
      SiteSetting.cnkd_login_client_type = "public"
      a = DiscourseCnkdLogin::Authenticator.new
      expect(a.public_client?).to eq(true)
      expect(a.pkce_enabled?).to eq(true)
    end

    it "confidential 应用默认也启用 PKCE" do
      SiteSetting.cnkd_login_client_type = "confidential"
      expect(DiscourseCnkdLogin::Authenticator.new.pkce_enabled?).to eq(true)
    end
  end

  # -------------------------------------------------------- 错误文案映射

  describe "错误文案映射" do
    {
      "回调地址未在生态应用白名单内。" => :redirect_uri_mismatch,
      "授权码已使用。" => :code_used,
      "授权码已过期。" => :code_expired,
      "PKCE 校验失败。" => :pkce_failed,
      "请先完成邮箱验证后再授权登录。" => :email_not_verified,
      "当前账号处于风控限制中。" => :account_risk_blocked,
      "生态应用当前不可用。" => :app_unavailable,
      "生态应用密钥无效。" => :invalid_client_secret,
      "生态访问令牌无效或已过期。" => :token_invalid,
      "该生态应用授权已撤销，请重新发起授权。" => :consent_revoked,
      "CNKD 生态登录请求过于频繁，约 3 分钟 后可再试。" => :rate_limited,
    }.each do |message, expected|
      it "把「#{message}」识别为 #{expected}" do
        expect(DiscourseCnkdLogin::ErrorMessages.resolve(message)).to eq(expected)
      end
    end

    it "未识别的文案回落到 unknown" do
      expect(DiscourseCnkdLogin::ErrorMessages.resolve("服务器内部错误")).to eq(:unknown)
    end

    it "区分「用户重试即可」与「配置错误」" do
      expect(DiscourseCnkdLogin::ErrorMessages.retryable?("授权码已使用。")).to eq(true)
      expect(DiscourseCnkdLogin::ErrorMessages.config_error?("生态应用密钥无效。")).to eq(true)
      expect(DiscourseCnkdLogin::ErrorMessages.config_error?("授权码已使用。")).to eq(false)
    end
  end

  # -------------------------------------------------------- 账号状态校验

  describe "账号状态校验" do
    it "active + normal 放行" do
      expect do
        DiscourseCnkdLogin::AccountMatcher.ensure_loginable!(
          { "accountStatus" => "active", "riskLevel" => "normal" },
        )
      end.not_to raise_error
    end

    it "非 active 拒绝" do
      expect do
        DiscourseCnkdLogin::AccountMatcher.ensure_loginable!(
          { "accountStatus" => "suspended", "riskLevel" => "normal" },
        )
      end.to raise_error(DiscourseCnkdLogin::AccountMatcher::Blocked)
    end

    it "riskLevel=blocked 拒绝" do
      expect do
        DiscourseCnkdLogin::AccountMatcher.ensure_loginable!(
          { "accountStatus" => "active", "riskLevel" => "blocked" },
        )
      end.to raise_error(DiscourseCnkdLogin::AccountMatcher::Blocked)
    end

    it "未申请 profile.status 时字段缺失，不做本地判断（由 CNKD 兜底）" do
      expect { DiscourseCnkdLogin::AccountMatcher.ensure_loginable!({}) }.not_to raise_error
    end
  end

  # ------------------------------------------------------------- info 构造

  describe "info hash 构造" do
    it "把 CNKD 字段映射到 Discourse 的 nickname / name / image" do
      info = DiscourseCnkdLogin::AccountMatcher.build_info(
        { "username" => "u1", "displayName" => "显示名", "avatarUrl" => "https://a/b.png" },
      )
      expect(info[:nickname]).to eq("u1")
      expect(info[:name]).to eq("显示名")
      expect(info[:image]).to eq("https://a/b.png")
    end

    it "外部合作方场景下不返回 email，用户需自行填写" do
      info = DiscourseCnkdLogin::AccountMatcher.build_info({ "sub" => sub })
      expect(info).not_to have_key(:email)
      expect(info).not_to have_key(:email_verified)
    end

    it "授予 email.address 时带出邮箱并标记为已验证" do
      info = DiscourseCnkdLogin::AccountMatcher.build_info(
        { "email" => "person@example.com", "emailVerified" => true },
      )
      expect(info[:email]).to eq("person@example.com")
      expect(info[:email_verified]).to eq(true)
    end
  end

  # -------------------------------------------------------- userinfo 客户端

  describe "UserinfoClient" do
    it "解析 CNKD 的统一信封 { ok, data }" do
      stub_userinfo
      result = DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value")
      expect(result.ok?).to eq(true)
      expect(result.data["sub"]).to eq(sub)
      expect(result.data["accountStatus"]).to eq("active")
    end

    it "缓存成功结果，避免打爆 1200 次/10 分钟的限流" do
      stub_userinfo
      2.times { DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value") }
      expect(a_request(:get, /userinfo/)).to have_been_made.once
    end

    it "401 时返回失败并带上平台文案" do
      stub_userinfo(
        status: 401,
        body: {
          "ok" => false,
          "error" => {
            "code" => "request_error",
            "message" => "生态访问令牌无效或已过期。",
            "requestId" => "abc123",
          },
        },
      )
      result = DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value")
      expect(result.ok?).to eq(false)
      expect(result.error_message).to eq("生态访问令牌无效或已过期。")
      expect(result.request_id).to eq("abc123")
    end

    it "失败结果不写入缓存，避免瞬时故障被固化" do
      stub_userinfo(status: 401, body: { "ok" => false, "error" => { "message" => "x" } })
      DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value")
      DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value")
      expect(a_request(:get, /userinfo/)).to have_been_made.twice
    end

    it "网络异常时不把底层报错文本暴露给用户" do
      stub_request(:get, /userinfo/).to_raise(Faraday::ConnectionFailed.new("connection refused"))
      result = DiscourseCnkdLogin::UserinfoClient.fetch("cnkd_access_token_stub_value")
      expect(result.ok?).to eq(false)
      expect(result.error_code).to eq("network_error")
      # 不应把 "connection refused" 这类内部信息透出
      expect(result.error_message).not_to include("connection refused")
      expect(result.error_message).to eq(I18n.t("login.cnkd.errors.unknown"))
    end
  end

  # ------------------------------------------------------------- 认证器契约

  describe "Authenticator 契约" do
    let(:authenticator) { DiscourseCnkdLogin::Authenticator.new }

    it "name 必须与 OmniAuth 策略名和回调路径一致" do
      expect(authenticator.name).to eq("cnkd")
      expect(OmniAuth::Strategies::Cnkd.new(nil).options.name).to eq("cnkd")
      expect(DiscourseCnkdLogin::CALLBACK_PATH).to eq("/auth/cnkd/callback")
    end

    it "回调地址拼装正确（须逐字符登记到 CNKD）" do
      expect(DiscourseCnkdLogin.callback_url).to end_with("/auth/cnkd/callback")
    end

    it "由 ManagedAuthenticator 托管账号关联" do
      expect(authenticator.is_managed?).to eq(true)
      expect(authenticator.can_connect_existing_user?).to eq(true)
      expect(authenticator.can_revoke?).to eq(true)
    end

    # 这条覆盖一个真实踩过的坑：基类 description_for_auth_hash 收到的
    # 是 UserAssociatedAccount 记录对象，不是 OmniAuth 的 auth hash。
    # 若按 hash 访问（auth_token[:info]）会拿到 nil，
    # 再 dig(:extra, ...) 会直接抛异常，导致「已关联账号」页面崩掉。
    it "description_for_auth_hash 接收 AR 记录而非 hash" do
      account =
        UserAssociatedAccount.new(
          provider_name: "cnkd",
          provider_uid: sub,
          info: {
            "nickname" => "example-user",
          },
          extra: {
            "cnkd_sub" => sub,
          },
        )

      expect { authenticator.description_for_auth_hash(account) }.not_to raise_error
      expect(authenticator.description_for_auth_hash(account)).to eq("example-user")
    end

    it "info 无 nickname 时回落到 extra 里的 sub" do
      account =
        UserAssociatedAccount.new(
          provider_name: "cnkd",
          provider_uid: sub,
          info: {},
          extra: {
            "cnkd_sub" => sub,
          },
        )
      expect(authenticator.description_for_auth_hash(account)).to eq(sub)
    end

    it "info 为 nil 时返回 nil 而不报错" do
      account = UserAssociatedAccount.new(provider_name: "cnkd", provider_uid: sub, info: nil)
      expect(authenticator.description_for_auth_hash(account)).to be_nil
    end

    it "required_settings 缺失时插件不启用" do
      SiteSetting.cnkd_login_client_id = ""
      expect(authenticator.configured?).to eq(false)
    end

    it "enable_setting 指向总开关" do
      expect(authenticator.enable_setting).to eq(:cnkd_login_enabled)
    end

    it "primary_email_verified? 只认显式 true" do
      expect(authenticator.primary_email_verified?({ info: { email_verified: true } })).to eq(true)
      expect(authenticator.primary_email_verified?({ info: {} })).to eq(false)
    end
  end

  # ------------------------------------------------------- 启动体检（非死代码）

  describe "启动体检" do
    # 早期版本把体检挂在 on(:site_settings_loaded) 上，该事件并不存在，
    # DiscourseEvent.on 对未知事件静默接受但永不触发 —— 等于死代码。
    it "未使用不存在的事件名 site_settings_loaded" do
      source = File.read(File.expand_path("../plugin.rb", __dir__))
      expect(source).not_to include("on(:site_settings_loaded)")
    end

    it "plugin.rb 里不设置 custom_url（否则会跳过 reconnect/signup 与跳回原页）" do
      source = File.read(File.expand_path("../plugin.rb", __dir__))
      # 允许出现在注释里说明原因，但不允许作为 auth_provider 的参数
      expect(source).not_to match(/auth_provider[^\n]*custom_url/)
    end

    it "auth_provider 注册在顶层而非 after_initialize 内" do
      source = File.read(File.expand_path("../plugin.rb", __dir__))
      provider_index = source.index("auth_provider ")
      after_init_index = source.index("after_initialize do")
      expect(provider_index).to be < after_init_index
    end
  end

  # ------------------------------------------------------ 配置体检（HealthCheck）

  describe "配置体检" do
    it "client_id 为空时报错" do
      SiteSetting.cnkd_login_client_id = ""
      checks = DiscourseCnkdLogin::HealthCheck.run
      ids = checks.map { |c| c[:id] }
      expect(ids).to include(:client_id_missing)
      expect(DiscourseCnkdLogin::HealthCheck.error?(checks)).to eq(true)
    end

    it "client_id 已配置时不再报该项错误" do
      SiteSetting.cnkd_login_client_id = "cnkd_abc123"
      checks = DiscourseCnkdLogin::HealthCheck.run
      ids = checks.map { |c| c[:id] }
      expect(ids).to include(:client_id_ok)
    end

    # public 应用不能带密钥：平台会报「公开应用不需要密钥」
    it "public 应用配置了密钥时报错" do
      SiteSetting.cnkd_login_client_type = "public"
      SiteSetting.cnkd_login_client_secret = "should-not-be-here"
      checks = DiscourseCnkdLogin::HealthCheck.run
      expect(checks.map { |c| c[:id] }).to include(:public_app_has_secret)
    end

    # confidential 应用缺密钥：平台会报「生态应用密钥无效」
    it "confidential 应用缺密钥时报错" do
      SiteSetting.cnkd_login_client_type = "confidential"
      SiteSetting.cnkd_login_client_secret = ""
      checks = DiscourseCnkdLogin::HealthCheck.run
      expect(checks.map { |c| c[:id] }).to include(:confidential_app_missing_secret)
    end

    # 常见的复制粘贴错误：把接口路径一起贴进站点地址
    it "站点地址里混入 /api-control 时报错" do
      SiteSetting.cnkd_login_site_url = "https://cloud.cnkd.fun/api-control"
      checks = DiscourseCnkdLogin::HealthCheck.run
      expect(checks.map { |c| c[:id] }).to include(:site_url_has_api_prefix)
    end

    it "站点地址不是 https 时报错" do
      SiteSetting.cnkd_login_site_url = "http://cloud.cnkd.fun"
      checks = DiscourseCnkdLogin::HealthCheck.run
      expect(checks.map { |c| c[:id] }).to include(:site_url_not_https)
    end

    # 敏感 scope 只对外部合作方是「提醒」，不是错误 ——
    # 因为 CNKD 自有应用确实可以用
    it "开启敏感 scope 时给出提醒而非错误" do
      SiteSetting.cnkd_login_request_email_verified = true
      checks = DiscourseCnkdLogin::HealthCheck.run
      check = checks.find { |c| c[:id] == :sensitive_scopes_enabled }
      expect(check[:level]).to eq(DiscourseCnkdLogin::HealthCheck::WARNING)
    end

    # 回调地址始终带一条「需人工登记」的提醒，并附上完整地址
    it "回调地址始终提示人工登记，并带出地址" do
      checks = DiscourseCnkdLogin::HealthCheck.run
      check = checks.find { |c| c[:id] == :callback_must_register }
      expect(check[:level]).to eq(DiscourseCnkdLogin::HealthCheck::WARNING)
      expect(check[:detail]).to end_with("/auth/cnkd/callback")
    end

    it "所有 check 的 message 都是 i18n key 且能解析出文案" do
      checks = DiscourseCnkdLogin::HealthCheck.run
      checks.each do |check|
        key = check[:message].to_s
        expect(key).to start_with("cnkd_login.")
        expect(I18n.t("js.#{key}")).not_to include("translation missing")
      end
    end

    # id 是稳定短标识，message 是 i18n key —— 两者不能混用。
    # 早期 ok() 只收一个参数，把 i18n key 塞进了 id，日志里因此出现
    # 一长串 key 作为「错误编号」。这里守住这条界线。
    it "id 是短标识、message 是独立 i18n key，两者不混用" do
      checks = DiscourseCnkdLogin::HealthCheck.run
      checks.each do |check|
        expect(check[:id].to_s).not_to include(".")
        expect(check[:id]).not_to eq(check[:message])
        expect(check[:message].to_s).to start_with("cnkd_login.check.")
      end
    end
  end

  # ------------------------------------------------------ 握手预览（PreviewRenderer）

  describe "握手预览" do
    let(:steps) { DiscourseCnkdLogin::PreviewRenderer.steps }

    it "输出授权的三步：authorize / token / userinfo" do
      expect(steps.map { |s| s[:step] }).to eq(%i[authorize token userinfo])
    end

    it "授权步骤生成完整 URL，含 scope 与 PKCE 参数" do
      authorize = steps.find { |s| s[:step] == :authorize }
      expect(authorize[:url]).to start_with("https://cloud.cnkd.fun/account/oauth/authorize?")
      expect(authorize[:url]).to include("scope=profile.basic")
      expect(authorize[:url]).to include("code_challenge_method=S256")
    end

    # 这是本插件与通用 OAuth2 的最大差异，必须在预览里体现
    it "换令牌步骤标注为 JSON 请求体" do
      token = steps.find { |s| s[:step] == :token }
      expect(token[:method]).to eq("POST")
      expect(token[:headers]["Content-Type"]).to eq("application/json")
      expect(token[:body]).to include("\"grant_type\": \"authorization_code\"")
    end

    it "userinfo 步骤使用 Bearer 令牌" do
      userinfo = steps.find { |s| s[:step] == :userinfo }
      expect(userinfo[:headers]["Authorization"]).to eq("Bearer <access_token>")
    end

    # 预览可能被管理员截图外发，绝不能出现密钥原文
    it "绝不泄露 client_secret 原文" do
      SiteSetting.cnkd_login_client_type = "confidential"
      SiteSetting.cnkd_login_client_secret = "SUPER_SECRET_VALUE_123"
      rendered = steps.map { |s| [s[:url], s[:body], s[:headers]].compact.join }.join
      expect(rendered).not_to include("SUPER_SECRET_VALUE_123")
    end

    # secret 已配置时只给掩码，让管理员知道「有值但看不到」
    it "confidential 应用已配置密钥时展示掩码" do
      SiteSetting.cnkd_login_client_type = "confidential"
      SiteSetting.cnkd_login_client_secret = "SUPER_SECRET_VALUE_123"
      token = DiscourseCnkdLogin::PreviewRenderer.steps.find { |s| s[:step] == :token }
      expect(token[:body]).to include(DiscourseCnkdLogin::PreviewRenderer::MASKED)
    end

    it "所有 step 的 title / subtitle / note 都是可解析的 i18n key" do
      steps.each do |step|
        %i[title subtitle note].each do |field|
          key = step[field]
          next if key.nil?
          expect(key.to_s).to start_with("cnkd_login.step.")
          expect(I18n.t("js.#{key}")).not_to include("translation missing")
        end
      end
    end
  end

  # --------------------------------------------------------- 后台设置页装配

  describe "后台设置页装配" do
    let(:plugin_source) { File.read(File.expand_path("../plugin.rb", __dir__)) }

    # ---------------------------------------------------- 迁移期安全（回归）

    # 这是本项目踩过的真实故障：plugin.rb 在 `rake db:migrate` 期间
    # 也会被加载，一旦顶层有 raise，迁移就以 exit 1 失败，表现为
    #   Pups::ExecError: ... 'bundle exec rake db:migrate' failed
    #   ** FAILED TO BOOTSTRAP **
    #
    # register_asset 对 assets/javascripts/ 下的 .js / .hbs 会直接 raise。
    describe "迁移期加载安全" do
      it "不对 javascripts 调用 register_asset" do
        expect(plugin_source).not_to match(
          /^\s*register_asset\s+["']javascripts\//,
        )
      end

      it "不对 hbs 调用 register_asset" do
        expect(plugin_source).not_to match(/register_asset\s+["'][^"']*\.hbs/)
      end

      it "没有任何 register_asset 调用（assets 由构建系统自动收录）" do
        expect(plugin_source).not_to match(/^\s*register_asset\b/)
      end

      it "顶层不定义控制器类（避免自动加载未就绪）" do
        # 顶层出现 `class X < ::Admin::AdminController` 是危险的，
        # 必须在 after_initialize 里 require_dependency 独立文件。
        top_level = plugin_source.split("after_initialize do").first
        expect(top_level).not_to match(/class\s+\w+\s*<\s*::Admin::AdminController/)
      end

      it "控制器通过 require_dependency 从独立文件加载" do
        expect(plugin_source).to include("require_dependency")
        expect(plugin_source).to include("discourse_cnkd_login/admin_controller.rb")
      end
    end

    # ------------------------------------------------------------ 路由注册

    it "通过 add_admin_route 注册，传的是完整 i18n key" do
      # 官方文档写法：add_admin_route 'purple_tentacle.title', 'purple-tentacle'
      expect(plugin_source).to match(
        /add_admin_route\s+"cnkd_login\.admin\.title",\s*"cnkd-login"/,
      )
    end

    it "注册了服务端页面路由，避免直接访问 404" do
      expect(plugin_source).to include(
        'get "/admin/plugins/cnkd-login" => "admin/plugins#index"',
      )
    end

    it "服务端页面路由带 StaffConstraint" do
      expect(plugin_source).to match(
        %r{/admin/plugins/cnkd-login.*StaffConstraint},
      )
    end

    it "数据接口挂在 /cnkd-login/preview" do
      expect(plugin_source).to include('get "/cnkd-login/preview"')
    end

    # ------------------------------------------------------ 前端文件布局

    # 布局遵循官方 developer-docs 04-plugins/05-admin-interface.md
    describe "前端文件布局" do
      let(:root) { File.expand_path("..", __dir__) }

      it "route map 放在 assets/javascripts/discourse/ 下且以 -route-map.js 结尾" do
        expect(File.exist?(File.join(root, "assets/javascripts/discourse/cnkd-login-route-map.js"))).to eq(true)
      end

      it "route map 声明了 admin.adminPlugins 下的 cnkd-login 路由" do
        src = File.read(File.join(root, "assets/javascripts/discourse/cnkd-login-route-map.js"))
        expect(src).to include('resource: "admin.adminPlugins"')
        expect(src).to include('this.route("cnkd-login")')
      end

      it "控制器命名为 admin-plugins-cnkd-login（与路由名对应）" do
        expect(
          File.exist?(
            File.join(root, "assets/javascripts/discourse/controllers/admin-plugins-cnkd-login.js"),
          ),
        ).to eq(true)
      end

      it "模板放在 templates/admin/ 下且命名为 plugins-cnkd-login.hbs" do
        expect(
          File.exist?(
            File.join(root, "assets/javascripts/discourse/templates/admin/plugins-cnkd-login.hbs"),
          ),
        ).to eq(true)
      end

      it "不再残留旧的 admin/ 目录布局" do
        expect(File.exist?(File.join(root, "assets/javascripts/discourse/admin"))).to eq(false)
      end
    end

    # ------------------------------------------------------------ 设置白名单

    it "设置白名单覆盖 settings.yml 里的全部 cnkd_login_* 设置" do
      settings = YAML.load_file(File.expand_path("../config/settings.yml", __dir__))
      declared = settings["cnkd_login"].keys
      expect(declared.sort).to eq(DiscourseCnkdLogin.admin_setting_keys.sort)
    end

    # ------------------------------------------------------------ i18n 完整

    it "add_admin_route 用到的 key 在两个语言文件里都存在" do
      %w[zh_CN en].each do |locale|
        data = YAML.load_file(File.expand_path("../config/locales/client.#{locale}.yml", __dir__))
        expect(data[locale]["js"]["cnkd_login"]["admin"]["title"]).to be_present
      end
    end

    # 模板里用到的 i18n key 必须真实存在，否则页面会显示
    # "translation missing" —— 这类问题在后台很难被注意到。
    it "模板里的 i18n key 全部存在" do
      template =
        File.read(
          File.expand_path(
            "../assets/javascripts/discourse/templates/admin/plugins-cnkd-login.hbs",
            __dir__,
          ),
        )
      keys = template.scan(/\{\{i18n\s+"([a-z0-9_.]+)"/).flatten
      keys |= template.scan(/@label="([a-z0-9_.]+)"/).flatten

      expect(keys).not_to be_empty
      keys.each do |key|
        expect(I18n.t("js.#{key}")).not_to include("translation missing")
      end
    end
  end
end
