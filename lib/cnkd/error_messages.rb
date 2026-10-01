# frozen_string_literal: true

# CNKD 返回的错误是中文业务文案（文档第 8 章），语义丰富但不适合直接展示给
# 终端用户。这里把平台文案映射成 Discourse 侧可本地化的 i18n key，
# 保证用户看到的是自己语言 + 可行动的提示。
#
# 接入文档 8.4 明确要求：「错误 message 为中文，可直接用于日志，但不建议
# 直接展示给终端用户（应转换为合作方自己的友好文案）」。
module ::DiscourseCnkdLogin
  module ErrorMessages
    # CNKD 明文错误 → i18n key（js.login.cnkd.errors.*）
    MAPPINGS = [
      # ---- 授权 / 参数类（用户可重试） ----
      { match: "回调地址未在生态应用白名单内", key: :redirect_uri_mismatch },
      { match: "当前应用未开放这些授权范围", key: :scope_not_allowed },
      { match: "生态授权范围不受支持", key: :scope_unknown },
      { match: "至少需要申请一项生态资料范围", key: :scope_missing },
      { match: "当前生态应用需要 PKCE 安全校验", key: :pkce_required },
      { match: "启用 PKCE 的生态应用仅支持 S256", key: :pkce_method_unsupported },
      { match: "PKCE 校验方式不受支持", key: :pkce_method_unsupported },
      { match: "PKCE 校验失败", key: :pkce_failed },
      { match: "缺少 PKCE 校验参数", key: :pkce_failed },

      # ---- 授权码类 ----
      { match: "授权码已使用", key: :code_used },
      { match: "授权码已使用或已失效", key: :code_used },
      { match: "授权码无效或已过期", key: :code_expired },
      { match: "授权码已过期", key: :code_expired },
      { match: "授权码不属于当前应用", key: :code_wrong_client },
      { match: "授权码和回调地址不能为空", key: :code_missing },
      { match: "回调地址与授权请求不一致", key: :redirect_uri_mismatch },

      # ---- 同意 / 授权纪元的变更（必须重新走登录） ----
      { match: "该生态应用授权已撤销", key: :consent_revoked },
      { match: "该生态应用授权范围已调整", key: :consent_scope_changed },
      { match: "生态应用授权已撤销", key: :consent_revoked },
      { match: "生态应用授权范围已调整", key: :consent_scope_changed },

      # ---- 账号状态（文档 11.1，不可自动重试） ----
      { match: "当前账号状态不可用于生态授权", key: :account_inactive },
      { match: "当前账号处于风控限制中", key: :account_risk_blocked },
      { match: "请先完成邮箱验证后再授权登录", key: :email_not_verified },
      { match: "当前账号未获受保护中控操作员授权", key: :not_operator },

      # ---- 应用 / 凭据类（多为配置错误，需管理员介入） ----
      { match: "生态应用当前不可用", key: :app_unavailable },
      { match: "生态应用不存在", key: :app_not_found },
      { match: "生态应用密钥无效", key: :invalid_client_secret },
      { match: "公开应用不需要密钥", key: :public_app_no_secret },

      # ---- 令牌类 ----
      { match: "缺少访问令牌", key: :token_missing },
      { match: "生态访问令牌无效或已过期", key: :token_invalid },
      { match: "刷新令牌无效", key: :token_invalid },
      { match: "刷新令牌已撤销", key: :token_invalid },
      { match: "刷新令牌已过期", key: :token_invalid },
      { match: "刷新令牌不能为空", key: :token_invalid },

      # ---- 限流（文档 12） ----
      { match: "过于频繁", key: :rate_limited },
      { match: "请求过于频繁", key: :rate_limited },

      # ---- 通用 ----
      { match: "请先登录 CNKD 账号", key: :cnkd_session_missing },
    ].freeze

    # 返回 i18n key 符号；无法识别时返回 :unknown
    def self.resolve(message)
      return :unknown if message.blank?
      hit = MAPPINGS.find { |m| message.include?(m[:match]) }
      hit ? hit[:key] : :unknown
    end

    # 判断该错误是否属于「用户重新登录即可解决」，用于决定是否清理本地登录态
    def self.retryable?(message)
      %i[
        code_used
        code_expired
        code_missing
        consent_revoked
        consent_scope_changed
        token_invalid
        token_missing
        cnkd_session_missing
        rate_limited
      ].include?(resolve(message))
    end

    # 判断是否属于「配置错误」，需要管理员处理而不是反复引导用户重试
    def self.config_error?(message)
      %i[
        redirect_uri_mismatch
        scope_not_allowed
        scope_unknown
        scope_missing
        app_unavailable
        app_not_found
        invalid_client_secret
        public_app_no_secret
        pkce_method_unsupported
      ].include?(resolve(message))
    end
  end
end
