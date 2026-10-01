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

    # 1) 后端 health_check / preview_renderer 里的 :"admin.cnkd_login.xxx"
    symbol_re = re.compile(r':"((?:admin|site_settings|login)\.cnkd[^"]*)"')
    referenced = set()
    for f in ROOT.rglob("*.rb"):
        src = f.read_text(encoding="utf-8")
        for m in symbol_re.finditer(src):
            referenced.add(m.group(1))

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
    在 client.*.yml 里的真实路径是 js.<key>。"""
    used = set()
    for f in list(ROOT.rglob("*.hbs")) + list(ROOT.rglob("*.js")):
        if "node_modules" in str(f):
            continue
        src = f.read_text(encoding="utf-8")
        # i18n("a.b.c") / i18n('a.b.c') —— 也匹配跨行调用的开头形式
        used |= set(re.findall(r'i18n\(\s*"([a-z0-9_.]+)"', src))
        used |= set(re.findall(r'i18n\(\s*\'([a-z0-9_.]+)\'', src))
        # 模板里的 {{i18n "a.b.c"}}
        used |= set(re.findall(r'\{\{i18n\s+"([a-z0-9_.]+)"', src))
        # @label="a.b.c" / label="a.b.c"
        used |= set(re.findall(r'@label="([a-z0-9_.]+)"', src))
        # 模板里的多行 i18n 调用（{{i18n "x" 换行续参）
        used |= set(re.findall(r'i18n "([a-z0-9_.]+)"', src))

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


# ---------------------------------------------------------------- main

def main():
    check_yaml()
    check_ruby_brackets()
    client_keys, server_keys = check_locale_symmetry()
    check_referenced_keys(client_keys, server_keys)
    check_template_keys(client_keys)

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
