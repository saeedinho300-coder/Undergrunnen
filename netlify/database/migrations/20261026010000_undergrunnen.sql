-- =====================================================================
--  UNDERGRUNNEN – tekstbasert mafiaspill (Netlify Database)
--  Kjøres automatisk av Netlify ved publisering. Ikke rediger denne
--  filen etter at den er tatt i bruk – lag en ny migrasjon i stedet.
-- =====================================================================

-- Kontoer (innlogging). Passord lagres kun som scrypt-hash.
create table public.kontoer (
  id uuid primary key default gen_random_uuid(),
  epost text not null,
  passord_hash text not null,
  opprettet timestamptz not null default now());
create unique index kontoer_epost_unik on public.kontoer (lower(epost));

-- Innlogget bruker settes av serverfunksjonen for hvert kall.
create function public.app_uid() returns uuid language sql stable as
$$ select nullif(current_setting('app.uid', true), '')::uuid $$;

-- ---------------------------------------------------------------------
--  SPILLDATA (kan endres fritt for å justere balansen)
-- ---------------------------------------------------------------------
create table public.ranker (indeks int primary key, navn text not null, exp int not null);
insert into public.ranker values
 (0,'Gatesmågutt',0),(1,'Lommetyv',60),(2,'Smågangster',200),(3,'Torpedo',500),
 (4,'Gangster',1200),(5,'Løytnant',2500),(6,'Kaptein',5000),(7,'Boss',10000),(8,'Gudfar',20000);

create table public.krim_typer (
  id int primary key, navn text not null, sjanse int not null,
  min_gevinst int not null, max_gevinst int not null, exp int not null,
  ventetid int not null, min_rank int not null default 0);
insert into public.krim_typer values
 (1,'Nask i kiosken',              70,   40,   180,  2,  60, 0),
 (2,'Lommetyveri på trikken',      55,  150,   450,  3,  75, 0),
 (3,'Innbrudd i kjellerbod',       45,  400,  1100,  5,  90, 1),
 (4,'Ran av bensinstasjon',        35, 1500,  3800,  9, 120, 2),
 (5,'Juveltyveri',                 25, 5000, 12000, 14, 150, 3),
 (6,'Ran av verditransport',       18,15000, 40000, 25, 180, 5);

create table public.bil_steder (id int primary key, navn text not null, sjanse int not null, tier int not null, min_rank int not null);
insert into public.bil_steder values
 (1,'Parkeringshus',60,1,0),(2,'Villastrøk',40,2,2),(3,'Bilforhandler',25,3,4);

create table public.biler (id int primary key, navn text not null, verdi int not null, tier int not null);
insert into public.biler values
 (1,'Volvo 240',2500,1),(2,'Toyota Corolla',3000,1),(3,'Ford Focus',3500,1),(4,'VW Golf',4500,1),
 (5,'Volvo XC90',15000,2),(6,'Audi A6',18000,2),(7,'Tesla Model 3',22000,2),
 (8,'BMW M5',60000,3),(9,'Mercedes G-klasse',95000,3),(10,'Porsche 911',120000,3);

create table public.vapen_typer (nivaa int primary key, navn text not null, styrke numeric not null, pris int not null);
insert into public.vapen_typer values
 (1,'Pistol',1.0,8000),(2,'Hagle',1.6,30000),(3,'MP5',2.4,90000),
 (4,'AK-47',3.4,250000),(5,'Snikskyttergevær',5.0,700000);

create table public.beskyttelse_typer (nivaa int primary key, navn text not null, styrke numeric not null, pris int not null);
insert into public.beskyttelse_typer values
 (1,'Skuddsikker vest',1.5,15000),(2,'Kevlardrakt',2.2,60000),
 (3,'Pansret bil',3.2,200000),(4,'Livvakter',4.5,600000);

create table public.byer (navn text primary key);
insert into public.byer values ('Oslo'),('Bergen'),('Trondheim'),('Stavanger'),('Kristiansand'),('Tromsø');

