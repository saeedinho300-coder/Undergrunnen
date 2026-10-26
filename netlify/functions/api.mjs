// Undergrunnen – all serverlogikk: innlogging + videresending av spillhandlinger til databasen.
import { getDatabase } from "@netlify/database";
import { scrypt, randomBytes, timingSafeEqual, createHmac } from "node:crypto";

let _db;
const db = () => (_db ??= getDatabase());
// Tåler både array og { rows } som svar fra driveren
async function q(strings, ...vals) {
  const r = await db().sql(strings, ...vals);
  return Array.isArray(r) ? r : (r?.rows ?? []);
}
const COOKIE = "ug_okt";
const OKT_DAGER = 30;

const env = (k) => (globalThis.Netlify?.env?.get(k) ?? process.env[k]);
// Nøkkel for å signere innloggings-cookies: miljøvariabel hvis den finnes, ellers lagret i databasen.
let _hemmelig;
async function hemmelig() {
  if (_hemmelig) return _hemmelig;
  const fraEnv = env("SESSION_SECRET");
  if (fraEnv && fraEnv.length >= 32) return (_hemmelig = fraEnv);
  const [rad] = await q`select verdi from app_hemmelighet where id = 1`;
  if (!rad || !rad.verdi || rad.verdi.length < 32) throw new Error("Fant ingen hemmelig nøkkel i databasen");
  return (_hemmelig = rad.verdi);
}

// Feilkode fra Postgres, uansett hvordan driveren pakker den inn
const pgKode = (e) => e && (e.code ?? e.cause?.code ?? e.originalError?.code);
const pgMelding = (e) => String((e && (e.message || e.cause?.message)) || e).replace(/^error:\s*/i, "");

// ---------- passord (scrypt) ----------
const scryptP = (pw, salt) => new Promise((ok, feil) =>
  scrypt(pw, salt, 64, { N: 16384, r: 8, p: 1 }, (e, k) => (e ? feil(e) : ok(k))));

async function hashPassord(pw) {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString("base64")}$${(await scryptP(pw, salt)).toString("base64")}`;
}
async function sjekkPassord(pw, lagret) {
  const [, salt, hash] = String(lagret).split("$");
  if (!salt || !hash) return false;
  const a = await scryptP(pw, Buffer.from(salt, "base64"));
  const b = Buffer.from(hash, "base64");
  return a.length === b.length && timingSafeEqual(a, b);
}

// ---------- signert økt-cookie ----------
const signer = async (data) => createHmac("sha256", await hemmelig()).update(data).digest("base64url");

async function lagOkt(uid) {
  const data = `${uid}.${Date.now() + OKT_DAGER * 864e5}`;
  return `${data}.${await signer(data)}`;
}
async function lesOkt(req) {
  const c = req.headers.get("cookie") || "";
  const m = c.match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  if (!m) return null;
  const [uid, exp, sig] = decodeURIComponent(m[1]).split(".");
  if (!uid || !exp || !sig) return null;
  const forventet = Buffer.from(await signer(`${uid}.${exp}`));
  const fikk = Buffer.from(sig);
  if (forventet.length !== fikk.length || !timingSafeEqual(forventet, fikk)) return null;
  if (Number(exp) < Date.now()) return null;
  if (!/^[0-9a-f-]{36}$/.test(uid)) return null;
  return uid;
}
const cookie = (verdi, maxAge) =>
  `${COOKIE}=${encodeURIComponent(verdi)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;

// ---------- Google-innlogging ----------
const googleId = () => env("GOOGLE_CLIENT_ID");
const googleHemmelig = () => env("GOOGLE_CLIENT_SECRET");
const googleKlar = () => !!(googleId() && googleHemmelig());
const STATE_COOKIE = "ug_gstate";
const tilbake = (req) => `${new URL(req.url).origin}/api/google/callback`;
const lesCookie = (req, navn) => {
  const m = (req.headers.get("cookie") || "").match(new RegExp(`(?:^|;\\s*)${navn}=([^;]+)`));
  return m ? decodeURIComponent(m[1]) : null;
};
const videre = (til, cookies = []) => {
  const h = new Headers({ location: til, "cache-control": "no-store" });
  for (const c of cookies) h.append("set-cookie", c);
  return new Response(null, { status: 302, headers: h });
};
const tilForsiden = (melding) => videre("/?feil=" + encodeURIComponent(melding), [`${STATE_COOKIE}=; Path=/api/google; HttpOnly; Secure; SameSite=Lax; Max-Age=0`]);

async function googleStart(req) {
  if (!googleKlar()) return tilForsiden("Google-innlogging er ikke satt opp ennå.");
  const state = randomBytes(24).toString("base64url");
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: googleId(), redirect_uri: tilbake(req), response_type: "code",
    scope: "openid email", state, prompt: "select_account",
  }).toString();
  return videre(url.toString(), [`${STATE_COOKIE}=${state}; Path=/api/google; HttpOnly; Secure; SameSite=Lax; Max-Age=600`]);
}

