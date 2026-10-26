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
const hemmelig = () => {
  const s = env("SESSION_SECRET");
  if (!s || s.length < 32) throw new Error("SESSION_SECRET mangler på serveren");
  return s;
};

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
const signer = (data) => createHmac("sha256", hemmelig()).update(data).digest("base64url");

function lagOkt(uid) {
  const data = `${uid}.${Date.now() + OKT_DAGER * 864e5}`;
  return `${data}.${signer(data)}`;
}
function lesOkt(req) {
  const c = req.headers.get("cookie") || "";
  const m = c.match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  if (!m) return null;
  const [uid, exp, sig] = decodeURIComponent(m[1]).split(".");
  if (!uid || !exp || !sig) return null;
  const forventet = Buffer.from(signer(`${uid}.${exp}`));
  const fikk = Buffer.from(sig);
  if (forventet.length !== fikk.length || !timingSafeEqual(forventet, fikk)) return null;
  if (Number(exp) < Date.now()) return null;
  if (!/^[0-9a-f-]{36}$/.test(uid)) return null;
  return uid;
}
const cookie = (verdi, maxAge) =>
  `${COOKIE}=${encodeURIComponent(verdi)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;

// ---------- svar ----------
const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });
const feil = (melding, status = 400) => json({ error: melding }, status);

// ---------- handler ----------
export default async (req) => {
  const sti = new URL(req.url).pathname.replace(/^\/api\/?/, "");
  if (sti === "helse") {
    const svar = { hemmelighet: !!(env("SESSION_SECRET") && env("SESSION_SECRET").length >= 32) };
    try { const r = await q`select count(*)::int as n from kontoer`; svar.database = "ok"; svar.kontoer = r[0]?.n; }
    catch (e) { svar.database = String(e && (e.message || e)).slice(0, 300); }
    return json(svar);
  }
  if (req.method !== "POST") return feil("Kun POST", 405);
  let body = {};
  try { body = await req.json(); } catch { /* tom body er greit */ }

  try {
    if (sti === "registrer" || sti === "logginn") {
      const epost = String(body.epost || "").trim().toLowerCase();
      const passord = String(body.passord || "");
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(epost) || epost.length > 200) return feil("Skriv inn en gyldig e-postadresse.");
      if (passord.length < 6 || passord.length > 200) return feil("Passordet må ha minst 6 tegn.");

      if (sti === "registrer") {
        const finnes = await q`select 1 from kontoer where lower(epost) = ${epost}`;
        if (finnes.length) return feil("E-posten er allerede registrert.");
        const hash = await hashPassord(passord);
        const [k] = await q`insert into kontoer (epost, passord_hash) values (${epost}, ${hash}) returning id`;
        return json({ ok: true }, 200, { "set-cookie": cookie(lagOkt(k.id), OKT_DAGER * 86400) });
      }
      const [k] = await q`select id, passord_hash from kontoer where lower(epost) = ${epost}`;
      if (!k || !(await sjekkPassord(passord, k.passord_hash))) return feil("Feil e-post eller passord.", 401);
      return json({ ok: true }, 200, { "set-cookie": cookie(lagOkt(k.id), OKT_DAGER * 86400) });
    }

    if (sti === "loggut") return json({ ok: true }, 200, { "set-cookie": cookie("", 0) });

    if (sti === "rpc") {
      const uid = lesOkt(req);
      if (!uid) return feil("Du er ikke innlogget", 401);
      const fn = String(body.fn || "");
      if (!/^[a-z_]{1,40}$/.test(fn)) return feil("Ukjent handling");
      const args = JSON.stringify(body.args && typeof body.args === "object" ? body.args : {});
      const [rad] = await q`select public.api(${uid}::uuid, ${fn}, ${args}::jsonb) as r`;
      return json({ data: rad ? rad.r : null });
    }

    return feil("Ikke funnet", 404);
  } catch (e) {
    // Spillfeil fra databasen (raise exception) sendes rett til spilleren.
    if (e && e.code === "P0001") return feil(e.message);
    if (e && (e.code === "22P02" || e.code === "22003")) return feil("Ugyldig verdi.");
    if (e && e.code === "23505") return feil("Navnet er opptatt.");
    console.error("api-feil", sti, e);
    return json({ error: "Noe gikk galt på serveren. Prøv igjen.", detalj: String(e && (e.message || e)).slice(0, 300), kode: e && e.code }, 500);
  }
};

export const config = { path: "/api/*" };
