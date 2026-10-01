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

### 2.1 在服务器上直接 clone（推荐）

```bash
cd /var/discourse

# 目录名会决定插件名，请保持 discourse-cnkd-login
git clone https://github.com/liangan772/CloudRail-CNKD-Log-In.git plugins/discourse-cnkd-login

# 确认 plugin.rb 位置正确（若报 No such file 说明目录多套了一层）
ls plugins/discourse-cnkd-login/plugin.rb

# 重新构建（插件无额外 gem 依赖，无需修改 Gemfile）
./launcher rebuild app
```

### 2.2 本地下载后上传

```bash
scp -r discourse-cnkd-login root@<服务器IP>:/tmp/
# 然后在服务器上：
cd /var/discourse && mv /tmp/discourse-cnkd-login plugins/
./launcher rebuild app
```

### 2.3 开发环境（非 Docker）

```bash
git clone https://github.com/liangan772/CloudRail-CNKD-Log-In.git \
  /path/to/discourse/plugins/discourse-cnkd-login
bin/ember-cli -u
```

安装完成后访问 `/admin/plugins` 应能看到 `discourse-cnkd-login`。

### 2.4 升级

```bash
cd /var/discourse/plugins/discourse-cnkd-login
git pull
cd /var/discourse && ./launcher rebuild app
```

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

安装后进入 `管理` → `插件` → `CNKD 一证通行` 右侧的 **设置** 按钮，
即可打开专属设置页面（`/admin/plugins/cnkd-login`）。

这个页面提供四块内容：

| 区块 | 作用 |
| --- | --- |
| **状态总览** | 一眼看出「没配全 / 配置有错 / 只是有提醒 / 一切正常」 |
| **回调地址** | 展示完整回调地址并支持一键复制，避免手工拼错 |
| **配置自检** | 列出所有 ERROR / WARNING，附上平台会返回的原始错误 |
| **当前配置 + 握手预览** | 展示各项生效值；预览三步 OAuth 的完整报文 |

设置项本身仍在站点设置里修改（页面底部有直达按钮）：

`管理` → `设置` → 搜索 `cnkd`：

| 设置项 | 说明 |
| --- | --- |
| `cnkd_login_enabled` | 总开关 |
| `cnkd_login_client_id` | CNKD 分配的 `client_id` |
| `cnkd_login_client_secret` | `confidential` 应用的密钥（仅存服务端） |
| `cnkd_login_client_type` | `confidential`（有服务端的网站） |
| `cnkd_login_enable_pkce` | PKCE 开关（`public` 应用被平台强制开启） |
| `cnkd_login_site_url` | 保持默认 `https://cloud.cnkd.fun` |
| `cnkd_login_button_title` | 登录按钮文案 |
| `cnkd_login_request_email_verified` | 仅 CNKD 自有应用可开启 |
| `cnkd_login_request_qq_summary` | 仅 CNKD 自有应用可开启 |
| `cnkd_login_verbose_logging` | 记录错误详情与 `requestId`，便于报障 |
| `cnkd_login_require_verified_email` | 邮箱未验证时拒绝登录（本地二次防御） |

> 设置**不自建表单**，而是复用 Discourse 的站点设置：类型校验、权限、
> 变更审计、多站点隔离都由核心负责。本页面专注于「看得懂 + 查得出问题」。


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
├── assets/
│   ├── javascripts/discourse/admin/
│   │   ├── cnkd-login.js                      # 后台设置页组件
│   │   ├── routes/cnkd-login.js               # /admin/plugins/cnkd-login 路由
│   │   └── templates/cnkd-login.hbs           # 后台设置页模板
│   └── stylesheets/common/cnkd-login-admin.scss
├── config/
│   ├── settings.yml                           # 站点设置
│   └── locales/
│       ├── server.en.yml / server.zh_CN.yml    # 错误文案（可本地化）
│       └── client.en.yml / client.zh_CN.yml    # 登录按钮 + 后台页面文案
├── lib/
│   ├── omniauth/strategies/cnkd.rb            # OAuth2 策略（JSON 信封适配）
│   └── cnkd/
│       ├── authenticator.rb                   # Auth::ManagedAuthenticator 子类
│       ├── userinfo_client.rb                 # /userinfo 调用与缓存
│       ├── account_matcher.rb                 # sub 关联与账号状态校验
│       ├── error_messages.rb                  # 平台错误文案 → i18n key
│       ├── health_check.rb                    # 配置体检（后台自检面板复用）
│       └── preview_renderer.rb                # OAuth 握手报文预览
├── spec/plugin_spec.rb
└── script/validate.py                         # 无 Ruby 环境下的静态校验
```

---

## 7. 排查

### 7.1 用后台设置页面自检（推荐）

打开 `管理` → `插件` → `CNKD 一证通行` → **设置**，
页面顶部的状态条与「配置自检」区块会直接告诉你哪里不对。

常见结论与对应处理：

| 自检提示 | 处理 |
| --- | --- |
| 缺少 `client_id` | 向 CNKD 申请应用后填入 |
| `public` 应用却配置了密钥 | 清空 `cnkd_login_client_secret` |
| `confidential` 应用缺密钥 | 补填 `cnkd_login_client_secret` |
| 站点地址含 `/api-control` | 只保留到域名，如 `https://cloud.cnkd.fun` |
| 开启了敏感 scope | 确认应用是 `cnkd_internal`，否则关闭 |
| 回调地址需登记 | 复制页面上的地址提交给 CNKD |

### 7.2 握手预览对照

自检面板下方的「握手预览」会把三步报文的**完整参数**渲染出来
（不含真实密钥，也不发任何网络请求）。授权失败时对着它逐项核对
CNKD 后台登记值，通常比翻设置页快得多。

### 7.3 日志

插件启动时会把回调地址写入日志，便于对照 CNKD 后台登记值：

```
[discourse-cnkd-login] CNKD 回调地址（须逐字符登记到平台）：https://forum.example.com/auth/cnkd/callback
```

配置有硬错误时也会在启动阶段直接打出来，不必等用户点登录：

```
[discourse-cnkd-login] 配置错误 client_id_missing
```

报障时请提供 CNKD 返回的 `requestId` —— 插件已把它写入日志
（`cnkd_login_verbose_logging` 开启时）。

### 7.4 静态校验（无需 Ruby 环境）

```bash
python3 script/validate.py
```

校验 YAML 可解析性、i18n key 的中英对称性、Ruby 括号配平，
以及代码/模板引用的 i18n key 是否真实存在。

## License

MIT
