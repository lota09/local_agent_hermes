#!/usr/bin/env python3
"""Open WebUI 대화 기록을 텍스트로 뽑는다.

대화는 webui.db 의 chat 테이블에 JSON 통째로 들어있다.
history.messages 가 정본이고, 최상위 messages 배열은 일부만 담고 있을 수 있다.
그래서 history 를 우선으로 읽고 parentId 사슬을 따라 시간순으로 편다.

사용:  chatlog.py <webui.db> [번호|id접두사] [--full]
"""
import json
import sqlite3
import sys


def messages(blob):
    c = json.loads(blob or "{}")
    hist = (c.get("history") or {}).get("messages") or {}
    if not hist:
        return c.get("messages") or []
    cur = (c.get("history") or {}).get("currentId")
    order, seen = [], set()
    while cur and cur in hist and cur not in seen:
        seen.add(cur)
        order.append(hist[cur])
        cur = hist[cur].get("parentId")
    if order:
        return list(reversed(order))
    return sorted(hist.values(), key=lambda m: m.get("timestamp") or 0)


def main():
    db_path = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) > 2 else ""
    full = "--full" in sys.argv[3:]
    db = sqlite3.connect(db_path)

    rows = db.execute(
        "select id, title, updated_at from chat where archived=0 order by updated_at desc"
    ).fetchall()

    if not target:
        print(f"  대화 {len(rows)}개 (최근순)\n")
        for i, (cid, title, _) in enumerate(rows, 1):
            blob = db.execute("select chat from chat where id=?", (cid,)).fetchone()[0]
            print(f"  {i:2d}) {(title or '(제목 없음)')[:44]:<44} "
                  f"{len(messages(blob)):>3}개 메시지  {cid[:8]}")
        print("\n  내용 보기:  ./openwebui-run.sh chats <번호|id>")
        return 0

    pick = None
    if target.isdigit() and 1 <= int(target) <= len(rows):
        pick = rows[int(target) - 1]
    else:
        for r in rows:
            if r[0].startswith(target):
                pick = r
                break
    if pick is None:
        print(f"  그런 대화가 없다: {target}")
        return 1

    cid, title, _ = pick
    blob = db.execute("select chat from chat where id=?", (cid,)).fetchone()[0]
    print(f"# {title}\n# id: {cid}\n")
    for m in messages(blob):
        print(f"## [{m.get('role', '?')}]")
        print((m.get("content") or "").rstrip() or "(내용 없음)")
        # 도구 호출·출처·상태 — 문제를 찾을 때 이게 핵심이다
        seen_keys = set()
        for key, label in (("toolCalls", "tool_calls"), ("tool_calls", "tool_calls"),
                           ("output", "output"), ("sources", "sources"),
                           ("statusHistory", "status")):
            v = m.get(key)
            if not v or label in seen_keys:
                continue
            seen_keys.add(label)
            text = json.dumps(v, ensure_ascii=False)
            if not full and len(text) > 800:
                text = text[:800] + f" …({len(text)}자 중 800자, --full 로 전체)"
            print(f"\n<{label}> {text}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
