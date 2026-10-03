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
| 注册页默认要求用户手填邮箱 | 第三方给的邮箱不被信任 | 申请 `email.address` 取回明文邮箱，标记为已验证并预填锁定（见 7.4） |

---

## 2. 安装

### 2.0 写进 containers/app.yml（Docker 标准做法）

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          # ⚠️ 末尾的目标目录名不能省。省掉的话目录会取仓库名
          # CloudRail-CNKD-Log-In，与 plugin.rb 的 `# name:` 不一致，
          # 日志里会出现 "Plugin name is ... but plugin directory is named ..."。
          - git clone https://github.com/liangan772/CloudRail-CNKD-Log-In.git discourse-cnkd-login
```

改完 `app.yml` 后：

```bash
cd /var/discourse && ./launcher rebuild app
```

### 2.1 在服务器上直接 clone（推荐）

```bash
cd /var/discourse

# ⚠️ 末尾的目录名不是可选项，必须保留为 discourse-cnkd-login。
# Discourse 用插件目录名和 plugin.rb 里的 `# name:` 做比对，不一致就打印：
#   Plugin name is 'discourse-cnkd-login', but plugin directory is named 'X'
# 仓库名是 CloudRail-CNKD-Log-In，直接 clone 不带目标目录就会得到这个名字，
# 从而触发上述警告（仅警告，不致故障：Discourse 会把两个名字互相别名，
# 站点设置仍能查到，但日志会一直吵）。
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
| 申请范围 `allowedScopes` | `profile.basic profile.status email.address` |
| 要求邮箱已验证 `requireEmailVerified` | `true`（建议） |
| 启用 refresh token `allowRefreshToken` | `true` 或 `false` 均可（本插件不使用刷新令牌） |
| 应用主页 / 隐私政策 / 用户协议 | 外部合作应用必填，且必须是 HTTPS |

> ⚠️ **回调地址必须逐字符精确匹配**：协议、主机名、端口、路径大小写、末尾斜杠
> 任一不同都会被拒绝（文档 5.1）。请把上表中第三行的完整地址原样提交。

> ⚠️ `email.verified`、`qq.summary` 属敏感范围，一般**外部合作方
> （`ownerType=partner`）不可申请**，申请会被平台 400 拒绝（文档 6.2）。
> 如需申请，请联系 CNKD 确认你的应用归属类型。
>
> `email.address` 不同：它用于把**邮箱明文**直接返给本站，让用户注册时
> **不必手工填写邮箱**。只要 CNKD 为你的应用开通了该范围，开启
> `cnkd_login_scope_email` 即可使用。建议在申请时一并勾选它。

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
| `cnkd_login_button_title` | 登录页按钮文案（改完刷新登录页即生效） |
| `cnkd_login_scope_email` | 申请 `email.address`，由 CNKD 返回邮箱明文 |
| `cnkd_login_auto_fill_email` | **邮箱直通**：注册页预填并锁定邮箱，用户免手填 |
| `cnkd_login_request_email_verified` | 仅 CNKD 自有应用可开启 |
| `cnkd_login_request_qq_summary` | 仅 CNKD 自有应用可开启 |
| `cnkd_login_verbose_logging` | 记录错误详情与 `requestId`，便于报障 |
| `cnkd_login_require_verified_email` | 严格校验 `emailVerified` 字段（自动带上邮箱范围） |

> 设置**不自建表单**，而是复用 Discourse 的站点设置：类型校验、权限、
> 变更审计、多站点隔离都由核心负责。本页面专注于「看得懂 + 查得出问题」。

### 3.3 登录按钮的图标

登录按钮的图标是**随插件走的**（`svg-icons/cnkd.svg`），不需要管理员配置。

图标生效靠三段式，**缺一不可**：

| 环节 | 位置 | 作用 |
| --- | --- | --- |
| ① 图形 | `svg-icons/cnkd.svg` | SVG spritesheet，内含 `<symbol id="cnkd">` |
| ② 白名单 | `plugin.rb` 的 `register_svg_icon "cnkd"` | 把名字登记进 sprite 的**按需打包**白名单 |
| ③ 下发 | `plugin.rb` 的 `auth_provider ..., icon: "cnkd"` | 经 `icon_override` 下发到前端 |

