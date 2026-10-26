-- =====================================================================
--  PROFILER, HANDLINGSLOGG, NYTT KASINO (blackjack, terninger, lotto),
--  LOTTOPOTT FRA KASINOTAP, BOTER OG ADMINRAPPORT
-- =====================================================================

-- ---------------------------------------------------------------------
--  PROFIL
-- ---------------------------------------------------------------------
alter table public.spillere add column if not exists bio text not null default '';
alter table public.spillere add column if not exists kjonn text not null default '';
alter table public.spillere add column if not exists avatar_url text not null default '';
alter table public.spillere add column if not exists musikk_url text not null default '';
alter table public.spillere add column if not exists vis_bio boolean not null default true;
alter table public.spillere add column if not exists er_bot boolean not null default false;
alter table public.spillere add constraint spillere_kjonn_ok check (kjonn in ('', 'mann', 'kvinne'));

create table public.profilbilder (
  spiller uuid primary key references public.spillere(id) on delete cascade,
  data text not null, versjon int not null default 1, oppdatert timestamptz not null default now());

create or replace function public._url_ok(u text) returns boolean language sql immutable as
$$ select u = '' or (u ~ '^https?://[^\s<>"'']+$' and length(u) <= 500) $$;

create or replace function public.sett_profil(p_bio text, p_kjonn text, p_avatar_url text, p_musikk_url text, p_vis_bio boolean) returns jsonb
language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  p_bio := coalesce(p_bio, ''); p_avatar_url := trim(coalesce(p_avatar_url, '')); p_musikk_url := trim(coalesce(p_musikk_url, ''));
  if length(p_bio) > 6000 then raise exception 'Om meg kan være maks 6000 tegn'; end if;
  if coalesce(p_kjonn, '') not in ('', 'mann', 'kvinne') then raise exception 'Ugyldig kjønn'; end if;
  if not _url_ok(p_avatar_url) then raise exception 'Avatar må være en lenke som starter med https://'; end if;
  if not _url_ok(p_musikk_url) then raise exception 'Musikk må være en lenke som starter med https://'; end if;
  update spillere set bio = p_bio, kjonn = coalesce(p_kjonn, ''), avatar_url = p_avatar_url, musikk_url = p_musikk_url,
    vis_bio = coalesce(p_vis_bio, true) where id = s.id;
  return jsonb_build_object('ok', true, 'melding', 'Profilen er lagret.');
end $$;

create or replace function public.sett_profilbilde(p_data text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b64 text; raw bytea;
begin
  s := _meg();
  if p_data is null or p_data not like 'data:image/jpeg;base64,%' then raise exception 'Bildet må være JPEG'; end if;
  b64 := substr(p_data, length('data:image/jpeg;base64,') + 1);
  if length(b64) > 400000 then raise exception 'Bildet er for stort'; end if;
  begin raw := decode(b64, 'base64'); exception when others then raise exception 'Ugyldig bilde'; end;
  if substr(raw, 1, 3) <> '\xffd8ff'::bytea then raise exception 'Ugyldig bilde'; end if;
  insert into profilbilder (spiller, data) values (s.id, b64)
    on conflict (spiller) do update set data = excluded.data, versjon = profilbilder.versjon + 1, oppdatert = now();
  return jsonb_build_object('ok', true, 'melding', 'Profilbildet er lastet opp.');
end $$;

create or replace function public.slett_profilbilde() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  delete from profilbilder where spiller = s.id;
  update spillere set avatar_url = '' where id = s.id;
  return jsonb_build_object('ok', true, 'melding', 'Profilbildet er fjernet.');
end $$;

-- Bildeadresse for en spiller: opplastet bilde går foran lenke
create or replace function public._bilde(p uuid) returns text language sql stable set search_path = public as $$
  select coalesce(
    (select '/api/bilde/' || (select navn from spillere where id = p) || '?v=' || versjon from profilbilder where spiller = p),
    nullif((select avatar_url from spillere where id = p), ''));
$$;

create or replace function public.bilde_liste() returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(navn, _bilde(id)), '{}') from spillere
  where avatar_url <> '' or exists (select 1 from profilbilder where spiller = spillere.id);
