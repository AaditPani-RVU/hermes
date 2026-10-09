// Date detection tests: node ui/tests/format.test.js
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "../Services/Format.js"), "utf8").replace(".pragma library", "");
const F = new Function(src + "; return { findWhen, calendarUrl };")();
// Sent: Fri 9 Oct 2026 10:00 local. Fake "now" = same moment so nothing counts as past.
const sent = new Date(2026, 9, 9, 10, 0).getTime() / 1000;
Date.now = () => sent * 1000;
const cases = [
  ["meet fri 5pm?", "Fri 9 Oct 17:00"],
  ["kal milte hain 6 baje", "Sat 10 Oct 18:00"],
  ["submission deadline 15/10", "Thu 15 Oct 09:00"],
  ["exam on 12th oct at 9:30am", "Mon 12 Oct 09:30"],
  ["call me at 7", "Fri 9 Oct 19:00"],
  ["we were 5 people", null],
  ["tonight?", "Fri 9 Oct 20:00"],
  ["next monday morning standup", "Mon 12 Oct 09:00"],
  ["see https://x.com/12/10 lol", null],
  ["tmrw 11:30", "Sat 10 Oct 11:30"],
  ["Lab moved to Oct 20th, 2pm", "Tue 20 Oct 14:00"],
  ["paid 500 rs", null],
  ["at 9 we leave", "Sat 10 Oct 09:00"],
  ["dinner at 8.30pm", "Fri 9 Oct 20:30"],
  ["I'll be there by 4:45", "Fri 9 Oct 16:45"],
  ["ok", null],
  ["bhai aaj raat ko call kar lena", "Fri 9 Oct 20:00"],
  ["parso shaam 5 baje aana", "Sun 11 Oct 17:00"],
  ["kal subah 10 baje", "Sat 10 Oct 10:00"],
  ["aaj kya plan hai", null], ["I am tired today", null], ["5 baje shaam ko", "Fri 9 Oct 17:00"], ["subah 7 baje gym", "Sat 10 Oct 07:00"], ["tomorrow", "Sat 10 Oct 09:00"],
];
const D = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"], M = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const p = n => String(n).padStart(2, "0");
let fail = 0;
for (const [text, want] of cases) {
  const r = F.findWhen(text, sent);
  const got = r ? (d => `${D[d.getDay()]} ${d.getDate()} ${M[d.getMonth()]} ${p(d.getHours())}:${p(d.getMinutes())}`)(new Date(r.ts * 1000)) : null;
  const ok = got === want;
  if (!ok) fail++;
  console.log(ok ? "ok  " : "FAIL", JSON.stringify(text), "→", got, ok ? "" : "(want " + want + ")", r ? "[" + r.label + " | " + r.text + "]" : "");
}
console.log(F.calendarUrl("Lab", sent + 3600, true, "from chat").slice(0, 110));
process.exit(fail ? 1 : 0);