链路依据（核心源码）：

```js
// frontend/discourse/app/components/login-buttons.gjs
{{#if b.icon}} {{dIcon b.icon}} {{else}} {{dIcon "right-to-bracket"}} {{/if}}
```

```ruby
# app/serializers/auth_provider_serializer.rb
def icon_override
  object.icon_setting ? SiteSetting.get(object.icon_setting) : object.icon
end
```

```ruby
# lib/svg_sprite.rb —— 插件 sprite 的查找路径
File.dirname(plugin.path) + "/svg-icons/*.svg"   # => 插件目录/svg-icons/
```

**要点：**

- 图标名取自 `<symbol id="...">`，**与文件名无关**；`dIcon` 就是按这个 id 查的。
- `register_svg_icon` **不读取文件**，只登记名字（`Set << name`）。
  少了它，即使 `cnkd.svg` 在，图标也可能不被打进 sprite。
- 图标必须写 `fill="currentColor"`。写死 `#000` 会在**暗色主题**下变成
  看不见的黑色块；用 `currentColor` 才能跟随 `.btn-social` 的前景色。
- spritesheet 必须是**外层 `<svg>` 包 `<symbol>`**（官方
  `05-themes-components/19-custom-icons` 的规定），不能是裸 `<symbol>` 作根节点。
  漏掉外层容器时，浏览器仍能渲染，但 `dIcon` 是按 **`<symbol id>`** 从 sprite
  里取符号的 —— 裸 `<symbol>` 不会被收进 sprite，**图标会静默消失**（不报错）。

**要换成别的图标：**

1. 把新图标加工成 spritesheet（外层 `<svg style="display:none">` + `<symbol id="cnkd">`，
   原 `<svg>` 的 `viewBox` 移到 `<symbol>` 上，`fill` 改 `currentColor`）；
2. 覆盖 `svg-icons/cnkd.svg` 即可 —— 只要 `<symbol id>` 仍是 `cnkd`，
   ② ③ 两处都不用改；
3. `./launcher rebuild app`（改了磁盘文件，必须重建）。

> 想让管理员能在后台**更换**图标（而不是换文件），把 `plugin.rb` 里的
> `icon: "cnkd"` 换成 `icon_setting: :<某个设置名>` 即可，
> 与 `title_setting` 的机制完全一致（注意该设置需要 `client: true`）。


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

> 根目录名必须是 `discourse-cnkd-login`，与 `plugin.rb` 的 `# name:` 一致。
> 仓库名（`CloudRail-CNKD-Log-In`）与它无关。不一致时见 7.0.1。

```
discourse-cnkd-login/
├── plugin.rb                                  # 插件清单与注册
├── admin/assets/javascripts/discourse/templates/
│   └── admin-plugins/show/cnkd-login/
│       └── index.gjs                          # 后台页面（.gjs，模板 + 控制器合一）
├── app/controllers/discourse_cnkd_login/
│   └── admin_controller.rb                    # 后台数据接口（自检 + 预览）
├── assets/
│   ├── javascripts/discourse/
│   │   ├── admin-cnkd-login-plugin-route-map.js
│   │   │                                      # 路由映射（挂 admin.adminPlugins.show）
│   │   └── initializers/
│   │       └── cnkd-login-admin-plugin-configuration-nav.js
│   │                                          # 顶部标签导航（仅管理员）
│   └── stylesheets/common/cnkd-login-admin.scss
├── config/
│   ├── settings.yml                           # 站点设置
│   └── locales/
│       ├── server.en.yml / server.zh_CN.yml    # 错误文案（可本地化）
│       └── client.en.yml / client.zh_CN.yml    # 登录按钮 + 后台页面文案
├── docs/
│   └── plugin-admin-interfaces.reference.md   # 官方后台界面约定（存档备查）
├── svg-icons/
│   └── cnkd.svg                               # 登录按钮图标（SVG spritesheet）
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

> 前端目录遵循官方后台界面约定（存档于
> `docs/plugin-admin-interfaces.reference.md`）。四处命名必须一致，
> 改一处就要改另外三处：
> `plugin.rb` 里 `add_admin_route` 的路由名 → `this.route(...)` →
> `templates/admin-plugins/show/<路由名>/` 目录名 →
> 顶部导航里的 `route: "adminPlugins.show.<路由名>"`。

### 关于 `.gjs`（重要）

本插件**不使用 `.hbs`**，后台页面是 `.gjs`（Glimmer 模板标签格式）。

Discourse 自 2026.3 起弃用 `.hbs`（主题与插件），2026.7 ESR 是最后一个
支持它的版本，2026.8.0-latest 起计划移除；残留 `.hbs` 会给管理员弹出
警告横幅。官方公告：
<https://meta.discourse.org/t/deprecating-hbs-file-extension-in-themes-and-plugins/398896>

`.gjs` 与 `.hbs` 的**三个关键差异**（迁移时最容易踩的坑）：

| 差异 | `.hbs`（旧） | `.gjs`（新） |
| --- | --- | --- |
| 组件解析 | 全局，直接用 `<DButton />` | **必须显式 import** |
| 属性引用 | 可写裸 `{{status}}` | 严格模式，必须 `{{this.status}}` |
| action | `{{action "foo"}}` 字符串 | `{{this.foo}}` / `{{on "click" this.foo}}` |

核心组件走 ui-kit 路径：

```js
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dIcon from "discourse/ui-kit/helpers/d-icon";
```

`script/validate.py` 里有专门的检查守住这三条（禁止 `.hbs` 残留、
组件必须已 import、禁止字符串 action、模板内属性必须带 `this.`）。

> 官方 codemod（`pnpm dlx https://github.com/discourse/discourse-gjs-codemod`）
> 可自动完成大部分转换，但边角仍需人工核对 —— 这也是校验脚本存在的原因。


