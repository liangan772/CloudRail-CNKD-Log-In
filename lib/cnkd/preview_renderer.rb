# frozen_string_literal: true

# OAuth 握手预览。
#
# 后台设置界面里有一个「握手预览」面板：它**不发任何真实网络请求**，
# 只是按当前配置把三步握手的报文原样渲染出来：
#
#   1. 跳转 CNKD 授权页  —— 完整 URL（含 PKCE challenge 与 state 占位）
#   2. 用 code 换令牌    —— JSON 请求体 + 完整 token URL
#   3. 调 /userinfo      —— 请求头 + 一个样例响应信封
#
# 价值在于：CNKD 的授权失败大多是「参数形态不对」而不是「账号不对」，
# 对着真实报文比对着设置项更容易看出问题（比如 scope 拼错、
# redirect_uri 多了个斜杠、client_secret 混进了 public 应用）。
#
# ⚠️ 渲染结果里绝不包含真实 client_secret / access_token 原文，
#    涉密字段统一用掩码，避免管理员截图外发时泄露。
module ::DiscourseCnkdLogin
  module PreviewRenderer
    # 掩码后的占位符，让管理员知道「这里有个值」但看不到原文
    MASKED = "••••••••"

    # 预览用的假 code / state，形态与真实值一致，便于肉眼核对长度与格式
    SAMPLE_CODE = "SAMPLE_AUTH_CODE_FOR_PREVIEW"
    SAMPLE_STATE = "SAMPLE_STATE_FOR_PREVIEW"

    # 返回 [{ step:, title:, subtitle:, url:, method:, headers:, body:, note: }, ...]
    # title / subtitle / note 均为 i18n key，由前端本地化。
    def self.steps
      authenticator = Authenticator.new

      [authorize_step(authenticator), token_step(authenticator), userinfo_step(authenticator)]
    end

    # ------------------------------------------------------------ 第 1 步：授权

    def self.authorize_step(authenticator)
      params = {
        "response_type" => "code",
        "client_id" => placeholder(SiteSetting.cnkd_login_client_id, "cnkd_xxxxxxxx"),
        "redirect_uri" => DiscourseCnkdLogin.callback_url,
        "scope" => DiscourseCnkdLogin.requested_scopes.join(" "),
        "state" => SAMPLE_STATE,
      }

      # PKCE：public 应用强制 S256。challenge 是从 verifier 算出来的，
      # 这里给一个固定样例值，形态与真实值一致（43 字符 base64url）。
      if authenticator.pkce_enabled?
        params["code_challenge"] = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        params["code_challenge_method"] = "S256"
      end

      {
        step: :authorize,
        title: :"cnkd_login.step.authorize.title",
        subtitle: :"cnkd_login.step.authorize.subtitle",
        method: "GET",
        url: "#{DiscourseCnkdLogin.authorize_url}?#{params.to_query}",
        params: params,
        headers: {
          # 授权页是浏览器直接跳转，不需要自定义头
          "Accept" => "text/html",
        },
        body: nil,
        note: :"cnkd_login.step.authorize.note",
      }
    end

    # ------------------------------------------------------------ 第 2 步：换令牌

    def self.token_step(authenticator)
      body = {
        "grant_type" => "authorization_code",
        "code" => SAMPLE_CODE,
        "redirect_uri" => DiscourseCnkdLogin.callback_url,
        "client_id" => placeholder(SiteSetting.cnkd_login_client_id, "cnkd_xxxxxxxx"),
      }

      # public 应用必须不传 client_secret —— 传了平台会报「公开应用不需要密钥。」
      if authenticator.public_client?
        body["_omitted"] = "client_secret（public 应用不传）"
      elsif SiteSetting.cnkd_login_client_secret.present?
        body["client_secret"] = MASKED
      else
        body["_missing"] = "client_secret（confidential 应用必须传，当前未配置）"
      end

      body["code_verifier"] = "SAMPLE_CODE_VERIFIER_43_CHARS_BASE64URL_XXXXXX" if authenticator.pkce_enabled?

      {
        step: :token,
        title: :"cnkd_login.step.token.title",
        subtitle: :"cnkd_login.step.token.subtitle",
        method: "POST",
        url: DiscourseCnkdLogin.token_endpoint,
        params: nil,
        headers: {
          # 这是本插件与通用 OAuth2 的最大差异点：必须是 JSON
          "Content-Type" => "application/json",
          "Accept" => "application/json",
        },
        body: JSON.pretty_generate(body),
        note: :"cnkd_login.step.token.note",
      }
    end

    # ---------------------------------------------------------- 第 3 步：userinfo

    def self.userinfo_step(authenticator)
      sample =
        if authenticator.public_client?
          {
            "ok" => true,
            "data" => {
              "sub" => "3f1a2b4c-5d6e-7f80-9a1b-2c3d4e5f6071",
              "username" => "example-user",
              "displayName" => "示例用户",
              "avatarUrl" => "https://oss.cnkd.xyz/avatar/example.png",
              "accountStatus" => "active",
              "riskLevel" => "normal",
              "emailVerified" => true,
            },
          }
        else
          {
            "ok" => true,
            "data" => {
              "sub" => "3f1a2b4c-5d6e-7f80-9a1b-2c3d4e5f6071",
              "username" => "example-user",
              "displayName" => "示例用户",
              "avatarUrl" => "https://oss.cnkd.xyz/avatar/example.png",
              "accountStatus" => "active",
              "riskLevel" => "normal",
              "emailVerified" => true,
            },
          }
        end

      # 选了邮箱相关范围时，把 email 字段放进样例响应 ——
      # 管理员一眼就能看出「这次握手会不会带回邮箱」，从而判断
      # 用户注册时还需不需要手工填写。
      if DiscourseCnkdLogin.email_scope_enabled?
        sample["data"]["email"] = "user@example.com"
      end

      {
        step: :userinfo,
        title: :"cnkd_login.step.userinfo.title",
        subtitle: :"cnkd_login.step.userinfo.subtitle",
        method: "GET",
        url: DiscourseCnkdLogin.userinfo_endpoint,
        params: nil,
        headers: {
          "Authorization" => "Bearer <access_token>",
          "Accept" => "application/json",
          "User-Agent" => "Discourse/#{Discourse::VERSION::STRING} CNKD-Login",
        },
        body: JSON.pretty_generate(sample),
        note: :"cnkd_login.step.userinfo.note",
      }
    end

    # ---------------------------------------------------------------- 工具

    # 未配置时给一个形态正确的占位值，管理员一眼能看出「这里还空着」
    def self.placeholder(value, fallback)
      value.presence || fallback
    end
    private_class_method :placeholder
  end
end
