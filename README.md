# discourse-cnkd-login

让 Discourse 论坛支持使用 **CNKD 一证通行** 账号登录。

基于 CNKD 官方文档实现：

- 《CNKD 一证通行系统 · 完整接口与接入文档 v2.0》(2026-09-27)
- 《CNKD 一证通行 · 新增授权范围 `email.address` 补充说明 v1.0》(2026-09-28)

同时遵循 Discourse 官方开发者指南中的插件规范，特别是
[Adding a new 'managed' authentication method](https://meta.discourse.org/t/adding-a-new-managed-authentication-method-to-discourse/103649)
（继承 `Auth::ManagedAuthenticator`，`auth_provider` 必须在 `after_initialize` 之前注册）。

---

## 1. 它做了什么

完整实现 OAuth 2.0 授权码流程（Authorization Code + S256 PKCE）：

```
浏览器                 Discourse 服务端              CNKD 托管页            CNKD API
  │                        │                            │                     │
  │ 点击「CNKD 一证通行」   │                            │                     │
  ├───────────────────────►│                            │                     │
  │                        │ 302 → /account/oauth/authorize                   │
  ├────────────────────────────────────────────────────►│                     │
  │  （未登录则先登录 CNKD，再回到同一授权请求）           │                     │
  │                        │                    用户点击「同意」               │
  │                        │                            ├────────────────────►│
  │◄────────────────────────────────────────────────────┤ 302 redirect_uri    │
  │  ?code=...&state=...   │                            │                     │
  ├───────────────────────►│                            │                     │
  │                        │ 校验 state → POST /token                        │
  │                        ├──────────────────────────────────────────────────►│
  │                        │◄──────── access_token（JSON 信封）───────────────┤
  │                        │ GET /userinfo                                   │
  │                        ├──────────────────────────────────────────────────►│
  │                        │◄──────── sub + 资料 ────────────────────────────┤
  │                        │ 以 sub 关联本地账号，建立会话                    │
  │◄───────────────────────┤                            │                     │
```

### 针对 CNKD 做的适配

CNKD 的接口与通用 OAuth2 有几处不一致，插件里逐一处理了：

| CNKD 的特性 | 通用 OAuth2 的默认行为 | 插件中的处理 |
| --- | --- | --- |
| 令牌接口只接受 `application/json` | oauth2 gem 默认发 form-urlencoded | 策略中覆盖请求头与 body 编码 |
| 响应是 `{ ok, data }` 信封 | gem 按扁平对象解析 | 策略中自行拆信封，再构造 `AccessToken` |
| 令牌是不透明字符串，无 JWT/JWKS | 可从 JWT 解出 `sub` | `uid` 改为从 `/userinfo` 的 `sub` 获取 |
| `sub` 是唯一稳定身份键 | 常按 email 匹配 | 强制以 `sub` 作为 `provider_uid` |
| `state` 由平台回传并强校验 | 同 | 由 gem 生成并绑定 session |
| 错误为中文业务文案 | 直接展示 | 映射为可本地化的友好文案 |
| userinfo 限流 1200 次 / 10 分钟 | 无 | 结果缓存 5 分钟，仅缓存成功结果 |

---

## 2. 安装

```bash
cd /var/discourse
# 将插件放到 plugins 目录
cp -r discourse-cnkd-login plugins/

# 重新构建（插件无额外 gem 依赖，无需修改 Gemfile）
./launcher rebuild app
```

开发环境（非 Docker）：

```bash
cp -r discourse-cnkd-login /path/to/discourse/plugins/
bin/ember-cli -u
```

安装完成后访问 `/admin/plugins` 应能看到 `discourse-cnkd-login`。

---

## 3. 配置

### 3.1 向 CNKD 提交接入申请

需要提交给 CNKD 的关键参数（模板见文档附录 A）：

| 配置项 | 本站应填写的值 |
| --- | --- |
| 授权页显示名称 `displayName` | 你的论坛名称 |
| 应用类型 `clientType` | 网站有服务端 → `confidential` |
| 回调地址 `allowedRedirectUris` | `https://<你的域名>/auth/cnkd/callback` |
| 申请范围 `allowedScopes` | `profile.basic profile.status` |
| 要求邮箱已验证 `requireEmailVerified` | `true`（建议） |
| 启用 refresh token `allowRefreshToken` | `true` 或 `false` 均可（本插件不使用刷新令牌） |
| 应用主页 / 隐私政策 / 用户协议 | 外部合作应用必填，且必须是 HTTPS |

> ⚠️ **回调地址必须逐字符精确匹配**：协议、主机名、端口、路径大小写、末尾斜杠
> 任一不同都会被拒绝（文档 5.1）。请把上表中第三行的完整地址原样提交。

> ⚠️ `email.verified`、`qq.summary`、`email.address` 属敏感范围，
> **外部合作方（`ownerType=partner`）不可申请**，申请会被平台 400 拒绝（文档 6.2）。
> 前两者如需申请，请联系 CNKD 确认你的应用归属类型。

### 3.2 在 Discourse 后台填写

`管理` → `设置` → 搜索 `cnkd`：

| 设置项 | 说明 |
| --- | --- |
| `cnkd_login_enabled` | 总开关 |
| `cnkd_login_client_id` | CNKD 分配的 `client_id` |
| `cnkd_login_client_secret` | `confidential` 应用的密钥（仅存服务端） |
| `cnkd_login_client_type` | `confidential`（有服务端的网站） |
| `cnkd_login_site_url` | 保持默认 `https://cloud.cnkd.fun` |
| `cnkd_login_button_title` | 登录按钮文案 |
| `cnkd_login_request_email_verified` | 仅 CNKD 自有应用可开启 |
| `cnkd_login_request_qq_summary` | 仅 CNKD 自有应用可开启 |

---

## 4. 依赖的官方能力与边界

严格按文档实现，**不越界**：

- ❌ 不解析令牌（不透明字符串，必须通过 `/userinfo` 校验）
- ❌ 不使用 OIDC / ID Token / JWKS（平台不提供）
- ❌ 不使用密码模式 / 隐式流程 / Device Code / Client Credentials
- ❌ 不申请手机号、真实姓名、余额、订单等未开放的数据
- ✅ 每次登录生成一次性随机 `state` 并严格校验
- ✅ `code_verifier` 每次随机生成，换码后立即销毁
- ✅ 登出 / 解绑时调用 `/account/oauth/revoke` 撤销远端授权

---

## 5. 运行测试

```bash
cd /path/to/discourse
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-cnkd-login/spec/plugin_spec.rb
```

---

## 6. 目录结构

```
discourse-cnkd-login/
├── plugin.rb                                  # 插件清单与注册
├── config/
│   ├── settings.yml                           # 站点设置
│   └── locales/
│       ├── server.en.yml / server.zh_CN.yml    # 错误文案（可本地化）
│       └── client.en.yml / client.zh_CN.yml    # 登录按钮文案
├── lib/
│   ├── omniauth/strategies/cnkd.rb            # OAuth2 策略（JSON 信封适配）
│   └── cnkd/
│       ├── authenticator.rb                   # Auth::ManagedAuthenticator 子类
│       ├── userinfo_client.rb                 # /userinfo 调用与缓存
│       ├── account_matcher.rb                 # sub 关联与账号状态校验
│       └── error_messages.rb                  # 平台错误文案 → i18n key
└── spec/plugin_spec.rb
```

---

## 7. 排查

插件启动时会把回调地址写入日志，便于对照 CNKD 后台登记值：

```
[discourse-cnkd-login] CNKD 回调地址（须逐字符登记到平台）：https://forum.example.com/auth/cnkd/callback
```

常见问题见 CNKD 文档附录 C，以及本插件映射的错误文案
（`config/locales/server.zh_CN.yml` 中的 `login.cnkd.errors.*`）。

报障时请提供 CNKD 返回的 `requestId` —— 插件已把它写入日志
（`cnkd_login_verbose_logging` 开启时）。

## License

MIT
