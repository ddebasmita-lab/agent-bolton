#!/usr/bin/env python3
"""The plug-and-play guarantee: one agent, either MCP server generation.

Run from the agent/ directory with no test framework:
    python3 tests/test_backend_generations.py

The agent must run unchanged against either MCP server generation: 1.2.x (two
fat tools, `place_observations` / `time_series` payloads) and 1.3.x (six tools,
columnar `data.rows` payloads).

Both are pinned because a CDC services container can be either one: the image
is Google's and moves independently of this agent, so capability discovery
reads whatever `tools/list` actually returns rather than assuming a version.
Dropping the 1.2.x path needs a survey of deployed versions first.

The case that matters most is the *empty* response. The previous regex-based
check looked for a `"time_series": [[` substring; a 1.3.x server signals "no
data" as `{"data": {}}`, which contains no such substring, so nothing matched,
`all_observations_empty` stayed True and `has_data` came back **True for zero
data**. The agent then confidently narrated numbers it did not have. That is a
silent wrong-answer bug, which is why it is pinned here.
"""
import importlib.util
import json
import os
import sys
import types

sys.path.insert(0, os.getcwd())

class _FakeSession:
    """Enough of requests.Session for client.py to construct one at import."""

    def mount(self, *args, **kwargs):
        pass


for name, attrs in {
    "src.config": {"load_config": lambda: {}, "AGENT_ROOT": "."},
    "src.session_logger": {"SessionLogger": object},
    "src.gcp_auth": {"attach_auth": lambda *a, **k: None},
    "requests": {"Session": _FakeSession, "RequestException": Exception},
    "requests.adapters": {"HTTPAdapter": lambda *a, **k: None},
}.items():
    module = types.ModuleType(name)
    for key, value in attrs.items():
        setattr(module, key, value)
    sys.modules[name] = module


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


du = _load("data_utils", "src/mcp/data_utils.py")
caps_mod = _load("capabilities", "src/mcp/capabilities.py")
schema = _load("schema", "src/mcp/schema.py")
sys.modules["src.mcp.schema"] = schema
client = _load("client", "src/mcp/client.py")


def tool_call(name, payload):
    """MCP wraps results in a content[0].text envelope of double-encoded JSON."""
    return {"name": name, "result": {"content": [{"type": "text", "text": json.dumps(payload)}]}}


# ---- payload fixtures, one per server generation -------------------------
V121_WITH_DATA = {"place_observations": [
    {"place": "country/BEL", "time_series": [["2020", 54577.6], ["2021", 59100.1]]}
]}
V121_EMPTY = {"place_observations": [{"place": "country/BEL", "time_series": []}]}
V130_WITH_DATA = {"data": {"rows": [
    {"entity": "country/BEL", "date": "2021", "value": 59100.1}
]}}
V130_EMPTY = {"data": {}}

TOOLS_121 = [{"name": "search_indicators"}, {"name": "get_observations"}]
TOOLS_130 = [{"name": n} for n in (
    "search_indicators", "search_child_indicators", "get_variable_metadata",
    "get_observations", "get_child_observations", "get_multi_entity_observations",
)]

fails = []


def check(label, cond):
    print(f"  {'ok  ' if cond else 'FAIL'} {label}")
    if not cond:
        fails.append(label)


print("data availability — both generations, populated and empty:")
check("1.2.x populated  -> has_data",
      du.check_data_availability([tool_call("get_observations", V121_WITH_DATA)])["has_data"])
check("1.2.x empty      -> no data",
      not du.check_data_availability([tool_call("get_observations", V121_EMPTY)])["has_data"])
check("1.3.x populated  -> has_data",
      du.check_data_availability([tool_call("get_observations", V130_WITH_DATA)])["has_data"])
check("1.3.x empty      -> no data  (the silent wrong-answer bug)",
      not du.check_data_availability([tool_call("get_observations", V130_EMPTY)])["has_data"])

print("\ncapability discovery:")
c121, c130 = caps_mod.from_tools(TOOLS_121), caps_mod.from_tools(TOOLS_130)
check("1.2.x -> no source attribution", not c121.supports_source_attribution)
check("1.3.x -> source attribution", c130.supports_source_attribution)
check("1.2.x observation tools = 1", len(c121.observation_tools) == 1)
check("1.3.x observation tools = 3", len(c130.observation_tools) == 3)
check("empty server -> generation 'unknown'", caps_mod.from_tools([]).generation == "unknown")
check("no version string branching leaks out",
      c130.generation == "1.3.x-or-later" and c121.generation == "1.2.x")

print("\nargument coercion — must cover every generation's tool names:")
check("date=range forced on get_observations",
      schema.fix_tool_arguments("get_observations", {"date_range_start": "2000"})["date"] == "range")
check("date=range forced on get_child_observations (1.3.x only)",
      schema.fix_tool_arguments("get_child_observations", {"date_range_start": "2000"})["date"] == "range")
check("places coerced to a list on search_child_indicators",
      schema.fix_tool_arguments("search_child_indicators", {"places": "India"})["places"] == ["India"])
check("variable_dcids coerced to a list on get_variable_metadata",
      schema.fix_tool_arguments("get_variable_metadata", {"variable_dcids": "Count_Person"})["variable_dcids"] == ["Count_Person"])

print("\nunknown tool — the server reports it as a successful call:")


def _envelope(text):
    return {"content": [{"type": "text", "text": text}]}


UNKNOWN_TOOL = _envelope("Unknown tool: 'get_variable_metadata'")

check("envelope form detected",
      client._looks_like_unknown_tool(UNKNOWN_TOOL))
check("bare string form detected",
      client._looks_like_unknown_tool("Unknown tool: 'get_places_in'"))
check("1.2.x data is not mistaken for one",
      not client._looks_like_unknown_tool(_envelope(json.dumps(V121_WITH_DATA))))
check("1.3.x data is not mistaken for one",
      not client._looks_like_unknown_tool(_envelope(json.dumps(V130_WITH_DATA))))
check("an empty result is not mistaken for one",
      not client._looks_like_unknown_tool(_envelope(json.dumps(V130_EMPTY))))


class _Recorder:
    """Captures the status each tool result is logged under."""

    def __init__(self):
        self.statuses = []

    def log_mcp_tool_call(self, *args, **kwargs):
        pass

    def log_mcp_tool_result(self, name, result, duration_ms, status="success"):
        self.statuses.append(status)


def _statuses_for(payload, tool="get_observations"):
    client.mcp_call = lambda method, params: {"result": payload}
    recorder = _Recorder()
    client.call_tool(tool, {}, recorder)
    return recorder.statuses


# The regression this pins: an unknown tool used to be logged "success", so a
# prompt naming a tool the server lacks cost a capped iteration and left no
# trace. Status is the only signal a reader of the session log gets.
check("unknown tool logs status error, not success",
      _statuses_for(UNKNOWN_TOOL, "get_variable_metadata") == ["error"])
check("a real result still logs success",
      _statuses_for(_envelope(json.dumps(V130_WITH_DATA))) == ["success"])
# Detection is observability only: the text tells the model what went wrong and
# it generally recovers, so nothing retries or rewrites the payload.
client.mcp_call = lambda method, params: {"result": UNKNOWN_TOOL}
check("the payload still reaches the model unchanged",
      client.call_tool("get_variable_metadata", {}) == UNKNOWN_TOOL)

total = 22
print(f"\n{total - len(fails)}/{total} checks passed" if not fails else f"\nFAILURES: {fails}")
sys.exit(1 if fails else 0)
