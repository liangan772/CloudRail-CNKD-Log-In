#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对 discourse-cnkd-login 做一轮静态校验。

没有 Ruby 环境，所以：
  * YAML 用 pyyaml 解析
  * Ruby 用栈式扫描器做括号/关键字配平（先剥注释和字符串）
  * i18n key 做双向对称性检查（代码里用到的 key 必须在两个语言文件里都存在）
"""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
# 脚本放在 <plugin>/script/ 下，所以仓库根是上一级
ROOT = ROOT.parent
if (ROOT / "discourse-cnkd-login").is_dir():
    ROOT = ROOT / "discourse-cnkd-login"

failures = []
notes = []


def fail(msg):
    failures.append(msg)


# ---------------------------------------------------------------- YAML

def check_yaml():
    files = [
        f
        for f in sorted(ROOT.rglob("*.yml"))
        if "node_modules" not in str(f) and ".git" not in str(f).split("discourse-cnkd-login")[-1]
    ]
    for f in files:
        try:
            with f.open(encoding="utf-8") as fh:
                yaml.safe_load(fh)
        except Exception as e:
            fail(f"YAML 解析失败 {f.relative_to(ROOT)}: {e}")
    notes.append(f"YAML 文件 {len(files)} 个全部可解析")
    return files


# ---------------------------------------------------------------- Ruby

def strip_ruby(src):
    """剥掉注释和字符串，保留结构字符。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        # 行注释
        if c == "#":
            while i < n and src[i] != "\n":
                i += 1
            continue
        # 双引号字符串。注意 #{} 插值：插值里的表达式要保留结构，
        # 否则 `"js.#{key}"` 会被当成纯字符串，把 `#{` 的 `{` 吞掉，
        # 导致括号配平误报。（早期版本正是踩了这个坑。）
        if c == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                # 进入插值：原样输出里面的内容（含匹配的花括号）
                if src[i] == "#" and i + 1 < n and src[i + 1] == "{":
                    out.append("{")
                    i += 2
                    depth = 1
                    while i < n and depth > 0:
                        ch = src[i]
                        if ch == "{":
                            depth += 1
                        elif ch == "}":
                            depth -= 1
                            if depth == 0:
                                out.append("}")
                                i += 1
                                break
                        out.append(ch)
                        i += 1
                    continue
                i += 1
            out.append('S')
            continue
        # 单引号字符串
        if c == "'":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            out.append('S')
            continue
        # 正则字面量 /\{\{.../ —— 里面的转义花括号不是结构字符，
        # 不跳过会导致括号配平误报。判定规则：`/` 出现在
        # 赋值、逗号、左括号、`=~`、`!~` 之后（即可能是正则开始），
        # 且同一行能找到未转义的收尾 `/`。
        if c == "/" and _looks_like_regex_start(src, i):
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "/":
                    i += 1
                    break
                if src[i] == "\n":
                    break
                i += 1
            # 跳过结尾的修饰符（i / m / x 等）
            while i < n and src[i] in "imxounse":
                i += 1
            out.append('R')
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _looks_like_regex_start(src, i):
    """判断 src[i] == '/' 是不是正则字面量的开始（而不是除号）。"""
    j = i - 1
    while j >= 0 and src[j] in " \t\r\n":
        j -= 1
    if j < 0:
        return True
    prev = src[j]
    # 这些符号之后出现的 / 基本是正则
    if prev in "=,([{!&|?:;":
        return True
    # `=~` / `!~` 之后
    if prev == "~":
        return True
    # return / next / and / or 等关键字之后
    for kw in ("return", "next", "and", "or", "not", "when", "if", "unless"):
        if src[max(0, j - len(kw) + 1) : j + 1] == kw:
            return True
    return False


