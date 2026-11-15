// Talks to Supabase, or to a local demo store when config.js is empty.
(function () {
  const C = window.STAMP_CONFIG || {};
  const DEMO = !C.SUPABASE_URL || !C.SUPABASE_ANON_KEY;

  // ---------- safe storage ----------
  const mem = {};
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return mem[k] ?? null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { mem[k] = v; } },
    del(k) { try { localStorage.removeItem(k); } catch (e) { delete mem[k]; } }
  };

  // ---------- real backend ----------
  async function rpc(fn, args) {
    let r;
    try {
      r = await fetch(C.SUPABASE_URL.replace(/\/$/, "") + "/rest/v1/rpc/" + fn, {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: C.SUPABASE_ANON_KEY },
        body: JSON.stringify(args)
      });
    } catch (e) { return { ok: false, error: "network" }; }
    if (!r.ok) return { ok: false, error: "network" };
    return r.json();
  }

  // ---------- demo backend ----------
  const DKEY = "stampcard-demo-v2";
  function dLoad() {
    let s = null;
    try { s = JSON.parse(store.get(DKEY)); } catch (e) {}
    if (!s) { s = seed(); dSave(s); }
    return s;
  }
  function dSave(s) { store.set(DKEY, JSON.stringify(s)); }
  function seed() {
    const s = {
      bars: { "old-school": { name: "Old School Pub", reward: "Jarra gratis", stamps_needed: 5,
              cooldown_minutes: 180, staff_pin: "1234", owner_pin: "246810" } },
      cards: {}, events: [], fails: []
    };
    // Sample history so the owner page has something to show in demo mode.
    const names = ["Lucía","Marco","Sofía","Jonas","Aitana","Pierre","Nerea","Luca","Paula","Emma","Hugo","Giulia",
                   "Álvaro","Lena","Carmen","Tom","Irene","Mateo","Chiara","Dani","Inés","Max","Julia","Leo"];
    const now = Date.now(), day = 864e5;
    names.forEach((n, i) => {
      const id = "demo-" + i;
      const joined = now - (2 + ((i * 7) % 26)) * day - 22 * 36e5;
      const c = { id, bar: "old-school", name: n, contact: "+346000000" + String(i).padStart(2, "0"),
                  marketing_opt_in: i % 3 !== 0, stamps: 0, rewards_redeemed: 0, last_stamp_at: null, created_at: joined };
      s.cards[id] = c;
      s.events.push({ bar: "old-school", card: id, kind: "join", t: joined });
      const visits = [1, 2, 3, 1, 4, 6, 2, 1, 5, 3, 0, 2][i % 12];
      for (let v = 0; v < visits; v++) {
        const t = Math.min(now - 3 * 36e5, joined + v * (3 + (i % 4)) * day);
        s.events.push({ bar: "old-school", card: id, kind: "stamp", t });
        c.stamps++; c.last_stamp_at = t;
        if (c.stamps >= 5) { c.stamps = 0; c.rewards_redeemed++; s.events.push({ bar: "old-school", card: id, kind: "redeem", t: t + 6e5 }); }
      }
    });
    return s;
  }
  function cardJson(s, c) {
    const b = s.bars[c.bar];
    return { id: c.id, name: c.name, stamps: c.stamps, stamps_needed: b.stamps_needed, reward: b.reward,
             rewards_redeemed: c.rewards_redeemed, bar_name: b.name, bar: c.bar };
  }
  function checkPin(s, bar, pin, owner) {
    const b = s.bars[bar]; if (!b) return "no_bar";
    const now = Date.now();
    s.fails = s.fails.filter(f => now - f.t < 6e5);
    if (s.fails.filter(f => f.bar === bar).length >= 8) return "locked";
    if (String(pin) === (owner ? b.owner_pin : b.staff_pin)) return "ok";
    s.fails.push({ bar, t: now }); dSave(s); return "bad_pin";
  }
  function norm(p) {
    let v = String(p || "").trim();
    if (v.includes("@")) return v.toLowerCase();
    v = v.replace(/[^0-9+]/g, "");
    if (v.startsWith("0034")) v = "+34" + v.slice(4);
    if (/^[679]\d{8}$/.test(v)) v = "+34" + v;
    return v;
  }
  const nightOf = t => { const d = new Date(t - 6 * 36e5); return d.toISOString().slice(0, 10); };

  const demo = {
    async bar_info({ p_bar }) {
      const b = dLoad().bars[p_bar];
      return b ? { ok: true, name: b.name, reward: b.reward, stamps_needed: b.stamps_needed } : { ok: false, error: "no_bar" };
    },
    async join_card({ p_bar, p_name, p_contact, p_consent, p_marketing }) {
      const s = dLoad();
      if (!s.bars[p_bar]) return { ok: false, error: "no_bar" };
      if (!p_consent) return { ok: false, error: "consent" };
      const contact = norm(p_contact), name = String(p_name || "").trim();
      if (contact.length < 6 || contact.length > 80) return { ok: false, error: "contact" };
      if (!name || name.length > 40) return { ok: false, error: "name" };
      let c = Object.values(s.cards).find(x => x.bar === p_bar && x.contact === contact);
      if (!c) {
        const id = "c" + Math.random().toString(36).slice(2, 12);
        c = { id, bar: p_bar, name, contact, marketing_opt_in: !!p_marketing, stamps: 0, rewards_redeemed: 0,
              last_stamp_at: null, created_at: Date.now() };
        s.cards[id] = c; s.events.push({ bar: p_bar, card: id, kind: "join", t: Date.now() });
      } else if (p_marketing) c.marketing_opt_in = true;
      dSave(s); return { ok: true, card: cardJson(s, c) };
    },
    async get_card({ p_card }) {
      const s = dLoad(), c = s.cards[p_card];
      return c ? { ok: true, card: cardJson(s, c) } : { ok: false, error: "not_found" };
    },
    async add_stamp({ p_card, p_pin }) {
      const s = dLoad(), c = s.cards[p_card];
      if (!c) return { ok: false, error: "not_found" };
      const b = s.bars[c.bar], chk = checkPin(s, c.bar, p_pin, false);
      if (chk !== "ok") return { ok: false, error: chk };
      if (c.stamps >= b.stamps_needed) return { ok: false, error: "full", card: cardJson(s, c) };
      // Demo uses a 1-minute cooldown so you can test quickly (real setup: 3 hours).
      const cd = 60e3;
      if (c.last_stamp_at && Date.now() - c.last_stamp_at < cd)
        return { ok: false, error: "cooldown", minutes_left: Math.ceil((cd - (Date.now() - c.last_stamp_at)) / 6e4) };
      c.stamps++; c.last_stamp_at = Date.now();
      s.events.push({ bar: c.bar, card: c.id, kind: "stamp", t: Date.now() });
      dSave(s); return { ok: true, card: cardJson(s, c) };
    },
    async redeem({ p_card, p_pin }) {
      const s = dLoad(), c = s.cards[p_card];
      if (!c) return { ok: false, error: "not_found" };
      const b = s.bars[c.bar], chk = checkPin(s, c.bar, p_pin, false);
      if (chk !== "ok") return { ok: false, error: chk };
      if (c.stamps < b.stamps_needed) return { ok: false, error: "not_ready" };
      c.stamps = 0; c.rewards_redeemed++;
      s.events.push({ bar: c.bar, card: c.id, kind: "redeem", t: Date.now() });
      dSave(s); return { ok: true, card: cardJson(s, c) };
    },
    async owner_stats({ p_bar, p_pin }) {
      const s = dLoad(), chk = checkPin(s, p_bar, p_pin, true);
      if (chk !== "ok") return { ok: false, error: chk };
      const b = s.bars[p_bar], now = Date.now(), d = 864e5;
      const ev = s.events.filter(e => e.bar === p_bar);
      const cnt = (k, ms) => ev.filter(e => e.kind === k && now - e.t < ms).length;
      const cards = Object.values(s.cards).filter(c => c.bar === p_bar);
      const perCard = {}; ev.filter(e => e.kind === "stamp").forEach(e => perCard[e.card] = (perCard[e.card] || 0) + 1);
      const daily = [];
      for (let i = 13; i >= 0; i--) {
        const key = nightOf(now - i * d);
        daily.push({ day: key,
          visits: ev.filter(e => e.kind === "stamp" && nightOf(e.t) === key).length,
          joins: ev.filter(e => e.kind === "join" && nightOf(e.t) === key).length });
      }
      return { ok: true, bar: { name: b.name, reward: b.reward, stamps_needed: b.stamps_needed, cooldown_minutes: b.cooldown_minutes },
        members: cards.length, opted_in: cards.filter(c => c.marketing_opt_in).length,
        joins_7d: cnt("join", 7 * d), joins_30d: cnt("join", 30 * d),
        visits_tonight: cnt("stamp", 12 * 36e5), visits_7d: cnt("stamp", 7 * d), visits_30d: cnt("stamp", 30 * d),
        redeemed_30d: cnt("redeem", 30 * d),
        returning: Object.values(perCard).filter(n => n >= 2).length,
        inactive_14d: cards.filter(c => now - (c.last_stamp_at || c.created_at) > 14 * d).length,
        daily };
    },
    async owner_members({ p_bar, p_pin }) {
      const s = dLoad(), chk = checkPin(s, p_bar, p_pin, true);
      if (chk !== "ok") return { ok: false, error: chk };
      const iso = t => t ? new Date(t).toISOString() : null;
      const members = Object.values(s.cards).filter(c => c.bar === p_bar).map(c => ({
        name: c.name, contact: c.marketing_opt_in ? c.contact : null, opted_in: c.marketing_opt_in,
        joined: iso(c.created_at), last_visit: iso(c.last_stamp_at),
        visits: s.events.filter(e => e.card === c.id && e.kind === "stamp").length,
        stamps: c.stamps, rewards: c.rewards_redeemed
      })).sort((a, b) => new Date(b.last_visit || b.joined) - new Date(a.last_visit || a.joined));
      return { ok: true, members };
    },
    async owner_update({ p_bar, p_pin, p_reward, p_stamps_needed, p_new_staff_pin }) {
      const s = dLoad(), chk = checkPin(s, p_bar, p_pin, true);
      if (chk !== "ok") return { ok: false, error: chk };
      const b = s.bars[p_bar];
      if (p_reward && p_reward.trim().length >= 2) b.reward = p_reward.trim().slice(0, 60);
      if (p_stamps_needed >= 2 && p_stamps_needed <= 20) b.stamps_needed = p_stamps_needed;
      if (p_new_staff_pin) {
        if (!/^\d{4,6}$/.test(p_new_staff_pin)) return { ok: false, error: "pin_format" };
        b.staff_pin = p_new_staff_pin;
      }
      dSave(s); return { ok: true };
    }
  };

  window.API = {
    demo: DEMO,
    store,
    call(fn, args) { return DEMO ? demo[fn](args) : rpc(fn, args); },
    resetDemo() { store.del(DKEY); }
  };
})();
