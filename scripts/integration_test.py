#!/usr/bin/env python3
"""Интеграционный тест agenthud-hook: фейковый HUD + реальные фикстуры событий Claude Code.

Запуск: python3 scripts/integration_test.py [путь к agenthud-hook]
"""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build/debug/agenthud-hook")
FIX = os.path.join(ROOT, "Tests/AgentHUDCoreTests/Fixtures/claude")
FAKE = os.path.join(ROOT, "scripts/fake-hud.py")

failures = 0


def check(name, cond, detail=""):
    global failures
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  → {detail}"))
    if not cond:
        failures += 1


def fixture(name):
    with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as f:
        return f.read()


def run_hook(sock, mode, payload, timeout=None, env_extra=None):
    args = [HOOK, "claude", mode]
    if timeout:
        args += ["--timeout", str(timeout)]
    env = dict(os.environ, AGENTHUD_SOCKET=sock, AGENTHUD_ANY_HOST="1")
    env.update(env_extra or {})
    t = time.time()
    p = subprocess.run(args, input=payload.encode(), capture_output=True, env=env, timeout=60)
    return p.returncode, p.stdout.decode(), time.time() - t


class Fake:
    def __init__(self, sock, log, permission, question):
        for f in (sock, log):
            try:
                os.unlink(f)
            except FileNotFoundError:
                pass
        self.log = log
        self.p = subprocess.Popen([sys.executable, FAKE, "--socket", sock, "--log", log,
                                   "--permission", permission, "--question", question],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if os.path.exists(sock):
                break
            time.sleep(0.05)

    def messages(self):
        time.sleep(0.2)
        if not os.path.exists(self.log):
            return []
        return [json.loads(l) for l in open(self.log, encoding="utf-8")]

    def stop(self):
        self.p.terminate()
        self.p.wait()


def main():
    tmp = tempfile.mkdtemp(prefix="ahud", dir=os.path.join(ROOT, ".build"))
    sock = os.path.join(tmp, "s.sock")
    log = os.path.join(tmp, "log.jsonl")

    print("HUD не запущен → хук молчит и выходит сразу")
    code, out, dt = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=600)
    check("код 0", code == 0, code)
    check("пустой stdout", out == "", out)
    check("быстро (< 1 с)", dt < 1, dt)

    print("Мусор на входе → молчит")
    code, out, _ = run_hook(sock, "event", "not json")
    check("код 0 и пусто", code == 0 and out == "", (code, out))

    print("Автоматизация (SDK, служебный запрос приложения) → хук не вмешивается")
    f = Fake(sock, log, "allow", "answer")
    for env in [{"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"},
                {"CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_HOST_SESSION_ID": ""}]:
        code, out, _ = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=600,
                                env_extra=dict(env, AGENTHUD_ANY_HOST="0"))
        check(f"{env['CLAUDE_CODE_ENTRYPOINT']}: пустой вывод", out == "", out)
    check("HUD ничего не получил", not any(x.get("mode") == "permission" for x in f.messages()))
    f.stop()

    print("Сессия приложения Claude → в HUD")
    f = Fake(sock, log, "allow", "answer")
    code, out, _ = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=600,
                            env_extra={"AGENTHUD_ANY_HOST": "0", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                                       "CLAUDE_CODE_HOST_SESSION_ID": "local_test"})
    check("решение HUD дошло", '"allow"' in out, out)
    m = next((x for x in f.messages() if x.get("mode") == "permission"), {})
    check("id сессии приложения передан", m.get("host", {}).get("host_session_id") == "local_test", m.get("host"))
    f.stop()

    print("Разрешить")
    f = Fake(sock, log, "allow", "answer")
    code, out, _ = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=600)
    o = json.loads(out)
    check("behavior=allow", o["hookSpecificOutput"]["decision"]["behavior"] == "allow", out)
    check("hookEventName", o["hookSpecificOutput"]["hookEventName"] == "PermissionRequest", out)
    msgs = f.messages()
    m = next(x for x in msgs if x.get("mode") == "permission")
    check("дедлайн = сейчас + 595 с", abs(m["deadline"] - (m["_received"] + 595)) < 3, m.get("deadline"))
    check("в сообщении есть TTY/цепочка процессов", "process_chain" in m["host"], m["host"])

    print("Ответ на вопрос")
    code, out, _ = run_hook(sock, "question", fixture("question-PreToolUse-AskUserQuestion"), timeout=600)
    o = json.loads(out)["hookSpecificOutput"]
    qtext = o["updatedInput"]["questions"][0]["question"]
    check("permissionDecision=allow", o["permissionDecision"] == "allow", o)
    check("answers по тексту вопроса", o["updatedInput"]["answers"] == {qtext: "Red"}, o)

    print("Вопрос через хук разрешений не идёт")
    ask = json.loads(fixture("permission-PermissionRequest"))
    ask["tool_name"] = "AskUserQuestion"
    code, out, _ = run_hook(sock, "permission", json.dumps(ask))
    check("пусто", out == "", out)

    print("Асинхронное событие")
    code, out, dt = run_hook(sock, "event", fixture("PreToolUse-Bash"))
    check("пусто и быстро", out == "" and dt < 1, (out, dt))
    check("событие дошло", any(x.get("payload", {}).get("hook_event_name") == "PreToolUse" and x.get("mode") == "event"
                               for x in f.messages()))
    f.stop()

    print("Отклонить с причиной")
    f = Fake(sock, log, "deny", "passthrough")
    code, out, _ = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=600)
    d = json.loads(out)["hookSpecificOutput"]["decision"]
    check("deny + message", d == {"behavior": "deny", "message": "Тестовый отказ"}, d)

    print("Ответить в терминале")
    code, out, _ = run_hook(sock, "question", fixture("question-PreToolUse-AskUserQuestion"), timeout=600)
    check("пусто", out == "", out)
    f.stop()

    print("Просрочка: HUD молчит → хук отпускает за 5 с до timeout")
    f = Fake(sock, log, "hold", "hold")
    code, out, dt = run_hook(sock, "permission", fixture("permission-PermissionRequest"), timeout=7)
    check("пусто", out == "", out)
    check("ушёл около 2 с", 1.5 < dt < 4, dt)
    msgs = f.messages()
    check("HUD увидел закрытие", any("closed" in x for x in msgs), msgs[-1:])
    f.stop()

    print("HUD закрылся во время ожидания → хук сразу отпускает")
    f = Fake(sock, log, "hold", "hold")
    p = subprocess.Popen([HOOK, "claude", "permission", "--timeout", "600"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, env=dict(os.environ, AGENTHUD_SOCKET=sock, AGENTHUD_ANY_HOST="1"))
    p.stdin.write(fixture("permission-PermissionRequest").encode())
    p.stdin.close()
    time.sleep(0.5)
    f.stop()
    t = time.time()
    p.wait(timeout=10)
    check("вышел быстро и молча", time.time() - t < 3 and p.stdout.read() == b"", time.time() - t)

    print()
    print("ИТОГ:", "все проверки прошли" if failures == 0 else f"провалов: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
