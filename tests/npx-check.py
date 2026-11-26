#!/usr/bin/env python3
# ABOUTME: Installs this checkout with plugins 1.3.9 in a fresh home per target.
# ABOUTME: Follows the install registrations and runs the packaged hooks without starting a chat.
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("claude-code", "codex", "cursor", "github-copilot", "vscode", "grok", "kimi")


def read(path):
    return json.loads(path.read_text())


def run(args, env):
    result = subprocess.run(args, env=env, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            timeout=120)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        result.check_returncode()
    return result.stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def enabled_key(settings):
    key, = [k for k, active in settings["enabledPlugins"].items()
            if k.startswith("workhorses@") and active is True]
    return key


def installed_root(target, home, env):
    if target in ("claude-code", "cursor"):
        key = enabled_key(read(home / ".claude/settings.json"))
        record, = read(home / ".claude/plugins/installed_plugins.json")["plugins"][key]
        return Path(record["installPath"])
    if target == "codex":
        config = (home / ".codex/config.toml").read_text()
        require('[plugins."workhorses@plugins-cli"]\nenabled = true' in config,
                "Codex did not enable workhorses@plugins-cli")
        version = read(ROOT / ".codex-plugin/plugin.json")["version"]
        return home / ".codex/plugins/cache/plugins-cli/workhorses" / version
    if target == "github-copilot":
        settings = read(home / ".copilot/settings.json")
        market = enabled_key(settings).split("@", 1)[1]
        directory = Path(settings["extraKnownMarketplaces"][market]["source"]["path"])
        entry, = read(directory / ".claude-plugin/marketplace.json")["plugins"]
        require(entry["name"] == "workhorses", "wrong Copilot marketplace entry")
        return directory / entry["source"]
    if target == "vscode":
        config = home / ("Library/Application Support" if sys.platform == "darwin" else ".config")
        settings, = config.glob("Code*/User/settings.json")
        path, = [k for k, v in read(settings)["chat.pluginLocations"].items() if v is True]
        return Path(path)
    if target == "grok":
        record, = json.loads(run(["grok", "plugin", "list", "--json"], env))
        require((record["name"], record["status"]) == ("workhorses", "installed"),
                "Grok did not register workhorses")
        return Path(record["path"])
    record, = read(home / ".kimi-code/plugins/installed.json")["plugins"]
    require(record["id"] == "workhorses" and record["enabled"], "Kimi plugin is disabled")
    return Path(record["root"])


def check(target, scratch, home):
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(scratch),
           "npm_config_cache": str(scratch / "npm"), "npm_config_userconfig": os.devnull,
           "npm_config_update_notifier": "false", "DISABLE_TELEMETRY": "1",
           "WORKHORSES_CONFIG_DIR": str(scratch / "config")}
    run(["npx", "--yes", "plugins@1.3.9", "add", str(ROOT), "--target", target, "--yes"], env)
    plugin = installed_root(target, home, env).resolve()
    plugin.relative_to(home.resolve())
    vendor = {"codex": ".codex-plugin", "github-copilot": ".plugin", "vscode": ".plugin",
              "kimi": ".kimi-plugin"}.get(target, ".claude-plugin")
    manifest = read(plugin / vendor / "plugin.json")
    require(manifest["name"] == "workhorses", "wrong manifest")
    skill = plugin / manifest.get("skills", "skills") / "workhorse/SKILL.md"
    require(skill.read_bytes() == (ROOT / "skills/workhorse/SKILL.md").read_bytes(),
            "installed workhorse skill differs from checkout")
    if target == "kimi":
        require(manifest.get("sessionStart") == {"skill": "workhorse"} and manifest.get("hooks") == [],
                "Kimi needs its static startup skill and no output-only startup command")
        return
    if target == "grok":
        details = run(["grok", "plugin", "details", "workhorses"], env)
        require("1 skill dir(s)" in details and "hooks" in details, "Grok component discovery failed")
        group, = read(plugin / "hooks/hooks.json")["hooks"]["SessionStart"]
        hook, = group["hooks"]
        require(hook["type"] == "command" and bool(hook["command"]), "missing Grok startup hook")
        return

    hooks = read(plugin / "hooks/hooks.json")
    if target == "claude-code":
        module, = hooks["modules"]
        require((plugin / "hooks" / module).read_bytes() ==
                (ROOT / "mods/workhorse-runs/hooks/register.tsx").read_bytes(), "Claude mod missing")
    if target == "codex":
        hooks = read(plugin / manifest["hooks"])
    root_var = {"vscode": "PLUGIN_ROOT", "github-copilot": "COPILOT_PLUGIN_ROOT"}.get(
        target, "CLAUDE_PLUGIN_ROOT")
    env[root_var] = str(plugin)
    plain = run(["bash", str(plugin / "scripts/policy.sh")], env)
    expected = plain.removesuffix("\n")
    require("| zeta | me@zeta.example.test | arm64 | 8 | 16 GB |" in expected,
            "policy did not read the test host")
    if target in ("github-copilot", "vscode"):
        copilot = read(plugin / manifest["hooks"])
        require(copilot["version"] == 1, "wrong Copilot hook schema")
        command = copilot["hooks"]["sessionStart"][0]["bash"]
        output = run(["bash", "-eu", "-c", command], env)
        if target == "github-copilot":
            require(json.loads(output)["additionalContext"] == expected, "Copilot context differs")
            return
        require(not output, "VS Code ran the Copilot CLI hook twice")
    command = hooks["hooks"]["SessionStart"][0]["hooks"][0]["command"]
    output = run(["bash", "-eu", "-c", command], env)
    if target == "codex":
        require(output == plain, "Codex hook output differs from installed policy")
        return
    else:
        response = json.loads(output)["hookSpecificOutput"]
        require(response["hookEventName"] == "SessionStart", "wrong hook event")
        actual = response["additionalContext"]
    require(actual == expected, "startup context differs from installed policy")


if __name__ == "__main__":
    targets = sys.argv[1:] or TARGETS
    if any(t not in TARGETS for t in targets):
        sys.exit("expected targets: " + ", ".join(TARGETS))
    with TemporaryDirectory() as directory:
        scratch = Path(directory)
        config = scratch / "config"
        config.mkdir()
        (config / "hosts").write_text("zeta me@zeta.example.test arm64 8 16\n")
        for target in targets:
            print(f"checking {target}", flush=True)
            with TemporaryDirectory(dir=scratch) as dest:
                check(target, scratch, Path(dest))
            print(f"ok   {target}", flush=True)