-- ---------------------------------------------------------------------
--  SPILLERTABELLER
-- ---------------------------------------------------------------------
create table public.spillere (
  id uuid primary key references public.kontoer(id) on delete cascade,
  navn text not null check (navn ~ '^[A-Za-z0-9_æøåÆØÅ]{3,16}$'),
  penger bigint not null default 1000 check (penger >= 0),
  bank bigint not null default 0 check (bank >= 0),
  helse int not null default 100,
  exp int not null default 0,
  kuler int not null default 0 check (kuler >= 0),
  vapen int not null default 0,
  beskyttelse int not null default 0,
  sted text not null default 'Oslo' references public.byer(navn),
  drap int not null default 0,
  fengsel_til timestamptz,
  krim_klar timestamptz not null default now(),
  bil_klar timestamptz not null default now(),
  angrep_klar timestamptz not null default now(),
  reise_klar timestamptz not null default now(),
  utbrudd_klar timestamptz not null default now(),
  chat_klar timestamptz not null default now(),
  melding_klar timestamptz not null default now(),
  beskyttet_til timestamptz default now() + interval '12 hours',
  sist_aktiv timestamptz not null default now(),
  opprettet timestamptz not null default now()
);
create unique index spillere_navn_unik on public.spillere (lower(navn));

create table public.garasje (
  id bigint generated always as identity primary key,
  eier uuid not null references public.spillere(id) on delete cascade,
  bil text not null, verdi int not null, sted text not null,
  stjalet timestamptz not null default now());
create index on public.garasje (eier);

create table public.meldinger (
  id bigint generated always as identity primary key,
  til uuid not null references public.spillere(id) on delete cascade,
  fra_navn text not null, emne text not null, tekst text not null,
  lest boolean not null default false, tid timestamptz not null default now());
create index on public.meldinger (til, tid desc);

create table public.chat (
  id bigint generated always as identity primary key,
  navn text not null, tekst text not null, tid timestamptz not null default now());
create index on public.chat (tid desc);

create table public.gravplass (
  id bigint generated always as identity primary key,
  bruker uuid, navn text not null, rank text not null, drap int not null,
  drept_av text not null, sett boolean not null default false,
  tid timestamptz not null default now());

-- ---------------------------------------------------------------------
--  HJELPEFUNKSJONER
-- ---------------------------------------------------------------------
create or replace function public.kr(bigint) returns text language sql immutable as
$$ select replace(to_char($1, 'FM999,999,999,999,990'), ',', ' ') || ' kr' $$;

create or replace function public.sek_igjen(timestamptz) returns int language sql stable as
$$ select greatest(0, ceil(extract(epoch from ($1 - now()))))::int $$;

create or replace function public.rank_indeks(p_exp int) returns int language sql stable as
$$ select coalesce(max(indeks), 0) from public.ranker where exp <= p_exp $$;

create or replace function public.rank_navn(p_exp int) returns text language sql stable as
$$ select navn from public.ranker where indeks = public.rank_indeks(p_exp) $$;

-- Henter og låser egen spiller
create or replace function public._meg() returns public.spillere
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  if app_uid() is null then raise exception 'Du er ikke innlogget'; end if;
  select * into s from spillere where id = app_uid() for update;
  if not found then raise exception 'Du har ingen karakter'; end if;
  update spillere set sist_aktiv = now() where id = s.id;
  return s;
end $$;

create or replace function public._sjekk_fri(s public.spillere) returns void
language plpgsql as $$
begin
  if s.fengsel_til is not null and s.fengsel_til > now() then
    raise exception 'Du sitter i fengsel i % sekunder til', sek_igjen(s.fengsel_til);
  end if;
end $$;

create or replace function public._vent(klar timestamptz, hva text) returns void
language plpgsql as $$
begin
  if klar > now() then
    raise exception 'Du må vente % sekunder før du kan %', sek_igjen(klar), hva;
  end if;
end $$;

create or replace function public._finn(p_navn text) returns public.spillere
language plpgsql security definer set search_path = public as $$
declare t spillere;
begin
  select * into t from spillere where lower(navn) = lower(trim(p_navn)) for update;
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  return t;
end $$;

create or replace function public._systemmelding(p_til uuid, p_emne text, p_tekst text) returns void
language sql security definer set search_path = public as $$
  insert into meldinger (til, fra_navn, emne, tekst) values (p_til, 'System', p_emne, p_tekst);
$$;