---

## 7. 排查

### 7.0 重建失败：`db:migrate` 报错 / FAILED TO BOOTSTRAP

```
Pups::ExecError: cd /var/www/discourse && su discourse -c 'bundle exec rake db:migrate' failed
** FAILED TO BOOTSTRAP **
```

**先看报错上方几行**，`db:migrate` 本身通常不是元凶 —— 它只是被上游异常
带崩了。最常见的两类原因：

| 原因 | 表现 | 处理 |
| --- | --- | --- |
| 插件 `plugin.rb` 在加载期 raise | 上方能看到 `[插件名]` 开头的异常或 `RuntimeError` | 见下方说明 |
| 磁盘空间不足 | `No space left on device` | `df -h` 后清理 Docker 镜像 |

**关于第一类**：`plugin.rb` **在 `rake db:migrate` 期间也会被加载** ——
`Plugin::Instance#activate!` 会把插件目录加入迁移路径。所以哪怕
插件里只有一行在加载期抛错的代码，也会让迁移整体失败。

本插件踩过这个坑：`register_asset` 对 `assets/javascripts/` 下的
`.js` 与 `.hbs` **会直接 raise**：

```
[discourse-cnkd-login] Javascript files under assets/javascripts are automatically
included in JS bundles. Manual register_asset calls should be removed.
```

现在插件里**没有任何 `register_asset` 调用** —— `assets/javascripts/**`
与 `assets/stylesheets/**` 都由构建系统按目录约定自动收录。
`script/validate.py` 里有专门的检查守住这条规则。

想快速定位是哪条插件在抛错，看上面的完整输出，或者：

```bash
cd /var/discourse
./launcher rebuild app 2>&1 | tee /tmp/rebuild.log
grep -n -B3 -A15 "db:migrate" /tmp/rebuild.log | head -60
```

若怀疑是插件导致，可临时移出插件再重建验证：

```bash
mv plugins/discourse-cnkd-login /tmp/
./launcher rebuild app
# 确认能起来后再移回来
```

### 7.0.1 日志出现 `Plugin name is '...', but plugin directory is named '...'`

```
Plugin name is 'discourse-cnkd-login', but plugin directory is named 'CloudRail-CNKD-Log-In'
```

**这只是警告，不是故障。** 源码在 `lib/discourse.rb`：

```ruby
dir_name = p.path.split("/")[-2]
if p.name != dir_name
  STDERR.puts "Plugin name is '#{p.name}', but plugin directory is named '#{dir_name}'"
  # Plugins are looked up by directory name in SiteSettingExtension ...
  # We alias the two names just to make sure the look up works
  @plugins_by_name[dir_name] = p
end
```

