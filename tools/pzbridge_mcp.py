#!/usr/bin/env python3
"""PZBridge MCP server: stdio, JSON-RPC 2.0, протокол Model Context Protocol.

Работает поверх тех же файлов, что и pzb.py (~/Zomboid/Lua/ или PZBRIDGE_DIR).
Только стандартная библиотека Python 3.8+.

Запуск: python3 pzbridge_mcp.py
"""

import json
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pzb  # noqa: E402

SERVER_NAME = "pzbridge"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2025-06-18"

# ---------------------------------------------------------------------------
# Плейбук для агента (instructions, prompt и resource)
# ---------------------------------------------------------------------------

PLAYBOOK = """You control a Project Zomboid (build 42) single-player character through the PZBridge mod.
The game runs in real time; you think slowly, so long behaviours (walking, searching, fighting,
fleeing) run inside the mod as loops, and you orchestrate them with small tool calls.

ALWAYS START with get_player_messages. If access=false, call reply_to_player asking the player to
press F9 in game and tick "Allow control" ("Разрешить управление"); until then every game action is denied.

Main loop:
1. get_player_messages -> understand what the player wants (messages are usually in Russian;
   answer in the player's language).
2. Perceive: get_state (short summary), scan_zombies, scan_area, find_items, get_building.
3. Act with primitives: move_to, search, take, use, drink_from, equip, fight, flee, open/close,
   barricade, sleep, ... Action tools return a cmd_id with status "running".
4. Follow up with wait_for_result(cmd_id) or wait_for("action_done|event:alert|zombie_within:6")
   and get_events(since=cursor) to see kills, found items, damage, bites, alerts, guard retreats.
5. reply_to_player with progress and the result. Keep replies short.

Safety: the mod has a global guard. With autopause on (default) the game pauses when a zombie
comes closer than pause_distance (6) and an "alert" event appears; decide (fight, flee, move away)
and call unpause. move_to/search are interrupted with status "interrupted" when a zombie sees the
player or comes within danger_radius; fight retreats and ends with status "paused" when health,
bleeding, endurance or crowd thresholds are crossed (call resume to continue or stop).
If the player presses Stop or disables access, everything stops.

Statuses: running (in progress), ok/done (success), failed, error, interrupted, paused, denied (no access).
Messages in results, events and state (job.step) are in English; item names come from the game
in its language. The mod shows its own notes to the player in the game language. Text you send
(reply_to_player, say) may be in any language: non-ASCII is escaped as \\uXXXX automatically.

Recipes (compose them yourself; there are no hard-coded quests):
- "Find food": find_items(filter={"category":"food"}, where="all") -> if nothing, search(scope="building",
  filter={"category":"food"}, stop_on_first=true) (without target it takes the current or nearest
  unvisited building) -> take(item_id=<found id>, from=<container id>) -> reply_to_player("Нашёл еду: <name>").
  If nothing: search the next building or reply that there is no food nearby.
- "I'm thirsty": find_items(filter={"category":"water_clean"}) and filter "drink"; if found in inventory
  use(how="drink"); in a container take then use; otherwise scan_area(only=["water"]) and drink_from a
  source with clean=true. Mention dirty sources (clean=false) as a fallback: they need boiling.
- "Kill 10 zombies": fight(until="kills:10") -> poll get_events for fight_progress and kill events, relay
  progress in the player's language (events say "killed 3/10"); on status paused (guard retreat) report the reason and ask the player
  whether to resume. The mod keeps fighting while zombies still chase the player after the goal.
- "Barricade the house": scan_area(only=["windows","doors"]) -> for each window: barricade(x,y,z)
  (needs hammer, planks, 2 nails each) -> report what was done and what is missing.
- "Go home": get_places -> move_to(place="home"). Use mark_place to remember places.
Coordinates are world tiles (x, y, z = floor level). Container ids look like "x,y,z,objIndex,containerIndex".
"""

# ---------------------------------------------------------------------------
# Схемы
# ---------------------------------------------------------------------------