-- ---------------------------------------------------------------------
--  KONTO / STATUS
-- ---------------------------------------------------------------------
create or replace function public.spill_data() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ranker', (select jsonb_agg(r order by indeks) from ranker r),
    'krim', (select jsonb_agg(k order by id) from krim_typer k),
    'bil_steder', (select jsonb_agg(b order by id) from bil_steder b),
    'vapen', (select jsonb_agg(v order by nivaa) from vapen_typer v),
    'beskyttelse', (select jsonb_agg(v order by nivaa) from beskyttelse_typer v),
    'byer', (select jsonb_agg(navn order by navn) from byer),
    'kulepris', 40, 'reisepris', 800);
$$;

create or replace function public.opprett_spiller(p_navn text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if app_uid() is null then raise exception 'Du er ikke innlogget'; end if;
  if exists (select 1 from spillere where id = app_uid()) then raise exception 'Du har allerede en karakter'; end if;
  p_navn := trim(p_navn);
  if p_navn !~ '^[A-Za-z0-9_æøåÆØÅ]{3,16}$' then
    raise exception 'Navnet må være 3–16 tegn: bokstaver, tall eller _';
  end if;
  if lower(p_navn) = 'system' or exists (select 1 from spillere where lower(navn) = lower(p_navn)) then
    raise exception 'Navnet % er opptatt', p_navn;
  end if;
  insert into spillere (id, navn) values (app_uid(), p_navn);
  update gravplass set sett = true where bruker = app_uid();
  perform _systemmelding(app_uid(), 'Velkommen til Undergrunnen',
    'Du starter med 1 000 kr i Oslo. Begå kriminalitet for å tjene penger og stige i rank. '
    || 'De første 12 timene kan ingen skyte deg – men angriper du selv, mister du beskyttelsen.');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.min_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; ri int; neste ranker; g gravplass;
begin
  if app_uid() is null then raise exception 'Du er ikke innlogget'; end if;
  select * into s from spillere where id = app_uid();
  if not found then
    select * into g from gravplass where bruker = app_uid() and not sett order by tid desc limit 1;
    return jsonb_build_object('spiller', null, 'tid', now(),
      'dod', case when g.id is null then null else jsonb_build_object('navn', g.navn, 'drept_av', g.drept_av, 'tid', g.tid) end);
  end if;
  update spillere set sist_aktiv = now() where id = s.id;
  ri := rank_indeks(s.exp);
  select * into neste from ranker where indeks = ri + 1;
  return jsonb_build_object(
    'tid', now(),
    'spiller', to_jsonb(s) - 'id',
    'rank_indeks', ri,
    'rank', rank_navn(s.exp),
    'rank_exp', (select exp from ranker where indeks = ri),
    'neste_rank', neste.navn,
    'neste_exp', neste.exp,
    'biler', (select count(*) from garasje where eier = s.id),
    'uleste', (select count(*) from meldinger where til = s.id and not lest));
end $$;

-- ---------------------------------------------------------------------
--  KRIMINALITET
-- ---------------------------------------------------------------------
create or replace function public.begaa_krim(p_id int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; k krim_typer; ri int; sjanse int; gevinst int; straff int;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.krim_klar, 'begå ny kriminalitet');
  select * into k from krim_typer where id = p_id;
  if not found then raise exception 'Ukjent handling'; end if;
  ri := rank_indeks(s.exp);
  if ri < k.min_rank then raise exception 'Du har for lav rank til dette'; end if;
  sjanse := least(95, k.sjanse + ri * 4);
  update spillere set krim_klar = now() + make_interval(secs => k.ventetid) where id = s.id;
  if random() * 100 < sjanse then
    gevinst := k.min_gevinst + floor(random() * (k.max_gevinst - k.min_gevinst + 1))::int;
    update spillere set penger = penger + gevinst, exp = exp + k.exp where id = s.id;
    return jsonb_build_object('ok', true, 'melding', format('Det gikk! Du tjente %s og fikk %s erfaring.', kr(gevinst), k.exp));
  elsif random() < 0.5 then
    straff := 45 + floor(random() * 60)::int;
    update spillere set fengsel_til = now() + make_interval(secs => straff) where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('Politiet tok deg! Du må sitte inne i %s sekunder.', straff));
  else
    return jsonb_build_object('ok', false, 'melding', 'Det gikk ikke, men du kom deg unna.');
  end if;
end $$;

