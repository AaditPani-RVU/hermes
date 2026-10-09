.pragma library

function pad(n) {
    return n < 10 ? "0" + n : "" + n;
}

function clock(ts) {
    const d = new Date(ts * 1000);
    return pad(d.getHours()) + ":" + pad(d.getMinutes());
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Chat list timestamp: 14:05 / Yesterday / Tuesday / 03 Oct 2025
function listTime(ts) {
    if (!ts)
        return "";
    const d = new Date(ts * 1000), now = new Date();
    if (sameDay(d, now))
        return clock(ts);
    const y = new Date(now);
    y.setDate(now.getDate() - 1);
    if (sameDay(d, y))
        return "Yesterday";
    if (now - d < 6 * 864e5)
        return DAYS[d.getDay()];
    if (d.getFullYear() === now.getFullYear())
        return d.getDate() + " " + MONTHS[d.getMonth()];
    return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
}

// Day separator in a conversation.
function dayLabel(ts) {
    const d = new Date(ts * 1000), now = new Date();
    if (sameDay(d, now))
        return "Today";
    const y = new Date(now);
    y.setDate(now.getDate() - 1);
    if (sameDay(d, y))
        return "Yesterday";
    if (now - d < 6 * 864e5)
        return DAYS[d.getDay()];
    const base = DAYS[d.getDay()].slice(0, 3) + ", " + d.getDate() + " " + MONTHS[d.getMonth()];
    return d.getFullYear() === now.getFullYear() ? base : base + " " + d.getFullYear();
}

function dayKey(ts) {
    const d = new Date(ts * 1000);
    return d.getFullYear() * 10000 + d.getMonth() * 100 + d.getDate();
}

function lastSeen(p) {
    if (!p)
        return "";
    if (p.online)
        return "online";
    if (!p.lastSeen)
        return "";
    const d = new Date(p.lastSeen * 1000), now = new Date();
    if (sameDay(d, now))
        return "last seen today at " + clock(p.lastSeen);
    return "last seen " + listTime(p.lastSeen).toLowerCase() + " at " + clock(p.lastSeen);
}

function size(n) {
    if (!n)
        return "";
    if (n > 1 << 30)
        return (n / (1 << 30)).toFixed(1) + " GB";
    if (n > 1 << 20)
        return (n / (1 << 20)).toFixed(1) + " MB";
    if (n > 1 << 10)
        return Math.round(n / (1 << 10)) + " KB";
    return n + " B";
}

function duration(secs) {
    secs = Math.max(0, Math.round(secs));
    return Math.floor(secs / 60) + ":" + pad(secs % 60);
}

function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// WhatsApp markup -> Qt rich text. Code spans are protected from further formatting.
function richText(text, linkColor, codeBg) {
    if (!text)
        return "";
    let s = escapeHtml(text);
    const codes = [];
    s = s.replace(/```([\s\S]+?)```/g, (m, c) => {
        codes.push("<span style=\"font-family:'JetBrainsMono Nerd Font',monospace; background:" + codeBg + ";\">" + c + "</span>");
        return "\u0000" + (codes.length - 1) + "\u0000";
    });
    s = s.replace(/`([^`\n]+)`/g, (m, c) => {
        codes.push("<span style=\"font-family:'JetBrainsMono Nerd Font',monospace; background:" + codeBg + ";\">&nbsp;" + c + "&nbsp;</span>");
        return "\u0000" + (codes.length - 1) + "\u0000";
    });
    s = s.replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)\]'"])/g, "<a href=\"$1\" style=\"color:" + linkColor + ";\">$1</a>");
    const edge = "(^|[\\s.,;:!?(\\[\"'])";
    s = s.replace(new RegExp(edge + "\\*([^*\\n]+)\\*(?=$|[\\s.,;:!?)\\]\"'])", "g"), "$1<b>$2</b>");
    s = s.replace(new RegExp(edge + "_([^_\\n]+)_(?=$|[\\s.,;:!?)\\]\"'])", "g"), "$1<i>$2</i>");
    s = s.replace(new RegExp(edge + "~([^~\\n]+)~(?=$|[\\s.,;:!?)\\]\"'])", "g"), "$1<s>$2</s>");
    s = s.replace(/^&gt; (.*)$/gm, "<span style=\"color:" + linkColor + ";\">▎</span><i>$1</i>");
    s = s.replace(/^[-*] (.*)$/gm, "• $1");
    s = s.replace(/@([^\s@<]{2,30})/g, "<b>@$1</b>");
    s = s.replace(/\u0000(\d+)\u0000/g, (m, i) => codes[+i]);
    return s.replace(/\n/g, "<br>");
}

// True when a message is only 1-3 emoji: shown big, like WhatsApp.
function isJumboEmoji(text) {
    if (!text || text.length > 24)
        return false;
    const stripped = text.replace(/[\s‍️]/g, "");
    if (!stripped)
        return false;
    try {
        const re = new RegExp("^(?:\\p{Extended_Pictographic}|\\p{Emoji_Modifier}|\\p{Regional_Indicator})+$", "u");
        if (!re.test(stripped))
            return false;
        const count = (stripped.match(new RegExp("\\p{Extended_Pictographic}|\\p{Regional_Indicator}{2}", "gu")) || []).length;
        return count > 0 && count <= 3;
    } catch (e) {
        // Engine without Unicode property escapes: approximate via surrogate pairs.
        return /^(?:[\ud83c-\udbff][\udc00-\udfff]|[\u2600-\u27bf]){1,3}$/.test(stripped);
    }
}

function initials(name) {
    if (!name)
        return "?";
    let clean = name;
    try {
        clean = name.replace(new RegExp("[^\\p{L}\\p{N}\\s]", "gu"), "").trim();
    } catch (e) {
        clean = name.replace(/[^\w\s]/g, "").trim();
    }
    const parts = clean.split(/\s+/).filter(p => p.length);
    if (parts.length === 0)
        return name.trim().charAt(0) || "?";
    if (parts.length === 1)
        return parts[0].charAt(0).toUpperCase();
    return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase();
}

function fileUrl(path) {
    if (!path)
        return "";
    if (path.startsWith("file://"))
        return path;
    return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F");
}

function docIcon(mime, name) {
    const n = (name || "").toLowerCase();
    if (mime === "application/pdf" || n.endsWith(".pdf"))
        return "picture_as_pdf";
    if (/zip|rar|7z|tar|gzip/.test(mime))
        return "folder_zip";
    if (/sheet|excel|csv/.test(mime) || /\.(xlsx?|csv|ods)$/.test(n))
        return "table";
    if (/presentation|powerpoint/.test(mime) || /\.(pptx?|odp)$/.test(n))
        return "slideshow";
    if (/word|document|text/.test(mime) || /\.(docx?|odt|txt|md)$/.test(n))
        return "description";
    if (/audio/.test(mime))
        return "audio_file";
    if (/video/.test(mime))
        return "video_file";
    if (/apk|android/.test(mime))
        return "android";
    return "draft";
}

// Compact age for triage rows: now / 5m / 2h / 3d / 2w
function age(ts) {
    const s = Math.max(0, Date.now() / 1000 - ts);
    if (s < 60)
        return "now";
    if (s < 3600)
        return Math.floor(s / 60) + "m";
    if (s < 86400)
        return Math.floor(s / 3600) + "h";
    if (s < 14 * 86400)
        return Math.floor(s / 86400) + "d";
    return Math.floor(s / (7 * 86400)) + "w";
}

// Upcoming time: "18:00" today, "Tomorrow 09:00", "Sat 10:00", "12 Oct 09:00"
function whenLabel(ts) {
    const d = new Date(ts * 1000), now = new Date();
    if (sameDay(d, now))
        return clock(ts);
    const t = new Date(now);
    t.setDate(now.getDate() + 1);
    if (sameDay(d, t))
        return "Tomorrow " + clock(ts);
    if (d - now < 6 * 864e5)
        return DAYS[d.getDay()].slice(0, 3) + " " + clock(ts);
    return d.getDate() + " " + MONTHS[d.getMonth()] + " " + clock(ts);
}

// Snooze presets, computed from now. Each is { key, label, ts }.
function snoozeOptions() {
    const now = new Date();
    const at = (days, h, m) => {
        const d = new Date(now);
        d.setDate(now.getDate() + days);
        d.setHours(h, m || 0, 0, 0);
        return Math.floor(d / 1000);
    };
    const out = [];
    out.push({ label: "In an hour", ts: Math.floor(now / 1000) + 3600 });
    if (now.getHours() < 14)
        out.push({ label: "This afternoon", ts: at(0, 15) });
    if (now.getHours() < 17)
        out.push({ label: "This evening", ts: at(0, 18) });
    else
        out.push({ label: "Later tonight", ts: Math.floor(now / 1000) + 3 * 3600 });
    out.push({ label: "Tomorrow morning", ts: at(1, 9) });
    const dow = now.getDay();
    if (dow >= 1 && dow <= 4)
        out.push({ label: "This weekend", ts: at(6 - dow, 10) });
    out.push({ label: "Next week", ts: at(((8 - dow) % 7) || 7, 9) });
    return out;
}

// Parse a typed snooze time. Returns unix seconds, or 0 if it doesn't parse or is in the past.
// Accepts: "in 2h", "45m", "3d", "18:30", "6pm", "6:15pm", "tomorrow", "tmr 14:00", "fri", "friday 9am".
function parseWhen(input) {
    const s = (input || "").trim().toLowerCase().replace(/\s+/g, " ");
    if (!s)
        return 0;
    const now = new Date();
    let m = s.match(/^(?:in )?(\d+(?:\.\d+)?) ?(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$/);
    if (m) {
        const n = parseFloat(m[1]);
        const unit = m[2][0] === "m" ? 60 : m[2][0] === "h" ? 3600 : 86400;
        return Math.floor(now / 1000 + n * unit);
    }
    const days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    let dayOffset = -1;
    let rest = s;
    m = rest.match(/^(today|tonight|tomorrow|tmr|tmrw|(sun|mon|tue|wed|thu|fri|sat)[a-z]*)\b ?(.*)$/);
    if (m) {
        rest = m[3];
        if (m[1] === "today" || m[1] === "tonight")
            dayOffset = 0;
        else if (m[1].startsWith("t"))
            dayOffset = 1;
        else {
            const target = days.indexOf(m[2]);
            dayOffset = ((target - now.getDay()) + 7) % 7 || 7;
        }
        if (!rest)
            rest = m[1] === "tonight" ? "20:00" : "9:00";
    }
    rest = rest.replace(/^at /, "");
    m = rest.match(/^(\d{1,2})(?::(\d{2}))? ?(am|pm)?$/);
    if (!m)
        return 0;
    let h = parseInt(m[1]);
    const min = m[2] ? parseInt(m[2]) : 0;
    if (m[3] === "pm" && h < 12)
        h += 12;
    if (m[3] === "am" && h === 12)
        h = 0;
    if (h > 23 || min > 59)
        return 0;
    const d = new Date(now);
    d.setHours(h, min, 0, 0);
    if (dayOffset >= 0)
        d.setDate(now.getDate() + dayOffset);
    else if (d <= now)
        d.setDate(d.getDate() + 1); // a bare time that's passed means tomorrow
    return d > now ? Math.floor(d / 1000) : 0;
}

// ---- Dates in messages ----
// findWhen("meet fri 5pm?", sentTs) -> { ts, label, text } for the first upcoming date/time in a message,
// read relative to when it was sent ("tomorrow" in yesterday's message is today). null if none, or if it's past.
// Needs a day ("tmrw", "friday", "12 oct", "15/10") or a clear time ("5pm", "17:30", "at 6", "6 baje").
const _MON = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?";
const _WD = "(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(?:day|nesday|sday|rsday|urday)?";
const _DAY_RE = new RegExp("\\b(?:(day after tomorrow|parso)|(today|tonight|tomorrow|tmrw|tmr|tomo|kal|aaj raat|aaj)|(?:(this|next|on|coming) )?(" + _WD + ")"
    + "|(\\d{1,2})(?:st|nd|rd|th)? (?:of )?(" + _MON + ")|(" + _MON + ") (\\d{1,2})(?:st|nd|rd|th)?"
    + "|(\\d{1,2})[/.](\\d{1,2})(?![/.]?\\d)|on the (\\d{1,2})(?:st|nd|rd|th))\\b", "i");
const _TIME_RE = /(?:\b(at|@|by|around|till|until)\s*)?\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|baje|o'?clock|hrs)?(?![\d/.:%])|\b(noon|midnight|morning|afternoon|evening|night|subah|dopahar|shaam|raat)\b/ig;

function _monthIndex(s) {
    return MONTHS.findIndex(m => s.toLowerCase().startsWith(m.toLowerCase()));
}

// A part-of-day word right after a time: "7 in the evening", "5 baje shaam".
function _nextPeriod(s, from) {
    const m = s.slice(from, from + 20).match(/^\s*(?:in the |baje |o'?clock )?\s*(morning|afternoon|evening|night|subah|dopahar|shaam|raat)\b/i);
    return m ? m[1].toLowerCase() : "";
}

function findWhen(text, sentTs) {
    if (!text || text.length > 2000)
        return null;
    const s = text.replace(/https?:\/\/\S+/g, " ");
    const sent = new Date((sentTs || Date.now() / 1000) * 1000);
    let base = null; // Date at midnight of the day mentioned
    let dayText = "", dayIdx = -1;
    const m = s.match(_DAY_RE);
    if (m) {
        dayText = m[0];
        dayIdx = m.index;
        base = new Date(sent);
        base.setHours(0, 0, 0, 0);
        if (m[1]) {
            base.setDate(base.getDate() + 2);
        } else if (m[2]) {
            const w = m[2].toLowerCase();
            if (w !== "today" && w !== "tonight" && !w.startsWith("aaj"))
                base.setDate(base.getDate() + 1);
        } else if (m[4]) {
            const target = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].indexOf(m[4].slice(0, 3).toLowerCase());
            let diff = (target - base.getDay() + 7) % 7;
            if (diff === 0 && (m[3] || "").toLowerCase() === "next")
                diff = 7;
            base.setDate(base.getDate() + diff);
        } else {
            let day, mon;
            if (m[5]) { day = +m[5]; mon = _monthIndex(m[6]); }
            else if (m[7]) { day = +m[8]; mon = _monthIndex(m[7]); }
            else if (m[9]) { day = +m[9]; mon = +m[10] - 1; } // dd/mm, as written in India and the UK
            else { day = +m[11]; mon = base.getDate() <= day ? base.getMonth() : base.getMonth() + 1; }
            if (day < 1 || day > 31 || mon < 0 || mon > 12)
                return null;
            base = new Date(sent.getFullYear(), mon, day);
            if (base < new Date(sent.getFullYear(), sent.getMonth(), sent.getDate()) - 864e5 * 60)
                base.setFullYear(base.getFullYear() + 1); // "5 jan" said in December
        }
    }

    // A time near the day (or anywhere, if there's no day). A clock time wins over a part of the day,
    // which only sets am/pm ("shaam 5 baje" = 17:00, "subah 7" = 07:00).
    let hour = -1, minute = 0, timeText = "", period = "";
    _TIME_RE.lastIndex = 0;
    let t;
    while ((t = _TIME_RE.exec(s)) !== null) {
        if (dayIdx >= 0 && Math.abs(t.index - dayIdx) > dayText.length + 30)
            continue;
        if (dayIdx >= 0 && t.index >= dayIdx && t.index < dayIdx + dayText.length)
            continue; // the "12" of "12 oct"
        if (t[5]) {
            if (!period)
                period = t[5].toLowerCase();
            continue;
        }
        const suffix = (t[4] || "").toLowerCase().replace(/\./g, "");
        const lead = (t[1] || "").toLowerCase();
        if (!suffix && !t[3] && !lead && !period)
            continue; // a bare number: "5 people"
        if (!suffix && !t[3] && !base && !period && lead !== "at" && lead !== "@")
            continue;
        let h = +t[2];
        const mm = t[3] ? +t[3] : 0;
        if (h > 23 || mm > 59)
            continue;
        if (suffix === "pm" && h < 12) h += 12;
        else if (suffix === "am" && h === 12) h = 0;
        else if (suffix !== "am" && suffix !== "pm" && suffix !== "hrs" && h >= 1 && h <= 11) {
            const p = period || _nextPeriod(s, _TIME_RE.lastIndex);
            if (/^(afternoon|evening|night|dopahar|shaam|raat)$/.test(p) || (!p && h <= 7))
                h += 12; // "at 5", "6 baje": evening is far likelier
        }
        hour = h;
        minute = mm;
        timeText = t[0];
        break;
    }
    if (hour < 0 && period && (base || period === "noon" || period === "midnight")) {
        hour = { noon: 12, midnight: 0, morning: 9, afternoon: 15, evening: 18, night: 20, subah: 9, dopahar: 14, shaam: 18, raat: 20 }[period];
        timeText = period;
    }
    if (base && hour < 0 && /^(today|aaj)$/i.test(dayText))
        return null; // "I'm tired today" isn't a plan
    if (!base && hour < 0)
        return null;
    let when;
    if (base) {
        when = new Date(base);
        if (hour >= 0)
            when.setHours(hour, minute, 0, 0);
        else if (dayText.toLowerCase() === "tonight" || dayText.toLowerCase() === "aaj raat") {
            when.setHours(20, 0, 0, 0);
            hour = 20;
        }
        else
            when.setHours(9, 0, 0, 0);
    } else {
        when = new Date(sent);
        when.setHours(hour, minute, 0, 0);
        if (when <= sent)
            when.setDate(when.getDate() + 1); // "at 6" after 6pm means tomorrow
    }
    const ts = Math.floor(when / 1000);
    if (ts < Date.now() / 1000 - 3600)
        return null; // already happened
    const hasTime = hour >= 0;
    const now = new Date();
    let label;
    const tmr = new Date(now); tmr.setDate(now.getDate() + 1);
    if (sameDay(when, now)) label = "Today";
    else if (sameDay(when, tmr)) label = "Tomorrow";
    else if (when - now < 6 * 864e5) label = DAYS[when.getDay()];
    else label = DAYS[when.getDay()].slice(0, 3) + " " + when.getDate() + " " + MONTHS[when.getMonth()];
    if (hasTime)
        label += " " + clock(ts);
    return { ts: ts, label: label, hasTime: hasTime, text: (dayText + (timeText && dayText ? " … " : "") + timeText).trim() };
}

// Google Calendar "new event" link, filled in for you to check and save (nothing is added automatically).
function calendarUrl(title, ts, hasTime, details) {
    const d = new Date(ts * 1000);
    const fmt = x => x.getFullYear() + pad(x.getMonth() + 1) + pad(x.getDate());
    let dates;
    if (hasTime) {
        const e = new Date(d.getTime() + 3600e3);
        const full = x => fmt(x) + "T" + pad(x.getHours()) + pad(x.getMinutes()) + "00";
        dates = full(d) + "/" + full(e);
    } else {
        const e = new Date(d); e.setDate(d.getDate() + 1);
        dates = fmt(d) + "/" + fmt(e);
    }
    return "https://calendar.google.com/calendar/render?action=TEMPLATE&text=" + encodeURIComponent(title)
        + "&dates=" + dates + "&details=" + encodeURIComponent(details || "");
}
