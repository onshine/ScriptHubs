#!/usr/bin/env node
// 用法：node selftest.js（在 moyu/ 目录下，读同目录的 moyu.js）
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "moyu.js"), "utf8");
const a = src.indexOf("// ===== moyu:lunar:start ===="), b = src.indexOf("// ===== moyu:lunar:end ====");
let body = src.slice(a, b).split("\n").slice(1).join("\n").replace(/\s+$/, "");
const keep = body.indexOf("return __CAL__;");
body = body.slice(0, keep)
fs.writeFileSync("/tmp/moyu-lunar.js", body + "\nreturn __CAL__;\n})();\nmodule.exports = __CAL__;\n");
fs.writeFileSync("/tmp/moyu-engine.js", src.slice(src.indexOf("const SCRIPT_VERSION"), src.indexOf("// ===== moyu:engine:end ====")));
require("./test-moyu.js");
