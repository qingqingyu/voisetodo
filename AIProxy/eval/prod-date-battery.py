#!/usr/bin/env python3
# 生产侧日期电池(2026-11-04 air 出口分池事故沉淀):从生产端点逐席位验证
# 日期家族计算——本地 harness 走好池,永远看不见坏池;日期类变更必须双轨评测
# (本地回归 + 本电池)。用法:
#   python3 prod-date-battery.py [席位id,默认 OR_DEEPSEEK_FLASH;可逗号分隔多个] [锚日期,默认今天]
#   token 从 AIProxy/.dev.vars 读 APP_TOKEN/ADMIN_TOKEN(相对 eval 目录,gitignored)
# 注意:连发会被 IP_RATE_PER_MINUTE(10/min)掐,内置 7s 节流;钉席位测试有 35s
# isolate 缓存等待;跑完自动恢复 deepseek 主力。
import subprocess, json, re, time, sys, os
env = dict(l.split("=",1) for l in open(DV).read().splitlines() if "=" in l and not l.startswith("#"))
APP, ADM = env["APP_TOKEN"].strip(), env["ADMIN_TOKEN"].strip()
if ANCHOR is None:
    ANCHOR = time.strftime("%Y-%m-%d")  # 默认今天(设备/本地口径由调用方保证)
# (id, transcript, locale, expected_due)
CASES = [
  ("zh-tomorrow","明天买牛奶","zh","2026-11-06"),
  ("zh-friday","周五晚上看电影","zh","2026-11-06"),
  ("zh-nextmon","下周一开周会","zh","2026-11-09"),
  ("zh-nextfri","下周五交报告","zh","2026-11-13"),
  ("zh-monthend","月底前交税","zh","2026-11-30"),
  ("zh-nextmonth","下月初复查牙齿","zh","2026-12-01"),
  ("zh-3days","三天后取快递","zh","2026-11-08"),
  ("en-tomorrow","buy milk tomorrow","en","2026-11-06"),
  ("en-friday","book a table for Friday night","en","2026-11-06"),
  ("en-nextmon","team standup next Monday","en","2026-11-09"),
  ("en-nextfri","submit the report next Friday","en","2026-11-13"),
  ("en-monthend","pay taxes before the end of the month","en","2026-11-30"),
  ("en-3days","dentist appointment in 3 days","en","2026-11-08"),
  ("ja-nextmon","来週の月曜日に会議","ja","2026-11-09"),
  ("ja-friday","金曜日の夜に映画を見る","ja","2026-11-06"),
  ("ja-monthend","月末までにレポートを提出","ja","2026-11-30"),
  ("ja-3days","3日後に荷物を受け取る","ja","2026-11-08"),
]
def admin(pin):
    subprocess.run(["curl","-s","-m","15","-X","POST","https://ai.saydo.org/v1/admin/providers/primary",
        "-H",f"X-Admin-Token: {ADM}","-H","Content-Type: application/json",
        "-d",json.dumps({"primaryId":pin})], capture_output=True)
def probe(cid, ts, lc):
    dev = f"batt-{cid}-{int(time.time())}"
    r = subprocess.run(["curl","-s","-m","60","https://ai.saydo.org/v1/todo-extractions",
        "-H","Content-Type: application/json","-H",f"X-App-Token: {APP}",
        "-H",f"X-Device-ID: {dev}","-H",f"X-Local-Date: {ANCHOR}",
        "-d",json.dumps({"transcript":ts,"locale":lc,"stream":True})], capture_output=True, text=True)
    try:
        text = "".join(json.loads('"'+m.group(1)+'"') for m in re.finditer(r'"text":\s*"((?:[^"\\]|\\.)*)"', r.stdout))
        m = re.search(r'"due_date":\s*"?(\d{4}-\d{2}-\d{2})', text)
        return m.group(1) if m else "(无)"
    except Exception:
        return "(解析失败)"
results = {}
try:
    for seat in SEATS:
        admin(seat); time.sleep(35)
        print(f"\n======== {seat} ========", flush=True)
        ok = 0
        for cid, ts, lc, want in CASES:
            time.sleep(7); got = probe(cid, ts, lc)
            mark = "✓" if got == want else "✗"
            ok += got == want
            print(f"  {mark} {cid:<14} want={want} got={got}", flush=True)
        results[seat] = (ok, len(CASES))
finally:
    admin("OR_DEEPSEEK_FLASH")  # 恢复主力
print("\n======== 汇总 ========", flush=True)
for seat,(ok,n) in results.items(): print(f"  {seat}: {ok}/{n}", flush=True)
print("主力已恢复: OR_DEEPSEEK_FLASH", flush=True)
