"""Offline installed-bridge contract regression; never calls a real model."""
from __future__ import annotations
import argparse
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path

REQUIRED = ["agent_type", "model", "reasoning_effort", "task_name", "message"]
PROFILES = [("gpt6_astra_high_protected_judgment", "gpt-6-astra", "escalated"),
            ("gpt6_sol_high_protected_judgment", "gpt-6-sol", "routine")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    here = Path(__file__).parent
    spec = importlib.util.spec_from_file_location("background_contract_client", here / "Invoke-BackgroundChildTests.py")
    client_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client_module)
    root = Path(tempfile.mkdtemp(prefix="protected-child-contract-"))
    tests = []
    client = None

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        tests.append(label)

    try:
        client = client_module.Client(args.bridge.resolve(), root, here / "transport-fixtures/background_fake.py")
        for model in ("glm-5.3-flash", "deepseek-flash"):
            parent_result = client.request("thread/start", {"model": model, "cwd": str(root), "config": {}})
            parent = parent_result["thread"]["id"]
            tool = next(t for t in parent_result["thread"]["tools"] if t["name"] == "openai_child")
            schema = tool["inputSchema"]
            check(model + ": five required fields", schema["required"] == REQUIRED)
            check(model + ": both protected tiers discoverable", all(role in schema["properties"]["agent_type"]["enum"] for role, _, _ in PROFILES))
            check(model + ": economic context-choice guidance", all(term in tool["description"] for term in ("no child is a valid choice", "model and effort separately", "fresh context", "single-task grant")))
            check(model + ": explicit protected instructions", "send ONLY" in tool["description"] and "gpt-6-astra" in tool["description"] and "not null" in tool["description"])
            check(model + ": background-only properties described", all("protected judgment" in schema["properties"][key]["description"] for key in ("thread_id", "reply_to", "wait_ms")))
            for role, selected_model, tier in PROFILES:
                valid = {"agent_type": role, "model": selected_model, "reasoning_effort": "high", "task_name": "astra_high_contract_test", "message": "CONTRACT_NONCE"}
                for changes in ({"model": "gpt-6-sol" if selected_model == "gpt-6-astra" else "gpt-6-astra"}, {"wait_ms": 30000}, {"wait_ms": 0}, {"wait_ms": None}, {"thread_id": "existing-thread"}, {"thread_id": None}, {"reply_to": "existing-reply"}, {"reply_to": None}, {"fork_turns": "all"}, {"unknown_field": "DO_NOT_ECHO_PRIVATE_VALUE"}, {"model": "gpt-5.6-luna"}, {"reasoning_effort": "low"}, {"reasoning_effort": "max"}):
                    before = client.request("test/state")["counts"].get("thread/start", 0)
                    ok, result = client.dispatch(parent, "openai_child", {**valid, **changes})
                    expected = "OPENAI_CHILD_PROTECTED_IDENTITY_INVALID" if ("model" in changes or "reasoning_effort" in changes) else "OPENAI_CHILD_PROTECTED_ARGUMENTS_INVALID"
                    label = model + "/" + role + ": reject " + json.dumps(changes)
                    check(label, not ok and result.get("error") == expected and result.get("required_fields") == REQUIRED and result.get("child_created") is False and "retry" in result.get("retry_action", "").lower() and "DO_NOT_ECHO_PRIVATE_VALUE" not in json.dumps(result) and client.request("test/state")["counts"].get("thread/start", 0) == before)
                ok, accepted = client.dispatch(parent, "openai_child", valid)
                check(model + "/" + role + ": corrected five-field judgment succeeds", ok and accepted.get("model") == selected_model and accepted.get("reasoning_effort") == "high" and accepted.get("persistent") is True and accepted.get("final_text") == "CHILD_OK" and accepted.get("agent_type") == role)
                check(model + "/" + role + ": tier is not qualification", accepted.get("judgment_tier") == tier and accepted.get("qualification_requires_host_verification") is True)
                first = accepted["thread_id"]
                record = client.request("thread/read", {"threadId": first, "includeTurns": True})["thread"]
                instructions = record.get("developerInstructions", "")
                check(model + "/" + role + ": role instructions and summary suppression reach host", role in instructions and "verbatim user prompts" in instructions and "not execution" in instructions and record.get("config", {}).get("model_reasoning_summary") == "none" and record.get("reasoningEffort") == "high")
                visible = client.request("thread/list")["data"]
                check(model + "/" + role + ": protected judgment is not a top-level task", first not in {t["id"] for t in visible})
                native = client.request("thread/start", {"model": selected_model, "modelProvider": "openai", "cwd": str(root)})["thread"]["id"]
                check(model + "/" + role + ": unrelated Astra task remains visible", native in {t["id"] for t in client.request("thread/list")["data"]})
                client.close()
                client = client_module.Client(args.bridge.resolve(), root, here / "transport-fixtures/background_fake.py")
                client.request("thread/resume", {"threadId": parent, "model": model, "config": {}})
                visible = {t["id"] for t in client.request("thread/list")["data"]}
                check(model + "/" + role + ": protected display classification survives restart", first not in visible and native in visible)
                ok, again = client.dispatch(parent, "openai_child", valid)
                check(model + "/" + role + ": protected judgment remains fresh", ok and again["thread_id"] != first)
                ok, ordinary = client.dispatch(parent, "openai_child", {**valid, "agent_type": "openai_child", "model": "gpt-5.6-luna", "task_name": "luna_high_regression", "wait_ms": 100})
                check(model + "/" + role + ": Luna still accepts background wait", ok and ordinary.get("state") == "completed")
                legacy = client.request("test/create-legacy-parent", {"cwd": str(root)})["thread_id"]
                client.request("thread/resume", {"threadId": legacy, "model": "glm-5.3-flash", "config": {}})
                ok, error = client.dispatch(legacy, "openai_child", {**valid, "wait_ms": 30000})
                check(model + "/" + role + ": old parent gets corrective error", not ok and error.get("error") == "OPENAI_CHILD_PROTECTED_ARGUMENTS_INVALID")
                ok, recovered = client.dispatch(legacy, "openai_child", valid)
                check(model + "/" + role + ": old parent succeeds after correction", ok and recovered.get("final_text") == "CHILD_OK")
        result = {"pass": True, "tests_passed": len(tests), "tests": tests, "live_models": False, "desktop_e2e": False}
    except Exception as exc:
        result = {"pass": False, "tests_passed": len(tests), "tests": tests, "error": repr(exc), "workspace": str(root), "live_models": False, "desktop_e2e": False}
    finally:
        if client:
            client.close()
    if result["pass"]:
        shutil.rmtree(root)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