def check_ruby_brackets():
    files = sorted(ROOT.rglob("*.rb"))
    for f in files:
        src = f.read_text(encoding="utf-8")
        clean = strip_ruby(src)

        for open_c, close_c in (("(", ")"), ("[", "]"), ("{", "}")):
            depth = 0
            line = 1
            for ch in clean:
                if ch == "\n":
                    line += 1
                elif ch == open_c:
                    depth += 1
                elif ch == close_c:
                    depth -= 1
                    if depth < 0:
                        fail(
                            f"{f.relative_to(ROOT)} 第 {line} 行出现多余的 '{close_c}'"
                        )
                        break
            if depth > 0:
                fail(f"{f.relative_to(ROOT)} 有 {depth} 个未闭合的 '{open_c}'")

        # 块级关键字与 end 的配平。
        #
        # ⚠️ 这条只是「明显漏写 end」的粗筛，不作为失败判定。
        # Ruby 的修饰式 if（`x = 1 if c`）、`index_with do` 这类
        # 方法后置块、以及多行字符串都会让纯文本统计失真，
        # 用正则做到 100% 准确不现实。真正的语法校验需要 Ruby 解析器。
        #
        # 因此：只输出观察值，不 fail。括号配平（上面那段）才是硬校验。
        opens = 0
        ends = 0
        for line in clean.split("\n"):
            code = line.strip()
            if not code:
                continue
            ends += len(re.findall(r"(?<![\w.])end(?![\w])", code))
            for _ in re.finditer(
                r"(?:^|[;=({,]\s*|\b(?:do|then)\b\s*)(def|class|module|case|begin|do)\b",
                code,
            ):
                opens += 1
            if re.match(r"^(if|unless|while|until)\b", code) and not re.search(
                r"\bthen\b", code
            ):
                opens += 1

        if ends - opens > 3:
            notes.append(
                f"{f.relative_to(ROOT)} end({ends}) 比块开启({opens}) 多，"
                "请人工确认（修饰式 if / do 块会导致统计失真，不一定是错）"
            )

    notes.append(f"Ruby 文件 {len(files)} 个括号配平（关键字为辅助提示）")


# ---------------------------------------------------------------- i18n

