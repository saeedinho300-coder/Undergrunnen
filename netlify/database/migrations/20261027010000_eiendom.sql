-- =====================================================================
--  EIENDOM: fra uteligger til mansion.
--  Leie betales én gang og varer 30 dager. Kjøp er permanent.
--  Kjøp betales med kontanter først, resten trekkes fra banken.
-- =====================================================================
create table if not exists public.boliger (
  id text primary key,
  navn text not null,
  beskrivelse text not null,
  leie bigint,          -- pris for 30 dager (null = kan ikke leies)
  kjop bigint,          -- kjøpspris (null = kan ikke kjøpes)
  rekkefolge int not null
);

insert into public.boliger (id, navn, beskrivelse, leie, kjop, rekkefolge) values
  ('uteligger', 'Uteligger',      'Pappesker under en bro. Gratis, men kaldt.',                         0,     null,        1),
  ('hybel',     'Hybel',          'Et lite rom med køyeseng og felles bad.',                            3000,  null,        2),
  ('leilighet', 'Leilighet',      'To roms leilighet i en blokk midt i byen.',                          15000, 4800000,     3),
  ('rekkehus',  'Rekkehus',       'Eget inngangsparti, liten hage og naboer som ikke spør.',            24000, 7900000,     4),
  ('enebolig',  'Enebolig',       'Frittstående hus med garasje og høy hekk.',                          32000, 12500000,    5),
  ('penthouse', 'Penthouse',      'Toppetasjen med glassvegger og utsikt over hele byen.',              null,  38000000,    6),
  ('villa',     'Moderne villa',  'Betong, glass og basseng. Kun til salgs.',                           null,  65000000,    7),
  ('bunker',    'Bunker',         'Atomsikker bunker under bakken. Ingen finner deg her.',              null,  90000000,    8),
  ('herregard', 'Herregård',      'Gammel herregård med eget jorde og lang innkjørsel.',               null,  180000000,   9),
  ('mansion',   'Mansion',        'Det største og dyreste huset i byen. Bare for de aller rikeste.',   null,  450000000,   10)
on conflict (id) do update set navn = excluded.navn, beskrivelse = excluded.beskrivelse, leie = excluded.leie, kjop = excluded.kjop, rekkefolge = excluded.rekkefolge;

alter table public.spillere add column if not exists bolig text not null default 'uteligger' references public.boliger(id);
alter table public.spillere add column if not exists bolig_eid boolean not null default false;
alter table public.spillere add column if not exists bolig_leie_til timestamptz;

-- Hvilken bolig spilleren faktisk har nå (utløpt leie = uteligger)
create or replace function public._bolig(s spillere) returns text language sql stable as $$
  select case when s.bolig_eid then s.bolig
              when s.bolig <> 'uteligger' and s.bolig_leie_til is not null and s.bolig_leie_til > now() then s.bolig
              else 'uteligger' end;
$$;

-- Betal med kontanter først, så fra banken
create or replace function public._betal(p uuid, p_belop bigint) returns void language plpgsql set search_path = public as $$
declare s spillere; fra_kontant bigint;
begin
  select * into s from spillere where id = p for update;
  if s.penger + s.bank < p_belop then
    raise exception 'Det koster %. Du har % i kontanter og banken til sammen.', kr(p_belop), kr(s.penger + s.bank);
  end if;
  fra_kontant := least(s.penger, p_belop);
  update spillere set penger = penger - fra_kontant, bank = bank - (p_belop - fra_kontant) where id = p;
end $$;

create or replace function public.eiendom_info() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; naa text;
begin
  s := _meg(); naa := _bolig(s);
  return jsonb_build_object(
    'bolig', naa, 'eid', s.bolig_eid and naa = s.bolig,
    'leie_til', case when not s.bolig_eid and naa <> 'uteligger' then s.bolig_leie_til end,
    'penger', s.penger, 'bank', s.bank,
    'boliger', (select jsonb_agg(jsonb_build_object('id', id, 'navn', navn, 'beskrivelse', beskrivelse, 'leie', leie, 'kjop', kjop) order by rekkefolge) from boliger));
end $$;

