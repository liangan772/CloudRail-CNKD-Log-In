# frozen_string_literal: true

# 本地账号关联策略。
#
# CNKD 接入文档反复强调两条硬性要求：
#   1. `sub` 是唯一稳定身份键，不得用 username / 昵称 / 邮箱验证状态 / QQ 昵称；
#   2. 用户撤销授权或令牌失效后，应按隐私政策删除或匿名化本地保存的 CNKD 资料。
#
# Discourse 的 user_associated_accounts 表用 (provider_name, provider_uid) 做
# 唯一索引，正好承载 `sub`。本模块只补充两点平台特有的判断：
#
#   * 邮箱：CNKD 对外部合作方默认**不返回邮箱原文**（仅 email.verified 布尔值，
#     且该 scope 不对外部合作方开放）。因此绝大多数合作方场景下
#     userinfo 里没有 email，用户需要在 Discourse 注册时自行填写并验证。
#     若应用是 CNKD 自有应用并被授予 email.address，则可以把邮箱带过来。
#   * 账号状态：accountStatus != active 或 riskLevel == blocked 时，
#     直接拒绝登录，而不是建号后再说。
module ::DiscourseCnkdLogin
  module AccountMatcher
    # 允许登录的账号状态（CNKD 归一化后，非 blocked 一律返回 normal）
    ALLOWED_ACCOUNT_STATUS = "active"

    class Blocked < StandardError
      attr_reader :i18n_key

      def initialize(i18n_key)
        @i18n_key = i18n_key
        super(i18n_key.to_s)
      end
    end

    # 校验 CNKD 侧账号状态，不通过则抛 Blocked
    def self.ensure_loginable!(profile)
      status = profile["accountStatus"]
      risk = profile["riskLevel"]

      # 未申请 profile.status 时字段缺失，此时不做判断（由 CNKD 在授权环节兜底）
      if status.present? && status != ALLOWED_ACCOUNT_STATUS
        raise Blocked, :account_inactive
      end

      if risk == "blocked"
        raise Blocked, :account_risk_blocked
      end

      # 本地二次防御：仅当能拿到邮箱明文（email.address，CNKD 自有应用）
      # 且管理员开启了该开关时才生效。外部合作方拿不到邮箱明文，
      # 这项检查不会触发，由 CNKD 侧的门禁负责。
      if SiteSetting.cnkd_login_require_verified_email &&
           profile["email"].present? &&
           profile["emailVerified"] != true
        raise Blocked, :email_not_verified
      end

      true
    end

    # 从 userinfo 结果构造 OmniAuth info hash 的增量部分
    def self.build_info(profile)
      info = {}

      # Discourse 的 nickname 对应用户名候选；CNKD 的 username 是稳定的
      info[:nickname] = profile["username"] if profile["username"].present?
      info[:name] = profile["displayName"] if profile["displayName"].present?
      info[:image] = profile["avatarUrl"] if profile["avatarUrl"].present?
      info[:description] = profile["bio"] if profile["bio"].present?

      # email 只在应用被授予 email.address 时才有值（CNKD 自有应用专属）
      if profile["email"].present?
        info[:email] = profile["email"]
        # 门禁强制 requireEmailVerified=true，返回的必然是已验证邮箱
        info[:email_verified] = true
      elsif profile["emailVerified"] == true
        # 只有布尔值、没有邮箱原文：无法用于 Discourse 建号，只作为元数据记录
        info[:email_verified] = true
      end

      info
    end

    # 记录在 user_associated_accounts.extra 里的诊断信息。
    # 注意：不写入 access_token / refresh_token 之外的敏感原文，
    # 令牌本身由 Discourse 的 credentials 字段承载。
    def self.build_extra(profile)
      {
        "cnkd_sub" => profile["sub"],
        "cnkd_username" => profile["username"],
        "cnkd_account_status" => profile["accountStatus"],
        "cnkd_risk_level" => profile["riskLevel"],
      }.compact
    end
  end
end