也就是说 Discourse 发现不一致后，会**把两个名字互相别名**，站点设置、
插件列表都照常工作。之所以还是建议消除它：日志会一直吵，且
`SiteSettingExtension` 以目录名为主索引，别名终究是补丁而非正解。

**成因**：clone 时没指定目标目录，目录取了仓库名 `CloudRail-CNKD-Log-In`，
而 `plugin.rb` 里是 `# name: discourse-cnkd-login`。

**处理**（任选其一，推荐第一种）：

```bash
# 1) 改 app.yml，给 clone 补上目标目录，然后重建
#    - git clone https://github.com/liangan772/CloudRail-CNKD-Log-In.git discourse-cnkd-login

# 2) 或在服务器上直接把目录改名（目录名是唯一判据，改完重建即可）
cd /var/discourse/plugins
mv CloudRail-CNKD-Log-In discourse-cnkd-login
cd /var/discourse && ./launcher rebuild app
```

> 不建议反过来改 `# name:` 去迁就目录名。`# name:` 是插件的稳定标识，
> 已被既有安装引用；而且本插件的 `PLUGIN_NAME` 常量、日志前缀、
> 文档路径全都围绕 `discourse-cnkd-login` 展开。

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

### 7.4 注册时仍要求手工填写邮箱

这是最常见的一个问题：CNKD 明明返回了邮箱，注册页却还要用户自己敲一遍。

**先理解机制。** Discourse 的服务端建号接口把邮箱当作**必填参数**
（`app/controllers/users_controller.rb`）：

```ruby
def create
  params.require(:email)      # 无条件要求，OAuth 也不能省
  params.require(:username)
```

也就是说注册表单**始终**会出现 —— 它正是 email 参数的唯一来源。
所以目标不是「去掉这个字段」，而是让它以**已验证状态预填并锁定**，
用户直接点「创建账号」即可。

决定这一点的是 `Auth::Result#email_valid`，它的唯一赋值点是：

```ruby
result.email_valid = primary_email_verified?(auth_token) if result.email.present?
```

插件据此把 CNKD 邮箱标记为已验证。**如果仍然要求手填，按顺序查这四项**
（后台设置页的「邮箱直通」区块会直接给出结论）：

| 检查项 | 应满足 |
| --- | --- |
| `cnkd_login_scope_email` | 已开启（或开了下面任一项，会自动带上） |
| CNKD 平台是否已为应用开通 `email.address` | 已开通。未开通时开启该项会导致授权被拒 |
| `cnkd_login_auto_fill_email` | 已开启 —— 这是「邮箱直通」的总开关 |
| 登录日志 | 出现「邮箱直通生效：xxx@yyy」字样 |

日志可以快速区分三种情况：

```
邮箱直通生效：user@example.com 将作为已验证邮箱预填到注册页。   ← 正常
本次登录未带回邮箱，注册页将要求用户手工填写。                  ← 范围没申请到
已带回邮箱 user@example.com，但 cnkd_login_auto_fill_email 为关闭状态…  ← 开关没开
```

> 若平台尚未开通 `email.address`，则本插件无法取得邮箱原文，
> 这个限制在平台侧，插件无法绕过。

### 7.4.1 登录时报 `Primary email 已被采用` / `Primary email has already been taken`

这是**邮箱归属冲突**，不是故障，是数据状态问题。

**机制。** 本插件的 `Authenticator#always_update_user_email?` 返回 `true`
（CNKD 是权威身份源，本地邮箱要跟随上游变化）。这让核心里
`Auth::Result#overrides_email` 为真，于是**老账号登录**时会执行：

```ruby
# app/controllers/users/omniauth_callbacks_controller.rb
user.save! if @auth_result.apply_user_attributes!
```

而 `apply_user_attributes!` 里有 `user.email = email`。若 CNKD 返回的邮箱
**正好是另一个本地账号的主邮箱**，这句赋值就撞上 `users` 表的唯一性校验，
`user.save!` 抛 `ActiveRecord::RecordInvalid`，核心在 `rescue` 里把
`errors.full_messages` 原文回吐到前端 —— 也就是你看到的那句话。

