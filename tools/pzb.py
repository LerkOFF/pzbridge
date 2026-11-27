#!/usr/bin/env python3
"""PZBridge: клиент файлового моста (CLI и библиотека для MCP-сервера).

Мод пишет и читает файлы в ~/Zomboid/Lua/:
  pzbridge_cmd.txt      - команды агента, по одной на строку: "<id> <tool> {json}"
  pzbridge_state.json   - состояние персонажа и мира (раз в секунду)
  pzbridge_results.json - результаты последних команд
  pzbridge_events.json  - журнал событий (убийства, находки, урон, alert...)
  pzbridge_inbox.txt    - сообщения игрока агенту из окна F9 (JSON на строку)
Этот модуль хранит отметки прочитанных сообщений в pzbridge_inbox_read.json.

Только стандартная библиотека Python 3.8+.

Примеры:
  pzb.py state
  pzb.py cmd "walk 10 20 0"
  pzb.py call move_to '{"x":10,"y":20,"z":0,"mode":"auto"}'
  pzb.py wait            # ждать результат последней команды
  pzb.py events --since 0
  pzb.py messages
  pzb.py reply "Иду за едой"
"""

import argparse
import json
import os
import re
import sys
import time

try:
    import fcntl  # noqa: F401  (нет на Windows)
except ImportError:  # pragma: no cover
    fcntl = None

LUA_DIR = os.path.expanduser(os.environ.get("PZBRIDGE_DIR", "~/Zomboid/Lua"))

F_CMD = "pzbridge_cmd.txt"
F_STATE = "pzbridge_state.json"
F_RESULTS = "pzbridge_results.json"
F_EVENTS = "pzbridge_events.json"
F_INBOX = "pzbridge_inbox.txt"
F_READ = "pzbridge_inbox_read.json"

FINAL = {"ok", "done", "error", "failed", "interrupted", "paused", "denied"}


def path(name):
    return os.path.join(LUA_DIR, name)


def read_json(name, default=None, retries=6):
    """Прочитать JSON-файл мода. Мод перезаписывает файлы целиком,
    поэтому при неудачном разборе (файл пишется прямо сейчас) повторяем."""
    p = path(name)
    for i in range(retries):
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = f.read()
            if not data.strip():
                raise ValueError("empty")
            return json.loads(data)
        except FileNotFoundError:
            return default
        except (ValueError, OSError):
            time.sleep(0.05 * (i + 1))
    return default


def state_age():
    """Сколько секунд назад мод обновлял state (None, если файла нет)."""
    try:
        return time.time() - os.path.getmtime(path(F_STATE))
    except OSError:
        return None


def game_alive(max_age=5.0):
    age = state_age()
    return age is not None and age <= max_age


# ---------------------------------------------------------------------------
# Команды
# ---------------------------------------------------------------------------

_LINE_ID = re.compile(r"^\s*(\d+)\s")


def _max_cmd_id():
    m = 0
    try:
        with open(path(F_CMD), "r", encoding="utf-8") as f:
            for line in f:
                mm = _LINE_ID.match(line)
                if mm:
                    m = max(m, int(mm.group(1)))
    except FileNotFoundError:
        pass
    for name in (F_STATE, F_RESULTS):
        d = read_json(name, {}) or {}
        try:
            m = max(m, int(d.get("last_cmd_id") or 0))
        except (TypeError, ValueError):
            pass
    return m


def _maybe_compact(f, max_lines=300):
    """Обрезать файл команд, если он длинный и мод уже прочитал все строки.
    Мод помнит последний id в памяти, поэтому старые строки ему не нужны."""
    try:
        f.seek(0)
        lines = f.readlines()
    except OSError:
        return
    if len(lines) < max_lines or not game_alive():
        return
    st = read_json(F_STATE, {}) or {}
    done = int(st.get("last_cmd_id") or 0)
    ids = [int(m.group(1)) for m in (_LINE_ID.match(x) for x in lines) if m]
    if ids and max(ids) <= done:
        f.seek(0)
        f.truncate()


