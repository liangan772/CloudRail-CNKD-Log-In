# frozen_string_literal: true

# CNKD 一证通行专用的 OmniAuth OAuth2 策略。
#
# 之所以要继承 OmniAuth::Strategies::OAuth2 而不是复用通用策略，是因为 CNKD
# 的令牌接口与 RFC 6749 的常见实现有三处差异（见接入文档 7.4 节）：
#
#   1. 只接受 `application/json` 请求体，不接受 form-urlencoded；
#   2. 令牌 URL 带 /api-control 前缀，且只支持 POST；
#   3. 响应是统一信封 `{ "ok": true, "data": { ... } }`，而不是扁平对象。
#
# oauth2 gem 生成的 POST 默认是 form-urlencoded，所以这里完全接管令牌请求：
#   * 请求侧：自行构造 JSON body 与 content-type 头
#   * 响应侧：自行拆 { ok, data } 信封，再构造 AccessToken
#
# 另外，令牌是不透明字符串（非 JWT），`sub` 只能从 /userinfo 拿到，
# 因此 uid 与 info 都由 Authenticator#after_authenticate 填充，
# 本策略只负责走完 authorize -> token 两步并拿到 access_token。
class OmniAuth::Strategies::Cnkd < ::OmniAuth::Strategies::OAuth2
  option :name, "cnkd"

  # CNKD 要求回调地址与授权请求时逐字符一致（文档 5.1）。
  # Discourse 挂载 OmniAuth 的路由是 /auth/:provider/callback。
  def callback_url
    Discourse.base_url_no_prefix + script_name + callback_path
  end

  # CNKD 要求 scope 以空格分隔（文档 6.4）；
  # state 由 oauth2 gem 的 super 生成并写入 session 做 CSRF 校验。
  def authorize_params
    params = super
    params[:scope] = Array(options.scope).join(" ") if options.scope.present?
    params
  end

  def build_access_token
    token = request.params["code"]

    # 不走 gem 的 auth_code.get_token（它按 form-urlencoded 解析响应），
    # 而是自己发请求、自己拆信封，把 data 层交给 AccessToken 构造。
    #
    # 这样做的另一个好处是：CNKD 的失败响应是
    #   { ok: false, error: { code, message, requestId } }
    # gem 默认会当成解析错误抛异常、丢失 message，这里可以完整保留。
    response =
      client.request(
        :post,
        client.token_url,
        body: JSON.generate(token_request_body(token)),
        headers: {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
        },
        raise_errors: false,
      )

    payload = parse_json(response.body)

    unless response.status == 200 && payload.is_a?(Hash) && payload["ok"]
      message = extract_error_message(payload)
      raise ::OAuth2::Error, message.presence ||
                               "CNKD token request failed (HTTP #{response.status})"
    end

    build_token_from_data(payload["data"] || {})
  end

  private

  # CNKD 失败响应是 { ok: false, error: { code, message, requestId } }，
  # 把 message 提到异常里，方便上层映射成友好文案（文档 8.2 / 8.3）。
  def extract_error_message(payload)
    return nil unless payload.is_a?(Hash)
    error = payload["error"]
    return nil unless error.is_a?(Hash)
    error["message"]
  end

  # 令牌请求体固定为 JSON（文档 7.4）。
  # redirect_uri 必须与授权请求逐字符一致，否则报
  # 「回调地址与授权请求不一致。」
  def token_request_body(code)
    body = {
      grant_type: "authorization_code",
      code: code,
      redirect_uri: callback_url,
    }
    body[:client_id] = options.client_id if options.client_id.present?
    body[:client_secret] = options.client_secret if options.client_secret.present?

    # PKCE：public 应用被平台强制 S256。
    # verifier 由 gem 在 authorize 阶段写入 session，用后即删（文档 13.1）。
    if options.pkce
      verifier = session.delete("omniauth.pkce.verifier")
      body[:code_verifier] = verifier if verifier.present?
    end

    body
  end

  # 用 data 层（已摊平信封）构造 AccessToken。
  # 不透明令牌没有 JWT，不需要 expires_at 之外的解析。
  def build_token_from_data(data)
    ::OAuth2::AccessToken.new(
      client,
      data["access_token"],
      refresh_token: data["refresh_token"],
      expires_in: data["expires_in"],
      token_type: data["token_type"] || "Bearer",
      params: data,
    )
  end

  def parse_json(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    nil
  end

  public

  # 不透明令牌无法解析，uid 交由 Authenticator 从 /userinfo 的 sub 填充。
  # 返回 nil 而不是抛错，避免 gem 在 callback_phase 里提前失败。
  uid { nil }

  info { {} }
end

# OmniAuth 默认把 :cnkd 驼峰化成 "Cnkd"，这里显式声明避免类名解析歧义
OmniAuth.config.add_camelization "cnkd", "Cnkd"
