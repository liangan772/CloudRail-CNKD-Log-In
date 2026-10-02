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
#   * 邮箱：申请邮箱范围后，/userinfo 会直接返回邮箱明文。把邮箱放进
#     OmniAuth info hash 的 :email + :email_verified 两个位置，
#     Discourse 就会用它建号或匹配既有账号 —— 用户在注册页不必再手工填写。
#       - email.address     -> 邮箱明文（推荐，登录即可自动带入）
#       - email.verified    -> 只有布尔值，无法用于建号，仅作元数据
#     注意：邮箱**不是**唯一身份键，仍然只认 `sub`。
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

      # 本地二次防御：仅在能拿到邮箱明文（email.address）时才有意义，
      # 否则 profile["email"] 为空，这项检查不会触发，由 CNKD 侧门禁负责。
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

      email = normalized_email(profile)

      if email.present?
        info[:email] = email

        # 只要拿到了邮箱明文就标记为已验证。
        #
        # 为什么不是「必须 emailVerified == true 才算」：
        # CNKD 的门禁本身已经强制 requireEmailVerified=true（见文档 4.x），
        # 能把明文邮箱返回来就说明它已经通过平台验证；而平台在某些范围
        # 组合下并不返回 emailVerified 字段，若要求该字段为 true，
        # 会出现「邮箱明明带回来了却仍被当成未验证」，用户又被弹回
        # 手工填写 —— 正是本次要修的问题。
        #
        # 需要更强约束的管理员可以打开 cnkd_login_require_verified_email，
        # 那样会在 ensure_loginable! 里严格校验 emailVerified 字段。
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
    #
    # cnkd_email 是给 plugin.rb 的 :after_auth 钩子做兜底用的 ——
    # 核心把 info[:email] 映射到 Auth::Result#email 时理论上不会丢，
    # 但多留一份来源可以让「邮箱直通」这块有单点可查。
    def self.build_extra(profile)
      {
        "cnkd_sub" => profile["sub"],
        "cnkd_username" => profile["username"],
        "cnkd_account_status" => profile["accountStatus"],
        "cnkd_risk_level" => profile["riskLevel"],
        "cnkd_email" => normalized_email(profile),
      }.compact
    end

    # 邮箱归一化：去空白 + 统一小写。
    #
    # Discourse 侧比对邮箱时（UserEmail）本就不区分大小写，这里先归一化
    # 可以避免 "Foo@Bar.com" 与 "foo@bar.com" 被当成两个值。
    def self.normalized_email(profile)
      profile["email"].to_s.strip.downcase.presence
    end
  end
end