async function googleCallback(req) {
  if (!googleKlar()) return tilForsiden("Google-innlogging er ikke satt opp ennå.");
  const u = new URL(req.url);
  if (u.searchParams.get("error")) return tilForsiden("Google-innloggingen ble avbrutt.");
  const code = u.searchParams.get("code"), state = u.searchParams.get("state");
  const lagret = lesCookie(req, STATE_COOKIE);
  if (!code || !state || !lagret || state !== lagret) return tilForsiden("Innloggingen gikk ut på tid. Prøv igjen.");

  const svar = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ code, client_id: googleId(), client_secret: googleHemmelig(), redirect_uri: tilbake(req), grant_type: "authorization_code" }),
  });
  const t = await svar.json().catch(() => ({}));
  if (!svar.ok || !t.id_token) { console.error("google token", svar.status, t); return tilForsiden("Google godtok ikke innloggingen. Prøv igjen."); }

  // id_token kommer rett fra Google over HTTPS, så innholdet kan leses direkte.
  let info;
  try { info = JSON.parse(Buffer.from(t.id_token.split(".")[1], "base64url").toString("utf8")); } catch { info = null; }
  const gyldigUtsteder = info && (info.iss === "https://accounts.google.com" || info.iss === "accounts.google.com");
  if (!info || !info.sub || !gyldigUtsteder || info.aud !== googleId() || Number(info.exp) * 1000 < Date.now()) {
    return tilForsiden("Kunne ikke bekrefte Google-kontoen.");
  }

  let [k] = await q`select id from kontoer where google_sub = ${String(info.sub)}`;
  if (!k) {
    await hemmelig();
    [k] = await q`insert into kontoer (epost, passord_hash, google_sub, google_epost)
                  values (${"google:" + info.sub}, null, ${String(info.sub)}, ${info.email || null}) returning id`;
  }
  return videre("/", [
    cookie(await lagOkt(k.id), OKT_DAGER * 86400),
    `${STATE_COOKIE}=; Path=/api/google; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
  ]);
}

// ---------- brukernavn eller e-post ----------
function lesIdent(raw) {
  const v = String(raw || "").trim().toLowerCase();
  if (v.includes("@")) {
    if (!/^[^\s@:]+@[^\s@:]+\.[^\s@:]+$/.test(v) || v.length > 200) return { feil: "Skriv inn en gyldig e-postadresse." };
    return { ident: v };
  }
  if (!/^[a-z0-9_æøå]{3,20}$/.test(v)) return { feil: "Brukernavnet må være 3–20 tegn: bokstaver, tall eller _." };
  return { ident: v };
}

// ---------- svar ----------
const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });
const feil = (melding, status = 400) => json({ error: melding }, status);

// ---------- handler ----------
export default async (req) => {
  const sti = new URL(req.url).pathname.replace(/^\/api\/?/, "");
  if (sti === "oppsett") return json({ google: googleKlar() });
  try {
    if (sti === "google/start") return await googleStart(req);
    if (sti === "google/callback") return await googleCallback(req);
  } catch (e) {
    console.error("google-feil", e);
    return tilForsiden("Google-innloggingen feilet. Prøv igjen.");
  }
  if (sti === "helse") {
    const svar = {};
    try { const r = await q`select count(*)::int as n from kontoer`; svar.database = "ok"; svar.kontoer = Number(r[0]?.n); }
    catch (e) { svar.database = pgMelding(e).slice(0, 300); }
    svar.google = googleKlar();
    try { await hemmelig(); svar.hemmelighet = true; } catch (e) { svar.hemmelighet = pgMelding(e).slice(0, 300); }
    try { const [r] = await q`select public.api(null, 'spill_data', '{}'::jsonb) as r`; svar.spill = typeof r?.r === "string" ? "tekst" : (r?.r?.byer ? "ok" : "ukjent"); }
    catch (e) { svar.spill = pgMelding(e).slice(0, 300); }
    return json(svar);
  }
  if (req.method !== "POST") return feil("Kun POST", 405);
  let body = {};
  try { body = await req.json(); } catch { /* tom body er greit */ }

  try {
    if (sti === "registrer" || sti === "logginn") {
      const { ident: epost, feil: identFeil } = lesIdent(body.epost);
      if (identFeil) return feil(identFeil);
      const passord = String(body.passord || "");
      if (passord.length < 6 || passord.length > 200) return feil("Passordet må ha minst 6 tegn.");

      if (sti === "registrer") {
        const finnes = await q`select 1 from kontoer where lower(epost) = ${epost}`;
        if (finnes.length) return feil(epost.includes("@") ? "E-posten er allerede registrert." : "Brukernavnet er opptatt.");
        await hemmelig(); // sjekk at innlogging kan fullføres før kontoen lagres
        const hash = await hashPassord(passord);
        const [k] = await q`insert into kontoer (epost, passord_hash) values (${epost}, ${hash}) returning id`;
        return json({ ok: true }, 200, { "set-cookie": cookie(await lagOkt(k.id), OKT_DAGER * 86400) });
      }
      const [k] = await q`select id, passord_hash from kontoer where lower(epost) = ${epost}`;
      if (!k || !k.passord_hash || !(await sjekkPassord(passord, k.passord_hash))) return feil("Feil brukernavn/e-post eller passord.", 401);
      return json({ ok: true }, 200, { "set-cookie": cookie(await lagOkt(k.id), OKT_DAGER * 86400) });
    }

    if (sti === "loggut") return json({ ok: true }, 200, { "set-cookie": cookie("", 0) });

    if (sti === "rpc") {
      const uid = await lesOkt(req);
      if (!uid) return feil("Du er ikke innlogget", 401);
      const fn = String(body.fn || "");
      if (!/^[a-z_]{1,40}$/.test(fn)) return feil("Ukjent handling");
      const args = JSON.stringify(body.args && typeof body.args === "object" ? body.args : {});
      const [rad] = await q`select public.api(${uid}::uuid, ${fn}, ${args}::jsonb) as r`;
      let data = rad ? rad.r : null;
      if (typeof data === "string") { try { data = JSON.parse(data); } catch { /* vanlig tekst */ } }
      return json({ data });
    }

    return feil("Ikke funnet", 404);
  } catch (e) {
    // Spillfeil fra databasen (raise exception) sendes rett til spilleren.
    const kode = pgKode(e);
    if (kode === "P0001") return feil(pgMelding(e));
    if (kode === "22P02" || kode === "22003") return feil("Ugyldig verdi.");
    if (kode === "23505") return feil("Navnet eller e-posten er opptatt.");
    console.error("api-feil", sti, e);
    return json({ error: "Noe gikk galt på serveren. Prøv igjen.", detalj: pgMelding(e).slice(0, 300), kode }, 500);
  }
};

export const config = { path: "/api/*" };
