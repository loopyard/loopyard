#!/usr/bin/env python3
"""Eval Elixir on the isolated profiling server via Tidewave MCP (streamable HTTP)."""
import json, sys, urllib.request

BASE = "http://localhost:4100/tidewave/mcp"

def post(payload, session=None):
    headers = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    if session:
        headers["mcp-session-id"] = session
    req = urllib.request.Request(BASE, json.dumps(payload).encode(), headers)
    resp = urllib.request.urlopen(req, timeout=120)
    sid = resp.headers.get("mcp-session-id")
    body = resp.read().decode()
    # streamable HTTP may wrap responses as SSE
    data = None
    for line in body.splitlines():
        if line.startswith("data:"):
            data = json.loads(line[5:].strip())
    if data is None and body.strip():
        data = json.loads(body)
    return sid, data

def main():
    code = sys.stdin.read()
    sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "prof", "version": "1"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, result = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "project_eval", "arguments": {"code": code, "timeout": 110_000}}}, sid)
    if result is None:
        print("NO RESPONSE"); sys.exit(1)
    if "error" in result:
        print("ERROR:", json.dumps(result["error"])[:2000]); sys.exit(1)
    for item in result.get("result", {}).get("content", []):
        if item.get("type") == "text":
            print(item["text"])

if __name__ == "__main__":
    main()