create or replace function public.lei_bolig(p_id text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b boliger; naa text; ny_til timestamptz;
begin
  s := _meg();
  select * into b from boliger where id = p_id;
  if not found then raise exception 'Ukjent bolig'; end if;
  if b.leie is null then raise exception '% kan bare kjøpes', b.navn; end if;
  naa := _bolig(s);
  if s.bolig_eid then raise exception 'Du eier allerede %. Selg den først hvis du vil leie.', (select navn from boliger where id = s.bolig); end if;

  if b.id = 'uteligger' then
    update spillere set bolig = 'uteligger', bolig_leie_til = null where id = s.id;
    return jsonb_build_object('ok', true, 'melding', 'Du flyttet ut på gata. Det er gratis, men kaldt.');
  end if;

  perform _betal(s.id, b.leie);
  -- Forlenger du samme bolig, legges 30 nye dager til
  ny_til := case when naa = b.id then s.bolig_leie_til + interval '30 days' else now() + interval '30 days' end;
  update spillere set bolig = b.id, bolig_eid = false, bolig_leie_til = ny_til where id = s.id;
  return jsonb_build_object('ok', true, 'melding',
    case when naa = b.id then format('Du forlenget leien av %s med 30 dager for %s.', lower(b.navn), kr(b.leie))
         else format('Du leier nå %s for %s. Leien varer i 30 dager.', lower(b.navn), kr(b.leie)) end);
end $$;

create or replace function public.kjop_bolig(p_id text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b boliger;
begin
  s := _meg();
  select * into b from boliger where id = p_id;
  if not found then raise exception 'Ukjent bolig'; end if;
  if b.kjop is null then raise exception '% kan ikke kjøpes', b.navn; end if;
  if s.bolig_eid then raise exception 'Du eier allerede %. Selg den først.', (select navn from boliger where id = s.bolig); end if;
  perform _betal(s.id, b.kjop);
  update spillere set bolig = b.id, bolig_eid = true, bolig_leie_til = null, exp = exp + 5 where id = s.id;
  perform _avis(format('%s kjøpte %s for %s.', s.navn, lower(b.navn), kr(b.kjop)));
  return jsonb_build_object('ok', true, 'melding', format('Gratulerer! Du kjøpte %s for %s. (+5 erfaring)', lower(b.navn), kr(b.kjop)));
end $$;

create or replace function public.selg_bolig() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b boliger; pris bigint;
begin
  s := _meg();
  if not s.bolig_eid then raise exception 'Du eier ingen bolig'; end if;
  select * into b from boliger where id = s.bolig;
  pris := floor(b.kjop * 0.8);
  update spillere set bank = bank + pris, bolig = 'uteligger', bolig_eid = false, bolig_leie_til = null where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du solgte %s for %s (80 %% av prisen). Pengene er satt inn i banken. Nå er du uteligger.', lower(b.navn), kr(pris)));
end $$;

-- ---------------------------------------------------------------------
--  API: eiendom legges til i den ytre funksjonen. Profilen viser bolig.
-- ---------------------------------------------------------------------
create or replace function public.api(p_uid uuid, p_fn text, a jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare r jsonb;
begin
  perform set_config('app.uid', coalesce(p_uid::text, ''), true);
  a := coalesce(a, '{}');
  case p_fn
    when 'admin_oversikt' then return admin_oversikt();
    when 'rediger_regel'  then r := rediger_regel((a->>'p_id')::bigint, a->>'p_tittel', a->>'p_tekst');
    when 'slett_traad'    then r := slett_traad((a->>'p_id')::bigint);
    when 'eiendom_info'   then return eiendom_info();
    when 'lei_bolig'      then r := lei_bolig(a->>'p_id');
    when 'kjop_bolig'     then r := kjop_bolig(a->>'p_id');
    when 'selg_bolig'     then r := selg_bolig();
    when 'profil' then
      r := api_v3(p_uid, p_fn, a);
      return r || jsonb_build_object('bolig', (select b.navn from spillere s join boliger b on b.id = _bolig(s) where lower(s.navn) = lower(trim(a->>'p_navn'))));
    else return api_v3(p_uid, p_fn, a);
  end case;
  if p_uid is not null and r ? 'melding' and exists (select 1 from spillere where id = p_uid) then
    perform _logg(p_uid, r->>'melding', 'handling', (r->>'ok')::boolean);
  end if;
  return r;
end $$;