def send_line(body):
    """Дописать команду. body: "tool {json}" или "tool a b c". Возвращает id."""
    body = body.strip().replace("\n", " ")
    os.makedirs(LUA_DIR, exist_ok=True)
    with open(path(F_CMD), "a+", encoding="utf-8") as f:
        if fcntl:
            fcntl.flock(f, fcntl.LOCK_EX)
        try:
            cid = _max_cmd_id() + 1
            _maybe_compact(f)
            f.seek(0, os.SEEK_END)
            f.write("%d %s\n" % (cid, body))
            f.flush()
        finally:
            if fcntl:
                fcntl.flock(f, fcntl.LOCK_UN)
    return cid


def send(tool, args=None):
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tool or ""):
        raise ValueError("bad tool name: %r" % tool)
    if args:
        return send_line("%s %s" % (tool, json.dumps(args, ensure_ascii=False, separators=(",", ":"))))
    return send_line(tool)


def get_result(cid):
    d = read_json(F_RESULTS, {}) or {}
    for r in d.get("results", []):
        if r.get("id") == cid:
            return r
    return None


def wait_result(cid, timeout=30.0, until_final=True, poll=0.2):
    """Ждать результат команды. until_final=False - вернуть, как только мод
    принял команду (status running или финальный)."""
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        r = get_result(cid)
        if r:
            last = r
            if r.get("status") in FINAL or (not until_final and r.get("status")):
                return r
        time.sleep(poll)
    if last:
        last = dict(last)
        last["timeout"] = True
        return last
    st = read_json(F_STATE, {}) or {}
    hint = "game not running" if not game_alive() else (
        "game is paused or command not yet read" if st.get("paused") else "no result yet")
    return {"id": cid, "status": "pending", "timeout": True, "hint": hint}


def call(tool, args=None, timeout=15.0, until_final=True):
    cid = send(tool, args)
    return wait_result(cid, timeout=timeout, until_final=until_final)


# ---------------------------------------------------------------------------
# События и сообщения игрока
# ---------------------------------------------------------------------------

def get_events(since=0, types=None, limit=100):
    d = read_json(F_EVENTS, {}) or {}
    evs = d.get("events", [])
    out = [e for e in evs if int(e.get("seq", 0)) > int(since or 0)]
    if types:
        ts = set(types)
        out = [e for e in out if e.get("type") in ts]
    return {"session": d.get("session"), "cursor": d.get("seq", 0), "events": out[-limit:]}


def _read_marks():
    try:
        with open(path(F_READ), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"last_read_id": 0}


def _write_marks(m):
    with open(path(F_READ), "w", encoding="utf-8") as f:
        json.dump(m, f)


