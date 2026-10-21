const fs = require("fs");
const vm = require("vm");
const dir = "/var/minis/workspace/moyu-port/repo/moyu/";
const src = fs.readFileSync(dir + "moyu.js", "utf8");
const config = [
  "<元宵节>", "<清明节>", "<劳动节>", "<端午节>", "<中秋节>", "<国庆节>", "<元旦>", "<春节>",
  "<母亲节>", "<儿童节>", "<父亲节>", "<七夕节>", "<情人节>",
  "❤️老婆生日🎂:1994年10月27日$农历#祝亲爱的老婆生日快乐",
  "❤️妈妈生日🎂:1964年9月11日$农历",
  "❤️爸爸生日🎂:1969年12月28日$农历",
  "❤️姐姐生日🎂:1991年1月26日$农历",
  "❤️苏苏生日🎂:2018年3月26日$农历",
  "奶奶生日:1949年7月7日$农历"
].join("&");
let out = "";
const sandbox = {
  console: { log: (...a) => { out += a.map(String).join(" ") + "\n"; } },
  $loon: "Loon/3.5.1",
  $argument: { moyu_festival_conf: config, moyu_remind_days: 50, moyu_bark_key: "", moyu_show_almanac: true, moyu_debug: true, moyu_notify_with_media: false },
  $persistentStore: { read: () => null, write: () => true },
  $notification: { post: (t, s, b) => { out += "NOTIFY|" + t + "|" + b + "\n"; } },
  $httpClient: { post: () => {} },
  $done: () => { console.log(out); }
};
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: "moyu.js", timeout: 20000 });
