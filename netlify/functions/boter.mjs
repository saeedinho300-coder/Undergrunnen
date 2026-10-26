// Undergrunnen – 20 datastyrte spillere (boter).
// Kjører hvert kvarter: hver bot gjør et utvalg vanlige handlinger gjennom samme API som ekte spillere.
// Alle uventede feil samles og rapporteres, slik at de kan rettes.
import { getDatabase } from "@netlify/database";

const BOTER = [
  "Svarte_Per", "Lille_Ola", "Kniven", "Bergens_Bjørn", "Nattugla", "Tromsø_Tone", "Sjarmøren", "Fjordulven",
  "Stille_Siri", "Kaptein_Kåre", "Gamle_Geir", "Raske_Rune", "Lommetyven", "Dama_i_rødt", "Snøhvit", "Bossen_Bent",
  "Hasjkongen", "Pokerfjes", "Revolver_Rita", "Uglen",
];
const CHAT = ["Noen som vil samarbeide om et ran?", "Fengselet er fullt igjen", "Hvem selger kuler billig?", "Lottopotten er feit denne uka",
  "Blackjack-dealeren jukser, jeg sier det bare", "Sett pengene i banken, folkens", "Bergen er stille i kveld", "Ny i byen? Si hei!",
  "Trenger folk til gjengen", "Børsen gikk rett til himmels", "Noen som har sett Kniven?", "Har noen en Porsche til salgs?"];
const GJENGER = [["Nattens Menn", "NTM"], ["Fjordmafiaen", "FJM"], ["Bryggegjengen", "BRY"], ["Polarbandittene", "PLB"]];
const BIO = (n) => `[center][size=5][b]${n.toUpperCase()}[/b][/size]\n[i]Datastyrt spiller i Undergrunnen[/i][/center]\n\n[b]Base:[/b] ${["Oslo", "Bergen", "Trondheim"][n.length % 3]}\n[b]Motto:[/b] ${["Penger snakker.", "Aldri tilgi, aldri glem.", "Stille vann har dyp bunn.", "Først til mølla."][n.length % 4]}\n\n[quote]Jeg er en bot som tester spillet hver dag.[/quote]`;

const tilfeldig = (a) => a[Math.floor(Math.random() * a.length)];
const sjanse = (p) => Math.random() < p;
const klamp = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.floor(v)));