> 注意 `email_valid` / `always_update_user_email?` 两者是一套的：
> 前者让注册页免手填，后者让老账号同步邮箱。这次的报错来自后者。

**典型触发路径：**

1. 用户早就用 `abc@qq.com` 在论坛注册过一个账号；
2. 之后又用同一个 CNKD 账号登录（CNKD 那边也是 `abc@qq.com`）；
3. 两个身份指向同一邮箱，但分属两个 `users` 记录 → 撞库。

**插件已做的拦截。** `Authenticator#email_owner_conflict` 会在
`after_authenticate` 调用 `super` 之前先行判断，命中则直接返回
`login.cnkd.errors.email_already_taken`，用户看到的是可读文案而不再是核心的裸报错：

> 该 CNKD 邮箱已在本站注册过另一个账号（abc@qq.com）。请改用那个账号登录，或先绑定 CNKD 后再试。

判定刻意保守，**只拦真冲突**：

| 情形 | 处理 | 原因 |
| --- | --- | --- |
| 邮箱无主 | 放行 | 首次建号 |
| 邮箱属于「已绑定**本次** CNKD sub」的账号 | 放行 | 就是本人 |
| 邮箱属于「尚未绑定任何 CNKD」的既有账号 | 放行 | 核心 `match_by_email` 的正常关联 |
| 邮箱属于「已绑定**另一个** CNKD sub」的账号 | **拦截** | 必定撞 `users` 唯一索引 |

**管理员如何处理这类冲突**（二选一）：

- 让用户用**原有账号**登录，然后到
  `个人设置 → 账号 → 已关联账号` 把 CNKD 绑定上去（会走 `reconnect` 流程，不撞库）；
- 或确认旧账号确实作废后，将其邮箱改掉/删除，再让用户用 CNKD 重新注册。

> 如果这类冲突在你的站点很常见，说明「同一个人先后用邮箱注册 + 用 CNKD 登录」
> 是常态。此时更合适的是**保留** `always_update_user_email?` 为 `true`
> （CNKD 变更邮箱能同步），靠本插件的前置拦截给出可读提示即可，
> 不必关闭 —— 关掉只会让 CNKD 侧改了邮箱后本站一直停在旧地址。


### 7.4.2 登录页按钮文案改了不生效

到 `管理 → 设置` 搜 `cnkd_login_button_title` 改了值，登录页却还是老文案。

**机制。** 前端取文案的优先级（`frontend/discourse/app/models/login-method.js`）：

```js
get title()      { return this.title_override      || i18n(`login.${this.name}.title`); }
get prettyName() { return this.pretty_name_override || i18n(`login.${this.name}.name`); }
```

`title_override` 由服务端序列化器算出
（`app/serializers/auth_provider_serializer.rb`）：

```ruby
def title_override
  object.title_setting ? SiteSetting.get(object.title_setting) : object.title
end
```

而 `title_setting` **只能**由 `plugin.rb` 的 `auth_provider` 传入：

```ruby
auth_provider authenticator: DiscourseCnkdLogin::Authenticator.new,
              title_setting: :cnkd_login_button_title
```

**所以**：不传 `title_setting` → `title_override` 恒为 `nil` → 前端永远回落到
静态的 `i18n("login.cnkd.title")`，站点设置里怎么改都无效。
本插件早期版本就是这状态（该设置只被 `Authenticator#display_name` 在服务端读取，
从未下发前端），现已接线。

**如果仍然不生效，按顺序查：**

| 检查项 | 应满足 |
| --- | --- |
| `title_setting` | `plugin.rb` 的 `auth_provider` 里传了 `title_setting: :cnkd_login_button_title` |
| 该设置的 `client` | 必须是 `true` —— 不下发到前端，`title_setting` 就取不到值 |
| 设置值 | 非空。留空会回落到 i18n 文案（不会出现空白按钮） |
| 是否重建 | 改 `client: true` 之类**代码级**改动需 `./launcher rebuild app`；只改设置**值**刷新页面即可 |

> 不需要改 locale 文件的 `js.login.cnkd.title` 来改文案 —— 那是**回落值**，
> 只有当站点设置为空时才使用。改站点设置才是正道。


### 7.4.3 登录按钮图标不显示 / 显示成默认图标