def flatten(node, prefix=""):
    out = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else str(k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.update(flatten(v, f"{prefix}[{i}]"))
    else:
        out[prefix] = node
    return out


def load_locale(path):
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    # 顶层是语言代码
    code = next(iter(data))
    return flatten(data[code])


def check_locale_symmetry():
    pairs = [
        ("config/locales/client.zh_CN.yml", "config/locales/client.en.yml"),
        ("config/locales/server.zh_CN.yml", "config/locales/server.en.yml"),
    ]
    for zh_rel, en_rel in pairs:
        zh = load_locale(ROOT / zh_rel)
        en = load_locale(ROOT / en_rel)
        only_zh = sorted(set(zh) - set(en))
        only_en = sorted(set(en) - set(zh))
        if only_zh:
            fail(f"{en_rel} 缺少这些 key: {only_zh}")
        if only_en:
            fail(f"{zh_rel} 缺少这些 key: {only_en}")
        if not only_zh and not only_en:
            notes.append(f"{zh_rel} / {en_rel} 对齐，共 {len(zh)} 个 key")

    return (
        load_locale(ROOT / "config/locales/client.zh_CN.yml"),
        load_locale(ROOT / "config/locales/server.zh_CN.yml"),
    )


# ---------------------------------------------------------------- 代码引用的 key

def check_referenced_keys(client_keys, server_keys):
    """后端产出的是 i18n key（如 admin.cnkd_login.check.xxx），
    前端用 i18n("cnkd_login.xxx") 或 i18n(check.message) 去取。

    注意命名空间：客户端 key 统一挂在 `js.` 下，所以后端产出的
    `admin.cnkd_login.check.x` 在 client.*.yml 里的真实路径是
    `js.admin.cnkd_login.check.x`。"""
    all_client = client_keys | server_keys

    # 1) 后端 health_check / preview_renderer 里的 :"cnkd_login.xxx"
    #
    # 这些 key 由前端用 i18n() 翻译，客户端 i18n 在 js.* 下，
    # 所以真实路径是 js.cnkd_login.xxx。
    symbol_re = re.compile(r':"((?:cnkd_login|admin|login)[\w.]*)"')
    referenced = set()
    for f in ROOT.rglob("*.rb"):
        src = f.read_text(encoding="utf-8")
        for m in symbol_re.finditer(src):
            key = m.group(1)
            # 排除非 i18n 的符号字面量
            if "." not in key:
                continue
            referenced.add(key)

    missing = []
    for key in sorted(referenced):
        # 客户端 key 在 client.*.yml 里的完整路径是 js.<key>
        if f"js.{key}" not in all_client:
            missing.append(key)
    if missing:
        fail(f"后端引用了不存在的 i18n key: {missing}")
    else:
        notes.append(f"后端引用的 {len(referenced)} 个 i18n key 全部存在")

    # 2) 认证器里用到的错误 key 是否齐全（server.*.yml 的 login.cnkd.errors）
    auth = (ROOT / "lib/cnkd/authenticator.rb").read_text(encoding="utf-8")
    err_keys = set(re.findall(r"failure\(:(\w+)", auth))
    matcher = (ROOT / "lib/cnkd/account_matcher.rb").read_text(encoding="utf-8")
    err_keys |= set(re.findall(r"raise Blocked, :(\w+)", matcher))
    for k in sorted(err_keys):
        if f"login.cnkd.errors.{k}" not in server_keys:
            fail(f"server.zh_CN.yml 缺少错误文案 login.cnkd.errors.{k}")
    notes.append(f"认证器用到的 {len(err_keys)} 个错误 key 均有文案")

    # 3) error_messages.rb 映射到的 key
    em = (ROOT / "lib/cnkd/error_messages.rb").read_text(encoding="utf-8")
    mapped = set(re.findall(r"key: :(\w+)", em))
    for k in sorted(mapped):
        if f"login.cnkd.errors.{k}" not in server_keys:
            fail(f"error_messages 映射到不存在的文案 login.cnkd.errors.{k}")
    notes.append(f"错误映射覆盖 {len(mapped)} 个 key，文案齐全")


# ---------------------------------------------------------------- 前端模板 key

def check_template_keys(client_keys):
    """模板里 i18n "xxx" 与 JS 里 i18n("xxx") 用到的 key，
    在 client.*.yml 里的真实路径是 js.<key>。

    模板已从 .hbs 迁移到 .gjs，所以这里扫描 .gjs（以及 .js）。"""
    used = set()
    files = list(ROOT.rglob("*.gjs")) + list(ROOT.rglob("*.js")) + list(ROOT.rglob("*.hbs"))
    for f in files:
        if "node_modules" in str(f):
            continue
        src = f.read_text(encoding="utf-8")
        # i18n("a.b.c") / i18n('a.b.c') —— 也匹配跨行调用的开头形式
        used |= set(re.findall(r'i18n\(\s*"([a-z0-9_.]+)"', src))
        used |= set(re.findall(r'i18n\(\s*\'([a-z0-9_.]+)\'', src))
        # 模板里的 {{i18n "a.b.c"}}
        used |= set(re.findall(r'\{\{i18n\s+"([a-z0-9_.]+)"', src))
        # @label="a.b.c" / label="a.b.c"
        used |= set(re.findall(r'@?label(?:Label)?="([a-z0-9_.]+)"', src))
        # 模板里的多行 i18n 调用（{{i18n "x" 换行续参）
        used |= set(re.findall(r'i18n "([a-z0-9_.]+)"', src))
        # gjs 模板里的裸 key 参数（如 @descriptionLabel="a.b.c"）
        used |= set(re.findall(r'@?\w*Label="([a-z0-9_.]+)"', src))

    # 这些是「运行时才决定 key」的动态引用，静态扫描看不到具体值，
    # 已由 check_referenced_keys 单独校验，这里跳过。
    dynamic = {"check.message", "step.title", "step.subtitle", "step.note"}

    missing = []
    for k in sorted(used):
        if k in dynamic:
            continue
        if f"js.{k}" not in client_keys:
            missing.append(k)
    if missing:
        fail(f"前端引用了不存在的客户端 i18n key: {missing}")
    else:
        notes.append(f"前端引用的 {len(used - dynamic)} 个 key 全部存在")


def check_gjs_strict_mode():
    """`.gjs` 模板是**严格模式**，与 .hbs 的宽松解析有语法差异：

      · 组件 / helper 必须**显式 import**（.hbs 里是全局解析）。
        未 import 的大写组件标签在 .gjs 里会直接编译失败。
      · 模板内引用控制器属性必须显式写 `this.`。
      · 不能再用字符串 action `{{action "foo"}}`，应为 `{{this.foo}}` 或
        `{{on "click" this.foo}}`。
      · 每个 .gjs 应当有一个 <template> 标签块。

    这条检查守住迁移正确性 —— codemod 覆盖不到的边角最容易在这里出错。
    """
    gjs_files = [
        f
        for f in ROOT.rglob("*.gjs")
        if "node_modules" not in str(f) and ".git" not in f.parts
    ]
    if not gjs_files:
        return

    # 无需 import 的内置标签 / 全局组件（保留字或核心始终可用的）
    BUILTIN = {
        "template",
        "let",
        "if",
        "each",
        "in-element",
        "link-to",
        "textarea",
        "input",
        "select",
        "option",
        "form",
        "button",
        "table",
        "thead",
        "tbody",
        "tr",
        "td",
        "th",
        "div",
        "span",
        "pre",
        "code",
        "br",
        "label",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "p",
        "ul",
        "ol",
        "li",
        "a",
        "img",
        "nav",
        "section",
        "article",
        "header",
        "footer",
        # 全局 helper / 概念，不需要 import
        # ⚠️ 不要往这里加 loading-spinner 之类的组件 ——
        # .gjs 严格模式下它们**必须 import**，放进来会让检查形同虚设。
        "outlet",
        "yield",
        "component",
        "concat",
        # 语言关键字与内置 helper：出现在 {{...}} 里但不是模块标识符
        "else",
        "this",
        "not",
        "and",
        "or",
        "eq",
        "ne",
        "gt",
        "gte",
        "lt",
        "lte",
        "inc",
        "dec",
        "on",
        "fn",
        "hash",
        "array",
        "if",
        "unless",
        "each",
        "let",
        "with",
        "in-element",
        "mount",
        "unique-id",
        "get",
        "concat",
        "join",
        "map-by",
        "sort-by",
        "filter-by",
        "t",
        "n",
    }

    for f in gjs_files:
        rel = f.relative_to(ROOT)
        src = f.read_text(encoding="utf-8")

        if "<template>" not in src:
            fail(f"{rel} 没有 <template> 标签块，不是合法的 .gjs 模板")
            continue

        # 收集 import 进来的标识符
        imported = set()
        for m in re.finditer(
            r'^import\s+(?:\{([^}]+)\}|(\w+))(?:\s*,\s*\{([^}]+)\})?\s+from',
            src,
            re.M,
        ):
            names = []
            for grp in (m.group(1), m.group(3)):
                if grp:
                    names += [n.strip().split(" as ")[-1] for n in grp.split(",")]
            if m.group(2):
                names.append(m.group(2))
            imported |= {n for n in names if n}

        tpl = src.split("<template>", 1)[1]

        # 收集模板块里的块参数（{{#each xs as |a b|}} 里的 a b 是合法局部变量）
        block_params = set()
        for m in re.finditer(r"as\s+\|([^|]+)\|", tpl):
            for name in m.group(1).split():
                block_params.add(name.strip())

        # 1) 大写开头的组件标签必须已 import
        used_components = set(re.findall(r"<([A-Z][A-Za-z0-9]*)", tpl))
        # 1b) 带连字符的小写标签（<loading-spinner /> / <d-button />）也必须是
        #     已 import 的组件 —— .gjs 里它们不再是全局可用的。
        #     纯 HTML 标签（div/span/pre…）在白名单里。
        hyphen_tags = set(re.findall(r"<([a-z][a-z0-9]*(?:-[a-z0-9]+)+)[\s/>]", tpl))
        # 2) 花括号里的 helper 调用：{{foo ...}} / {{foo}}
        used_helpers = set()
        for m in re.finditer(r"\{\{\s*([a-zA-Z_][\w-]*)", tpl):
            used_helpers.add(m.group(1))

        missing = sorted(
            (used_components | hyphen_tags | used_helpers)
            - imported
            - BUILTIN
            - block_params
        )
        if missing:
            fail(
                f"{rel} 模板里用到但未 import 的组件/helper：{missing} —— "
                ".gjs 严格模式要求显式 import（核心组件走 discourse/ui-kit/...）"
            )

        # 3) 字符串形式的 action：{{action "name"}} —— .gjs 不再支持。
        #    先剥掉注释（{{! ... }} 与 // 行注释），否则文档里的示例代码会误报。
        code = re.sub(r"\{\{!.*?\}\}", "", src, flags=re.S)
        code = re.sub(r"^\s*//.*$", "", code, flags=re.M)
        for m in re.finditer(r'\{\{action\s+"([^"]+)"', code):
            fail(
                f'{rel} 用了字符串 action {{{{action "{m.group(1)}"}}}} —— '
                f".gjs 严格模式应改为 {{{{this.{m.group(1)}}}}}"
            )

        # 4) 模板块内未加 this. 的裸属性引用
        suspicious = set()
        for m in re.finditer(r"\{\{#(if|unless|each)\s+([A-Za-z_][\w.]*)", tpl):
            expr = m.group(2)
            root = expr.split(".")[0]
            if expr.startswith(("this.", "@")) or expr in ("true", "false", "null"):
                continue
            if root in block_params:
                continue
            suspicious.add(expr)
        if suspicious:
            fail(
                f"{rel} 模板里有未加 this. 的属性引用：{sorted(suspicious)} —— "
                ".gjs 严格模式必须显式写 this."
            )

    notes.append(f".gjs 模板 {len(gjs_files)} 个通过严格模式与 import 检查")


def check_plugin_load_safety():
    """检查 plugin.rb 是否存在「加载期就 raise」的写法。

    这条检查来自一次真实故障：plugin.rb 在 `rake db:migrate` 期间也会被
    加载，顶层一旦 raise，迁移就以 exit 1 失败，表现为
        Pups::ExecError: ... 'bundle exec rake db:migrate' failed
        ** FAILED TO BOOTSTRAP **
    Discourse 的 register_asset 对 assets/javascripts/ 下的 .js 与 .hbs
    会直接 raise，所以这两类注册必须禁止。
    """
    src = (ROOT / "plugin.rb").read_text(encoding="utf-8")
    # 去掉注释行，避免注释里的示例代码误报
    code_lines = [
        ln for ln in src.split("\n") if not ln.lstrip().startswith("#")
    ]
    code = "\n".join(code_lines)

    for m in re.finditer(r'register_asset\s+["\']([^"\']+)["\']', code):
        target = m.group(1)
        if target.startswith("javascripts/") or target.endswith((".hbs", ".handlebars")):
            fail(
                f"plugin.rb 用 register_asset 注册了 {target!r} —— "
                "Discourse 会直接 raise，且 plugin.rb 在 db:migrate 期间也会加载，"
                "会导致迁移失败（FAILED TO BOOTSTRAP）"
            )

    # 顶层定义控制器类：自动加载可能尚未就绪
    first_after_init = code.split("after_initialize do")[0]
    if re.search(r"class\s+\w+\s*<\s*::?\w*(Admin|Application)Controller", first_after_init):
        fail("plugin.rb 顶层定义了控制器类，应改为在 after_initialize 里 require_dependency")

    notes.append("plugin.rb 迁移期加载安全（无 JS/hbs 注册、无顶层控制器）")


def check_health_check_ids():
    """health_check.rb 里 ok/warning/error 的 id 与 message 必须是两个不同的东西：
        id      —— 稳定机器标识（短符号，无点）
        message —— i18n key（字符串/符号，含点，形如 cnkd_login.check.xxx）

    这条检查来自一次真实疏漏：早期 ok() 只收一个参数，写成
        ok(:"cnkd_login.check.client_id_ok")
    于是 id 被塞进了 i18n key，与 warning/error 的签名不一致
    （plugin.rb 的启动日志会把 id 打出来，日志里因此出现一长串 key）。
    """
    src = (ROOT / "lib/cnkd/health_check.rb").read_text(encoding="utf-8")

    # 只看调用点，不看定义（def self.ok(...) 里是形参）
    src = re.sub(r"def\s+self\.(?:ok|warning|error)\([^)]*\)", "", src)

    call_re = re.compile(
        r"\b(ok|warning|error)\(\s*(:[A-Za-z0-9_]+|\"[^\"]+\"|'[^']+')"
        r"(?:\s*,\s*(:[A-Za-z0-9_]+|\"[^\"]+\"|'[^']+'))?"
    )
    issues = []
    for m in call_re.finditer(src):
        kind = m.group(1)
        first = m.group(2)
        # 第一个实参必须是「短符号 id」：以 : 开头且不含点
        if not first.startswith(":"):
            issues.append(f"{kind} 的第一个参数应是 id 符号，实际为 {first}")
            continue
        if "." in first:
            issues.append(
                f"{kind}({first}) 的第一参数看起来是 i18n key，"
                "id 应是稳定短标识（不含点），i18n key 放第二个参数"
            )

    if issues:
        for i in issues:
            fail(f"health_check.rb：{i}")
    else:
        notes.append("health_check.rb 的 ok/warning/error 均使用 id + message 双参数")


def check_preview_keys(client_keys):
    """preview_renderer.rb 里的 title/subtitle/note 必须是 i18n key，
    且在 client.*.yml（js. 前缀下）存在。"""
    src = (ROOT / "lib/cnkd/preview_renderer.rb").read_text(encoding="utf-8")
    keys = set(re.findall(r'(?:title|subtitle|note):\s*:"([\w.]+)"', src))
    missing = [k for k in sorted(keys) if f"js.{k}" not in client_keys]
    if missing:
        fail(f"preview_renderer 引用了不存在的预览文案 key: {missing}")
    else:
        notes.append(f"握手预览的 {len(keys)} 个文案 key 全部存在")


def check_admin_page_layout():
    """检查后台页面文件是否遵循官方目录约定。

    依据官方 admin 参考文档（docs/plugin-admin-interfaces.reference.md）：
      · add_admin_route 必须带 use_new_show_route: true
      · route map 挂在 admin.adminPlugins.show 下
      · route map 放 assets/javascripts/discourse/
      · 页面模板是 .gjs，放
        admin/assets/javascripts/discourse/templates/admin-plugins/show/<route>/

    ⚠️ 旧的 templates/admin/plugins-<name>.hbs 布局已随 .hbs 弃用而淘汰
    （见 https://meta.discourse.org/t/398896），这里显式禁止。
    """
    src = (ROOT / "plugin.rb").read_text(encoding="utf-8")

    # add_admin_route 的第二个参数就是路由名
    m = re.search(r'add_admin_route\s+"[^"]+",\s*"([^"]+)"', src)
    if not m:
        return  # 没注册后台页，跳过
    route_name = m.group(1)

    # 1) use_new_show_route 必须是 true
    if not re.search(r"use_new_show_route:\s*true", src):
        fail(
            "add_admin_route 缺少 use_new_show_route: true —— "
            "没有它就不会挂到共享的 adminPlugins.show 路由上"
        )

    # 2) 必备文件
    expected = {
        f"assets/javascripts/discourse/admin-{route_name}-plugin-route-map.js": "route map",
        f"admin/assets/javascripts/discourse/templates/"
        f"admin-plugins/show/{route_name}/index.gjs": "页面模板（.gjs）",
    }
    for rel, label in expected.items():
        if not (ROOT / rel).is_file():
            fail(f"后台页面缺少{label}：{rel}")

    # 3) 禁止任何 .hbs 残留（弃用 + 会给管理员弹警告横幅）
    hbs = [
        f
        for f in ROOT.rglob("*.hbs")
        if ".git" not in f.parts and "node_modules" not in f.parts
    ]
    if hbs:
        rel = ", ".join(str(f.relative_to(ROOT)) for f in hbs)
        fail(f"存在 .hbs 文件（已弃用，须迁移为 .gjs）：{rel}")

    # 4) 禁止旧的布局残留
    legacy = [
        ROOT / "assets/javascripts/discourse/admin",
        ROOT / f"assets/javascripts/discourse/templates/admin/plugins-{route_name}.hbs",
    ]
    for path in legacy:
        if path.exists():
            fail(f"存在旧布局残留，应删除：{path.relative_to(ROOT)}")

    notes.append(f"后台页面布局符合官方约定（路由名 {route_name}，无 .hbs）")


def check_route_map_consistency():
    """route map 里声明的路由名必须与 add_admin_route 一致，
    且 resource 必须是带 .show 的共享路由。"""
    src = (ROOT / "plugin.rb").read_text(encoding="utf-8")
    m = re.search(r'add_admin_route\s+"[^"]+",\s*"([^"]+)"', src)
    if not m:
        return
    route_name = m.group(1)

    map_file = ROOT / f"assets/javascripts/discourse/admin-{route_name}-plugin-route-map.js"
    if not map_file.is_file():
        return

    mapped = map_file.read_text(encoding="utf-8")

    if 'resource: "admin.adminPlugins.show"' not in mapped:
        fail(
            f'route map 的 resource 必须是 "admin.adminPlugins.show"'
            f"（与 use_new_show_route: true 配套），当前文件："
            f"{map_file.relative_to(ROOT)}"
        )

    if f'this.route("{route_name}")' not in mapped:
        fail(f"route map 里没有声明 this.route(\"{route_name}\")")
    else:
        notes.append("route map 与 add_admin_route 的路由名一致，且挂在共享 show 路由下")


# ---------------------------------------------------------------- 邮箱直通

def check_email_passthrough():
    """守住「注册时不再手工填邮箱」这条链路的四个环节。

    背景（回看 Discourse 核心源码得到的结论）：

      · app/controllers/users_controller.rb 的 create 里
          params.require(:email)
        是**无条件**的 —— 服务端建号永远要收到 email 参数，
        注册页表单是唯一取值来源。所以目标不是「不显示该字段」，
        而是让它以**已验证状态预填并锁定**。

      · 该表单读的是 Auth::Result#email_valid（经 UserAuthenticator#email_valid?），
        而它的唯一赋值点是 lib/auth/managed_authenticator.rb：
          result.email_valid = primary_email_verified?(auth_token) if result.email.present?

    因此四件事缺一不可，否则用户就会被弹回手工填写：
      1. plugin.rb 申请 email.address 范围（否则拿不到邮箱原文）
      2. AccountMatcher.build_info 把邮箱写进 info[:email]
      3. Authenticator#primary_email_verified? 对「有邮箱明文」返回 true
      4. plugin.rb 的 :after_auth 钩子把它落到 result.email_valid

    这条链路跨 4 个文件、且错了不报错（只是静默退化成手填），
    所以必须用静态检查钉住。
    """
    plugin = (ROOT / "plugin.rb").read_text(encoding="utf-8")
    matcher = (ROOT / "lib/cnkd/account_matcher.rb").read_text(encoding="utf-8")
    auth = (ROOT / "lib/cnkd/authenticator.rb").read_text(encoding="utf-8")

    # 1) 必须定义并申请 email.address 范围
    if 'SCOPE_EMAIL_ADDRESS = "email.address"' not in plugin:
        fail("plugin.rb 缺少 SCOPE_EMAIL_ADDRESS 常量（邮箱直通的前提）")
    if not re.search(r"scopes << SCOPE_EMAIL_ADDRESS", plugin):
        fail("plugin.rb 的 requested_scopes 没有申请 SCOPE_EMAIL_ADDRESS")

    # 2) info[:email] 必须由 AccountMatcher 写入
    if "info[:email] = email" not in matcher:
        fail("account_matcher.rb 没有把邮箱写进 info[:email]，注册页拿不到预填值")

    # 3) 邮箱明文必须被判定为「已验证」
    #
    # 这是整个链路最容易退化的地方：只要这里变成「必须 email_verified == true」，
    # 普通应用（拿不到 email.verified 敏感 scope）就会静默退化成手工填邮箱，
    # 而且不报任何错 —— 必须从**语义**上钉死，而不是匹配某个具体写法。
    #
    # 做法：剥掉注释与空行，对剩下的有效语句逐条判定。
    if "def primary_email_verified?" not in auth:
        fail("authenticator.rb 缺少 primary_email_verified?（email_valid 的唯一来源）")
    else:
        raw = auth.split("def primary_email_verified?", 1)[1].split("\n  end", 1)[0]
        stmts = []
        for ln in raw.replace("\r\n", "\n").split("\n"):
            ln = ln.split("#", 1)[0].strip()
            if ln:
                stmts.append(ln)

        # a) 必须存在「邮箱为空 -> 返回 false」的前提
        if not any("blank?" in x and "false" in x for x in stmts):
            fail(
                "primary_email_verified? 没有以「邮箱非空」为前提 —— "
                "会在没有邮箱时误判为已验证"
            )

        # b) 最后一条语句必须是裸 `true`：有明文、平台又没给布尔值时
        #    必须放行，这是普通应用唯一的出路。
        if not stmts or stmts[-1] != "true":
            fail(
                "primary_email_verified? 的最后一条语句必须是 `true`（兜底）—— "
                "否则普通应用拿不到 email.verified 敏感 scope，"
                "会永远退化回手工填邮箱"
            )

        # c) 必须显式判断 email_verified 是否为布尔值，而不是直接 `== true`
        if not any("include?" in x and "email_verified" in x for x in stmts):
            fail(
                "primary_email_verified? 必须显式判断 info[:email_verified] 是否为布尔值"
                "（形如 [true, false].include?(...)）—— 直接 `== true` "
                "就是修复前的 bug，会让注册页始终要求手工填邮箱"
            )

    # 4) :after_auth 钩子必须存在且落到 result.email_valid
    if "on(:after_auth)" not in plugin:
        fail(
            "plugin.rb 缺少 on(:after_auth) 钩子 —— core 只在 "
            "ManagedAuthenticator 里按 primary_email_verified? 赋值 "
            "email_valid，插件侧无法覆盖『邮箱直通』开关"
        )
    else:
        hook = plugin.split("on(:after_auth)", 1)[1]
        if "result.email_valid = true" not in hook:
            fail(":after_auth 钩子没有把 result.email_valid 置为 true")
        if 'authenticator.name == "cnkd"' not in hook:
            fail(":after_auth 钩子没有限定 authenticator.name，会影响其他登录方式")

    # 5) 开关必须真实存在
    settings = (ROOT / "config/settings.yml").read_text(encoding="utf-8")
    for key in ("cnkd_login_scope_email", "cnkd_login_auto_fill_email"):
        if key not in settings:
            fail(f"settings.yml 缺少 {key}（邮箱直通无法配置）")

    notes.append("邮箱直通链路完整（scope -> info -> email_valid -> after_auth 钩子）")


# ---------------------------------------------------------------- main

def main():
    check_yaml()
    check_ruby_brackets()
    check_plugin_load_safety()
    check_admin_page_layout()
    check_route_map_consistency()
    check_health_check_ids()
    check_email_passthrough()
    client_keys, server_keys = check_locale_symmetry()
    check_referenced_keys(client_keys, server_keys)
    check_template_keys(client_keys)
    check_preview_keys(client_keys)
    check_gjs_strict_mode()

    print("=" * 62)
    for n in notes:
        print(f"  [OK]   {n}")
    if failures:
        print("-" * 62)
        for m in failures:
            print(f"  [FAIL] {m}")
        print("=" * 62)
        return 1
    print("=" * 62)
    print("  全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
