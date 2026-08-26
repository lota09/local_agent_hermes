#!/usr/bin/env python3
"""대화 기록의 잔여 흔적을 진단하고(기본) 정리한다(--apply).

두 가지 범위:
  기본          이미 삭제한 대화의 잔여물만 (고아 첨부 + 해제 페이지 + 로그)
  --everything  살아있는 대화까지 **전부** 지운다.
                단 초기화와는 다르다 — 설정·계정·모델·지식베이스·
                작업공간의 산출물은 그대로 둔다.


왜 필요한가 — 실측으로 확인한 것들:
  · Open WebUI 의 대화 삭제는 진짜 DELETE 다(소프트 삭제 아님).
  · 그런데 SQLite 가 secure_delete=0 / auto_vacuum=NONE 이라
    해제된 페이지의 바이트가 파일에 그대로 남는다 → 원본에서 본문이 복구된다.
  · delete_chat_by_id 는 chat / chat_message / shared_chat 만 지운다.
    chat_file 은 안 지워서 업로드 파일과 그 기록이 고아로 남는다.

사용:  purge.py <webui.db> [--apply] [--uploads DIR]
"""
import os
import re
import sqlite3
import sys


# 대화 blob 은 {"id": "<uuid>", "title": ... 형태로 저장된다.
# 이 서명으로 원본 바이트를 훑으면 '복구 가능한 삭제 대화'를 정확히 셀 수 있다.
CHAT_SIG = re.compile(rb'\{"id": "([0-9a-f-]{36})", "title"')


def recoverable_deleted(db_path, live_ids):
    out = {}
    for name in (db_path, db_path + "-wal"):
        if not os.path.exists(name):
            continue
        with open(name, "rb") as fh:
            data = fh.read()
        found = {m.group(1).decode() for m in CHAT_SIG.finditer(data)}
        out[os.path.basename(name)] = sorted(found - live_ids)
    return out


# ── --everything 의 범위 ──────────────────────────────────────────────────
# 지우는 것: '대화'라고 부를 수 있는 모든 것. 자식 테이블부터 지운다.
CONVERSATION_TABLES = [
    ("chat_message", "대화 메시지"),
    ("message_reaction", "메시지 반응"),
    ("message", "채널 메시지"),
    ("chat_file", "대화 첨부 연결"),
    ("shared_chat", "공유 링크"),
    ("chatidtag", "대화-태그 연결"),
    ("tag", "태그 (대화에서 생성된 이름이라 남기면 내용이 유추된다)"),
    ("feedback", "평가 기록"),
    ("folder", "대화 폴더"),
    ("prompt_history", "프롬프트 입력 이력"),
    ("memory", "장기 기억 (대화에서 추출된 내용)"),
    ("chat", "대화 본문"),
]

# 남기는 것: 설정과 산출물. 이게 '초기화'와 다른 점이다.
PRESERVED = [
    ("config", "모든 관리자 설정 (연결·검색·도구·터미널)"),
    ("user / auth / api_key", "계정과 로그인"),
    ("model", "모델별 파라미터와 능력 설정"),
    ("prompt / tool / function / skill", "등록한 프롬프트·도구"),
    ("knowledge / note / calendar", "지식베이스·노트·캘린더"),
    ("file (대화에 안 붙은 것)", "지식베이스 등에서 쓰는 파일"),
    ("~/agent-workspace", "모델이 파일시스템에 만든 산출물 — 건드리지 않는다"),
]


def safe_upload_path(stored_path, uploads_dir):
    """DB 에 저장된 절대경로를 그대로 믿지 않는다.

    file.path 는 설치 시점의 절대경로다. 복사본 DB 로 시험해도 그 경로는
    '실제' uploads 를 가리키므로, 그대로 os.remove 하면 원본이 지워진다.
    (실제로 그렇게 원본 파일을 날린 적이 있어 이 가드를 넣었다.)
    파일명만 취해 --uploads 로 지정된 디렉터리 안에서 찾는다.
    """
    if not stored_path or not uploads_dir:
        return None
    candidate = os.path.join(uploads_dir, os.path.basename(stored_path))
    real_dir = os.path.realpath(uploads_dir)
    real_cand = os.path.realpath(candidate)
    if not real_cand.startswith(real_dir + os.sep):
        return None
    return candidate if os.path.exists(candidate) else None


