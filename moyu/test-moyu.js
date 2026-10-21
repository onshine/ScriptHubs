// 摸鱼农历回归测试：node test-moyu.js（不联网、不发通知）
// 前置准备见 README 的“本地自测”一节：从 moyu.js 抽出农历库与日期引擎到 /tmp，
// 或用环境变量 MOYU_LUNAR / MOYU_ENGINE 指向这两个文件。
const fs = require("fs");
const vm = require("vm");
const BUNDLE = process.env.MOYU_LUNAR || "/tmp/moyu-lunar.js";
const ENGINE = process.env.MOYU_ENGINE || "/tmp/moyu-engine.js";
const bundle = fs.readFileSync(BUNDLE, "utf8");
let engine = fs.readFileSync(ENGINE, "utf8");
engine = engine.replace(/if \(typeof module[\s\S]*$/, "");
engine += "\n;globalThis.__ENGINE__={nextOccurrence,selectEvents,parseEvent,notificationText,beijingDate,DAY_MS};";
const sandbox = { console };
vm.createContext(sandbox);
const lunar = require(process.env.MOYU_LUNAR || "/tmp/moyu-lunar.js");
sandbox.Calendar = lunar;

vm.runInContext(engine, sandbox, { filename: "engine.js" });
const E = sandbox.__ENGINE__;

let pass = 0, fail = 0;
function eq(name, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) { pass++; return; }
  fail++;
  console.log("FAIL", name, "\n  got ", JSON.stringify(got), "\n  want", JSON.stringify(want));
}
const day = (y, m, d) => ({ year: y, month: m, day: d });
function next(date, config, days = 400) {
  const r = E.selectEvents(config, date, days);
  if (r.errors.length) throw new Error(r.errors.join(";"));
  return r.events.map(e => [e.name, e.iso, e.diff, e.lunarYear || null]);
}

// 用户六个农历生日：只按农历月日循环，与出生年无关；跨春节不回退
eq("lunar 10/27", next(day(2026,10,21), "A生日:1994年10月27日$农历#祝福A"), [["A生日","2026-12-05",45,2026]]);
eq("lunar 9/11 passed today -> next year", next(day(2026,10,21), "B生日:1964年9月11日$农历"), [["B生日","2027-10-10",354,2027]]);
eq("lunar 12/28 rolls over CNY", next(day(2026,10,21), "C生日:1969年12月28日$农历"), [["C生日","2027-02-04",106,2026]]);
eq("lunar 1/26 after CNY", next(day(2026,10,21), "D生日:1991年1月26日$农历"), [["D生日","2027-03-03",133,2027]]);
eq("lunar 3/26", next(day(2026,10,21), "E生日:2018年3月26日$农历"), [["E生日","2027-05-02",193,2027]]);
eq("lunar 7/7", next(day(2026,10,21), "F生日:1949年7月7日$农历"), [["F生日","2027-08-08",291,2027]]);
eq("birth year must not matter", next(day(2026,10,21), "G:2001年9月11日$农历"), next(day(2026,10,21), "G:17年9月11日$农历"));
eq("no year = this lunar month", next(day(2026,10,21), "H:9月11日$农历"), next(day(2026,10,21), "H:2026年9月11日$农历"));
// 春节前后跨农历年（2026 春节 = 2026-02-17，2027 春节 = 2027-02-06，均有 8 天假期）
eq("Jan 1 -> this lunar-year CNY", next(day(2026,1,1), "<春节>"), [["春节","2026-02-15",45,2026]]);
eq("CNY day itself stays on the day", next(day(2026,2,17), "<春节>"), [["春节","2026-02-17",0,2026]]);
eq("Dec 31 -> next lunar year", next(day(2026,12,31), "<春节>"), [["春节","2027-02-05",36,2027]]);
eq("CNY eve", next(day(2026,1,1), "<除夕>"), [["除夕","2026-02-16",46,2025]]);
eq("actual CNY date kept as trueDate", E.selectEvents("<春节>", day(2026,1,1), 400).events[0].trueDate, "2026-02-17");
// 农历月只有 29 天时，卅日按廿九提醒
eq("lunar 30 fallback", next(day(2026,10,21), "I:12月30日$农历"), [["I","2027-02-05",107,2026]]);
eq("lunar 30 note", /仅29天/.test(E.selectEvents("I:12月30日$农历", day(2026,10,21), 400).events[0].note), true);
// 闰月缺失时退回普通同月
eq("missing leap month falls back", /本年无该闰月/.test((E.selectEvents("J:闰2月3日$农历", day(2026,10,21), 1200).events[0]||{}).note||""), true);
// 公历生日
eq("solar 2/29 -> next leap year", next(day(2026,3,1), "K:2月29日", 800), [["K","2028-02-29",730,null]]);
eq("solar this year", next(day(2026,10,21), "L:12月5日$阳历"), [["L","2026-12-05",45,null]]);
// 内置节日的公历/星期规则
eq("mother day 2027", next(day(2027,1,1), "<母亲节>"), [["母亲节","2027-05-09",128,null]]);
eq("father day 2026", next(day(2026,1,1), "<父亲节>"), [["父亲节","2026-06-21",171,null]]);
eq("qingming shifts to holiday start", next(day(2026,3,1), "<清明节>"), [["清明节","2026-04-05",35,null]]);
eq("national day pre-holiday", next(day(2026,9,1), "<国庆节>"), [["国庆节","2026-10-01",30,null]]);
eq("new year pre-holiday", next(day(2026,12,1), "<元旦>"), [["元旦","2027-01-01",31,null]]);
// 双历法、错误容错、通知文案
eq("dual calendars", E.selectEvents("生日:1990年3月14日$阳历$农历", day(2026,10,21), 400).events.map(e => e.name), ["生日","生日（农历）"]);
eq("bad entries do not break others", (() => { const r = E.selectEvents("<不存在的节>&坏的&<春节>", day(2026,10,21), 400); return [r.errors.length, r.events.map(e => e.name)]; })(), [2,["春节"]]);
const nt = E.notificationText(E.selectEvents("<春节>&老婆生日:1994年10月27日$农历#祝老婆生日快乐", day(2027,2,6), 400).events, { days: 400, almanac: false }, { today: day(2027,2,6) });
eq("notification title", /^【来摸鱼啦】2月6日 农历正月初一$/.test(nt.title), true);
eq("notification today line", /今天就是春节/.test(nt.body), true);
eq("notification shows lunar date", /农历十月廿七/.test(nt.body), true);
console.log(`pass=${pass} fail=${fail}`);
process.exitCode = fail ? 1 : 0;