按钮上是 Discourse 默认的 `right-to-bracket`（一个「→]」箭头），不是 CNKD 图标。

**机制。** 前端 `login-buttons.gjs`：

```js
{{#if b.icon}} {{dIcon b.icon}} {{else}} {{dIcon "right-to-bracket"}} {{/if}}
```

`b.icon` 为空就回落默认图标；`dIcon` 再从 **SVG sprite** 里按 `<symbol id>` 查找。
所以问题只可能出在三处（对应 §3.3 的三段式）：

| 检查项 | 应满足 |
| --- | --- |
| ① `svg-icons/cnkd.svg` | 文件存在，且含 `<symbol id="cnkd">`；外层是 `<svg>` 而不是裸 `<symbol>` |
| ② `register_svg_icon "cnkd"` | `plugin.rb` 里有这行（**不能写在注释里**） |
| ③ `icon: "cnkd"` | `auth_provider` 传了它，且名字与 `<symbol id>` **逐字符一致** |
| 是否重建 | `svg-icons/` 与 `plugin.rb` 都是磁盘文件，改完必须 `./launcher rebuild app` |

常见误因：

- **图标名不匹配**：`<symbol id="cnkd-square">` 但 `icon: "cnkd"` ——
  名字取自 `<symbol id>`，与**文件名无关**，两处必须一致。
- **裸 `<symbol>` 作根节点**：不是合法 spritesheet，spritesheet 必须外层 `<svg>` 包 `<symbol>`。
- **只在注释里写了 `register_svg_icon`**：那是死代码，必须真实调用。
- **改了文件只 `restart`**：磁盘文件不会重新打包，必须 `rebuild`。

> 快速自查：`python3 script/validate.py` 会一次性把这三段都查一遍
> （含 spritesheet 格式与 `currentColor` 检查）。


### 7.5 后台出现「已弃用」警告横幅（`.hbs`）

如果管理员看到类似这样的横幅：

> This plugin uses deprecated `.hbs` files…

说明插件里还有 `.hbs` 没迁到 `.gjs`。本插件**已经全部迁移完毕**，
正常不会出现；如果出现，多半是：

1. 服务器上的插件代码是旧版本 —— `git pull` 后重新 `./launcher rebuild app`；
2. 本插件与其他插件混装，横幅指的是别的插件（逐条看横幅里的插件名）。

自行检查本插件有无残留：

```bash
find plugins/discourse-cnkd-login -name "*.hbs"
# 应当没有任何输出
```

迁移方法见第 6 节「关于 `.gjs`」；官方公告：
<https://meta.discourse.org/t/deprecating-hbs-file-extension-in-themes-and-plugins/398896>

### 7.6 后台页面空白或报「组件未定义」

`.gjs` 是严格模式，**用到的组件必须显式 import**（`.hbs` 时代是全局解析）。
如果页面报 `DButton is not defined` 之类，检查 `.gjs` 顶部的 import 段。

核心组件路径走 ui-kit：

```js
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dIcon from "discourse/ui-kit/helpers/d-icon";
```

`script/validate.py` 可离线查出这类问题（无需浏览器）。

### 7.7 静态校验（无需 Ruby 环境）

```bash
python3 script/validate.py
```

校验内容：

- YAML 可解析性、i18n key 的中英对称性、Ruby 括号配平
- 代码/模板引用的 i18n key 是否真实存在
- `plugin.rb` 迁移期加载安全（禁止 `register_asset` JS/hbs、禁止顶层控制器）
- 后台页面布局符合官方约定（route map 挂 `.show`、模板为 `.gjs`）
- **禁止任何 `.hbs` 残留**
- `.gjs` 严格模式：组件必须已 import、禁止字符串 action、属性必须带 `this.`
- 邮箱直通链路（scope → info → email_valid → `:after_auth` 钩子）四环齐全
- 邮箱归属冲突前置拦截（`email_owner_conflict` 必须先于 `super`，且中英文案存在）
- 登录按钮文案接线（`title_setting` 已传、指向的设置存在/默认非空/`client: true`）
- 登录按钮图标接线（`svg-icons/*.svg` 含对应 `<symbol id>`、spritesheet 格式正确、
  用了 `currentColor`、`register_svg_icon` 与 `icon:` 都已登记）

## License

MIT