def orphan_chat_files(db):
    return db.execute(
        "select cf.chat_id, cf.file_id from chat_file cf "
        "left join chat c on c.id = cf.chat_id where c.id is null"
    ).fetchall()


def file_referenced_elsewhere(db, file_id, skip_chat_file=True):
    """file_id 가 chat_file 말고 다른 곳(지식베이스 등)에서 쓰이는지 본다."""
    for (table,) in db.execute(
        "select name from sqlite_master where type='table'"
    ).fetchall():
        if table in ("file",) or (skip_chat_file and table == "chat_file"):
            continue
        try:
            cols = [r[1] for r in db.execute(f'PRAGMA table_info("{table}")')]
        except sqlite3.Error:
            continue
        for c in cols:
            try:
                n = db.execute(
                    f'select count(*) from "{table}" where CAST("{c}" AS TEXT) like ?',
                    (f"%{file_id}%",),
                ).fetchone()[0]
            except sqlite3.Error:
                continue
            if n:
                return f"{table}.{c}"
    return None


def main():
    db_path = sys.argv[1]
    apply = "--apply" in sys.argv
    everything = "--everything" in sys.argv
    uploads = None
    if "--uploads" in sys.argv:
        uploads = sys.argv[sys.argv.index("--uploads") + 1]
    # --log <경로> 는 여러 번 올 수 있다 (Open WebUI 로그, SearXNG 로그 …)
    logs = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == "--log"]

    db = sqlite3.connect(db_path)
    size_before = os.path.getsize(db_path)
    wal = db_path + "-wal"
    wal_before = os.path.getsize(wal) if os.path.exists(wal) else 0

    print("── 진단 ──────────────────────────────────────")
    for p in ("secure_delete", "auto_vacuum", "freelist_count"):
        print(f"  {p:<15}= {db.execute(f'PRAGMA {p}').fetchone()[0]}")
    print(f"  webui.db       = {size_before/1024:.0f} KB")
    print(f"  webui.db-wal   = {wal_before/1024:.0f} KB")

    live = {r[0] for r in db.execute("select id from chat")}
    rec = recoverable_deleted(db_path, live)
    total = sum(len(v) for v in rec.values())
    print(f"\n  원본 바이트에서 복구 가능한 '삭제된 대화': {total}건")
    for fname, ids in rec.items():
        if ids:
            print(f"    {fname}: {len(ids)}건")
            for cid in ids[:5]:
                row = None
                print(f"      {cid}")
    if total == 0:
        print("    (없음)")

    if everything:
        print("\n── --everything : 지울 대상 ─────────────────")
        total_rows = 0
        for t, label in CONVERSATION_TABLES:
            try:
                n = db.execute(f'select count(*) from "{t}"').fetchone()[0]
            except sqlite3.Error:
                continue
            total_rows += n
            if n:
                print(f"    {t:<18} {n:>4}행   {label}")
        print(f"    합계 {total_rows}행")
        print("\n── --everything : 남길 것 ───────────────────")
        for t, label in PRESERVED:
            print(f"    {t:<26} {label}")

    orphans = orphan_chat_files(db)
    print(f"\n  삭제된 대화의 고아 첨부: {len(orphans)}건")
    removable = []
    for chat_id, file_id in orphans:
        row = db.execute("select filename, path from file where id=?", (file_id,)).fetchone()
        name = row[0] if row else "(file 레코드 없음)"
        where = file_referenced_elsewhere(db, file_id)
        mark = f"다른 곳에서 사용 중({where}) — 보존" if where else "제거 가능"
        print(f"    chat {chat_id[:8]}  {name}  → {mark}")
        if not where:
            removable.append((chat_id, file_id, row[1] if row else None))

    if logs:
        print("\n  로그에 남은 흔적:")
        for lg in logs:
            if not os.path.exists(lg):
                print(f"    {lg} — 없음")
                continue
            with open(lg, "rb") as fh:
                blob = fh.read()
            ids = len({m for m in re.findall(rb"[0-9a-f]{8}-[0-9a-f-]{27}", blob)})
            qs = len(re.findall(rb"[?&]q=", blob))
            bits = []
            if ids:
                bits.append(f"UUID {ids}종")
            if qs:
                bits.append(f"검색어 {qs}건")
            print(f"    {os.path.basename(lg)} ({len(blob)/1024:.0f} KB) — "
                  + (", ".join(bits) or "식별 가능한 흔적 없음")
                  + ("  → 비운다" if apply else "  → --apply 시 비운다"))

    if not apply:
        print("\n  ※ 진단만 했다. 실제로 정리하려면 --apply 를 붙여라.")
        print("     정리 내용: 고아 첨부 제거 → WAL 체크포인트 → VACUUM(해제 페이지 폐기)")
        print("     로그(대화 id·검색어)도 함께 비운다.")
        return 0

    print("\n── 정리 ──────────────────────────────────────")

    if everything:
        # 대화에 붙은 업로드 파일은 대화 기록의 일부다 → 함께 지운다.
        # 단 지식베이스 등 다른 곳에서 쓰이면 남긴다(위 file_referenced_elsewhere).
        for (file_id,) in db.execute("select distinct file_id from chat_file").fetchall():
            where = file_referenced_elsewhere(db, file_id)
            row = db.execute("select path from file where id=?", (file_id,)).fetchone()
            if where:
                print(f"  보존: file {file_id[:8]} — {where} 에서 사용 중")
                continue
            target = safe_upload_path(row[0] if row else None, uploads)
            if target:
                os.remove(target)
                print(f"  파일 삭제: {os.path.basename(target)}")
            elif row and row[0]:
                print(f"  파일 없음(건너뜀): {os.path.basename(row[0])}")
            db.execute("delete from file where id=?", (file_id,))
        try:
            db.execute("update automation_run set chat_id=null")
        except sqlite3.Error:
            pass
        for t, _ in CONVERSATION_TABLES:
            try:
                n = db.execute(f'select count(*) from "{t}"').fetchone()[0]
                db.execute(f'delete from "{t}"')
                if n:
                    print(f"  {t} 비움 ({n}행)")
            except sqlite3.Error:
                pass
        db.commit()
    for chat_id, file_id, path in removable:
        db.execute("delete from chat_file where chat_id=? and file_id=?", (chat_id, file_id))
        db.execute("delete from file where id=?", (file_id,))
        target = safe_upload_path(path, uploads)
        if target:
            os.remove(target)
            print(f"  파일 삭제: {os.path.basename(target)}")
        elif path:
            print(f"  파일 없음(건너뜀): {os.path.basename(path)}")
    # 대화가 사라진 chat_file 행은 파일이 남아있든 아니든 정리한다
    db.execute(
        "delete from chat_file where chat_id not in (select id from chat)"
    )
    db.commit()
    print(f"  고아 행 정리 완료 ({len(orphans)}건 대상)")

    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.execute("VACUUM")
    db.commit()
    db.close()

    for lg in logs:
        if True:
            if os.path.exists(lg):
                with open(lg, "w"):
                    pass
                print(f"  로그 비움: {lg}")

    size_after = os.path.getsize(db_path)
    wal_after = os.path.getsize(wal) if os.path.exists(wal) else 0
    print(f"  VACUUM 완료: {size_before/1024:.0f} KB → {size_after/1024:.0f} KB")
    print(f"  WAL        : {wal_before/1024:.0f} KB → {wal_after/1024:.0f} KB")
    print("\n  ※ VACUUM 은 해제된 페이지를 버리지만, 파일시스템 수준의")
    print("     이전 블록까지 지우지는 못한다. 완전 소거가 필요하면")
    print("     디스크 전체 암호화가 유일한 답이다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