-- ---------------------------------------------------------------------
--  BILTYVERI
-- ---------------------------------------------------------------------
create or replace function public.stjel_bil(p_id int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; st bil_steder; b biler; ri int; sjanse int; straff int;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.bil_klar, 'stjele ny bil');
  select * into st from bil_steder where id = p_id;
  if not found then raise exception 'Ukjent sted'; end if;
  ri := rank_indeks(s.exp);
  if ri < st.min_rank then raise exception 'Du har for lav rank til dette'; end if;
  if (select count(*) from garasje where eier = s.id) >= 30 then raise exception 'Garasjen er full (maks 30 biler). Selg noen først.'; end if;
  sjanse := least(90, st.sjanse + ri * 3);
  update spillere set bil_klar = now() + interval '240 seconds' where id = s.id;
  if random() * 100 < sjanse then
    select * into b from biler where tier <= st.tier
      order by -ln(1 - random()) / (case when tier = st.tier then 3 else 1 end) limit 1;
    insert into garasje (eier, bil, verdi, sted) values (s.id, b.navn, b.verdi, s.sted);
    update spillere set exp = exp + 2 + st.tier * 2 where id = s.id;
    return jsonb_build_object('ok', true, 'melding', format('Du stjal en %s verdt %s!', b.navn, kr(b.verdi)));
  elsif random() < 0.5 then
    straff := 60 + floor(random() * 60)::int;
    update spillere set fengsel_til = now() + make_interval(secs => straff) where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('Alarmen gikk og politiet tok deg! %s sekunder i fengsel.', straff));
  else
    return jsonb_build_object('ok', false, 'melding', 'Du fikk ikke bilen i gang og stakk av tomhendt.');
  end if;
end $$;

create or replace function public.selg_bil(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; g garasje;
begin
  s := _meg();
  delete from garasje where id = p_id and eier = s.id returning * into g;
  if not found then raise exception 'Fant ikke bilen'; end if;
  update spillere set penger = penger + g.verdi where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du solgte %s for %s.', g.bil, kr(g.verdi)));
end $$;

create or replace function public.selg_alle_biler() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; sum_ bigint; ant int;
begin
  s := _meg();
  with d as (delete from garasje where eier = s.id returning verdi)
  select coalesce(sum(verdi), 0), count(*) into sum_, ant from d;
  if ant = 0 then raise exception 'Du har ingen biler'; end if;
  update spillere set penger = penger + sum_ where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du solgte %s %s for %s.', ant, case when ant = 1 then 'bil' else 'biler' end, kr(sum_)));
end $$;

create or replace function public.min_garasje() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'bil', bil, 'verdi', verdi, 'sted', sted) order by verdi desc), '[]')
  from garasje where eier = app_uid();
$$;

-- ---------------------------------------------------------------------
--  FENGSEL
-- ---------------------------------------------------------------------
create or replace function public.fengsel_liste() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('navn', navn, 'rank', rank_navn(exp), 'sek', sek_igjen(fengsel_til)) order by fengsel_til), '[]')
  from spillere where fengsel_til > now();
$$;

create or replace function public.bryt_ut(p_navn text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere; sjanse int;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.utbrudd_klar, 'prøve et nytt utbrudd');
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke bryte ut deg selv'; end if;
  if t.fengsel_til is null or t.fengsel_til <= now() then raise exception '% sitter ikke i fengsel', t.navn; end if;
  sjanse := least(85, 40 + rank_indeks(s.exp) * 3);
  update spillere set utbrudd_klar = now() + interval '30 seconds' where id = s.id;
  if random() * 100 < sjanse then
    update spillere set fengsel_til = null where id = t.id;
    update spillere set exp = exp + 3 where id = s.id;
    perform _systemmelding(t.id, 'Du ble brutt ut!', format('%s brøt deg ut av fengselet.', s.navn));
    return jsonb_build_object('ok', true, 'melding', format('Du brøt ut %s og fikk 3 erfaring!', t.navn));
  elsif random() < 0.5 then
    update spillere set fengsel_til = now() + interval '75 seconds' where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', 'Vakten så deg! Du havnet selv i fengsel i 75 sekunder.');
  else
    return jsonb_build_object('ok', false, 'melding', 'Utbruddet mislyktes, men du kom deg unna.');
  end if;
end $$;

