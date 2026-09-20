#!/usr/bin/env python3
"""Core of the deepseek-subagent wrapper.

Runs `opencode run --format json`, streams tool-call progress to stderr, and prints
the assistant's final text followed by a trailer with the session id so the caller
can continue the conversation with --session.

Exit code: opencode's, 124 on timeout, 2 on bad arguments, 127 if opencode is missing.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

IS_WIN = os.name == "nt"


def summarize_input(tool, inp):
    if not isinstance(inp, dict):
        return ""
    for key in ("filePath", "path", "command", "pattern", "url", "query", "description"):
        v = inp.get(key)
        if isinstance(v, str) and v:
            v = v.replace("\n", " ")
            return v if len(v) <= 100 else v[:97] + "..."
    for v in inp.values():
        if isinstance(v, str) and v:
            v = v.replace("\n", " ")
            return v if len(v) <= 100 else v[:97] + "..."
    return ""


def kill_tree(proc):
    try:
        if IS_WIN:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            for _ in range(50):
                if proc.poll() is not None:
                    return
                time.sleep(0.1)
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--agent", default="deepseek")
    ap.add_argument("--model", default=os.environ.get("DEEPSEEK_SUBAGENT_MODEL", "deepseek/deepseek-flash"))
    ap.add_argument("--dir", default=os.getcwd())
    ap.add_argument("--session")
    ap.add_argument("--fork", action="store_true")
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--out")
    ap.add_argument("--log")
    ap.add_argument("--title", default="deepseek-subagent")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("prompt")
    a = ap.parse_args()

    if not a.prompt.strip():
        print("error: empty prompt", file=sys.stderr)
        return 2
    exe = shutil.which("opencode")
    if not exe:
        print("error: opencode not found on PATH", file=sys.stderr)
        return 127
    try:
        a.dir = os.path.abspath(a.dir)
        if not os.path.isdir(a.dir):
            raise FileNotFoundError
    except Exception:
        print(f"error: bad --dir {a.dir!r}", file=sys.stderr)
        return 2

    cmd = [exe, "run", "--format", "json", "--agent", a.agent, "--model", a.model,
           "--dir", a.dir, "--title", a.title]
    if a.session:
        cmd += ["--session", a.session]
        if a.fork:
            cmd.append("--fork")
    for f in a.file:
        cmd += ["--file", f]
    cmd += ["--", a.prompt]

    if a.dry_run:
        import shlex
        print(" ".join(shlex.quote(c) for c in cmd) if not IS_WIN else subprocess.list2cmdline(cmd))
        return 0

    env = dict(os.environ, OPENCODE_DISABLE_AUTOUPDATE="1")
    popen_kw = dict(stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace", bufsize=1, env=env, cwd=a.dir)
    if IS_WIN:
        popen_kw["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        popen_kw["start_new_session"] = True
    proc = subprocess.Popen(cmd, **popen_kw)

    timed_out = {"v": False}

    def watchdog():
        timed_out["v"] = True
        kill_tree(proc)

    timer = threading.Timer(a.timeout, watchdog)
    timer.daemon = True
    timer.start()

    log = open(a.log, "a", encoding="utf-8") if a.log else None
    texts, plain = [], []
    session = a.session or ""
    tokens = {"input": 0, "output": 0, "reasoning": 0, "total": 0}
    cost = 0.0
    tool_count = 0

    def progress(msg):
        if not a.quiet:
            print(msg, file=sys.stderr, flush=True)

    try:
        for line in proc.stdout:
            if log:
                log.write(line)
                log.flush()
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                plain.append(line)
                progress(line)
                continue
            session = ev.get("sessionID") or session
            part = ev.get("part") or {}
            t = ev.get("type")
            if t == "text":
                txt = part.get("text", "")
                if txt:
                    texts.append(txt)
            elif t == "tool_use":
                tool_count += 1
                tool = part.get("tool", "?")
                state = part.get("state") or {}
                status = state.get("status", "")
                summ = summarize_input(tool, state.get("input"))
                mark = "x" if status == "error" else "»"
                progress(f"{mark} {tool} {summ}".rstrip())
                if status == "error" and state.get("error"):
                    progress(f"  error: {str(state['error'])[:300]}")
            elif t == "step_finish":
                tk = part.get("tokens") or {}
                for k in ("input", "output", "reasoning"):
                    tokens[k] += int(tk.get(k) or 0)
                tokens["total"] += int(tk.get("total") or 0)
                cost += float(part.get("cost") or 0)
            elif t == "error":
                msg = json.dumps(ev.get("error") or ev)[:500]
                plain.append(f"Error: {msg}")
                progress(f"x error {msg}")
    finally:
        proc.wait()
        timer.cancel()
        if log:
            log.close()

    rc = 124 if timed_out["v"] else proc.returncode
    text = "\n\n".join(texts).strip()
    if timed_out["v"]:
        plain.append(f"error: subagent timed out after {a.timeout}s")
    if rc == 0 and not text and plain:
        rc = 1  # opencode printed an error but exited 0

    if a.json:
        out = json.dumps({"session": session, "exit": rc, "text": text, "errors": plain,
                          "tools": tool_count, "tokens": tokens, "cost": round(cost, 6),
                          "dir": a.dir, "agent": a.agent, "model": a.model}, ensure_ascii=False, indent=2)
    else:
        lines = []
        if text:
            lines.append(text)
        if plain:
            lines.append("\n".join(plain))
        lines.append("---")
        lines.append(f"session: {session or 'unknown'}")
        lines.append(f"agent: {a.agent}  model: {a.model}  tools: {tool_count}  "
                     f"tokens: in={tokens['input']} out={tokens['output']}  cost: ${cost:.4f}")
        lines.append(f"exit: {rc}")
        out = "\n".join(lines)

    print(out)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(out + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