def get_messages(mark_read=True, include_read=False, limit=50):
    msgs = []
    try:
        with open(path(F_INBOX), "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msgs.append(json.loads(line))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    marks = _read_marks()
    last = int(marks.get("last_read_id", 0))
    for m in msgs:
        m["read"] = int(m.get("id", 0)) <= last
    out = msgs if include_read else [m for m in msgs if not m["read"]]
    out = out[-limit:]
    if mark_read and msgs:
        newest = max(int(m.get("id", 0)) for m in msgs)
        if newest > last:
            marks["last_read_id"] = newest
            _write_marks(marks)
    st = read_json(F_STATE, {}) or {}
    return {"access": st.get("access"), "messages": out, "unread_count": len([m for m in msgs if not m["read"]])}


# ---------------------------------------------------------------------------
# Ожидание условий
# ---------------------------------------------------------------------------

_STAT_RE = re.compile(r"^stat:([a-z_]+)\s*(<=|>=|<|>|==)\s*([-0-9.]+)$")


def _check(cond, st, ev_since):
    if cond in ("action_done", "idle"):
        # state должен уже отражать последнюю отправленную команду,
        # иначе свежая задача ещё не видна в файле
        last = _max_cmd_id()
        if int(st.get("last_cmd_id") or 0) < last:
            return False
        r = get_result(last)
        if r and r.get("status") not in FINAL:
            return False
        return not st.get("job") and not st.get("busy")
    if cond == "message":
        return get_messages(mark_read=False)["unread_count"] > 0
    if cond.startswith("event:"):
        t = cond.split(":", 1)[1]
        return len(get_events(ev_since, [t])["events"]) > 0
    if cond.startswith("zombie_within:"):
        r = float(cond.split(":", 1)[1])
        d = (st.get("threat") or {}).get("nearest_dist")
        return d is not None and d <= r
    if cond.startswith("result:"):
        r = get_result(int(cond.split(":", 1)[1]))
        return bool(r and r.get("status") in FINAL)
    m = _STAT_RE.match(cond)
    if m:
        name, op, val = m.group(1), m.group(2), float(m.group(3))
        v = (st.get("stats") or {}).get(name)
        if v is None:
            v = (st.get("body") or {}).get(name)
        if v is None:
            return False
        return {"<": v < val, ">": v > val, "<=": v <= val, ">=": v >= val, "==": v == val}[op]
    raise ValueError("unknown condition: %s" % cond)


def wait_for(condition, timeout=60.0, poll=0.3):
    """condition: action_done | idle | message | event:<type> | zombie_within:<R> |
    result:<id> | stat:<name><op><value>. Можно несколько через '|' (любое)."""
    conds = [c.strip() for c in condition.split("|") if c.strip()]
    ev0 = (read_json(F_EVENTS, {}) or {}).get("seq", 0)
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = read_json(F_STATE, {}) or {}
        for c in conds:
            if _check(c, st, ev0):
                return {"met": c, "waited_s": round(time.time() - t0, 1), "state": summary(st),
                        "events": get_events(ev0)["events"]}
        time.sleep(poll)
    st = read_json(F_STATE, {}) or {}
    return {"met": None, "timeout": True, "waited_s": round(time.time() - t0, 1), "state": summary(st),
            "events": get_events(ev0)["events"], "game_alive": game_alive()}


# ---------------------------------------------------------------------------
# Краткая выжимка state
# ---------------------------------------------------------------------------

def summary(st):
    if not st:
        return {"error": "no state file: the game is not running or the mod is not enabled"}
    p = st.get("player") or {}
    out = {
        "access": st.get("access"),
        "paused": st.get("paused"),
        "time": st.get("time"),
        "pos": [p.get("x"), p.get("y"), p.get("z")],
        "indoors": p.get("indoors"),
        "building": p.get("building"),
        "room": p.get("room"),
        "health": (st.get("body") or {}).get("health"),
        "wounds": (st.get("body") or {}).get("wounds"),
        "stats": st.get("stats"),
        "moodles": st.get("moodles"),
        "hands": {k: (v or {}).get("name") for k, v in (st.get("hands") or {}).items() if isinstance(v, dict)},
        "weight": st.get("weight"),
        "threat": st.get("threat"),
        "nearest_zombies": (st.get("zombies") or [])[:5],
        "busy": st.get("busy"),
        "job": st.get("job"),
        "paused_job": st.get("paused_job"),
        "alert": st.get("alert"),
        "last_cmd": st.get("last_cmd"),
        "last_error": st.get("last_error"),
        "events_seq": st.get("events_seq"),
        "inbox_last_id": st.get("inbox_last_id"),
        "kills": p.get("kills"),
        "state_age_s": round(state_age() or -1, 1),
    }
    return out


def print_state(st):
    s = summary(st)
    if "error" in s:
        print(s["error"])
        return
    t = s["time"] or {}
    print("доступ: %s   пауза: %s   время: %s.%s %s:%02d" % (
        "да" if s["access"] else "НЕТ", "да" if s["paused"] else "нет",
        t.get("day"), t.get("month"), t.get("hour"), int(t.get("minute") or 0)))
    print("позиция: %s  в здании: %s  комната: %s" % (s["pos"], s["building"], s["room"]))
    print("здоровье: %s  раны: %s" % (s["health"], len(s["wounds"] or [])))
    stats = s["stats"] or {}
    print("голод %.2f  жажда %.2f  усталость %.2f  выносливость %.2f  паника %.2f" % tuple(
        float(stats.get(k) or 0) for k in ("hunger", "thirst", "fatigue", "endurance", "panic")))
    print("в руках: %s   вес: %s" % (s["hands"], s["weight"]))
    th = s["threat"] or {}
    print("угроза: %s, зомби в 15 кл.: %s, ближайший: %s, видят: %s" % (
        th.get("level"), th.get("count"), th.get("nearest_dist"), th.get("seeing")))
    print("задача: %s   занят: %s" % ((s["job"] or {}).get("name"), s["busy"]))
    if s["alert"]:
        print("ALERT: %s" % json.dumps(s["alert"], ensure_ascii=False))
    print("последняя команда: %s" % json.dumps(s["last_cmd"], ensure_ascii=False))
    print("state обновлён %s с назад" % s["state_age_s"])


def _dump(x):
    print(json.dumps(x, ensure_ascii=False, indent=2))


def main(argv=None):
    ap = argparse.ArgumentParser(description="PZBridge CLI")
    sub = ap.add_subparsers(dest="op", required=True)
    s = sub.add_parser("state", help="выжимка состояния")
    s.add_argument("--json", action="store_true", help="полный state как есть")
    c = sub.add_parser("cmd", help='команда строкой: "walk 10 20 0"')
    c.add_argument("line")
    c.add_argument("--wait", type=float, default=0, help="ждать результат N секунд")
    k = sub.add_parser("call", help="инструмент с JSON-аргументами")
    k.add_argument("tool")
    k.add_argument("args", nargs="?", default="{}")
    k.add_argument("--wait", type=float, default=15)
    w = sub.add_parser("wait", help="ждать результат команды (по умолчанию последней)")
    w.add_argument("id", nargs="?", type=int)
    w.add_argument("--timeout", type=float, default=60)
    r = sub.add_parser("result", help="результат команды")
    r.add_argument("id", type=int)
    e = sub.add_parser("events", help="журнал событий")
    e.add_argument("--since", type=int, default=0)
    m = sub.add_parser("messages", help="сообщения игрока")
    m.add_argument("--all", action="store_true")
    m.add_argument("--keep", action="store_true", help="не отмечать прочитанными")
    rp = sub.add_parser("reply", help="ответить игроку")
    rp.add_argument("text")
    wf = sub.add_parser("waitfor", help="ждать условие")
    wf.add_argument("condition")
    wf.add_argument("--timeout", type=float, default=60)
    sub.add_parser("stop", help="остановить всё")
    a = ap.parse_args(argv)

    if a.op == "state":
        st = read_json(F_STATE)
        if a.json:
            _dump(st)
        else:
            print_state(st)
    elif a.op == "cmd":
        cid = send_line(a.line)
        print(cid)
        if a.wait:
            _dump(wait_result(cid, a.wait))
    elif a.op == "call":
        args = json.loads(a.args) if a.args else {}
        cid = send(a.tool, args)
        print(cid, file=sys.stderr)
        _dump(wait_result(cid, a.wait))
    elif a.op == "wait":
        cid = a.id or _max_cmd_id()
        _dump(wait_result(cid, a.timeout))
    elif a.op == "result":
        _dump(get_result(a.id))
    elif a.op == "events":
        _dump(get_events(a.since))
    elif a.op == "messages":
        _dump(get_messages(mark_read=not a.keep, include_read=a.all))
    elif a.op == "reply":
        _dump(call("reply", {"text": a.text}))
    elif a.op == "waitfor":
        _dump(wait_for(a.condition, a.timeout))
    elif a.op == "stop":
        _dump(call("stop"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