create or replace function public.kjop_deg_ut() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; pris bigint;
begin
  s := _meg();
  if s.fengsel_til is null or s.fengsel_til <= now() then raise exception 'Du sitter ikke i fengsel'; end if;
  pris := sek_igjen(s.fengsel_til) * 25;
  if s.penger < pris then raise exception 'Kausjonen koster %. Du har ikke nok kontanter.', kr(pris); end if;
  update spillere set penger = penger - pris, fengsel_til = null where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du betalte %s i kausjon og er fri.', kr(pris)));
end $$;

-- ---------------------------------------------------------------------
--  BANK
-- ---------------------------------------------------------------------
create or replace function public.bank_sett_inn(p_belop bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  if p_belop is null or p_belop < 1 then raise exception 'Ugyldig beløp'; end if;
  if p_belop > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  update spillere set penger = penger - p_belop, bank = bank + p_belop where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du satte inn %s.', kr(p_belop)));
end $$;

create or replace function public.bank_ta_ut(p_belop bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  if p_belop is null or p_belop < 1 then raise exception 'Ugyldig beløp'; end if;
  if p_belop > s.bank then raise exception 'Du har ikke så mye i banken'; end if;
  update spillere set penger = penger + p_belop, bank = bank - p_belop where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du tok ut %s.', kr(p_belop)));
end $$;

create or replace function public.overfor(p_navn text, p_belop bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if p_belop is null or p_belop < 1 then raise exception 'Ugyldig beløp'; end if;
  if p_belop > s.bank then raise exception 'Du har ikke så mye i banken'; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke overføre til deg selv'; end if;
  update spillere set bank = bank - p_belop where id = s.id;
  update spillere set bank = bank + p_belop where id = t.id;
  perform _systemmelding(t.id, 'Penger mottatt', format('%s overførte %s til banken din.', s.navn, kr(p_belop)));
  return jsonb_build_object('ok', true, 'melding', format('Du overførte %s til %s.', kr(p_belop), t.navn));
end $$;

-- ---------------------------------------------------------------------
--  BUTIKK OG SYKEHUS
-- ---------------------------------------------------------------------
create or replace function public.kjop_vapen(p_nivaa int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; v vapen_typer;
begin
  s := _meg(); perform _sjekk_fri(s);
  select * into v from vapen_typer where nivaa = p_nivaa;
  if not found then raise exception 'Ukjent våpen'; end if;
  if s.vapen >= v.nivaa then raise exception 'Du har allerede et like godt eller bedre våpen'; end if;
  if s.penger < v.pris then raise exception 'Du har ikke råd (% kontant)', kr(v.pris); end if;
  update spillere set penger = penger - v.pris, vapen = v.nivaa where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s.', v.navn));
end $$;

create or replace function public.kjop_beskyttelse(p_nivaa int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; v beskyttelse_typer;
begin
  s := _meg(); perform _sjekk_fri(s);
  select * into v from beskyttelse_typer where nivaa = p_nivaa;
  if not found then raise exception 'Ukjent beskyttelse'; end if;
  if s.beskyttelse >= v.nivaa then raise exception 'Du har allerede like god eller bedre beskyttelse'; end if;
  if s.penger < v.pris then raise exception 'Du har ikke råd (% kontant)', kr(v.pris); end if;
  update spillere set penger = penger - v.pris, beskyttelse = v.nivaa where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s.', v.navn));
end $$;

create or replace function public.kjop_kuler(p_antall int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; pris bigint;
begin
  s := _meg(); perform _sjekk_fri(s);
  if p_antall is null or p_antall < 1 or p_antall > 10000 then raise exception 'Du kan kjøpe 1–10 000 kuler om gangen'; end if;
  pris := p_antall * 40;
  if s.penger < pris then raise exception 'Du har ikke råd (% kontant)', kr(pris); end if;
  update spillere set penger = penger - pris, kuler = kuler + p_antall where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s kuler for %s.', p_antall, kr(pris)));
end $$;

create or replace function public.sykehus() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; pris bigint;
begin
  s := _meg();
  if s.helse >= 100 then raise exception 'Du er allerede frisk'; end if;
  pris := (100 - s.helse) * 200;
  if s.penger < pris then raise exception 'Behandlingen koster %. Du har ikke nok kontanter.', kr(pris); end if;
  update spillere set penger = penger - pris, helse = 100 where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du ble lappet sammen for %s. Helse: 100 %%.', kr(pris)));
end $$;

-- ---------------------------------------------------------------------
--  REISE
-- ---------------------------------------------------------------------
create or replace function public.reis(p_by text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.reise_klar, 'reise igjen');
  if not exists (select 1 from byer where navn = p_by) then raise exception 'Ukjent by'; end if;
  if s.sted = p_by then raise exception 'Du er allerede i %', p_by; end if;
  if s.penger < 800 then raise exception 'Flybilletten koster 800 kr'; end if;
  update spillere set penger = penger - 800, sted = p_by, reise_klar = now() + interval '5 minutes' where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du landet i %s.', p_by));
end $$;

-- ---------------------------------------------------------------------
--  KASINO (rulett)
-- ---------------------------------------------------------------------
create or replace function public.rulett(p_innsats bigint, p_valg text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; tall int; rod boolean; vinn boolean; faktor int; farge text;
begin
  s := _meg(); perform _sjekk_fri(s);
  if p_innsats is null or p_innsats < 100 or p_innsats > 5000000 then raise exception 'Innsatsen må være mellom 100 kr og 5 000 000 kr'; end if;
  if p_innsats > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  tall := floor(random() * 37)::int;
  rod := tall = any (array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
  farge := case when tall = 0 then 'grønn' when rod then 'rød' else 'svart' end;
  if p_valg in ('rod','svart','partall','oddetall') then
    faktor := 2;
    vinn := tall <> 0 and case p_valg when 'rod' then rod when 'svart' then not rod
                                       when 'partall' then tall % 2 = 0 else tall % 2 = 1 end;
  elsif p_valg ~ '^\d{1,2}$' and p_valg::int between 0 and 36 then
    faktor := 36; vinn := tall = p_valg::int;
  else raise exception 'Ugyldig valg'; end if;
  if vinn then
    update spillere set penger = penger + p_innsats * (faktor - 1) where id = s.id;
  else
    update spillere set penger = penger - p_innsats where id = s.id;
  end if;
  return jsonb_build_object('ok', vinn, 'tall', tall, 'farge', farge,
    'melding', case when vinn then format('Kulen landet på %s %s. Du vant %s!', farge, tall, kr(p_innsats * (faktor - 1)))
                    else format('Kulen landet på %s %s. Du tapte %s.', farge, tall, kr(p_innsats)) end);
end $$;

-- ---------------------------------------------------------------------
--  ANGREP OG DETEKTIV
-- ---------------------------------------------------------------------
create or replace function public.detektiv(p_navn text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if s.penger < 5000 then raise exception 'Detektiven koster 5 000 kr'; end if;
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  update spillere set penger = penger - 5000 where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Detektiven fant %s i %s.', t.navn, t.sted));
end $$;

create or replace function public.angrip(p_navn text, p_kuler int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere; vm numeric; bm numeric; skade int; utbytte bigint; ekstra int;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.angrep_klar, 'angripe igjen');
  if s.vapen = 0 then raise exception 'Du trenger et våpen. Kjøp et i butikken.'; end if;
  if p_kuler is null or p_kuler < 1 then raise exception 'Du må bruke minst 1 kule'; end if;
  if p_kuler > s.kuler then raise exception 'Du har bare % kuler', s.kuler; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke skyte deg selv'; end if;
  if t.beskyttet_til is not null and t.beskyttet_til > now() then
    raise exception '% er ny og beskyttet i % minutter til', t.navn, ceil(sek_igjen(t.beskyttet_til) / 60.0);
  end if;
  if t.fengsel_til is not null and t.fengsel_til > now() then raise exception '% sitter i fengsel', t.navn; end if;

  if t.sted <> s.sted then
    update spillere set angrep_klar = now() + interval '60 seconds', beskyttet_til = null where id = s.id;
    return jsonb_build_object('ok', false, 'melding', format('Du lette etter %s i %s, men fant ingen. Bruk en detektiv.', t.navn, s.sted));
  end if;

  select styrke into vm from vapen_typer where nivaa = s.vapen;
  bm := coalesce((select styrke from beskyttelse_typer where nivaa = t.beskyttelse), 1.0);
  skade := floor(p_kuler * vm * (1 + rank_indeks(s.exp) * 0.2) / (bm * (1 + rank_indeks(t.exp) * 0.2)) / 10)::int;

  update spillere set kuler = kuler - p_kuler, angrep_klar = now() + interval '5 minutes', beskyttet_til = null where id = s.id;

  if skade >= t.helse then
    utbytte := t.penger;
    ekstra := 40 + rank_indeks(t.exp) * 15;
    insert into gravplass (bruker, navn, rank, drap, drept_av) values (t.id, t.navn, rank_navn(t.exp), t.drap, s.navn);
    update spillere set penger = penger + utbytte, drap = drap + 1, exp = exp + ekstra where id = s.id;
    delete from spillere where id = t.id;
    insert into chat (navn, tekst) values ('System', format('%s ble funnet død i %s.', t.navn, s.sted));
    return jsonb_build_object('ok', true, 'drept', true,
      'melding', format('Du drepte %s! Du tok %s fra liket og fikk %s erfaring.', t.navn, kr(utbytte), ekstra));
  else
    update spillere set helse = helse - skade where id = t.id;
    perform _systemmelding(t.id, 'Du ble skutt!',
      format('%s skjøt på deg i %s. Du mistet %s helse og har %s igjen. Kom deg til sykehuset!', s.navn, s.sted, skade, t.helse - skade));
    return jsonb_build_object('ok', skade > 0, 'drept', false,
      'melding', case when skade = 0 then format('Kulene prellet av %s. Ingen skade.', t.navn)
                      else format('Du traff %s for %s skade. Hen har %s helse igjen.', t.navn, skade, t.helse - skade) end);
  end if;
end $$;

-- ---------------------------------------------------------------------
--  SPILLERLISTER
-- ---------------------------------------------------------------------
create or replace function public.toppliste() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select navn, rank_navn(exp) as rank, drap, sist_aktiv > now() - interval '5 minutes' as online
    from spillere order by exp desc, opprettet limit 100) x;
$$;

create or replace function public.profil(p_navn text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t spillere;
begin
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  return jsonb_build_object('navn', t.navn, 'rank', rank_navn(t.exp), 'drap', t.drap,
    'opprettet', t.opprettet, 'online', t.sist_aktiv > now() - interval '5 minutes',
    'fengsel', coalesce(t.fengsel_til > now(), false), 'beskyttet', coalesce(t.beskyttet_til > now(), false));
end $$;

create or replace function public.antall_online() returns int
language sql security definer set search_path = public as $$
  select count(*)::int from spillere where sist_aktiv > now() - interval '5 minutes';
$$;

-- ---------------------------------------------------------------------
--  MELDINGER OG CHAT
-- ---------------------------------------------------------------------
create or replace function public.send_melding(p_til text, p_emne text, p_tekst text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg(); perform _vent(s.melding_klar, 'sende ny melding');
  p_emne := left(trim(coalesce(p_emne, '')), 80); p_tekst := trim(coalesce(p_tekst, ''));
  if p_emne = '' then p_emne := '(uten emne)'; end if;
  if length(p_tekst) < 1 or length(p_tekst) > 2000 then raise exception 'Meldingen må være 1–2000 tegn'; end if;
  t := _finn(p_til);
  insert into meldinger (til, fra_navn, emne, tekst) values (t.id, s.navn, p_emne, p_tekst);
  update spillere set melding_klar = now() + interval '10 seconds' where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Melding sendt til %s.', t.navn));
end $$;

create or replace function public.les_melding(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update meldinger set lest = true where id = p_id and til = app_uid();
$$;

create or replace function public.slett_melding(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from meldinger where id = p_id and til = app_uid();
$$;

create or replace function public.send_chat(p_tekst text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  s := _meg(); perform _vent(s.chat_klar, 'skrive igjen');
  p_tekst := trim(coalesce(p_tekst, ''));
  if length(p_tekst) < 1 or length(p_tekst) > 300 then raise exception 'Meldingen må være 1–300 tegn'; end if;
  insert into chat (navn, tekst) values (s.navn, p_tekst);
  update spillere set chat_klar = now() + interval '3 seconds' where id = s.id;
  delete from chat where id < (select min(id) from (select id from chat order by id desc limit 500) x);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
--  LISTER SOM TIDLIGERE BLE LEST DIREKTE
-- ---------------------------------------------------------------------
create or replace function public.mine_meldinger() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.tid desc), '[]') from (
    select id, fra_navn, emne, tekst, lest, tid from meldinger
    where til = app_uid() order by tid desc limit 50) x;
$$;

create or replace function public.chat_siste(p_etter bigint) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.id), '[]') from (
    select id, navn, tekst, tid from chat
    where id > coalesce(p_etter, 0) order by id desc limit 60) x;
$$;

create or replace function public.gravplass_liste() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.tid desc), '[]') from (
    select navn, rank, drap, drept_av, tid from gravplass order by tid desc limit 50) x;
$$;

-- ---------------------------------------------------------------------
--  API: eneste inngang fra nettleseren. Kun funksjonene i listen kan kalles.
-- ---------------------------------------------------------------------
create or replace function public.api(p_uid uuid, p_fn text, a jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare r jsonb;
begin
  perform set_config('app.uid', coalesce(p_uid::text, ''), true);
  a := coalesce(a, '{}');
  r := case p_fn
    when 'spill_data'       then spill_data()
    when 'opprett_spiller'  then opprett_spiller(a->>'p_navn')
    when 'min_status'       then min_status()
    when 'begaa_krim'       then begaa_krim((a->>'p_id')::int)
    when 'stjel_bil'        then stjel_bil((a->>'p_id')::int)
    when 'selg_bil'         then selg_bil((a->>'p_id')::bigint)
    when 'selg_alle_biler'  then selg_alle_biler()
    when 'min_garasje'      then min_garasje()
    when 'fengsel_liste'    then fengsel_liste()
    when 'bryt_ut'          then bryt_ut(a->>'p_navn')
    when 'kjop_deg_ut'      then kjop_deg_ut()
    when 'bank_sett_inn'    then bank_sett_inn((a->>'p_belop')::bigint)
    when 'bank_ta_ut'       then bank_ta_ut((a->>'p_belop')::bigint)
    when 'overfor'          then overfor(a->>'p_navn', (a->>'p_belop')::bigint)
    when 'kjop_vapen'       then kjop_vapen((a->>'p_nivaa')::int)
    when 'kjop_beskyttelse' then kjop_beskyttelse((a->>'p_nivaa')::int)
    when 'kjop_kuler'       then kjop_kuler((a->>'p_antall')::int)
    when 'sykehus'          then sykehus()
    when 'reis'             then reis(a->>'p_by')
    when 'rulett'           then rulett((a->>'p_innsats')::bigint, a->>'p_valg')
    when 'detektiv'         then detektiv(a->>'p_navn')
    when 'angrip'           then angrip(a->>'p_navn', (a->>'p_kuler')::int)
    when 'toppliste'        then toppliste()
    when 'profil'           then profil(a->>'p_navn')
    when 'antall_online'    then to_jsonb(antall_online())
    when 'send_melding'     then send_melding(a->>'p_til', a->>'p_emne', a->>'p_tekst')
    when 'les_melding'      then (select '{"ok":true}'::jsonb from (select les_melding((a->>'p_id')::bigint)) x)
    when 'slett_melding'    then (select '{"ok":true}'::jsonb from (select slett_melding((a->>'p_id')::bigint)) x)
    when 'send_chat'        then send_chat(a->>'p_tekst')
    when 'mine_meldinger'   then mine_meldinger()
    when 'chat_siste'       then chat_siste((a->>'p_etter')::bigint)
    when 'gravplass_liste'  then gravplass_liste()
  end;
  if r is null and p_fn not in ('les_melding','slett_melding') then
    if p_fn not in ('spill_data','opprett_spiller','min_status','begaa_krim','stjel_bil','selg_bil','selg_alle_biler',
      'min_garasje','fengsel_liste','bryt_ut','kjop_deg_ut','bank_sett_inn','bank_ta_ut','overfor','kjop_vapen',
      'kjop_beskyttelse','kjop_kuler','sykehus','reis','rulett','detektiv','angrip','toppliste','profil','antall_online',
      'send_melding','send_chat','mine_meldinger','chat_siste','gravplass_liste') then
      raise exception 'Ukjent handling';
    end if;
  end if;
  return r;
end $$;
