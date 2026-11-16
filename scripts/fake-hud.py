#!/usr/bin/env python3
"""Фейковый AgentHUD для проверок и интеграционных тестов.

Слушает unix-сокет, пишет каждое сообщение в лог (JSONL) и отвечает на синхронные
запросы по заданной политике:

  hold         — никогда не отвечать (держать соединение)
  allow        — разрешить
  deny         — отклонить с причиной
  answer       — ответить на вопрос первым вариантом
  passthrough  — «ответить в терминале»
  delay:N:pol  — ждать N секунд, потом применить политику pol

Отключение хука (EOF) тоже пишется в лог как {"closed": request_id}.
"""
import argparse
import json
import os
import socket
import sys
import threading
import time


def log(path, obj):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def reply_for(msg, policy):
    rid = msg["request_id"]
    if policy == "allow":
        return {"request_id": rid, "decision": "allow"}
    if policy == "deny":
        return {"request_id": rid, "decision": "deny", "reason": "Тестовый отказ"}
    if policy == "passthrough":
        return {"request_id": rid, "decision": "passthrough"}
    if policy == "answer":
        qs = msg["payload"].get("tool_input", {}).get("questions", [])
        answers = {}
        for q in qs:
            opts = q.get("options") or [{"label": "ok"}]
            answers[q["question"]] = opts[0]["label"]
        return {"request_id": rid, "decision": "answer", "answers": answers}
    return None


def handle(conn, args):
    buf = b""
    msg = None
    while b"\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            conn.close()
            return
        buf += chunk
    line = buf.split(b"\n", 1)[0]
    msg = json.loads(line)
    msg["_received"] = time.time()
    log(args.log, msg)
    if msg.get("mode") == "event":
        conn.close()
        return
    policy = args.question if msg["mode"] == "question" else args.permission
    if policy.startswith("delay:"):
        _, secs, policy = policy.split(":", 2)
        conn.settimeout(float(secs))
        try:
            if conn.recv(1) == b"":
                log(args.log, {"closed": msg["request_id"], "t": time.time()})
                conn.close()
                return
        except socket.timeout:
            pass
        conn.settimeout(None)
    r = reply_for(msg, policy)
    if r is None:
        # hold: ждём, пока хук сам не закроет соединение
        try:
            while conn.recv(1):
                pass
        except OSError:
            pass
        log(args.log, {"closed": msg["request_id"], "t": time.time()})
        conn.close()
        return
    conn.sendall((json.dumps(r, ensure_ascii=False) + "\n").encode())
    log(args.log, {"replied": msg["request_id"], "reply": r, "t": time.time()})
    conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--permission", default="hold")
    ap.add_argument("--question", default="hold")
    args = ap.parse_args()
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(args.socket)
    os.chmod(args.socket, 0o600)
    s.listen(64)
    print("fake-hud listening", args.socket, flush=True)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, args), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
