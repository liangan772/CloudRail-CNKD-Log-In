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
  end
end