FILTER = {
    "type": "object",
    "description": ("Item filter. category: food, drink, water_clean, water_dirty, weapon, firearm, medical, tool, "
                    "clothing, ammo, container, literature, water_container, any. Other fields narrow it down."),
    "properties": {
        "category": {"type": "string"},
        "fullType": {"type": "string", "description": "e.g. Base.Hammer"},
        "name": {"type": "string", "description": "case-insensitive substring of name or fullType"},
        "tag": {"type": "string", "description": "ItemTag name, e.g. HAMMER"},
        "not_spoiled": {"type": "boolean", "description": "default true"},
        "no_cooking": {"type": "boolean", "description": "exclude raw cookable food"},
        "safe": {"type": "boolean", "description": "exclude poison, dangerous raw food, tainted water (default true)"},
        "min_condition": {"type": "number"},
        "firearms": {"type": "boolean"},
    },
}
XYZ = {
    "x": {"type": "number", "description": "world tile X"},
    "y": {"type": "number", "description": "world tile Y"},
    "z": {"type": "number", "description": "floor level (0 = ground); default: player's level"},
}
GUARD_PROPS = {
    "guard": {"type": "boolean", "description": "enable the safety guard for this call (default true)"},
    "hp_min": {"type": "number", "description": "retreat below this overall health 0..100 (default 45)"},
    "bleeding_max": {"type": "number", "description": "retreat if more body parts bleed (default 1)"},
    "endurance_min": {"type": "number", "description": "retreat below this endurance 0..1 (default 0.25)"},
    "crowd_max": {"type": "number", "description": "retreat if more zombies within crowd_radius (default 4)"},
    "crowd_radius": {"type": "number"},
    "threat_radius": {"type": "number", "description": "zombies within this radius count as a threat (15)"},
    "danger_radius": {"type": "number", "description": "closer than this = danger (5)"},
    "flee_distance": {"type": "number"},
}
MODE = {"type": "string", "enum": ["auto", "walk", "sneak", "run", "sprint"],
        "description": "auto: walk when no threat, sneak when zombies are near but unaware, run when seen"}
ITEM = {
    "item_id": {"type": "number", "description": "item id from get_state/find_items/search"},
    "filter": FILTER,
}


def obj(props=None, required=None):
    s = {"type": "object", "properties": props or {}}
    if required:
        s["required"] = required
    return s


def merge(*dicts):
    out = {}
    for d in dicts:
        out.update(d)
    return out


WAIT = {"wait": {"type": "number", "description": "seconds to wait for the final result (default 0: return as soon as the mod accepts)"}}

