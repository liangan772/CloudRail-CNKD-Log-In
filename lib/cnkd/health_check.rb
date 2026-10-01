# frozen_string_literal: true

# 配置体检。
#
# 目的：把「只有等用户点登录才会暴露」的配置错误，提前算成结构化结论，
# 同时供两个消费方复用：
#   1. plugin.rb 的 after_initialize —— 启动时写日志
#   2. 后台设置界面的自检面板 —— 管理员打开页面即可看到红/黄/绿
#
# 这里的每条判断都对应 CNKD 文档里的硬性约束，注释里标注了出处，
# 以后改规则时能直接回溯到依据。
module ::DiscourseCnkdLogin
  module HealthCheck
    # 严重级别
    OK = :ok
    WARNING = :warning
    ERROR = :error

    # 返回 [{ id:, level:, message:, detail: }, ...]
    #
    # message 是面向管理员的短句（由调用方本地化，这里返回 i18n key），
    # 所以本模块不产出任何自然语言，避免和 i18n 打架。
    def self.run
      checks = []
      authenticator = Authenticator.new

      checks << client_id_check
      checks << secret_check(authenticator)
      checks << pkce_check(authenticator)
      checks << site_url_check
      checks << scope_check(authenticator)
      checks << callback_check

      checks
    end

    # 汇总：出现任一 ERROR 即为不可用
    def self.error?(checks)
      checks.any? { |c| c[:level] == ERROR }
    end

    # 是否所有配置项就绪（Auth::Authenticator 的契约）
    def self.configured?
      Authenticator.new.configured?
    end

    # ---------------------------------------------------------------- 单项检查

    # 文档 5.1：client_id 由平台审核通过后分配
    def self.client_id_check
      if SiteSetting.cnkd_login_client_id.blank?
        error(
          :client_id_missing,
          :"cnkd_login.check.client_id_missing",
        )
      else
        ok(:client_id_ok, :"cnkd_login.check.client_id_ok")
      end
    end

    # 文档 4.1：public 应用不携带密钥；confidential 应用必须携带。
    # 这两条配反了会分别触发「公开应用不需要密钥。」与「生态应用密钥无效。」
    def self.secret_check(authenticator)
      if authenticator.public_client?
        if SiteSetting.cnkd_login_client_secret.present?
          error(
            :public_app_has_secret,
            :"cnkd_login.check.public_app_has_secret",
          )
        else
          ok(:public_app_secret_ok, :"cnkd_login.check.public_app_secret_ok")
        end
      elsif SiteSetting.cnkd_login_client_secret.blank?
        error(
          :confidential_app_missing_secret,
          :"cnkd_login.check.confidential_app_missing_secret",
        )
      else
        ok(:confidential_app_secret_ok, :"cnkd_login.check.confidential_app_secret_ok")
      end
    end

    # 文档 4.1：public 应用平台强制 S256，关闭开关也不会生效。
    # 这不是错误，但要让管理员知道「这个开关现在不起作用」。
    def self.pkce_check(authenticator)
      if authenticator.public_client?
        warning(
          :pkce_forced,
          :"cnkd_login.check.pkce_forced",
        )
      elsif SiteSetting.cnkd_login_enable_pkce
        ok(:pkce_ok, :"cnkd_login.check.pkce_ok")
      else
        warning(
          :pkce_disabled,
          :"cnkd_login.check.pkce_disabled",
        )
      end
    end

    # 站点地址必须是 https 且不带 /api-control 之类的前缀 ——
    # 因为 authorize / token 等路径由插件各自拼接（plugin.rb 顶部的 *_PATH）。
    def self.site_url_check
      raw = SiteSetting.cnkd_login_site_url.to_s
      normalized = DiscourseCnkdLogin.site_url

      if normalized.blank?
        return error(:site_url_blank, :"cnkd_login.check.site_url_blank")
      end

      if !normalized.start_with?("https://")
        return error(
          :site_url_not_https,
          :"cnkd_login.check.site_url_not_https",
          detail: normalized,
        )
      end

      # 常见的复制粘贴错误：把接口路径一起贴进来了
      if raw.downcase.include?("/api-control")
        return error(
          :site_url_has_api_prefix,
          :"cnkd_login.check.site_url_has_api_prefix",
          detail: normalized,
        )
      end

      if raw != normalized
        return warning(
          :site_url_trailing_slash,
          :"cnkd_login.check.site_url_trailing_slash",
          detail: normalized,
        )
      end

      ok(:site_url_ok, :"cnkd_login.check.site_url_ok", detail: normalized)
    end

    # 文档 6.2：敏感 scope 仅 ownerType=cnkd_internal 且 trustedLevel>=4 可申请。
    # 外部合作方开启后，平台会在授权环节 400 拒绝。
    def self.scope_check(authenticator)
      sensitive = []
      sensitive << "email.verified" if SiteSetting.cnkd_login_request_email_verified
      sensitive << "qq.summary" if SiteSetting.cnkd_login_request_qq_summary

      if sensitive.empty?
        ok(:scope_ok, :"cnkd_login.check.scope_ok")
      else
        warning(
          :sensitive_scopes_enabled,
          :"cnkd_login.check.sensitive_scopes_enabled",
          detail: sensitive.join(", "),
        )
      end
    end

    # 回调地址是本插件最容易配错、且报错信息最不直观的一项（文档 5.1）。
    # 这里只做形态校验；「平台是否已登记」需要人手去 CNKD 后台核对，
    # 所以始终返回 warning + 把完整地址作为 detail 带出来方便复制。
    def self.callback_check
      url = DiscourseCnkdLogin.callback_url

      if !url.start_with?("https://")
        return error(
          :callback_not_https,
          :"cnkd_login.check.callback_not_https",
          detail: url,
        )
      end

      warning(:callback_must_register, :"cnkd_login.check.callback_must_register", detail: url)
    end

    # ---------------------------------------------------------------- 构造器
    #
    # id 与 message 是两个不同的东西，不要混用：
    #   id      —— 稳定的机器标识（稳定不改，用于日志检索与前端 keyed each）
    #   message —— i18n key（前端 i18n() / 日志里翻译成中文）
    # 三者签名保持一致，避免「ok 的 id 被写成 i18n key」这类不一致。
    def self.ok(id, message, detail: nil)
      { id: id, level: OK, message: message, detail: detail }
    end

    def self.warning(id, message, detail: nil)
      { id: id, level: WARNING, message: message, detail: detail }
    end

    def self.error(id, message, detail: nil)
      { id: id, level: ERROR, message: message, detail: detail }
    end

    private_class_method :ok, :warning, :error
  end
end