$$;

create or replace function public._pengestatus(n bigint) returns text language sql immutable as $$
  select case when n < 10000 then 'Blakk' when n < 100000 then 'Arbeider' when n < 1000000 then 'Middelklasse'
              when n < 10000000 then 'Velstående' when n < 100000000 then 'Rik' else 'Styrtrik' end;
$$;

create or replace function public.profil(p_navn text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t spillere; meg uuid := app_uid();
begin
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  return jsonb_build_object('navn', t.navn, 'rank', rank_navn(t.exp), 'drap', t.drap, 'min', t.id = meg,
    'opprettet', t.opprettet, 'sist_aktiv', t.sist_aktiv, 'online', t.sist_aktiv > now() - interval '5 minutes',
    'gjeng', (select navn from gjenger where id = t.gjeng_id), 'tag', (select tag from gjenger where id = t.gjeng_id),
    'pengestatus', _pengestatus(t.penger + t.bank), 'kjonn', t.kjonn, 'bot', t.er_bot,
    'bilde', _bilde(t.id), 'musikk', t.musikk_url,
    'bio', case when t.vis_bio or t.id = meg then t.bio else '' end,
    'prestasjoner', (select count(*) from prestasjon_hentet where spiller = t.id),
    'prestasjoner_totalt', (select count(*) from prestasjon_typer),
    'prestasjonspoeng', (select coalesce(sum(p.poeng), 0) from prestasjon_hentet h join prestasjon_typer p on p.id = h.prestasjon where h.spiller = t.id),
    'meldinger_sendt', _stat(t.id, 'melding'), 'krim', _stat(t.id, 'krim_ok'), 'biler', _stat(t.id, 'bil_ok'),
    'fengsel', coalesce(t.fengsel_til > now(), false), 'beskyttet', coalesce(t.beskyttet_til > now(), false));
end $$;

create or replace function public.min_profil() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return jsonb_build_object('bio', s.bio, 'kjonn', s.kjonn, 'avatar_url', s.avatar_url, 'musikk_url', s.musikk_url,
    'vis_bio', s.vis_bio, 'bilde', _bilde(s.id), 'opplastet', exists (select 1 from profilbilder where spiller = s.id),
    'statistikk', (select coalesce(jsonb_object_agg(nokkel, antall), '{}') from stat where spiller = s.id));
end $$;

-- ---------------------------------------------------------------------
--  HANDLINGSLOGG (vises under Meldinger)
-- ---------------------------------------------------------------------
create table public.handlingslogg (
  id bigint generated always as identity primary key,
  spiller uuid not null references public.spillere(id) on delete cascade,
  tekst text not null, type text not null default 'handling' check (type in ('handling', 'hendelse')),
  ok boolean, lest boolean not null default true, tid timestamptz not null default now());
create index on public.handlingslogg (spiller, id desc);

create or replace function public._logg(p uuid, t text, typ text default 'handling', o boolean default null) returns void
language plpgsql set search_path = public as $$
begin
  insert into handlingslogg (spiller, tekst, type, ok, lest) values (p, t, typ, o, typ = 'handling');
  if random() < 0.05 then
    delete from handlingslogg where spiller = p and id < (select coalesce(min(id), 0) from (select id from handlingslogg where spiller = p order by id desc limit 300) x);
  end if;
end $$;

-- Systemvarsler (du ble ranet, skutt, fikk penger …) går nå til loggen i stedet for innboksen.
create or replace function public._systemmelding(p_til uuid, p_emne text, p_tekst text) returns void
language sql security definer set search_path = public as $$
  select _logg(p_til, p_emne || ': ' || p_tekst, 'hendelse', null);
$$;

-- Flytt gamle systemmeldinger fra innboksen til loggen
insert into public.handlingslogg (spiller, tekst, type, lest, tid)
  select til, emne || ': ' || tekst, 'hendelse', lest, tid from public.meldinger where fra_navn = 'System';
delete from public.meldinger where fra_navn = 'System';

create or replace function public.min_logg(p_type text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return coalesce((select jsonb_agg(jsonb_build_object('tekst', tekst, 'type', type, 'ok', ok, 'lest', lest, 'tid', tid) order by id desc)
    from (select * from handlingslogg where spiller = s.id and (coalesce(p_type, '') = '' or type = p_type) order by id desc limit 150) x), '[]');
end $$;

create or replace function public.les_logg() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  update handlingslogg set lest = true where spiller = s.id and not lest;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
--  KASINO: LOTTOPOTT FRA TAP, TERNINGER MOT BANKEN
-- ---------------------------------------------------------------------
create table public.lotto_pott (runde int primary key, ekstra bigint not null default 0);

create or replace function public._lotto_legg_til(b bigint) returns void language sql set search_path = public as $$
  insert into lotto_pott (runde, ekstra) values (_lotto_runde(), b)
    on conflict (runde) do update set ekstra = lotto_pott.ekstra + excluded.ekstra;
$$;

create or replace function public._lotto_pott(r int) returns bigint language sql stable set search_path = public as $$
  select 100000 + 5000 * coalesce((select sum(antall) from lotto_kuponger where runde = r), 0)
       + coalesce((select ekstra from lotto_pott where runde = r), 0);
$$;

create or replace function public._lotto_trekk() returns void language plpgsql set search_path = public as $$
declare r int; total int; x int; k record; vinner lotto_kuponger; pott bigint; ekstra_ bigint;
begin
  for r in select runde from (select runde from lotto_kuponger union select runde from lotto_pott) u
           where runde < _lotto_runde() and runde not in (select runde from lotto_trekninger) order by runde loop
    select coalesce(sum(antall), 0) into total from lotto_kuponger where runde = r;
    if total = 0 then
      -- Ingen kuponger: potten fra kasinotap rulles over til neste uke
      select coalesce(ekstra, 0) into ekstra_ from lotto_pott where runde = r;
      if coalesce(ekstra_, 0) > 0 then perform _lotto_legg_til(ekstra_); end if;
      insert into lotto_trekninger (runde, vinner, pott, kuponger) values (r, null, 0, 0);
      continue;
    end if;
    x := floor(random() * total)::int;
    for k in select * from lotto_kuponger where runde = r order by spiller loop
      x := x - k.antall;
      if x < 0 then vinner := k; exit; end if;
    end loop;
    pott := _lotto_pott(r);
    update spillere set bank = bank + pott where id = vinner.spiller;
    insert into lotto_trekninger (runde, vinner, pott, kuponger) values (r, vinner.navn, pott, total);
    perform _systemmelding(vinner.spiller, 'Du vant i lotto!', format('Gratulerer! Du vant %s i ukens lotto. Pengene er satt inn i banken.', kr(pott)));
    perform _avis(format('%s vant %s i lotto!', vinner.navn, kr(pott)));
  end loop;
end $$;

create or replace function public.lotto_info() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; r int;
begin
  s := _meg(); perform _lotto_trekk(); r := _lotto_runde();
  return jsonb_build_object('pott', _lotto_pott(r), 'pris', 5000,
    'kuponger', coalesce((select sum(antall) from lotto_kuponger where runde = r), 0),
    'fra_kasino', coalesce((select ekstra from lotto_pott where runde = r), 0),
    'mine', coalesce((select antall from lotto_kuponger where runde = r and spiller = s.id), 0),
    'trekning', (date_trunc('week', now() at time zone 'Europe/Oslo') + interval '7 days') at time zone 'Europe/Oslo',
    'siste', (select coalesce(jsonb_agg(jsonb_build_object('vinner', vinner, 'pott', pott, 'kuponger', kuponger, 'tid', tid) order by runde desc), '[]')
              from (select * from lotto_trekninger where vinner is not null order by runde desc limit 5) x));
end $$;

-- Blackjack: tapte innsatser går i lottopotten
create or replace function public._bj_avslutt(b bj_spill) returns jsonb language plpgsql set search_path = public as $$
declare p int; d int; gevinst bigint := 0; m text; ok boolean;
begin
  p := _bj_verdi(b.hand); d := _bj_verdi(b.dealer);
  if p > 21 then m := format('Du fikk %s og gikk over 21. %s går i lottopotten.', p, kr(b.innsats)); ok := false;
  elsif d > 21 or p > d then gevinst := b.innsats * 2; m := format('Du vant med %s mot %s! Gevinst %s.', p, d, kr(b.innsats)); ok := true;
  elsif p = d then gevinst := b.innsats; m := format('Uavgjort på %s. Du får innsatsen tilbake.', p); ok := null;
  else m := format('Banken vant med %s mot %s. %s går i lottopotten.', d, p, kr(b.innsats)); ok := false; end if;
  if gevinst > 0 then update spillere set penger = penger + gevinst where id = b.spiller; end if;
  if ok = false then perform _lotto_legg_til(b.innsats); end if;
  delete from bj_spill where spiller = b.spiller;
  return _bj_json(b, false) || jsonb_build_object('ferdig', true, 'ok', coalesce(ok, false), 'uavgjort', ok is null, 'melding', m);
end $$;

create or replace function public.terning_kast(p_innsats bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; a int; b int; a1 int; a2 int; b1 int; b2 int;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.kasino_klar, 'kaste igjen');
  if p_innsats is null or p_innsats < 100 or p_innsats > 2000000 then raise exception 'Innsatsen må være mellom 100 kr og 2 000 000 kr'; end if;
  if p_innsats > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  loop
    a1 := 1 + floor(random() * 6)::int; a2 := 1 + floor(random() * 6)::int;
    b1 := 1 + floor(random() * 6)::int; b2 := 1 + floor(random() * 6)::int;
    a := a1 + a2; b := b1 + b2;
    exit when a <> b;
  end loop;
  update spillere set kasino_klar = now() + interval '3 seconds' where id = s.id;
  if a > b then
    update spillere set penger = penger + p_innsats where id = s.id;
    return jsonb_build_object('ok', true, 'din', array[a1, a2], 'bank', array[b1, b2],
      'melding', format('Du kastet %s mot bankens %s. Du vant %s!', a, b, kr(p_innsats)));
  end if;
  update spillere set penger = penger - p_innsats where id = s.id;
  perform _lotto_legg_til(p_innsats);
  return jsonb_build_object('ok', false, 'din', array[a1, a2], 'bank', array[b1, b2],
    'melding', format('Du kastet %s mot bankens %s. %s går i lottopotten.', a, b, kr(p_innsats)));
end $$;

-- ---------------------------------------------------------------------
--  FJERNEDE KASINOSPILL: tilbakebetal alt som står åpent
-- ---------------------------------------------------------------------
update public.spillere s set penger = s.penger + u.innsats
  from public.utfordringer u where u.status = 'apen' and u.utfordrer = s.id;
delete from public.utfordringer where status = 'apen';
update public.spillere s set penger = s.penger + g.innsats
  from public.gruppespill g join public.gruppe_deltaker d on d.spill_id = g.id
  where g.status = 'apen' and d.spiller = s.id;
delete from public.gruppespill where status = 'apen';

-- Oppdrag og prestasjoner for kasino teller fortsatt (blackjack, terninger, lotto)
update public.oppdrag_typer set tittel = 'Spill 5 ganger i kasinoet (blackjack, terninger eller lotto)' where id = 'kasino5';

-- ---------------------------------------------------------------------
--  ADMIN OG BOTER
-- ---------------------------------------------------------------------
create table public.app_admin (epost text primary key);
insert into public.app_admin values ('saeedinho300@gmail.com'), ('saeed_carlos3@hotmail.com');

create or replace function public._er_admin(p uuid) returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from kontoer k join app_admin a on a.epost = lower(k.epost) or a.epost = lower(coalesce(k.google_epost, '')) where k.id = p);
$$;

create table public.bot_kjoring (
  id bigint generated always as identity primary key,
  start timestamptz not null default now(), varighet_ms int not null default 0,
  boter int not null default 0, kall int not null default 0,
  regelfeil jsonb not null default '{}', uventet jsonb not null default '[]', rapportert boolean not null default false);

create or replace function public.bot_rapport() returns jsonb language plpgsql set search_path = public as $$
begin
  if not _er_admin(app_uid()) then raise exception 'Ingen tilgang'; end if;
  return jsonb_build_object(
    'boter', (select coalesce(jsonb_agg(jsonb_build_object('navn', navn, 'rank', rank_navn(exp), 'penger', penger + bank, 'sist_aktiv', sist_aktiv) order by exp desc), '[]') from spillere where er_bot),
    'kjoringer', (select coalesce(jsonb_agg(jsonb_build_object('start', start, 'ms', varighet_ms, 'boter', boter, 'kall', kall,
                     'uventet', jsonb_array_length(uventet), 'regelfeil', (select coalesce(sum(value::int), 0) from jsonb_each_text(regelfeil))) order by id desc), '[]')
                  from (select * from bot_kjoring order by id desc limit 40) x),
    'uventet', (select coalesce(jsonb_agg(f order by f->>'tid' desc), '[]') from (
                  select e as f from bot_kjoring k, jsonb_array_elements(k.uventet) e where k.start > now() - interval '3 days' order by k.id desc limit 100) y),
    'regelfeil', (select coalesce(jsonb_object_agg(key, sum), '{}') from (
                  select key, sum(value::int) from bot_kjoring, jsonb_each_text(regelfeil) where start > now() - interval '1 day' group by key order by 2 desc limit 25) z));
end $$;

-- ---------------------------------------------------------------------
--  API (erstatter forrige versjon)
-- ---------------------------------------------------------------------
create or replace function public.api(p_uid uuid, p_fn text, a jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare r jsonb; exp_for int; exp_etter int; mitt_navn text; ok boolean;
begin
  perform set_config('app.uid', coalesce(p_uid::text, ''), true);
  a := coalesce(a, '{}');
  select exp, navn into exp_for, mitt_navn from spillere where id = p_uid;

  case p_fn
    -- konto, status og profil
    when 'spill_data'       then r := spill_data();
    when 'opprett_spiller'  then r := opprett_spiller(a->>'p_navn');
    when 'min_status'       then perform _verv_sjekk(p_uid); r := min_status();
    when 'sett_verver'      then r := sett_verver(a->>'p_navn');
    when 'verv_info'        then r := verv_info();
    when 'min_profil'       then r := min_profil();
    when 'sett_profil'      then r := sett_profil(a->>'p_bio', a->>'p_kjonn', a->>'p_avatar_url', a->>'p_musikk_url', (a->>'p_vis_bio')::boolean);
    when 'sett_profilbilde' then r := sett_profilbilde(a->>'p_data');
    when 'slett_profilbilde' then r := slett_profilbilde();
    when 'bilde_liste'      then r := bilde_liste();
    when 'min_logg'         then r := min_logg(a->>'p_type');
    when 'les_logg'         then r := les_logg();
    when 'bot_rapport'      then r := bot_rapport();
    -- handlinger
    when 'begaa_krim'       then r := begaa_krim((a->>'p_id')::int);
    when 'stjel_bil'        then r := stjel_bil((a->>'p_id')::int);
    when 'ran_spiller'      then r := ran_spiller(a->>'p_navn');
    when 'selg_bil'         then r := selg_bil((a->>'p_id')::bigint);
    when 'selg_alle_biler'  then r := selg_alle_biler();
    when 'min_garasje'      then r := min_garasje();
    when 'fengsel_liste'    then r := fengsel_liste();
    when 'bryt_ut'          then r := bryt_ut(a->>'p_navn');
    when 'kjop_deg_ut'      then r := kjop_deg_ut();
    when 'sykehus'          then r := sykehus();
    when 'reis'             then r := reis(a->>'p_by');
    when 'detektiv'         then r := detektiv(a->>'p_navn');
    when 'angrip'           then r := angrip(a->>'p_navn', (a->>'p_kuler')::int);
    -- handel
    when 'bank_sett_inn'    then r := bank_sett_inn((a->>'p_belop')::bigint);
    when 'bank_ta_ut'       then r := bank_ta_ut((a->>'p_belop')::bigint);
    when 'overfor'          then r := overfor(a->>'p_navn', (a->>'p_belop')::bigint);
    when 'kjop_vapen'       then r := kjop_vapen((a->>'p_nivaa')::int);
    when 'kjop_beskyttelse' then r := kjop_beskyttelse((a->>'p_nivaa')::int);
    when 'kjop_kuler'       then r := kjop_kuler((a->>'p_antall')::int);
    when 'overfor_kuler'    then r := overfor_kuler(a->>'p_navn', (a->>'p_antall')::int);
    when 'overfor_poeng'    then r := overfor_poeng(a->>'p_navn', (a->>'p_antall')::int);
    when 'poeng_kjop'       then r := poeng_kjop(a->>'p_vare');
    when 'borsen'           then r := borsen();
    when 'kjop_aksje'       then r := kjop_aksje((a->>'p_id')::int, (a->>'p_antall')::bigint);
    when 'selg_aksje'       then r := selg_aksje((a->>'p_id')::int, (a->>'p_antall')::bigint);
    when 'bruktbil_liste'   then r := bruktbil_liste();
    when 'legg_ut_bil'      then r := legg_ut_bil((a->>'p_garasje_id')::bigint, (a->>'p_pris')::bigint);
    when 'trekk_bruktbil'   then r := trekk_bruktbil((a->>'p_id')::bigint);
    when 'kjop_bruktbil'    then r := kjop_bruktbil((a->>'p_id')::bigint);
    when 'forretninger'     then r := forretninger();
    when 'livvakt_oppgrader' then r := livvakt_oppgrader();
    when 'livvakt_hent'     then r := livvakt_hent();
    when 'hasj_plant'       then r := hasj_plant((a->>'p_antall')::int);
    when 'hasj_host'        then r := hasj_host();
    -- sosialt
    when 'toppliste'        then r := toppliste();
    when 'profil'           then r := profil(a->>'p_navn');
    when 'antall_online'    then r := to_jsonb(antall_online());
    when 'palogget_liste'   then r := palogget_liste();
    when 'sok_spillere'     then r := sok_spillere(a->>'p_sok');
    when 'send_melding'     then r := send_melding(a->>'p_til', a->>'p_emne', a->>'p_tekst');
    when 'les_melding'      then perform les_melding((a->>'p_id')::bigint); r := '{"ok":true}';
    when 'slett_melding'    then perform slett_melding((a->>'p_id')::bigint); r := '{"ok":true}';
    when 'mine_meldinger'   then r := mine_meldinger();
    when 'send_chat'        then r := send_chat(a->>'p_tekst');
    when 'chat_siste'       then r := chat_siste((a->>'p_etter')::bigint);
    when 'gravplass_liste'  then r := gravplass_liste();
    when 'gjeng_liste'      then r := gjeng_liste();
    when 'min_gjeng'        then r := min_gjeng();
    when 'opprett_gjeng'    then r := opprett_gjeng(a->>'p_navn', a->>'p_tag');
    when 'bli_med_gjeng'    then r := bli_med_gjeng((a->>'p_id')::bigint);
    when 'forlat_gjeng'     then r := forlat_gjeng();
    when 'kast_ut_gjeng'    then r := kast_ut_gjeng(a->>'p_navn');
    when 'gjeng_innskudd'   then r := gjeng_innskudd((a->>'p_belop')::bigint);
    when 'gjeng_utbetal'    then r := gjeng_utbetal(a->>'p_navn', (a->>'p_belop')::bigint);
    when 'forum_liste'      then r := forum_liste(a->>'p_kategori');
    when 'forum_traad'      then r := forum_traad((a->>'p_id')::bigint);
    when 'ny_traad'         then r := ny_traad(a->>'p_kategori', a->>'p_tittel', a->>'p_tekst');
    when 'svar_traad'       then r := svar_traad((a->>'p_id')::bigint, a->>'p_tekst');
    when 'nyheter_liste'    then r := nyheter_liste();
    when 'avis_liste'       then r := avis_liste();
    when 'mine_oppdrag'     then r := mine_oppdrag();
    when 'hent_oppdrag'     then r := hent_oppdrag(a->>'p_id');
    when 'mine_prestasjoner' then r := mine_prestasjoner();
    when 'hent_prestasjon'  then r := hent_prestasjon(a->>'p_id');
    -- kasino: blackjack, terninger og lotto
    when 'bj_status'        then r := bj_status();
    when 'bj_start'         then r := bj_start((a->>'p_innsats')::bigint);
    when 'bj_trekk'         then r := bj_trekk();
    when 'bj_staa'          then r := bj_staa();
    when 'terning_kast'     then r := terning_kast((a->>'p_innsats')::bigint);
    when 'lotto_info'       then r := lotto_info();
    when 'kjop_lotto'       then r := kjop_lotto((a->>'p_antall')::int);
    else raise exception 'Ukjent handling';
  end case;

  if p_uid is not null and exp_for is not null and jsonb_typeof(r) = 'object' then
    ok := (r->>'ok')::boolean;
    case p_fn
      when 'begaa_krim' then perform _tell(p_uid, 'krim'); if ok then perform _tell(p_uid, 'krim_ok'); end if;
      when 'stjel_bil'  then perform _tell(p_uid, 'bil');  if ok then perform _tell(p_uid, 'bil_ok'); end if;
      when 'ran_spiller' then perform _tell(p_uid, 'ran'); if ok then perform _tell(p_uid, 'ran_ok'); end if;
      when 'bryt_ut'    then perform _tell(p_uid, 'utbrudd'); if ok then perform _tell(p_uid, 'utbrudd_ok'); end if;
      when 'reis'       then perform _tell(p_uid, 'reise');
      when 'send_melding' then perform _tell(p_uid, 'melding');
      when 'angrip'     then
        perform _tell(p_uid, 'angrep');
        if coalesce((r->>'drept')::boolean, false) then
          perform _tell(p_uid, 'drap');
          perform _avis(format('%s ble drept av %s.', a->>'p_navn', mitt_navn));
        end if;
      when 'bj_start', 'terning_kast', 'kjop_lotto' then perform _tell(p_uid, 'kasino');
      else null;
    end case;

    -- Handlingsloggen: alt som gir en melding til spilleren
    if r ? 'melding' and exists (select 1 from spillere where id = p_uid) then
      perform _logg(p_uid, r->>'melding', 'handling', case when coalesce((r->>'uavgjort')::boolean, false) then null else ok end);
    end if;

    select exp into exp_etter from spillere where id = p_uid;
    if exp_etter is not null and rank_indeks(exp_etter) > rank_indeks(exp_for) then
      perform _avis(format('%s rykket opp til %s.', mitt_navn, rank_navn(exp_etter)));
      perform _logg(p_uid, format('Du rykket opp til %s!', rank_navn(exp_etter)), 'hendelse', true);
      r := r || jsonb_build_object('rankopp', rank_navn(exp_etter));
    end if;

    if p_fn = 'min_status' and jsonb_typeof(r->'spiller') = 'object' then
      r := r || jsonb_build_object('varsler', _varsler(p_uid),
        'gjeng_tag', (select tag from gjenger g join spillere s on s.gjeng_id = g.id where s.id = p_uid),
        'uleste_logg', (select count(*) from handlingslogg where spiller = p_uid and not lest),
        'bilde', _bilde(p_uid), 'admin', _er_admin(p_uid));
    end if;
  end if;
  return r;
end $$;
