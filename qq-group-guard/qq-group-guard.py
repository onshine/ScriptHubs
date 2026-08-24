#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
QQ 群名片守卫 · Python 版  R1.0.3

对上传的 group_kick.py 的重写版本：
  1. 自包含 —— 不再依赖 group_member_check.py，检查 + 踢人一体
  2. 宽容模式 —— 观察期 / 连续多轮 / 群内 @ 提醒 / 单轮上限 / 比例熔断 / 多重豁免
  3. 全部参数可从环境变量、配置文件、命令行三处读取（优先级：命令行 > 配置文件 > 环境变量）

仓库：https://github.com/onshine/ScriptHubs/tree/main/qq-group-guard

用法：
  qq-group-guard --group 123456789 --keywords "深圳,SZ" --mode report      # 只报告
  qq-group-guard --group 123456789 --mode lenient                          # 宽容模式（默认）
  qq-group-guard --config /etc/qq-group-guard/config.json                   # 读配置文件
  qq-group-guard --group 123456789 --mode strict --yes                      # 严格模式免确认
"""

import argparse
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_VERSION = "R1.0.3"

DEFAULT_CONFIG_PATHS = [
    Path(os.environ.get("QGG_CONFIG", "")) if os.environ.get("QGG_CONFIG") else None,
    Path("/etc/qq-group-guard/config.json"),
    Path.home() / ".config/qq-group-guard/config.json",
    Path(__file__).with_name("config.json"),
]

DEFAULTS = {
    "api_base": "http://127.0.0.1:5700",
    "token": "",
    "group_id": [],
    "keywords": [],
    "mode": "lenient",          # report | lenient | strict
    "grace_hours": 48,
    "grace_rounds": 2,
    "new_member_days": 3,
    "veteran_days": 0,
    "whitelist": [],
    "skip_admin": True,
    "skip_title": True,
    "self_qq": 0,
    "interval": 1.5,
    "max_kick": 5,
    "max_ratio": 30,
    "breaker_min": 5,
    "reject_add": False,
    "warn_in_group": True,
    "warn_template": "请在 {hours} 小时内把群名片改成含「{keywords}」的格式，否则将被移出本群。",
    "timeout": 20,
    "state_dir": "/var/lib/qq-group-guard",
    "log_dir": "/var/log/qq-group-guard",
}

BOOL_KEYS = {"skip_admin", "skip_title", "reject_add", "warn_in_group"}
INT_KEYS = {"grace_rounds", "self_qq", "max_kick", "timeout", "breaker_min"}
FLOAT_KEYS = {"grace_hours", "new_member_days", "veteran_days", "interval", "max_ratio"}
LIST_KEYS = {"group_id", "keywords", "whitelist"}

STRIP_RE = re.compile(
    r"[\s\-_|/\\.,:;'\"`~!@#$%^&*+=?<>\[\]{}()【】〔〕《》「」『』·、。，！？—–\u200b-\u200d\ufeff]"
)


# ─────────────────────────── 工具 ───────────────────────────
def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def to_bool(v, dft=False) -> bool:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if not s:
        return dft
    return s in ("1", "true", "yes", "y", "on")


def to_list(v):
    if isinstance(v, (list, tuple)):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in re.split(r"[,，\s]+", str(v or "")) if x.strip()]


def norm(s: str) -> str:
    """全角转半角 + 去大小写 + 去空白与常见装饰符号，用于模糊匹配。"""
    t = unicodedata.normalize("NFKC", str(s or "")).lower()
    return STRIP_RE.sub("", t)


def fmt_duration(seconds: float) -> str:
    seconds = int(max(0, seconds))
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def render_bar(done: int, total: int, width: int = 30, extra: str = "") -> str:
    ratio = done / total if total else 1.0
    filled = int(width * ratio)
    if filled == 0:
        bar = ""
    elif filled >= width:
        bar = "=" * width
    else:
        bar = "=" * (filled - 1) + ">"
    return f"[{bar.ljust(width)}] {done}/{total} {ratio * 100:5.1f}%  {extra}"


# ─────────────────────── 配置加载 ───────────────────────────
def load_config(cli_config: str = "") -> dict:
    cfg = dict(DEFAULTS)

    # 1) 环境变量 QGG_*
    for key in DEFAULTS:
        env = os.environ.get("QGG_" + key.upper())
        if env not in (None, ""):
            cfg[key] = env

    # 2) 配置文件
    paths = [Path(cli_config)] if cli_config else [p for p in DEFAULT_CONFIG_PATHS if p]
    for p in paths:
        try:
            if p and p.is_file():
                cfg.update(json.loads(p.read_text(encoding="utf-8")))
                cfg["_config_file"] = str(p)
                break
        except Exception as e:  # noqa: BLE001
            log(f"⚠️ 配置文件 {p} 解析失败：{e}")
    return cfg


def coerce(cfg: dict) -> dict:
    for k in LIST_KEYS:
        cfg[k] = to_list(cfg.get(k))
    cfg["group_id"] = [int(x) for x in cfg["group_id"] if str(x).isdigit()]
    cfg["whitelist"] = [int(x) for x in cfg["whitelist"] if str(x).isdigit()]
    for k in BOOL_KEYS:
        cfg[k] = to_bool(cfg.get(k), DEFAULTS[k])
    for k in INT_KEYS:
        try:
            cfg[k] = int(float(cfg.get(k, DEFAULTS[k])))
        except (TypeError, ValueError):
            cfg[k] = DEFAULTS[k]
    for k in FLOAT_KEYS:
        try:
            cfg[k] = float(cfg.get(k, DEFAULTS[k]))
        except (TypeError, ValueError):
            cfg[k] = DEFAULTS[k]
    m = str(cfg.get("mode", "lenient")).strip().lower()
    cfg["mode"] = m if m in ("report", "lenient", "strict") else "lenient"
    cfg["api_base"] = str(cfg.get("api_base", "")).strip().rstrip("/")
    cfg["grace_rounds"] = max(1, cfg["grace_rounds"])
    return cfg


# ─────────────────────── OneBot 客户端 ──────────────────────
class OneBot:
    def __init__(self, base: str, token: str = "", timeout: int = 20):
        self.base = base.rstrip("/")
        self.token = token
        self.timeout = timeout

    def call(self, action: str, params: dict = None):
        data = json.dumps(params or {}, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(f"{self.base}/{action}", data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"HTTP {e.code}") from e
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(str(e)) from e

        try:
            j = json.loads(body)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"响应非 JSON：{body[:120]}") from e

        if str(j.get("status", "")) == "failed":
            raise RuntimeError(j.get("wording") or j.get("msg") or f"retcode {j.get('retcode')}")
        return j.get("data")


# ─────────────────────── 业务逻辑 ───────────────────────────
def display_name(m: dict) -> str:
    return (m.get("card") or "").strip() or (m.get("nickname") or "").strip()


def soft_norm(s: str) -> str:
    """仅做 NFKC 全角转半角 + 转小写，保留分隔符与数字，供 re: 正则匹配用。

    普通关键词走 norm()（去掉所有符号），但正则往往依赖 _ - 数字等结构，
    不能去符号；又不能不做全角转换，否则「ＧＩＴＨＵＢ_６６６」会被误伤。
    """
    return unicodedata.normalize("NFKC", str(s or ""))


def is_compliant(name: str, keywords) -> bool:
    n = norm(name)
    if not n:
        return False  # 空名片视为不合规
    soft = soft_norm(name)
    for kw in keywords:
        if kw.lower().startswith("re:"):
            pat = kw[3:]
            try:
                # 原始名片与全角归一化后各匹配一次，避免全角写法被误杀
                if re.search(pat, name, re.I) or re.search(pat, soft, re.I):
                    return True
            except re.error:
                continue
            continue
        k = norm(kw)
        if k and k in n:
            return True
    return False


def exempt_reason(m: dict, uid: int, now: int, cfg: dict) -> str:
    if cfg["self_qq"] and uid == cfg["self_qq"]:
        return "机器人自己"
    if uid in cfg["whitelist"]:
        return "白名单"
    if cfg["skip_admin"] and m.get("role") in ("owner", "admin"):
        return "群主/管理员"
    if cfg["skip_title"] and str(m.get("title") or "").strip():
        return "有专属头衔"
    join = int(m.get("join_time") or 0)
    if join > 0:
        days = (now - join) / 86400
        if cfg["new_member_days"] > 0 and days < cfg["new_member_days"]:
            return f"新人保护期（入群 {days:.1f} 天）"
        if cfg["veteran_days"] > 0 and days >= cfg["veteran_days"]:
            return f"老成员保护（入群 {days:.0f} 天）"
    return ""


def state_file(cfg: dict, gid: int) -> Path:
    d = Path(cfg["state_dir"])
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError:
        d = Path.home() / ".local/share/qq-group-guard"
        d.mkdir(parents=True, exist_ok=True)
    return d / f"pending_{gid}.json"


def load_pending(cfg: dict, gid: int) -> dict:
    f = state_file(cfg, gid)
    if not f.is_file():
        return {}
    try:
        o = json.loads(f.read_text(encoding="utf-8"))
        return o if isinstance(o, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def save_pending(cfg: dict, gid: int, obj: dict) -> None:
    state_file(cfg, gid).write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")


def render_warn(cfg: dict) -> str:
    return (
        cfg["warn_template"]
        .replace("{hours}", str(int(cfg["grace_hours"])))
        .replace("{rounds}", str(cfg["grace_rounds"]))
        .replace("{keywords}", " / ".join(cfg["keywords"]))
    )


def patrol(bot: OneBot, gid: int, cfg: dict, assume_yes: bool) -> dict:
    log(f"===== 群 {gid} =====")
    members = bot.call("get_group_member_list", {"group_id": gid}) or []
    if not members:
        log("⚠️ 成员列表为空，接口异常或无权限")
        return {"group_id": gid, "error": "empty member list"}

    now = int(time.time())
    pending = load_pending(cfg, gid)
    next_pending, violators, exempt = {}, [], []

    for m in members:
        uid = int(m.get("user_id") or 0)
        if not uid:
            continue
        name = display_name(m)
        if is_compliant(name, cfg["keywords"]):
            continue
        why = exempt_reason(m, uid, now, cfg)
        if why:
            exempt.append({"user_id": uid, "display_name": name, "reason": why})
            continue
        violators.append(
            {"user_id": uid, "display_name": name, "role": m.get("role", "member"),
             "join_time": int(m.get("join_time") or 0)}
        )

    log(f"成员 {len(members)} 人 · 不合规 {len(violators)} 人 · 豁免 {len(exempt)} 人")
    for e in exempt:
        log(f"  豁免 {e['user_id']}  {e['display_name']}  -> {e['reason']}")

    if not violators:
        save_pending(cfg, gid, {})
        log("✅ 全部合规")
        return {"group_id": gid, "total": len(members), "violators": 0, "kicked": [], "failed": []}

    ratio = len(violators) / len(members) * 100
    # 熔断需同时满足：比例超阈值 且 人数达到下限（避免小群 3/10 就误触发）
    if cfg["max_ratio"] > 0 and ratio > cfg["max_ratio"] and len(violators) >= cfg["breaker_min"]:
        log(f"🛑 不合规占比 {ratio:.1f}%（{len(violators)} 人）超过熔断阈值 {cfg['max_ratio']}%，中止踢人")
        log("   请检查 keywords 是否配置正确")
        return {"group_id": gid, "total": len(members), "violators": len(violators),
                "aborted": "ratio_breaker", "ratio": round(ratio, 1), "kicked": [], "failed": []}

    if cfg["mode"] == "report":
        log("👀 report 模式，仅报告不执行：")
        for v in violators:
            log(f"   {v['user_id']}  {v['display_name']}")
        return {"group_id": gid, "total": len(members), "mode": "report",
                "violators": len(violators), "list": violators, "kicked": [], "failed": []}

    to_kick, watching = [], []
    for v in violators:
        if cfg["mode"] == "strict":
            to_kick.append({**v, "rounds": 1, "hours": 0.0})
            continue
        old = pending.get(str(v["user_id"])) or {}
        first = int(old.get("first") or now)
        rounds = int(old.get("rounds") or 0) + 1
        hours = (now - first) / 3600
        if rounds >= cfg["grace_rounds"] and hours >= cfg["grace_hours"]:
            to_kick.append({**v, "rounds": rounds, "hours": hours})
        else:
            next_pending[str(v["user_id"])] = {"first": first, "rounds": rounds, "name": v["display_name"]}
            watching.append({**v, "rounds": rounds, "hours": hours})

    if watching:
        log(f"⏳ 观察期 {len(watching)} 人（需满 {cfg['grace_rounds']} 轮且 {cfg['grace_hours']}h）：")
        for v in watching:
            log(f"   {v['user_id']}  {v['display_name']}  第{v['rounds']}轮/{v['hours']:.1f}h")
        if cfg["warn_in_group"]:
            at = " ".join(f"[CQ:at,qq={v['user_id']}]" for v in watching[:10])
            try:
                bot.call("send_group_msg", {"group_id": gid, "message": f"{at} {render_warn(cfg)}"})
                log("   已在群内 @ 提醒改名")
            except RuntimeError as e:
                log(f"   ⚠️ 提醒发送失败：{e}")

    if not to_kick:
        save_pending(cfg, gid, next_pending)
        log("🤝 本轮无人到期，未踢任何人")
        return {"group_id": gid, "total": len(members), "violators": len(violators),
                "watching": len(watching), "kicked": [], "failed": []}

    batch = to_kick
    if cfg["max_kick"] > 0 and len(batch) > cfg["max_kick"]:
        defer = batch[cfg["max_kick"]:]
        batch = batch[: cfg["max_kick"]]
        for v in defer:
            next_pending[str(v["user_id"])] = {
                "first": now - int(cfg["grace_hours"] * 3600),
                "rounds": v["rounds"], "name": v["display_name"],
            }
        log(f"🔒 单轮上限 {cfg['max_kick']} 人，其余 {len(defer)} 人下轮继续")

    log(f"\n{'=' * 70}")
    log(f"群号 {gid} · 模式 {cfg['mode']} · 本轮待踢 {len(batch)} 人 · 间隔 {cfg['interval']}s")
    for v in batch:
        log(f"   {v['user_id']}  {v['display_name']}")
    log(f"{'=' * 70}")

    if not assume_yes:
        if not sys.stdin.isatty():
            log("非交互环境且未加 --yes，安全起见不执行。")
            save_pending(cfg, gid, next_pending)
            return {"group_id": gid, "aborted": "need_confirm", "kicked": [], "failed": []}
        print("\n此操作不可撤销。确认要踢出以上成员吗？")
        if input("输入 yes 继续，其它任意键取消: ").strip().lower() != "yes":
            log("已取消，未执行任何操作。")
            save_pending(cfg, gid, next_pending)
            return {"group_id": gid, "aborted": "user_cancel", "kicked": [], "failed": []}

    started = time.monotonic()
    ok, failed = [], []
    for idx, v in enumerate(batch, 1):
        try:
            bot.call("set_group_kick", {"group_id": gid, "user_id": v["user_id"],
                                        "reject_add_request": cfg["reject_add"]})
            ok.append(v)
            status = f"OK   {v['user_id']}  {v['display_name']}"
        except RuntimeError as e:
            failed.append({**v, "error": str(e)})
            next_pending[str(v["user_id"])] = {
                "first": now - int(cfg["grace_hours"] * 3600),
                "rounds": v["rounds"], "name": v["display_name"],
            }
            status = f"FAIL {v['user_id']}  {v['display_name']}  -> {e}"
        except KeyboardInterrupt:
            log("\n!! 被 Ctrl+C 中断")
            break

        remaining = len(batch) - idx
        elapsed = time.monotonic() - started
        avg_api = max(0.0, elapsed - cfg["interval"] * (idx - 1)) / idx
        eta = remaining * (avg_api + cfg["interval"])
        print(f"\r{' ' * 100}\r{status}")
        print(render_bar(idx, len(batch), extra=f"ETA {fmt_duration(eta)}"), end="", flush=True)

        if idx < len(batch) and cfg["interval"] > 0:
            try:
                time.sleep(cfg["interval"])
            except KeyboardInterrupt:
                log("\n!! 被 Ctrl+C 中断")
                break
    print()

    save_pending(cfg, gid, next_pending)
    log(f"🚪 已踢出 {len(ok)} 人 · 失败 {len(failed)} 人 · 耗时 {fmt_duration(time.monotonic() - started)}")
    for f in failed:
        log(f"   ✘ {f['user_id']}  {f['display_name']}  -> {f['error']}")

    return {"group_id": gid, "total": len(members), "violators": len(violators),
            "watching": len(watching), "kicked": ok, "failed": failed}


# ─────────────────────────── CLI ────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="qq-group-guard",
        description=f"QQ 群名片守卫 {SCRIPT_VERSION} — 宽容模式的名片合规巡检与踢人",
    )
    p.add_argument("--config", default="", help="配置文件路径（默认自动搜索）")
    p.add_argument("-g", "--group", dest="group_id", help="群号，多个用英文逗号分隔")
    p.add_argument("-k", "--keywords", help="合规关键词，多个用英文逗号分隔；re: 前缀表示正则")
    p.add_argument("-m", "--mode", choices=["report", "lenient", "strict"], help="运行模式")
    p.add_argument("--api-base", dest="api_base", help="OneBot HTTP 地址，如 http://127.0.0.1:5700")
    p.add_argument("--token", help="OneBot access_token")
    p.add_argument("--grace-hours", dest="grace_hours", type=float, help="观察期小时数")
    p.add_argument("--grace-rounds", dest="grace_rounds", type=int, help="连续命中轮数")
    p.add_argument("--new-member-days", dest="new_member_days", type=float, help="新人保护天数")
    p.add_argument("--veteran-days", dest="veteran_days", type=float, help="老成员保护天数，0 关闭")
    p.add_argument("--whitelist", help="永不处理的 QQ 号，逗号分隔")
    p.add_argument("--self-qq", dest="self_qq", type=int, help="机器人自身 QQ")
    p.add_argument("-i", "--interval", type=float, help="踢人间隔秒数")
    p.add_argument("--max-kick", dest="max_kick", type=int, help="单轮最多踢几人，0 不限")
    p.add_argument("--max-ratio", dest="max_ratio", type=float, help="不合规比例熔断阈值(%%)，0 关闭")
    p.add_argument("--breaker-min", dest="breaker_min", type=int,
                   help="熔断同时要求的最少不合规人数（默认 5，避免小群误触发）")
    p.add_argument("--reject-add", dest="reject_add", action="store_true", help="同时拒绝其再次加群")
    p.add_argument("--no-warn", dest="warn_in_group", action="store_false", default=None,
                   help="观察期不在群内 @ 提醒")
    p.add_argument("--no-skip-admin", dest="skip_admin", action="store_false", default=None,
                   help="不豁免群主/管理员（危险）")
    p.add_argument("--timeout", type=int, help="HTTP 超时秒数")
    p.add_argument("--json", dest="json_out", default="", help="把结果写入指定 JSON 文件")
    p.add_argument("-y", "--yes", action="store_true", help="跳过人工确认（定时任务必加）")
    p.add_argument("-V", "--version", action="version", version=f"qq-group-guard {SCRIPT_VERSION}")
    return p


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

    args = build_parser().parse_args()
    cfg = load_config(args.config)

    # 命令行覆盖
    for key in ("group_id", "keywords", "mode", "api_base", "token", "grace_hours",
                "grace_rounds", "new_member_days", "veteran_days", "whitelist",
                "self_qq", "interval", "max_kick", "max_ratio", "timeout", "breaker_min"):
        val = getattr(args, key, None)
        if val not in (None, ""):
            cfg[key] = val
    if args.reject_add:
        cfg["reject_add"] = True
    if args.warn_in_group is False:
        cfg["warn_in_group"] = False
    if args.skip_admin is False:
        cfg["skip_admin"] = False

    cfg = coerce(cfg)

    log(f"qq-group-guard {SCRIPT_VERSION} · 模式 {cfg['mode']}")
    if cfg.get("_config_file"):
        log(f"配置文件：{cfg['_config_file']}")

    if not cfg["api_base"].startswith(("http://", "https://")):
        log(f"❌ api_base 无效：{cfg['api_base']}")
        return 2
    if not cfg["group_id"]:
        log("❌ 未配置 group_id")
        return 2
    if not cfg["keywords"]:
        log("❌ 未配置 keywords。为防止清群事故，关键词为空时拒绝运行。")
        return 2

    log(f"关键词：{' / '.join(cfg['keywords'])}")
    bot = OneBot(cfg["api_base"], cfg["token"], cfg["timeout"])

    results = []
    for gid in cfg["group_id"]:
        try:
            results.append(patrol(bot, gid, cfg, args.yes))
        except RuntimeError as e:
            log(f"❌ 群 {gid} 处理失败：{e}")
            results.append({"group_id": gid, "error": str(e)})

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps({"version": SCRIPT_VERSION, "mode": cfg["mode"], "ts": int(time.time()),
                        "results": results}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        log(f"结果已写入 {args.json_out}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已取消。")
        sys.exit(130)