# (name, kind, description, schema). kind: query = wait for final result; action = returns cmd_id quickly.
GAME_TOOLS = [
    # --- perception
    ("scan_zombies", "query", "List live zombies around the player with distance, whether they target/see the player, are on the floor; also recently seen ones.",
     obj({"radius": {"type": "number", "description": "default 20, max 60"}})),
    ("scan_area", "query", "Survey the area: buildings (id, visited), rooms, doors, windows (open/locked/barricaded), containers (id, explored, visited), water sources (clean or tainted), floor items, beds, vehicles.",
     obj({"radius": {"type": "number", "description": "default 8, max 30"},
          "only": {"type": "array", "items": {"type": "string", "enum": ["doors", "windows", "containers", "water", "items", "beds", "buildings", "vehicles"]}},
          "with_items": {"type": "boolean", "description": "include item lists of explored containers"}})),
    ("find_items", "query", "Find items by filter in the inventory, in explored containers and on the floor nearby, or in remembered containers. Also returns unexplored containers nearby (use search to open them).",
     obj({"filter": FILTER, "where": {"type": "string", "enum": ["inventory", "nearby", "known", "all"]},
          "radius": {"type": "number"}, "limit": {"type": "number"}})),
    ("get_item", "query", "Details of one item by id (inventory or nearby).", obj({"id": {"type": "number"}}, ["id"])),
    ("get_building", "query", "Info about the current building or a building by id: rooms, containers count, visited flag.",
     obj({"id": {"type": "string"}})),
    ("get_places", "query", "Places remembered with mark_place (name, coordinates, distance).", obj()),
    ("get_guard", "query", "Current global guard settings.", obj()),
    # --- movement and loops inside the mod
    ("move_to", "action", "Walk to a tile (or a remembered place). Opens doors on the way, chooses walk/sneak/run by threat in auto mode. Interrupted (status interrupted, event guard) when a zombie sees the player or comes within danger_radius, unless guard=false.",
     obj(merge(XYZ, {"place": {"type": "string"}, "mode": MODE, "adjacent": {"type": "boolean", "description": "stop next to the tile"},
                     "flee_on_threat": {"type": "boolean"}, "open_doors": {"type": "boolean"}, "timeout": {"type": "number", "description": "seconds, default 300"}},
               GUARD_PROPS, WAIT))),
    ("move_rel", "action", "Walk by offset dx, dy tiles from the current position.",
     obj(merge({"dx": {"type": "number"}, "dy": {"type": "number"}, "mode": MODE}, GUARD_PROPS, WAIT), ["dx", "dy"])),
    ("flee", "action", "Run away from the nearest zombies (or from point x,y) by distance tiles.",
     obj(merge({"distance": {"type": "number"}, "mode": MODE, "x": {"type": "number"}, "y": {"type": "number"}}, WAIT))),
    ("search", "action", "Visit containers one by one, open them (loot is generated on first look, like in the loot window), remember contents, report matches as 'found' events. Result has found[] with item ids and container ids.",
     obj(merge({"scope": {"type": "string", "enum": ["container", "room", "building", "radius"], "description": "default building (current, or nearest unvisited)"},
                "target": {"type": "string", "description": "container id (scope=container) or building id"},
                "filter": FILTER, "stop_on_first": {"type": "boolean", "description": "default true when filter is set"},
                "radius": {"type": "number"}, "take": {"type": "boolean", "description": "take the first match into inventory"},
                "max_containers": {"type": "number"}, "include_visited": {"type": "boolean"}, "include_corpses": {"type": "boolean"},
                "mode": MODE}, GUARD_PROPS, WAIT))),
    ("fight", "action", "Melee combat loop: picks the best weapon, approaches, faces, attacks, finishes downed zombies. until: 'clear' (no zombies in radius), 'kills:N' (at least N kills AND nobody is still chasing the player), 'target:<zombie id>'. Guard retreats and ends with status paused (resume to continue). Firearms only with firearms=true.",
     obj(merge({"until": {"type": "string"}, "kills": {"type": "number", "description": "shortcut for until=kills:N"},
                "radius": {"type": "number", "description": "engage radius, default 10"},
                "seek_radius": {"type": "number", "description": "look for targets this far, default 35"},
                "weapon": {"type": "string", "description": "best | current | none | <item id>"},
                "firearms": {"type": "boolean"}, "attack_interval_ms": {"type": "number"}}, GUARD_PROPS, WAIT))),
    ("wait", "action", "Wait real seconds or game minutes (interrupted by danger unless interrupt_on_threat=false).",
     obj(merge({"seconds": {"type": "number"}, "game_minutes": {"type": "number"}, "interrupt_on_threat": {"type": "boolean"}}, WAIT))),
    ("face", "action", "Turn to face a tile.", obj({"x": {"type": "number"}, "y": {"type": "number"}}, ["x", "y"])),
    ("attack", "action", "Single melee swing at the nearest zombie in range (or at target id).", obj({"target": {"type": "number"}})),
    # --- items
    ("take", "action", "Take items into the inventory from a container (from=<container id>), from the floor (from='floor') or from anything nearby. Use item_id or filter; count for several.",
     obj(merge(ITEM, {"from": {"type": "string"}, "count": {"type": "number"}, "radius": {"type": "number"}}, WAIT))),
    ("drop", "action", "Drop an inventory item on the floor.", obj(merge(ITEM, WAIT))),
    ("transfer", "action", "Move an inventory item into a container: a world container id, the id of a bag in the inventory (state inventory items with bag=true), or \"inventory\" for the main inventory. Items inside bags have in_bag in state.", obj(merge(ITEM, {"to": {"type": "string", "description": "world container id, inventory bag item id, or inventory"}}, WAIT), ["to"])),
    ("equip", "action", "Equip an item in hands, or attach it to a hotbar slot: back (e.g. saucepan, pan, big weapon on the back) or belt.", obj(merge(ITEM, {"slot": {"type": "string", "enum": ["primary", "secondary", "both", "back", "belt"]}}, WAIT))),
    ("unequip", "action", "Unequip an item (or the primary hand item).", obj(merge(ITEM, {"slot": {"type": "string", "enum": ["primary", "secondary"]}}, WAIT))),
    ("wear", "action", "Wear clothing.", obj(merge(ITEM, WAIT))),
    ("use", "action", "Use an inventory item: how=eat | drink | read | pill | apply_bandage (part, e.g. Hand_L, else the worst wound). Without item_id/filter picks food/drink/bandage automatically.",
     obj(merge(ITEM, {"how": {"type": "string", "enum": ["eat", "drink", "read", "pill", "apply_bandage"]},
                      "part": {"type": "string"}, "percent": {"type": "number", "description": "portion 0..1, default 1"},
                      "allow_dirty": {"type": "boolean"}}, WAIT), ["how"])),
    ("drink_from", "action", "Drink from a world water source (sink, tub, cooler, well...). Without coordinates uses the nearest clean source. Refuses tainted water unless allow_dirty=true.",
     obj(merge(XYZ, {"radius": {"type": "number"}, "allow_dirty": {"type": "boolean"}}, WAIT))),
    ("fill", "action", "Fill a water container from a world source.",
     obj(merge(ITEM, XYZ, {"allow_dirty": {"type": "boolean"}}, WAIT))),
    # --- world objects
    ("open", "action", "Open a door or window at x,y,z (walks next to it).", obj(merge(XYZ, {"kind": {"type": "string", "enum": ["door", "window"]}}, WAIT), ["x", "y"])),
    ("close", "action", "Close a door or window.", obj(merge(XYZ, {"kind": {"type": "string", "enum": ["door", "window"]}}, WAIT), ["x", "y"])),
    ("lock", "action", "Lock a door (needs the key).", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("unlock", "action", "Unlock a door (needs the key).", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("climb_window", "action", "Climb through an open or smashed window.", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("smash_window", "action", "Smash a window (noisy).", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("barricade", "action", "Nail one plank on a window or door (needs hammer, plank, 2 nails). Call again for more planks.", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("unbarricade", "action", "Remove planks (needs crowbar or claw hammer).", obj(merge(XYZ, WAIT), ["x", "y"])),
    ("sleep", "action", "Go to sleep on the nearest bed (or bed at x,y,z, or floor=true). Fails if zombies are near, pain or panic.", obj(merge(XYZ, {"floor": {"type": "boolean"}, "radius": {"type": "number"}}, WAIT))),
    ("rest", "action", "Sit and rest on furniture nearby or on the ground.", obj(merge(XYZ, WAIT))),
    ("say", "action", "Character says a line above the head (does not go to the chat window).", obj({"text": {"type": "string"}}, ["text"])),
    # --- control
    ("pause", "control", "Pause the game.", obj()),
    ("unpause", "control", "Unpause the game and clear the alert.", obj()),
    ("resume", "control", "Resume the loop that the guard paused (e.g. fight after retreat).", obj()),
    ("set_guard", "control", "Change global guard settings: autopause, pause_distance, autoflee, flee_distance, hp_min, bleeding_max, endurance_min, crowd_max, crowd_radius, threat_radius, danger_radius.",
     obj(merge({"autopause": {"type": "boolean"}, "pause_distance": {"type": "number"}, "autoflee": {"type": "boolean"}}, GUARD_PROPS))),
    ("mark_place", "control", "Remember a named place (default: current position), e.g. 'home', 'storage'.",
     obj(merge({"name": {"type": "string"}, "note": {"type": "string"}}, XYZ), ["name"])),
    ("forget_place", "control", "Forget a named place.", obj({"name": {"type": "string"}}, ["name"])),
    ("forget_visited", "control", "Clear visited buildings/containers memory (known=true also clears remembered contents).", obj({"known": {"type": "boolean"}})),
]

LOCAL_TOOLS = [
    ("get_player_messages", "New messages the player typed in the in-game F9 window, with ids. Marks them read. Call this first in every turn. Also returns access (false = ask the player to enable control).",
     obj({"include_read": {"type": "boolean"}, "mark_read": {"type": "boolean", "description": "default true"}})),
    ("reply_to_player", "Send a message to the player: shown in the F9 window log and spoken by the character. Works even when access=false.",
     obj({"text": {"type": "string"}, "say": {"type": "boolean", "description": "character speaks it, default true"}}, ["text"])),
    ("get_state", "Short state summary from the state file (position, health, wounds, stats, threat, job, alert, last command). full=true returns the whole state including inventory and nearby objects.",
     obj({"full": {"type": "boolean"}})),
    ("get_events", "Events since a cursor: kill, found, container_searched, damage, bitten, alert, guard, fight_progress, job_done/failed/paused/interrupted, player_message, reply, access. Pass the returned cursor next time.",
     obj({"since": {"type": "number"}, "types": {"type": "array", "items": {"type": "string"}}, "limit": {"type": "number"}})),
    ("wait_for", "Block until a condition: action_done | idle | message | event:<type> | zombie_within:<R> | result:<cmd_id> | stat:<name><op><value> (e.g. stat:thirst<0.1). Several with '|'. Returns state summary and new events.",
     obj({"condition": {"type": "string"}, "timeout": {"type": "number", "description": "seconds, default 60, max 600"}}, ["condition"])),
    ("wait_for_result", "Wait for the final result of a command by cmd_id.",
     obj({"cmd_id": {"type": "number"}, "timeout": {"type": "number", "description": "seconds, default 60"}}, ["cmd_id"])),
    ("send_command", "Low-level: send a raw bridge command line (e.g. 'walk 10 20 0' or 'move_to {\"x\":1,\"y\":2}') or a tool with args. Returns cmd_id and first status.",
     obj({"command": {"type": "string"}, "tool": {"type": "string"}, "args": {"type": "object"}, "wait": {"type": "number"}})),
    ("stop", "Stop everything: current loop, action queue, running.", obj()),
    ("get_access", "Whether the player allowed control (from the state file).", obj()),
]

GAME_BY_NAME = {t[0]: t for t in GAME_TOOLS}


def tool_list():
    out = []
    for name, desc, schema in LOCAL_TOOLS:
        out.append({"name": name, "description": desc, "inputSchema": schema})
    for name, kind, desc, schema in GAME_TOOLS:
        out.append({"name": name, "description": desc, "inputSchema": schema})
    return out


# ---------------------------------------------------------------------------
# Выполнение
# ---------------------------------------------------------------------------

def _clean(args):
    return {k: v for k, v in (args or {}).items() if v is not None}


def run_game_tool(name, args):
    kind = GAME_BY_NAME[name][1]
    args = _clean(args)
    wait = args.pop("wait", None)
    if not pzb.game_alive():
        return {"error": "the game is not running or the PZBridge mod is not enabled (state file is stale)",
                "state_age_s": pzb.state_age()}
    cid = pzb.send(name, args)
    if kind in ("query", "control"):
        r = pzb.wait_result(cid, timeout=20)
    elif wait:
        r = pzb.wait_result(cid, timeout=min(float(wait), 600))
    else:
        r = pzb.wait_result(cid, timeout=5, until_final=False)
    r = dict(r)
    r["cmd_id"] = cid
    if r.get("status") == "denied":
        r["hint"] = "access=false: ask the player (reply_to_player) to press F9 and enable control"
    elif r.get("status") == "running":
        r["hint"] = "in progress: use wait_for_result(cmd_id) or wait_for/get_events"
    return r


def run_local_tool(name, args):
    args = args or {}
    if name == "get_player_messages":
        return pzb.get_messages(mark_read=args.get("mark_read", True), include_read=bool(args.get("include_read")))
    if name == "reply_to_player":
        text = str(args.get("text") or "").strip()
        if not text:
            return {"error": "empty text"}
        a = {"text": text}
        if args.get("say") is False:
            a["say"] = False
        cid = pzb.send("reply", a)
        r = dict(pzb.wait_result(cid, timeout=10))
        r["cmd_id"] = cid
        return r
    if name == "get_state":
        st = pzb.read_json(pzb.F_STATE)
        if args.get("full"):
            return st or {"error": "no state file"}
        return pzb.summary(st)
    if name == "get_events":
        return pzb.get_events(args.get("since") or 0, args.get("types"), int(args.get("limit") or 100))
    if name == "wait_for":
        t = min(float(args.get("timeout") or 60), 600)
        return pzb.wait_for(str(args["condition"]), t)
    if name == "wait_for_result":
        t = min(float(args.get("timeout") or 60), 600)
        return pzb.wait_result(int(args["cmd_id"]), timeout=t)
    if name == "send_command":
        if args.get("command"):
            cid = pzb.send_line(str(args["command"]))
        elif args.get("tool"):
            cid = pzb.send(str(args["tool"]), args.get("args") or None)
        else:
            return {"error": "command or tool is required"}
        w = args.get("wait")
        r = dict(pzb.wait_result(cid, timeout=float(w) if w else 5, until_final=bool(w)))
        r["cmd_id"] = cid
        return r
    if name == "stop":
        cid = pzb.send("stop")
        r = dict(pzb.wait_result(cid, timeout=10))
        r["cmd_id"] = cid
        return r
    if name == "get_access":
        st = pzb.read_json(pzb.F_STATE, {}) or {}
        return {"access": st.get("access"), "game_alive": pzb.game_alive(), "state_age_s": pzb.state_age()}
    raise KeyError(name)


LOCAL_NAMES = {t[0] for t in LOCAL_TOOLS}


def call_tool(name, args):
    if name in LOCAL_NAMES:
        return run_local_tool(name, args)
    if name in GAME_BY_NAME:
        return run_game_tool(name, args)
    raise KeyError("unknown tool: %s" % name)


# ---------------------------------------------------------------------------
# JSON-RPC / MCP
# ---------------------------------------------------------------------------

PROMPTS = [{"name": "play", "description": "How to play Project Zomboid through PZBridge: loop and recipes.", "arguments": []}]
RESOURCES = [
    {"uri": "pzbridge://playbook", "name": "PZBridge playbook", "mimeType": "text/markdown",
     "description": "How to play through PZBridge: loop, safety, recipes."},
    {"uri": "pzbridge://state", "name": "Current state", "mimeType": "application/json",
     "description": "Full state file written by the mod."},
]


def handle(msg):
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        proto = params.get("protocolVersion") or DEFAULT_PROTOCOL
        return {
            "protocolVersion": proto,
            "capabilities": {"tools": {"listChanged": False}, "prompts": {"listChanged": False},
                             "resources": {"listChanged": False, "subscribe": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": PLAYBOOK,
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": tool_list()}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            res = call_tool(name, args)
            is_err = isinstance(res, dict) and (res.get("error") is not None or res.get("status") in ("error", "denied"))
            return {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False)}], "isError": bool(is_err)}
        except KeyError as e:
            raise RpcError(-32602, str(e))
        except Exception as e:  # ошибка инструмента -> результат с isError
            return {"content": [{"type": "text", "text": "error: %s" % e}], "isError": True}
    if method == "prompts/list":
        return {"prompts": PROMPTS}
    if method == "prompts/get":
        if params.get("name") != "play":
            raise RpcError(-32602, "unknown prompt")
        return {"description": PROMPTS[0]["description"],
                "messages": [{"role": "user", "content": {"type": "text", "text": PLAYBOOK}}]}
    if method == "resources/list":
        return {"resources": RESOURCES}
    if method == "resources/read":
        uri = params.get("uri")
        if uri == "pzbridge://playbook":
            return {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": PLAYBOOK}]}
        if uri == "pzbridge://state":
            st = pzb.read_json(pzb.F_STATE, {})
            return {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(st, ensure_ascii=False)}]}
        raise RpcError(-32602, "unknown resource")
    raise RpcError(-32601, "method not found: %s" % method)


class RpcError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def send(obj_):
    sys.stdout.write(json.dumps(obj_, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    # stdout только для JSON-RPC, диагностика в stderr
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        batch = msg if isinstance(msg, list) else [msg]
        replies = []
        for m in batch:
            if not isinstance(m, dict):
                continue
            mid = m.get("id")
            is_notification = "id" not in m
            try:
                result = handle(m)
                if not is_notification:
                    replies.append({"jsonrpc": "2.0", "id": mid, "result": result})
            except RpcError as e:
                if not is_notification:
                    replies.append({"jsonrpc": "2.0", "id": mid, "error": {"code": e.code, "message": e.message}})
            except Exception as e:  # pragma: no cover
                traceback.print_exc(file=sys.stderr)
                if not is_notification:
                    replies.append({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}})
        if isinstance(msg, list):
            if replies:
                send(replies)
        else:
            for r in replies:
                send(r)


if __name__ == "__main__":
    main()
