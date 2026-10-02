# frozen_string_literal: true

# 调用 CNKD `GET /account/oauth/userinfo` 读取用户资料（文档 7.6）。
#
# 设计要点：
#   * 令牌是不透明字符串，唯一可用的校验方式就是调这个接口 —— 每次调用
#     平台都会重新校验同意状态、应用状态、账号状态、风控与邮箱验证。
#     所以「令牌没过期」不等于「一定能用」，必须以本接口的返回为准。
#   * 必须使用 `sub` 作为唯一身份键，不得使用 username / 昵称 / 邮箱。
#   * 平台对 userinfo 限流 1200 次 / 10 分钟，因此结果要缓存，
#     不要每个页面请求都调一次（文档 12「对接建议」）。
module ::DiscourseCnkdLogin
  class UserinfoClient
    Result = Struct.new(:ok?, :data, :error_code, :error_message, :request_id, keyword_init: true)

    CACHE_TTL = 5.minutes

    def initialize(access_token)
      @access_token = access_token
    end

    def self.fetch(access_token)
      new(access_token).fetch
    end

    def fetch
      cache_key = "cnkd-userinfo-#{Digest::SHA256.hexdigest(@access_token)}"

      cached = Discourse.cache.read(cache_key)
      return cached if cached

      result = request
      # 仅缓存成功结果，避免把瞬时故障（5xx / 429）缓存住
      Discourse.cache.write(cache_key, result, expires_in: CACHE_TTL) if result.ok?
      result
    end

    private

    def request
      conn = build_connection
      response =
        conn.get(DiscourseCnkdLogin::USERINFO_PATH) do |req|
          req.headers["Authorization"] = "Bearer #{@access_token}"
          req.headers["Accept"] = "application/json"
        end

      body = parse_body(response)

      if response.status == 200 && body.is_a?(Hash) && body["ok"]
        return Result.new(ok?: true, data: normalize(body["data"]))
      end

      # 失败分支：CNKD 统一错误信封是 { ok: false, error: { code, message, requestId } }
      err = body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"] : {}
      Result.new(
        ok?: false,
        error_code: err["code"] || "http_#{response.status}",
        error_message: err["message"] || I18n.t("login.cnkd.errors.unknown"),
        request_id: err["requestId"],
      )
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
      # 网络异常的技术细节只进日志；展示给用户的仍是通用文案
      Rails.logger.warn(
        "[#{DiscourseCnkdLogin::PLUGIN_NAME}] userinfo 网络异常: #{e.class} #{e.message}",
      )
      Result.new(
        ok?: false,
        error_code: "network_error",
        error_message: I18n.t("login.cnkd.errors.unknown"),
      )
    end

    def build_connection
      Faraday.new(url: DiscourseCnkdLogin.site_url) do |f|
        # 注意：这里不带 :raise_error。
        # 业务错误（4xx）由 CNKD 用统一信封返回，我们需要读到 body 里的 message
        # 才能映射成友好文案；一旦 raise，message 就丢了。
        f.headers["User-Agent"] = "Discourse/#{Discourse::VERSION::STRING} CNKD-Login"
        f.adapter FinalDestination::FaradayAdapter
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
    end

    def parse_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end

    # 归一化字段。CNKD 的 avatarUrl 为绝对地址，Discourse 需要能直接下载。
    def normalize(data)
      return {} if data.blank?
      {
        "sub" => data["sub"],
        "username" => data["username"],
        "displayName" => data["displayName"],
        "avatarUrl" => data["avatarUrl"],
        "bio" => data["bio"],
        "accountStatus" => data["accountStatus"],
        "riskLevel" => data["riskLevel"],
        # 以下两项仅当应用被授予对应邮箱范围时才存在。
        # 申请 email.address 后 data["email"] 会带上邮箱明文，
        # 用于让用户注册时免于手工填写（见 README 7.4）。
        "emailVerified" => data["emailVerified"],
        "email" => data["email"],
      }
    end
  end
end