export default async () => {
  const start = Date.now();
  const db = getDatabase();
  const q = async (strings, ...vals) => { const r = await db.sql(strings, ...vals); return Array.isArray(r) ? r : (r?.rows ?? []); };
  const regelfeil = {}; const uventet = []; let kall = 0; let aktive = 0;

  const notat = (bot, fn, args, feil, kode) => {
    uventet.push({ tid: new Date().toISOString(), bot, fn, args, feil: String(feil).slice(0, 300), kode: kode ?? null });
  };
  // Kaller spillets API som en vanlig spiller. Spillregler (P0001) telles, alt annet er en feil.
  async function api(bot, fn, args = {}) {
    kall++;
    try {
      const [rad] = await q`select public.api(${bot.id}::uuid, ${fn}, ${JSON.stringify(args)}::jsonb) as r`;
      let r = rad ? rad.r : null;
      if (typeof r === "string") { try { r = JSON.parse(r); } catch { /* tekst */ } }
      if (r && r.fengsel) bot.inne = true;   // havnet i fengsel: resten av runden avbrytes
      return r;
    } catch (e) {
      const kode = e?.code ?? e?.cause?.code;
      const melding = String(e?.cause?.message || e?.message || e);
      if (kode === "P0001" && /sitter i fengsel/.test(melding)) bot.inne = true;
      if (kode === "P0001") { const k = fn + ": " + melding.replace(/\d[\d\s]*/g, "#"); regelfeil[k] = (regelfeil[k] || 0) + 1; }
      else notat(bot.navn, fn, args, melding, kode);
      return null;
    }
  }
  const sjekk = (bot, fn, betingelse, tekst) => { if (!betingelse) notat(bot.navn, fn, null, "Logikkfeil: " + tekst, "LOGIKK"); };

  // ---------- sørg for at alle boter finnes ----------
  const boter = [];
  for (const navn of BOTER) {
    try {
      const epost = "bot:" + navn.toLowerCase();
      await q`insert into kontoer (epost, passord_hash) values (${epost}, null) on conflict do nothing`;
      const [k] = await q`select id from kontoer where lower(epost) = ${epost}`;
      let [sp] = await q`select id, navn from spillere where id = ${k.id}::uuid`;
      if (!sp) {
        // Ny karakter (første gang, eller etter at boten ble drept)
        for (const forsok of [navn, navn.slice(0, 14) + Math.floor(Math.random() * 90 + 10)]) {
          const r = await api({ id: k.id, navn }, "opprett_spiller", { p_navn: forsok });
          if (r?.ok) break;
        }
        await q`update spillere set er_bot = true where id = ${k.id}::uuid`;
        [sp] = await q`select id, navn from spillere where id = ${k.id}::uuid`;
      }
      if (sp) boter.push({ id: k.id, navn: sp.navn });
    } catch (e) { notat(navn, "oppsett", null, e?.message || e, e?.code); }
  }

  const data = boter.length ? await api(boter[0], "spill_data") : null;

  // ---------- hver bot gjør sin runde ----------
  for (const bot of boter.sort(() => Math.random() - 0.5)) {
    if (Date.now() - start > 22000) break;           // planlagte funksjoner har 30 sekunder
    if (!sjanse(0.85)) continue;
    aktive++;
    try { await spillRunde(bot); } catch (e) { notat(bot.navn, "runde", null, e?.stack || e?.message || e, "JS"); }
  }

  async function status(bot) {
    const st = await api(bot, "min_status");
    if (!st || !st.spiller) { notat(bot.navn, "min_status", null, "Mangler spiller i status", "LOGIKK"); return null; }
    const s = st.spiller;
    sjekk(bot, "min_status", s.penger >= 0 && s.bank >= 0 && s.kuler >= 0 && s.poeng >= 0, `negativ saldo (${s.penger}/${s.bank}/${s.kuler}/${s.poeng})`);
    sjekk(bot, "min_status", s.helse > 0 && s.helse <= 100, `helse utenfor 1–100 (${s.helse})`);
    sjekk(bot, "min_status", typeof st.rank === "string" && st.rank_indeks >= 0, "rank mangler");
    return st;
  }

  async function spillRunde(bot) {
    let st = await status(bot); if (!st) return;
    let s = st.spiller; const naa = Date.parse(st.tid) + 500;
    const klar = (f) => !s[f] || Date.parse(s[f]) <= naa;
    const ri = st.rank_indeks;

    if (!s.bio) await api(bot, "sett_profil", { p_bio: BIO(bot.navn), p_kjonn: tilfeldig(["mann", "kvinne", ""]), p_avatar_url: "", p_musikk_url: "", p_vis_bio: true });

    if (s.fengsel_til && Date.parse(s.fengsel_til) > naa) {
      if (s.penger > 30000 && sjanse(0.4)) await api(bot, "kjop_deg_ut");
      else { if (sjanse(0.1)) await api(bot, "send_chat", { p_tekst: "Noen som kan bryte meg ut? 🙏" }); return; }
      st = await status(bot); if (!st) return; s = st.spiller; bot.inne = false;
    }

    // Kriminalitet og biler
    if (klar("krim_klar")) {
      const mulige = data.krim.filter(k => k.min_rank <= ri);
      const k = sjanse(0.6) ? mulige[mulige.length - 1] : tilfeldig(mulige);
      const r = await api(bot, "begaa_krim", { p_id: k.id });
      if (r) sjekk(bot, "begaa_krim", typeof r.melding === "string", "mangler melding");
    }
    if (bot.inne) return;
    if (klar("bil_klar") && sjanse(0.9)) {
      const mulige = data.bil_steder.filter(b => b.min_rank <= ri);
      await api(bot, "stjel_bil", { p_id: mulige[mulige.length - 1].id });
    }
    if (st.biler >= 4 && sjanse(0.5)) await api(bot, "selg_alle_biler");
    if (sjanse(0.05)) {
      const g = await api(bot, "min_garasje");
      if (g?.length) await api(bot, "legg_ut_bil", { p_garasje_id: g[0].id, p_pris: Math.floor(g[0].verdi * (1.1 + Math.random() * 0.4)) });
    }
    if (sjanse(0.06)) {
      const l = await api(bot, "bruktbil_liste");
      const kjop = (l || []).find(b => !b.min && b.pris <= b.verdi * 1.3);
      if (kjop && s.penger > kjop.pris * 2) await api(bot, "kjop_bruktbil", { p_id: kjop.id });
    }

    if (bot.inne) return;
    // Fengsel: bryt ut andre (ekte spillere først)
    if (klar("utbrudd_klar") && sjanse(0.6)) {
      const f = await api(bot, "fengsel_liste");
      const andre = (f || []).filter(x => x.navn !== bot.navn);
      if (andre.length) {
        const [ekte] = await q`select navn from spillere where not er_bot and fengsel_til > now() order by random() limit 1`;
        await api(bot, "bryt_ut", { p_navn: (ekte || tilfeldig(andre)).navn });
      }
    }

    if (bot.inne) return;
    // Helse, bank og utstyr
    st = await status(bot); if (!st) return; s = st.spiller;
    if (s.helse < 70 && s.penger > (100 - s.helse) * 200) await api(bot, "sykehus");
    const nesteV = data.vapen.find(v => v.nivaa === s.vapen + 1);
    if (nesteV && s.penger > nesteV.pris * 1.5 && sjanse(0.3)) await api(bot, "kjop_vapen", { p_nivaa: nesteV.nivaa });
    const nesteB = data.beskyttelse.find(v => v.nivaa === s.beskyttelse + 1);
    if (nesteB && s.penger > nesteB.pris * 1.5 && sjanse(0.3)) await api(bot, "kjop_beskyttelse", { p_nivaa: nesteB.nivaa });
    if (s.kuler < 200 && s.penger > 30000 && sjanse(0.3)) await api(bot, "kjop_kuler", { p_antall: 200 });
    if (klar("reise_klar") && sjanse(0.06)) await api(bot, "reis", { p_by: tilfeldig(data.byer.filter(b => b !== s.sted)) });

    if (bot.inne) return;
    // Ran og (sjelden) angrep – bare mot andre boter
    if (klar("ran_klar") && sjanse(0.35)) {
      const [m] = await q`select navn from spillere where er_bot and sted = ${s.sted} and id <> ${bot.id}::uuid
        and (fengsel_til is null or fengsel_til < now()) and (beskyttet_til is null or beskyttet_til < now()) order by random() limit 1`;
      if (m) await api(bot, "ran_spiller", { p_navn: m.navn });
    }
    if (s.vapen > 0 && s.kuler > 60 && klar("angrep_klar") && sjanse(0.03)) {
      const [m] = await q`select navn from spillere where er_bot and sted = ${s.sted} and id <> ${bot.id}::uuid and helse > 60
        and (fengsel_til is null or fengsel_til < now()) and (beskyttet_til is null or beskyttet_til < now()) order by random() limit 1`;
      if (m) await api(bot, "angrip", { p_navn: m.navn, p_kuler: 30 });
    }
    if (s.penger > 10000 && sjanse(0.02)) await api(bot, "detektiv", { p_navn: tilfeldig(boter).navn });

    if (bot.inne) return;
    // Kasino: blackjack, terninger, lotto
    st = await status(bot); if (!st) return; s = st.spiller;
    if (sjanse(0.15)) {
      let h = await api(bot, "bj_status");
      if (h && !h.aktiv) {
        const innsats = klamp(s.penger * 0.03, 100, 50000);
        if (s.penger >= innsats) h = await api(bot, "bj_start", { p_innsats: innsats });
      }
      for (let i = 0; h && h.aktiv && !h.ferdig && i < 8; i++) {
        h = await api(bot, h.hand_verdi < 17 ? "bj_trekk" : "bj_staa");
        if (h) sjekk(bot, "blackjack", h.hand_verdi <= 31 && Array.isArray(h.hand), "rar hånd " + JSON.stringify(h.hand));
      }
    }
    if (sjanse(0.12) && klar("kasino_klar")) {
      const innsats = klamp(s.penger * 0.02, 100, 30000);
      if (s.penger >= innsats) {
        const r = await api(bot, "terning_kast", { p_innsats: innsats });
        if (r) sjekk(bot, "terning_kast", r.din?.length === 2 && r.bank?.length === 2 && r.din[0] + r.din[1] !== r.bank[0] + r.bank[1], "terningene gikk likt eller mangler");
      }
    }
    if (sjanse(0.08) && s.penger > 30000) await api(bot, "kjop_lotto", { p_antall: 1 + Math.floor(Math.random() * 2) });
    if (sjanse(0.05)) { const l = await api(bot, "lotto_info"); if (l) sjekk(bot, "lotto_info", l.pott >= 100000, "lottopotten under grunnbeløpet"); }

    if (bot.inne) return;
    // Handel og forretninger
    if (sjanse(0.06)) {
      const b = await api(bot, "borsen");
      if (b?.length) {
        const eid = b.filter(x => x.antall > 0);
        if (eid.length && sjanse(0.5)) await api(bot, "selg_aksje", { p_id: eid[0].id, p_antall: Math.ceil(eid[0].antall / 2) });
        else { const a = tilfeldig(b); const n = Math.floor(s.penger * 0.03 / a.pris); if (n > 0) await api(bot, "kjop_aksje", { p_id: a.id, p_antall: n }); }
      }
    }
    if (sjanse(0.2)) {
      const f = await api(bot, "forretninger");
      if (f) {
        if (f.livvakt.nivaa === 0 && s.penger > 200000) await api(bot, "livvakt_oppgrader");
        else if (f.livvakt.opptjent > 2000) await api(bot, "livvakt_hent");
        if (f.hasj.planter === 0 && s.penger > 80000 && sjanse(0.3)) await api(bot, "hasj_plant", { p_antall: 5 + Math.floor(Math.random() * 15) });
        else if (f.hasj.planter > 0 && f.hasj.ferdig && Date.parse(f.hasj.ferdig) < naa) await api(bot, "hasj_host");
      }
    }
    if (s.poeng >= 5 && sjanse(0.15)) await api(bot, "poeng_kjop", { p_vare: s.poeng >= 10 ? "penger" : "kuler" });

    // Oppdrag og prestasjoner
    if (sjanse(0.3)) for (const o of (await api(bot, "mine_oppdrag")) || []) if (!o.hentet && o.fremdrift >= o.mal) await api(bot, "hent_oppdrag", { p_id: o.id });
    if (sjanse(0.2)) for (const p of (await api(bot, "mine_prestasjoner")) || []) if (!p.hentet && p.fremdrift >= p.mal) await api(bot, "hent_prestasjon", { p_id: p.id });

    // Gjeng
    if (ri >= 2 && !st.gjeng_tag && sjanse(0.15)) {
      const g = await api(bot, "gjeng_liste");
      const ledig = (g || []).filter(x => x.medlemmer < 10);
      if (ledig.length) await api(bot, "bli_med_gjeng", { p_id: tilfeldig(ledig).id });
      else if (s.penger >= 300000) { const [n, t] = tilfeldig(GJENGER); await api(bot, "opprett_gjeng", { p_navn: n, p_tag: t }); }
    }
    if (st.gjeng_tag && s.penger > 50000 && sjanse(0.05)) await api(bot, "gjeng_innskudd", { p_belop: 5000 });

    // Bank til slutt: sikre pengene
    st = await status(bot); if (!st) return; s = st.spiller;
    if (s.penger > 30000 && sjanse(0.7)) await api(bot, "bank_sett_inn", { p_belop: Math.floor(s.penger * 0.8) });
    else if (s.penger < 20000 && s.bank > 100000 && sjanse(0.3)) await api(bot, "bank_ta_ut", { p_belop: 50000 });

    // Sosialt og lesing (tester at sidene fungerer)
    if (sjanse(0.04)) await api(bot, "send_chat", { p_tekst: tilfeldig(CHAT) });
    if (sjanse(0.015)) await api(bot, "ny_traad", { p_kategori: tilfeldig(["Generelt", "Salg", "Gjeng"]), p_tittel: tilfeldig(CHAT).slice(0, 60), p_tekst: "Hva mener dere?" });
    if (sjanse(0.03)) { const l = await api(bot, "forum_liste", { p_kategori: "" }); if (l?.length) { const t = tilfeldig(l); await api(bot, "forum_traad", { p_id: t.id }); await api(bot, "svar_traad", { p_id: t.id, p_tekst: tilfeldig(["Enig!", "Nei, tull.", "Bump", "Interessert, send melding."]) }); } }
    if (sjanse(0.02)) await api(bot, "send_melding", { p_til: tilfeldig(boter).navn, p_emne: "Hei", p_tekst: "Skal vi gjøre en jobb sammen?" });
    for (const [fn, args] of [["toppliste"], ["avis_liste"], ["palogget_liste"], ["nyheter_liste"], ["gravplass_liste"], ["mine_meldinger"], ["verv_info"], ["min_profil"], ["bilde_liste"], ["gjeng_liste"], ["min_gjeng"], ["chat_siste", { p_etter: 0 }], ["sok_spillere", { p_sok: "a" }], ["profil", { p_navn: tilfeldig(BOTER) }]]) {
      if (sjanse(0.05)) await api(bot, fn, args || {});
    }
    if (sjanse(0.1)) { await api(bot, "min_logg", { p_type: "" }); await api(bot, "les_logg"); }
  }

  // ---------- lagre og rapporter ----------
  const varighet = Date.now() - start;
  const [kj] = await q`insert into bot_kjoring (varighet_ms, boter, kall, regelfeil, uventet)
    values (${varighet}, ${aktive}, ${kall}, ${JSON.stringify(regelfeil)}::jsonb, ${JSON.stringify(uventet)}::jsonb) returning id`;
  await q`delete from bot_kjoring where start < now() - interval '14 days'`;
  console.log(`BOTRAPPORT kjøring=${kj?.id} boter=${aktive} kall=${kall} ms=${varighet} uventet=${uventet.length}`);
  for (const f of uventet) console.error("BOTFEIL", JSON.stringify(f));

  // Rapport til utvikleren (Netlify-skjema): nye feiltyper straks, ellers en oppsummering daglig ca. kl. 08.
  const signatur = (f) => f.fn + "|" + String(f.feil).replace(/\d+/g, "#").slice(0, 120);
  const tidligere = new Set((await q`select e as f from bot_kjoring k, jsonb_array_elements(k.uventet) e
    where k.start > now() - interval '24 hours' and k.id <> ${kj.id} and k.rapportert`).map(r => signatur(typeof r.f === "string" ? JSON.parse(r.f) : r.f)));
  const nye = [...new Map(uventet.filter(f => !tidligere.has(signatur(f))).map(f => [signatur(f), f])).values()];
  const time = new Date().getUTCHours();
  const [sistDaglig] = await q`select count(*)::int as n from bot_kjoring where rapportert and start > now() - interval '20 hours' and id <> ${kj.id}`;
  const daglig = time === 7 && (sistDaglig?.n ?? 0) === 0;
  if (nye.length || daglig) {
    const [sum] = await q`select count(*)::int as kjoringer, coalesce(sum(kall), 0)::int as kall,
      coalesce(sum(jsonb_array_length(uventet)), 0)::int as uventet from bot_kjoring where start > now() - interval '24 hours'`;
    const tekst = (nye.length ? `NYE FEIL (${nye.length}):\n` + nye.map(f => `- [${f.bot}] ${f.fn} ${f.args ? JSON.stringify(f.args) : ""}: ${f.feil} (kode ${f.kode})`).join("\n") + "\n\n" : "")
      + `Siste døgn: ${sum.kjoringer} kjøringer, ${sum.kall} kall, ${sum.uventet} uventede feil.\n`
      + `Denne kjøringen: ${aktive} boter, ${kall} kall, ${varighet} ms.\nVanligste spillregel-avvisninger: `
      + Object.entries(regelfeil).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, v]) => `${k} (${v})`).join("; ");
    try {
      const base = (globalThis.Netlify?.env?.get("URL")) || process.env.URL || "https://undergrunnen.netlify.app";
      const svar = await fetch(base + "/rapport.html", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ "form-name": "botrapport", type: nye.length ? "feil" : "daglig", tekst: tekst.slice(0, 9000) }).toString() });
      if (svar.ok) await q`update bot_kjoring set rapportert = true where id = ${kj.id}`;
      else console.error("Rapport feilet", svar.status);
    } catch (e) { console.error("Rapport feilet", e); }
  }
  return new Response("ok");
};

export const config = { schedule: "*/15 * * * *" };
