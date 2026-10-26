-- =====================================================================
--  STOR UTVIDELSE: poeng, oppdrag, prestasjoner, gjenger, forum, nyheter,
--  avis, verving, poenghandel, børs, bruktbil, forretninger, ran,
--  blackjack, utfordringer (terning/streetrace), gruppespill
--  (battle royale / dødsterninger), lotto og nummerspill.
-- =====================================================================

-- ---------------------------------------------------------------------
--  NYE KOLONNER PÅ SPILLERE
-- ---------------------------------------------------------------------
alter table public.spillere add column if not exists poeng int not null default 0;
alter table public.spillere add column if not exists ran_klar timestamptz not null default now();
alter table public.spillere add column if not exists kasino_klar timestamptz not null default now();
alter table public.spillere add column if not exists forum_klar timestamptz not null default now();
alter table public.spillere add column if not exists gjeng_id bigint;
alter table public.spillere add column if not exists vervet_av uuid;
alter table public.spillere add column if not exists verv_betalt boolean not null default false;
alter table public.spillere add constraint spillere_poeng_ok check (poeng >= 0);

-- ---------------------------------------------------------------------
--  STATISTIKK (brukes av oppdrag og prestasjoner)
-- ---------------------------------------------------------------------
create table public.stat (
  spiller uuid not null references public.spillere(id) on delete cascade,
  nokkel text not null, antall bigint not null default 0,
  primary key (spiller, nokkel));
create table public.dagstat (
  spiller uuid not null references public.spillere(id) on delete cascade,
  dato date not null, nokkel text not null, antall int not null default 0,
  primary key (spiller, dato, nokkel));

create or replace function public._idag() returns date language sql stable as
$$ select (now() at time zone 'Europe/Oslo')::date $$;

create or replace function public._tell(p uuid, k text, n int default 1) returns void
language sql set search_path = public as $$
  insert into stat (spiller, nokkel, antall) values (p, k, n)
    on conflict (spiller, nokkel) do update set antall = stat.antall + excluded.antall;
  insert into dagstat (spiller, dato, nokkel, antall) values (p, _idag(), k, n)
    on conflict (spiller, dato, nokkel) do update set antall = dagstat.antall + excluded.antall;
$$;

-- ---------------------------------------------------------------------
--  AVIS OG NYHETER
-- ---------------------------------------------------------------------
create table public.avis (id bigint generated always as identity primary key, tekst text not null, tid timestamptz not null default now());
create table public.nyheter (id bigint generated always as identity primary key, tittel text not null, tekst text not null, tid timestamptz not null default now());

create or replace function public._avis(t text) returns void language sql set search_path = public as $$
  insert into avis (tekst) values (t);
  delete from avis where id < (select coalesce(min(id), 0) from (select id from avis order by id desc limit 300) x);
$$;

insert into public.nyheter (tittel, tekst) values
 ('Velkommen til nye Undergrunnen',
  'Byen har fått nytt utseende og mange nye muligheter: oppdrag hver dag, prestasjoner med poeng, gjenger, forum, børs, bruktbilmarked, forretninger, ran av andre spillere og et helt nytt kasino med blackjack, lotto, nummerspill, terningdueller, streetracing, battle royale og dødsterninger. Poker og blackjack mot andre spillere kommer senere.'),
 ('Slik tjener du poeng',
  'Poeng får du ved å fullføre daglige oppdrag, låse opp prestasjoner og verve venner. Poeng kan brukes i poenghandelen på kuler, penger, fri fra fengsel og mer.');

create or replace function public.nyheter_liste() returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.tid desc), '[]') from (select tittel, tekst, tid from nyheter order by tid desc limit 20) x;
$$;
create or replace function public.avis_liste() returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.id desc), '[]') from (select id, tekst, tid from avis order by id desc limit 60) x;
$$;

-- ---------------------------------------------------------------------
--  OPPDRAG (daglige) OG PRESTASJONER
-- ---------------------------------------------------------------------
create table public.oppdrag_typer (id text primary key, tittel text not null, nokkel text not null, mal int not null, penger int not null, poeng int not null, sortering int not null);
insert into public.oppdrag_typer values
 ('krim10',   'Utfør 10 kriminelle handlinger', 'krim',       10, 15000, 2, 1),
 ('bil3',     'Prøv å stjele 3 biler',          'bil',         3, 10000, 1, 2),
 ('ran2',     'Ran 2 spillere',                 'ran',         2,  8000, 1, 3),
 ('utbrudd2', 'Bryt ut 2 spillere av fengsel',  'utbrudd_ok',  2, 12000, 2, 4),
 ('reise1',   'Reis til en annen by',           'reise',       1,  3000, 1, 5),
 ('kasino5',  'Spill 5 ganger i kasinoet',      'kasino',      5,  5000, 1, 6);
create table public.oppdrag_hentet (spiller uuid not null references public.spillere(id) on delete cascade, dato date not null, oppdrag text not null, primary key (spiller, dato, oppdrag));

create table public.prestasjon_typer (id text primary key, tittel text not null, beskrivelse text not null, nokkel text not null, mal int not null, penger int not null, poeng int not null, sortering int not null);
insert into public.prestasjon_typer values
 ('krim10',    'Småkjeltring',      'Lykkes med 10 kriminelle handlinger',    'krim_ok',     10,   5000,  2, 1),
 ('krim100',   'Yrkeskriminell',    'Lykkes med 100 kriminelle handlinger',   'krim_ok',    100,  50000,  5, 2),
 ('krim1000',  'Legende på gata',   'Lykkes med 1 000 kriminelle handlinger', 'krim_ok',   1000, 500000, 25, 3),
 ('bil10',     'Biltyv',            'Stjel 10 biler',                         'bil_ok',      10,  10000,  2, 4),
 ('bil100',    'Bilbaron',          'Stjel 100 biler',                        'bil_ok',     100, 100000, 10, 5),
 ('ran10',     'Lommerusker',       'Ran 10 spillere',                        'ran_ok',      10,  20000,  3, 6),
 ('utbrudd5',  'Fluktekspert',      'Bryt ut 5 spillere',                     'utbrudd_ok',   5,  10000,  2, 7),
 ('utbrudd50', 'Fengselsmareritt',  'Bryt ut 50 spillere',                    'utbrudd_ok',  50, 100000, 10, 8),
 ('drap1',     'Første blod',       'Drep en spiller',                        'drap',         1,  25000,  5, 9),
 ('drap10',    'Leiemorder',        'Drep 10 spillere',                       'drap',        10, 250000, 20, 10),
 ('reise10',   'Globetrotter',      'Reis 10 ganger',                         'reise',       10,  10000,  2, 11),
 ('kasino50',  'Stamgjest',         'Spill 50 ganger i kasinoet',             'kasino',      50,  25000,  3, 12),
 ('rank4',     'Gangster',          'Nå ranken Gangster',                     'rank',         4,  50000,  5, 13),
 ('rank7',     'Boss',              'Nå ranken Boss',                         'rank',         7, 250000, 15, 14),
 ('rank9',     'Don',               'Nå ranken Don',                          'rank',         9, 1000000, 50, 15);
create table public.prestasjon_hentet (spiller uuid not null references public.spillere(id) on delete cascade, prestasjon text not null, tid timestamptz not null default now(), primary key (spiller, prestasjon));

create or replace function public._stat(p uuid, k text) returns bigint language sql stable set search_path = public as $$
  select case when k = 'rank' then (select rank_indeks(exp)::bigint from spillere where id = p)
              else coalesce((select antall from stat where spiller = p and nokkel = k), 0) end;
$$;

create or replace function public.mine_oppdrag() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'tittel', o.tittel, 'mal', o.mal, 'penger', o.penger, 'poeng', o.poeng,
      'fremdrift', least(o.mal, coalesce(d.antall, 0)),
      'hentet', exists (select 1 from oppdrag_hentet h where h.spiller = s.id and h.dato = _idag() and h.oppdrag = o.id))
      order by o.sortering)
    from oppdrag_typer o left join dagstat d on d.spiller = s.id and d.dato = _idag() and d.nokkel = o.nokkel), '[]');
end $$;

create or replace function public.hent_oppdrag(p_id text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; o oppdrag_typer; n int;
begin
  s := _meg();
  select * into o from oppdrag_typer where id = p_id;
  if not found then raise exception 'Ukjent oppdrag'; end if;
  select coalesce(antall, 0) into n from dagstat where spiller = s.id and dato = _idag() and nokkel = o.nokkel;
  if coalesce(n, 0) < o.mal then raise exception 'Oppdraget er ikke fullført ennå'; end if;
  insert into oppdrag_hentet values (s.id, _idag(), o.id) on conflict do nothing;
  if not found then raise exception 'Du har allerede hentet denne belønningen i dag'; end if;
  update spillere set penger = penger + o.penger, poeng = poeng + o.poeng where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Oppdrag fullført! Du fikk %s og %s poeng.', kr(o.penger), o.poeng));
end $$;

create or replace function public.mine_prestasjoner() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'tittel', p.tittel, 'beskrivelse', p.beskrivelse, 'mal', p.mal, 'penger', p.penger, 'poeng', p.poeng,
      'fremdrift', least(p.mal::bigint, _stat(s.id, p.nokkel)),
      'hentet', exists (select 1 from prestasjon_hentet h where h.spiller = s.id and h.prestasjon = p.id))
      order by p.sortering) from prestasjon_typer p), '[]');
end $$;

create or replace function public.hent_prestasjon(p_id text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; p prestasjon_typer;
begin
  s := _meg();
  select * into p from prestasjon_typer where id = p_id;
  if not found then raise exception 'Ukjent prestasjon'; end if;
  if _stat(s.id, p.nokkel) < p.mal then raise exception 'Prestasjonen er ikke låst opp ennå'; end if;
  insert into prestasjon_hentet (spiller, prestasjon) values (s.id, p.id) on conflict do nothing;
  if not found then raise exception 'Du har allerede hentet denne'; end if;
  update spillere set penger = penger + p.penger, poeng = poeng + p.poeng where id = s.id;
  perform _avis(format('%s låste opp prestasjonen «%s».', s.navn, p.tittel));
  return jsonb_build_object('ok', true, 'melding', format('Prestasjon «%s»! Du fikk %s og %s poeng.', p.tittel, kr(p.penger), p.poeng));
end $$;

create or replace function public._varsler(p uuid) returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'oppdrag', (select count(*) from oppdrag_typer o
                join dagstat d on d.spiller = p and d.dato = _idag() and d.nokkel = o.nokkel and d.antall >= o.mal
                where not exists (select 1 from oppdrag_hentet h where h.spiller = p and h.dato = _idag() and h.oppdrag = o.id)),
    'prestasjoner', (select count(*) from prestasjon_typer t
                where _stat(p, t.nokkel) >= t.mal and not exists (select 1 from prestasjon_hentet h where h.spiller = p and h.prestasjon = t.id)));
$$;

-- ---------------------------------------------------------------------
--  GJENGER
-- ---------------------------------------------------------------------
create table public.gjenger (
  id bigint generated always as identity primary key,
  navn text not null, tag text not null,
  leder uuid references public.spillere(id) on delete set null,
  bank bigint not null default 0 check (bank >= 0),
  beskrivelse text not null default '',
  opprettet timestamptz not null default now());
create unique index gjenger_navn_unik on public.gjenger (lower(navn));
create unique index gjenger_tag_unik on public.gjenger (lower(tag));
alter table public.spillere add constraint spillere_gjeng_fk foreign key (gjeng_id) references public.gjenger(id) on delete set null;

create or replace function public._gjeng_rydd(g bigint) returns void language plpgsql set search_path = public as $$
declare ny uuid;
begin
  if not exists (select 1 from spillere where gjeng_id = g) then delete from gjenger where id = g; return; end if;
  if (select leder from gjenger where id = g) is null then
    select id into ny from spillere where gjeng_id = g order by exp desc limit 1;
    update gjenger set leder = ny where id = g;
  end if;
end $$;

create or replace function public.gjeng_liste() returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.erfaring desc), '[]') from (
    select g.id, g.navn, g.tag, g.beskrivelse, (select navn from spillere where id = g.leder) as leder,
           count(s.id) as medlemmer, coalesce(sum(s.exp), 0) as erfaring, coalesce(sum(s.drap), 0) as drap
    from gjenger g left join spillere s on s.gjeng_id = g.id group by g.id order by coalesce(sum(s.exp), 0) desc limit 50) x;
$$;

create or replace function public.min_gjeng() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g gjenger;
begin
  s := _meg();
  if s.gjeng_id is null then return jsonb_build_object('gjeng', null); end if;
  perform _gjeng_rydd(s.gjeng_id);
  select * into g from gjenger where id = s.gjeng_id;
  if not found then return jsonb_build_object('gjeng', null); end if;
  return jsonb_build_object('gjeng', jsonb_build_object('id', g.id, 'navn', g.navn, 'tag', g.tag, 'bank', g.bank, 'beskrivelse', g.beskrivelse,
      'er_leder', g.leder = s.id, 'leder', (select navn from spillere where id = g.leder)),
    'medlemmer', (select jsonb_agg(jsonb_build_object('navn', navn, 'rank', rank_navn(exp), 'drap', drap,
                    'online', sist_aktiv > now() - interval '5 minutes', 'leder', id = g.leder) order by exp desc)
                  from spillere where gjeng_id = g.id));
end $$;

create or replace function public.opprett_gjeng(p_navn text, p_tag text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; nid bigint;
begin
  s := _meg();
  if s.gjeng_id is not null then raise exception 'Du er allerede med i en gjeng'; end if;
  if rank_indeks(s.exp) < 2 then raise exception 'Du må være minst Smågangster for å starte en gjeng'; end if;
  p_navn := trim(p_navn); p_tag := upper(trim(p_tag));
  if p_navn !~ '^[A-Za-z0-9 _æøåÆØÅ]{3,24}$' then raise exception 'Gjengnavnet må være 3–24 tegn'; end if;
  if p_tag !~ '^[A-Z0-9ÆØÅ]{2,4}$' then raise exception 'Taggen må være 2–4 bokstaver eller tall'; end if;
  if s.penger < 250000 then raise exception 'Det koster 250 000 kr i kontanter å starte en gjeng'; end if;
  if exists (select 1 from gjenger where lower(navn) = lower(p_navn) or lower(tag) = lower(p_tag)) then raise exception 'Navnet eller taggen er opptatt'; end if;
  insert into gjenger (navn, tag, leder) values (p_navn, p_tag, s.id) returning id into nid;
  update spillere set penger = penger - 250000, gjeng_id = nid where id = s.id;
  perform _avis(format('%s startet gjengen %s [%s].', s.navn, p_navn, p_tag));
  return jsonb_build_object('ok', true, 'melding', format('Gjengen %s [%s] er startet!', p_navn, p_tag));
end $$;

create or replace function public.bli_med_gjeng(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g gjenger;
begin
  s := _meg();
  if s.gjeng_id is not null then raise exception 'Du er allerede med i en gjeng'; end if;
  select * into g from gjenger where id = p_id for update;
  if not found then raise exception 'Fant ikke gjengen'; end if;
  if (select count(*) from spillere where gjeng_id = g.id) >= 10 then raise exception 'Gjengen er full (maks 10 medlemmer)'; end if;
  update spillere set gjeng_id = g.id where id = s.id;
  if g.leder is not null then perform _systemmelding(g.leder, 'Nytt gjengmedlem', format('%s ble med i %s.', s.navn, g.navn)); end if;
  return jsonb_build_object('ok', true, 'melding', format('Du er nå med i %s [%s].', g.navn, g.tag));
end $$;

create or replace function public.forlat_gjeng() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g bigint;
begin
  s := _meg(); g := s.gjeng_id;
  if g is null then raise exception 'Du er ikke med i en gjeng'; end if;
  update spillere set gjeng_id = null where id = s.id;
  update gjenger set leder = null where id = g and leder = s.id;
  perform _gjeng_rydd(g);
  return jsonb_build_object('ok', true, 'melding', 'Du forlot gjengen.');
end $$;

create or replace function public.kast_ut_gjeng(p_navn text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if s.gjeng_id is null or (select leder from gjenger where id = s.gjeng_id) is distinct from s.id then raise exception 'Bare lederen kan kaste ut medlemmer'; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke kaste ut deg selv'; end if;
  if t.gjeng_id is distinct from s.gjeng_id then raise exception '% er ikke med i gjengen', t.navn; end if;
  update spillere set gjeng_id = null where id = t.id;
  perform _systemmelding(t.id, 'Kastet ut av gjengen', format('%s kastet deg ut av gjengen.', s.navn));
  return jsonb_build_object('ok', true, 'melding', format('%s er kastet ut.', t.navn));
end $$;

create or replace function public.gjeng_innskudd(p_belop bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  if s.gjeng_id is null then raise exception 'Du er ikke med i en gjeng'; end if;
  if p_belop is null or p_belop < 1 then raise exception 'Ugyldig beløp'; end if;
  if p_belop > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  update spillere set penger = penger - p_belop where id = s.id;
  update gjenger set bank = bank + p_belop where id = s.gjeng_id;
  return jsonb_build_object('ok', true, 'melding', format('Du satte inn %s i gjengbanken.', kr(p_belop)));
end $$;

create or replace function public.gjeng_utbetal(p_navn text, p_belop bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere; g gjenger;
begin
  s := _meg();
  select * into g from gjenger where id = s.gjeng_id for update;
  if not found or g.leder is distinct from s.id then raise exception 'Bare lederen kan betale ut fra gjengbanken'; end if;
  if p_belop is null or p_belop < 1 then raise exception 'Ugyldig beløp'; end if;
  if p_belop > g.bank then raise exception 'Gjengbanken har ikke så mye'; end if;
  t := _finn(p_navn);
  if t.gjeng_id is distinct from g.id then raise exception '% er ikke med i gjengen', t.navn; end if;
  update gjenger set bank = bank - p_belop where id = g.id;
  update spillere set bank = bank + p_belop where id = t.id;
  if t.id <> s.id then perform _systemmelding(t.id, 'Utbetaling fra gjengen', format('Du fikk %s fra gjengbanken.', kr(p_belop))); end if;
  return jsonb_build_object('ok', true, 'melding', format('%s ble betalt ut til %s.', kr(p_belop), t.navn));
end $$;

-- ---------------------------------------------------------------------
--  FORUM
-- ---------------------------------------------------------------------
create table public.forum_traader (
  id bigint generated always as identity primary key,
  kategori text not null check (kategori in ('Generelt','Salg','Gjeng','Hjelp')),
  tittel text not null, forfatter text not null,
  opprettet timestamptz not null default now(), sist_aktiv timestamptz not null default now(), antall int not null default 1);
create table public.forum_innlegg (
  id bigint generated always as identity primary key,
  traad_id bigint not null references public.forum_traader(id) on delete cascade,
  forfatter text not null, tekst text not null, tid timestamptz not null default now());
create index on public.forum_innlegg (traad_id, id);

create or replace function public.forum_liste(p_kategori text) returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.sist_aktiv desc), '[]') from (
    select id, kategori, tittel, forfatter, antall, sist_aktiv from forum_traader
    where p_kategori is null or p_kategori = '' or kategori = p_kategori order by sist_aktiv desc limit 50) x;
$$;
create or replace function public.forum_traad(p_id bigint) returns jsonb language plpgsql stable set search_path = public as $$
declare t forum_traader;
begin
  select * into t from forum_traader where id = p_id;
  if not found then raise exception 'Fant ikke tråden'; end if;
  return jsonb_build_object('traad', to_jsonb(t), 'innlegg',
    (select coalesce(jsonb_agg(jsonb_build_object('forfatter', forfatter, 'tekst', tekst, 'tid', tid) order by id), '[]')
     from (select * from forum_innlegg where traad_id = t.id order by id limit 200) i));
end $$;
create or replace function public.ny_traad(p_kategori text, p_tittel text, p_tekst text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; nid bigint;
begin
  s := _meg(); perform _vent(s.forum_klar, 'skrive i forumet igjen');
  p_tittel := trim(coalesce(p_tittel, '')); p_tekst := trim(coalesce(p_tekst, ''));
  if p_kategori not in ('Generelt','Salg','Gjeng','Hjelp') then raise exception 'Velg en kategori'; end if;
  if length(p_tittel) < 3 or length(p_tittel) > 80 then raise exception 'Tittelen må være 3–80 tegn'; end if;
  if length(p_tekst) < 1 or length(p_tekst) > 3000 then raise exception 'Innlegget må være 1–3000 tegn'; end if;
  insert into forum_traader (kategori, tittel, forfatter) values (p_kategori, p_tittel, s.navn) returning id into nid;
  insert into forum_innlegg (traad_id, forfatter, tekst) values (nid, s.navn, p_tekst);
  update spillere set forum_klar = now() + interval '60 seconds' where id = s.id;
  return jsonb_build_object('ok', true, 'melding', 'Tråden er opprettet.', 'id', nid);
end $$;
create or replace function public.svar_traad(p_id bigint, p_tekst text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg(); perform _vent(s.forum_klar, 'skrive i forumet igjen');
  p_tekst := trim(coalesce(p_tekst, ''));
  if length(p_tekst) < 1 or length(p_tekst) > 3000 then raise exception 'Svaret må være 1–3000 tegn'; end if;
  if not exists (select 1 from forum_traader where id = p_id) then raise exception 'Fant ikke tråden'; end if;
  insert into forum_innlegg (traad_id, forfatter, tekst) values (p_id, s.navn, p_tekst);
  update forum_traader set sist_aktiv = now(), antall = antall + 1 where id = p_id;
  update spillere set forum_klar = now() + interval '15 seconds' where id = s.id;
  return jsonb_build_object('ok', true, 'melding', 'Svaret er publisert.');
end $$;

-- ---------------------------------------------------------------------
--  SPILLERE: SØK, PÅLOGGET, PROFIL, TOPPLISTE, VERVING
-- ---------------------------------------------------------------------
create or replace function public._tag(g bigint) returns text language sql stable set search_path = public as
$$ select tag from gjenger where id = g $$;

create or replace function public.sok_spillere(p_sok text) returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select navn, rank_navn(exp) as rank, _tag(gjeng_id) as tag, sist_aktiv > now() - interval '5 minutes' as online
    from spillere where length(trim(coalesce(p_sok, ''))) >= 1 and navn ilike '%' || replace(replace(trim(p_sok), '%', ''), '_', '\_') || '%'
    order by exp desc limit 25) x;
$$;
create or replace function public.palogget_liste() returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select navn, rank_navn(exp) as rank, _tag(gjeng_id) as tag, sted
    from spillere where sist_aktiv > now() - interval '5 minutes' order by exp desc limit 200) x;
$$;
create or replace function public.toppliste() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select navn, rank_navn(exp) as rank, drap, _tag(gjeng_id) as tag, sist_aktiv > now() - interval '5 minutes' as online
    from spillere order by exp desc, opprettet limit 100) x;
$$;
create or replace function public.profil(p_navn text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t spillere;
begin
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  return jsonb_build_object('navn', t.navn, 'rank', rank_navn(t.exp), 'drap', t.drap,
    'opprettet', t.opprettet, 'online', t.sist_aktiv > now() - interval '5 minutes',
    'gjeng', (select navn || ' [' || tag || ']' from gjenger where id = t.gjeng_id),
    'prestasjoner', (select count(*) from prestasjon_hentet where spiller = t.id),
    'fengsel', coalesce(t.fengsel_til > now(), false), 'beskyttet', coalesce(t.beskyttet_til > now(), false));
end $$;

create or replace function public.sett_verver(p_navn text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if s.vervet_av is not null then return jsonb_build_object('ok', false); end if;
  if s.opprettet < now() - interval '1 hour' then return jsonb_build_object('ok', false); end if;
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found or t.id = s.id then return jsonb_build_object('ok', false); end if;
  update spillere set vervet_av = t.id where id = s.id;
  perform _systemmelding(t.id, 'Ny vervet spiller', format('%s registrerte seg via lenken din. Du får 10 poeng og 25 000 kr når hen blir Smågangster.', s.navn));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public._verv_sjekk(p uuid) returns void language plpgsql set search_path = public as $$
declare s spillere;
begin
  select * into s from spillere where id = p for update;
  if s.vervet_av is null or s.verv_betalt or rank_indeks(s.exp) < 2 then return; end if;
  update spillere set verv_betalt = true where id = s.id;
  update spillere set poeng = poeng + 10, bank = bank + 25000 where id = s.vervet_av;
  perform _systemmelding(s.vervet_av, 'Vervebonus', format('%s ble Smågangster. Du fikk 10 poeng og 25 000 kr i banken.', s.navn));
end $$;
create or replace function public.verv_info() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return jsonb_build_object('kode', s.navn,
    'vervede', (select coalesce(jsonb_agg(jsonb_build_object('navn', navn, 'rank', rank_navn(exp), 'betalt', verv_betalt) order by opprettet desc), '[]')
                from spillere where vervet_av = s.id));
end $$;

-- ---------------------------------------------------------------------
--  POENGHANDEL OG OVERFØRINGER
-- ---------------------------------------------------------------------
create or replace function public.poeng_kjop(p_vare text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; pris int; m text;
begin
  s := _meg();
  pris := case p_vare when 'kuler' then 5 when 'penger' then 10 when 'fengsel' then 3 when 'ventetid' then 2 when 'helse' then 4 else null end;
  if pris is null then raise exception 'Ukjent vare'; end if;
  if s.poeng < pris then raise exception 'Du trenger % poeng (du har %)', pris, s.poeng; end if;
  if p_vare = 'fengsel' and not coalesce(s.fengsel_til > now(), false) then raise exception 'Du sitter ikke i fengsel'; end if;
  if p_vare = 'helse' and s.helse >= 100 then raise exception 'Du er allerede frisk'; end if;
  update spillere set poeng = poeng - pris where id = s.id;
  case p_vare
    when 'kuler' then update spillere set kuler = kuler + 500 where id = s.id; m := 'Du fikk 500 kuler.';
    when 'penger' then update spillere set penger = penger + 100000 where id = s.id; m := 'Du fikk 100 000 kr.';
    when 'fengsel' then update spillere set fengsel_til = null where id = s.id; m := 'Du er fri fra fengselet.';
    when 'ventetid' then update spillere set krim_klar = now(), bil_klar = now(), ran_klar = now() where id = s.id; m := 'Ventetiden på kriminalitet, biltyveri og ran er nullstilt.';
    when 'helse' then update spillere set helse = 100 where id = s.id; m := 'Du er helt frisk igjen.';
  end case;
  return jsonb_build_object('ok', true, 'melding', m || format(' (−%s poeng)', pris));
end $$;

create or replace function public.overfor_poeng(p_navn text, p_antall int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if p_antall is null or p_antall < 1 then raise exception 'Ugyldig antall'; end if;
  if p_antall > s.poeng then raise exception 'Du har bare % poeng', s.poeng; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke overføre til deg selv'; end if;
  update spillere set poeng = poeng - p_antall where id = s.id;
  update spillere set poeng = poeng + p_antall where id = t.id;
  perform _systemmelding(t.id, 'Poeng mottatt', format('%s sendte deg %s poeng.', s.navn, p_antall));
  return jsonb_build_object('ok', true, 'melding', format('Du sendte %s poeng til %s.', p_antall, t.navn));
end $$;

create or replace function public.overfor_kuler(p_navn text, p_antall int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere;
begin
  s := _meg();
  if p_antall is null or p_antall < 1 then raise exception 'Ugyldig antall'; end if;
  if p_antall > s.kuler then raise exception 'Du har bare % kuler', s.kuler; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke overføre til deg selv'; end if;
  update spillere set kuler = kuler - p_antall where id = s.id;
  update spillere set kuler = kuler + p_antall where id = t.id;
  perform _systemmelding(t.id, 'Kuler mottatt', format('%s sendte deg %s kuler.', s.navn, p_antall));
  return jsonb_build_object('ok', true, 'melding', format('Du sendte %s kuler til %s.', p_antall, t.navn));
end $$;

-- ---------------------------------------------------------------------
--  BØRSEN
-- ---------------------------------------------------------------------
create table public.aksjer (id int primary key, navn text not null, ticker text not null, basis numeric not null);
insert into public.aksjer values
 (1, 'Fjordlinje Shipping', 'FJL', 120), (2, 'Nordlys Energi', 'NLE', 85), (3, 'Bryggen Bank', 'BRB', 240),
 (4, 'Polarbit Tech', 'PBT', 60), (5, 'Kystfisk Eksport', 'KFE', 35), (6, 'Tunnelbygg', 'TNB', 150);
create table public.beholdning (
  spiller uuid not null references public.spillere(id) on delete cascade,
  aksje_id int not null references public.aksjer(id), antall bigint not null default 0 check (antall >= 0),
  kostpris numeric not null default 0, primary key (spiller, aksje_id));

create or replace function public.aksje_pris(p_id int, p_t timestamptz default now()) returns numeric language plpgsql stable set search_path = public as $$
declare b numeric; e double precision; h bigint; f double precision; r0 double precision; r1 double precision; trend double precision;
begin
  select basis into b from aksjer where id = p_id;
  if b is null then return null; end if;
  e := extract(epoch from p_t); h := floor(e / 1800); f := e / 1800 - h;
  r0 := (abs(hashtext(p_id || ':' || h)) % 10000) / 10000.0;
  r1 := (abs(hashtext(p_id || ':' || (h + 1))) % 10000) / 10000.0;
  trend := 1 + 0.3 * sin(e / 86400 * 2 * pi() / 3 + p_id * 1.7);
  return round((b * trend * (0.75 + 0.5 * (r0 + (r1 - r0) * f)))::numeric, 2);
end $$;

create or replace function public.borsen() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'navn', a.navn, 'ticker', a.ticker,
      'pris', aksje_pris(a.id), 'endring', round((aksje_pris(a.id) / aksje_pris(a.id, now() - interval '1 day') - 1) * 100, 1),
      'historikk', (select jsonb_agg(aksje_pris(a.id, now() - make_interval(hours => g)) order by g desc) from generate_series(0, 24, 2) g),
      'antall', coalesce(b.antall, 0), 'kostpris', coalesce(b.kostpris, 0)) order by a.id)
    from aksjer a left join beholdning b on b.aksje_id = a.id and b.spiller = s.id), '[]');
end $$;

create or replace function public.kjop_aksje(p_id int, p_antall bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; pris numeric; sum_ bigint; a aksjer;
begin
  s := _meg();
  select * into a from aksjer where id = p_id;
  if not found then raise exception 'Ukjent aksje'; end if;
  if p_antall is null or p_antall < 1 or p_antall > 1000000 then raise exception 'Ugyldig antall'; end if;
  pris := aksje_pris(p_id); sum_ := ceil(pris * p_antall * 1.01);
  if sum_ > s.penger then raise exception 'Det koster % inkludert 1 %% kurtasje. Du har ikke nok kontanter.', kr(sum_); end if;
  update spillere set penger = penger - sum_ where id = s.id;
  insert into beholdning (spiller, aksje_id, antall, kostpris) values (s.id, p_id, p_antall, sum_)
    on conflict (spiller, aksje_id) do update set antall = beholdning.antall + excluded.antall, kostpris = beholdning.kostpris + excluded.kostpris;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s %s-aksjer for %s.', p_antall, a.ticker, kr(sum_)));
end $$;

create or replace function public.selg_aksje(p_id int, p_antall bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b beholdning; pris numeric; sum_ bigint; a aksjer;
begin
  s := _meg();
  select * into a from aksjer where id = p_id;
  if not found then raise exception 'Ukjent aksje'; end if;
  select * into b from beholdning where spiller = s.id and aksje_id = p_id for update;
  if not found or b.antall < 1 then raise exception 'Du eier ingen % -aksjer', a.ticker; end if;
  if p_antall is null or p_antall < 1 then raise exception 'Ugyldig antall'; end if;
  if p_antall > b.antall then raise exception 'Du eier bare % aksjer', b.antall; end if;
  pris := aksje_pris(p_id); sum_ := floor(pris * p_antall * 0.99);
  update beholdning set kostpris = kostpris * (antall - p_antall) / antall, antall = antall - p_antall where spiller = s.id and aksje_id = p_id;
  update spillere set penger = penger + sum_ where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du solgte %s %s-aksjer for %s.', p_antall, a.ticker, kr(sum_)));
end $$;

-- ---------------------------------------------------------------------
--  BRUKTBILMARKED
-- ---------------------------------------------------------------------
create table public.bruktbiler (
  id bigint generated always as identity primary key,
  selger uuid not null references public.spillere(id) on delete cascade, selger_navn text not null,
  bil text not null, verdi int not null, pris bigint not null, tid timestamptz not null default now());

create or replace function public.bruktbil_liste() returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'selger', selger_navn, 'bil', bil, 'verdi', verdi, 'pris', pris, 'min', selger = s.id, 'tid', tid) order by tid desc)
    from bruktbiler), '[]');
end $$;
create or replace function public.legg_ut_bil(p_garasje_id bigint, p_pris bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g garasje;
begin
  s := _meg();
  select * into g from garasje where id = p_garasje_id and eier = s.id;
  if not found then raise exception 'Fant ikke bilen i garasjen din'; end if;
  if p_pris is null or p_pris < 100 or p_pris > g.verdi * 10 then raise exception 'Prisen må være mellom 100 kr og % (10 ganger verdien)', kr(g.verdi * 10); end if;
  if (select count(*) from bruktbiler where selger = s.id) >= 10 then raise exception 'Du kan ha maks 10 biler til salgs'; end if;
  delete from garasje where id = g.id;
  insert into bruktbiler (selger, selger_navn, bil, verdi, pris) values (s.id, s.navn, g.bil, g.verdi, p_pris);
  return jsonb_build_object('ok', true, 'melding', format('%s er lagt ut for %s.', g.bil, kr(p_pris)));
end $$;
create or replace function public.trekk_bruktbil(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b bruktbiler;
begin
  s := _meg();
  delete from bruktbiler where id = p_id and selger = s.id returning * into b;
  if not found then raise exception 'Fant ikke annonsen'; end if;
  insert into garasje (eier, bil, verdi, sted) values (s.id, b.bil, b.verdi, s.sted);
  return jsonb_build_object('ok', true, 'melding', format('%s er tilbake i garasjen.', b.bil));
end $$;
create or replace function public.kjop_bruktbil(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b bruktbiler;
begin
  s := _meg();
  select * into b from bruktbiler where id = p_id for update;
  if not found then raise exception 'Bilen er allerede solgt'; end if;
  if b.selger = s.id then raise exception 'Du kan ikke kjøpe din egen bil'; end if;
  if b.pris > s.penger then raise exception 'Bilen koster %. Du har ikke nok kontanter.', kr(b.pris); end if;
  if (select count(*) from garasje where eier = s.id) >= 30 then raise exception 'Garasjen din er full'; end if;
  delete from bruktbiler where id = b.id;
  update spillere set penger = penger - b.pris where id = s.id;
  update spillere set bank = bank + b.pris where id = b.selger;
  insert into garasje (eier, bil, verdi, sted) values (s.id, b.bil, b.verdi, s.sted);
  perform _systemmelding(b.selger, 'Bil solgt', format('%s kjøpte %s. %s er satt inn i banken din.', s.navn, b.bil, kr(b.pris)));
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s for %s.', b.bil, kr(b.pris)));
end $$;

-- ---------------------------------------------------------------------
--  FORRETNINGER: LIVVAKTUTLEIE OG HASJPLANTASJE
-- ---------------------------------------------------------------------
create table public.forretning (
  spiller uuid primary key references public.spillere(id) on delete cascade,
  livvakt_nivaa int not null default 0, livvakt_hentet timestamptz not null default now(),
  hasj_planter int not null default 0, hasj_ferdig timestamptz);

create or replace function public._livvakt(n int) returns jsonb language sql immutable as $$
  select (array[
    null,
    '{"navn":"2 livvakter","pris":100000,"timelonn":2000}',
    '{"navn":"Vaktselskap","pris":300000,"timelonn":6000}',
    '{"navn":"Sikkerhetsfirma","pris":800000,"timelonn":15000}',
    '{"navn":"Privat hær","pris":2000000,"timelonn":35000}',
    '{"navn":"Internasjonalt nettverk","pris":5000000,"timelonn":80000}'
  ]::jsonb[])[n + 1];
$$;

create or replace function public.forretninger() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; f forretning; timer numeric; opptjent bigint;
begin
  s := _meg();
  insert into forretning (spiller) values (s.id) on conflict do nothing;
  select * into f from forretning where spiller = s.id;
  timer := least(24, extract(epoch from (now() - f.livvakt_hentet)) / 3600);
  opptjent := case when f.livvakt_nivaa > 0 then floor(timer * (_livvakt(f.livvakt_nivaa)->>'timelonn')::int) else 0 end;
  return jsonb_build_object(
    'livvakt', jsonb_build_object('nivaa', f.livvakt_nivaa, 'info', _livvakt(f.livvakt_nivaa), 'neste', _livvakt(f.livvakt_nivaa + 1),
                                  'opptjent', opptjent, 'timer', round(timer, 1)),
    'hasj', jsonb_build_object('planter', f.hasj_planter, 'ferdig', f.hasj_ferdig, 'pris_per_plante', 2000, 'maks', 100));
end $$;

create or replace function public.livvakt_oppgrader() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; f forretning; neste jsonb; pris bigint;
begin
  s := _meg();
  insert into forretning (spiller) values (s.id) on conflict do nothing;
  select * into f from forretning where spiller = s.id for update;
  neste := _livvakt(f.livvakt_nivaa + 1);
  if neste is null then raise exception 'Du har allerede høyeste nivå'; end if;
  pris := (neste->>'pris')::bigint;
  if s.penger < pris then raise exception 'Det koster % i kontanter', kr(pris); end if;
  -- Opptjente penger på nåværende nivå betales ut før oppgraderingen
  if f.livvakt_nivaa > 0 then
    update spillere set penger = penger + floor(least(24, extract(epoch from (now() - f.livvakt_hentet)) / 3600) * (_livvakt(f.livvakt_nivaa)->>'timelonn')::int)
      where id = s.id;
  end if;
  update spillere set penger = penger - pris where id = s.id;
  update forretning set livvakt_nivaa = livvakt_nivaa + 1, livvakt_hentet = now() where spiller = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s. Den tjener %s i timen.', neste->>'navn', kr((neste->>'timelonn')::bigint)));
end $$;

create or replace function public.livvakt_hent() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; f forretning; timer numeric; sum_ bigint;
begin
  s := _meg();
  select * into f from forretning where spiller = s.id for update;
  if not found or f.livvakt_nivaa = 0 then raise exception 'Du eier ingen livvaktutleie'; end if;
  timer := least(24, extract(epoch from (now() - f.livvakt_hentet)) / 3600);
  sum_ := floor(timer * (_livvakt(f.livvakt_nivaa)->>'timelonn')::int);
  if sum_ < 1 then raise exception 'Det er ingenting å hente ennå'; end if;
  update forretning set livvakt_hentet = now() where spiller = s.id;
  update spillere set penger = penger + sum_ where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du hentet %s fra livvaktutleien.', kr(sum_)));
end $$;

create or replace function public.hasj_plant(p_antall int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; f forretning; pris bigint;
begin
  s := _meg(); perform _sjekk_fri(s);
  insert into forretning (spiller) values (s.id) on conflict do nothing;
  select * into f from forretning where spiller = s.id for update;
  if f.hasj_planter > 0 then raise exception 'Du har allerede planter som gror'; end if;
  if p_antall is null or p_antall < 1 or p_antall > 100 then raise exception 'Du kan plante 1–100 planter'; end if;
  pris := p_antall * 2000;
  if s.penger < pris then raise exception 'Det koster % i kontanter', kr(pris); end if;
  update spillere set penger = penger - pris where id = s.id;
  update forretning set hasj_planter = p_antall, hasj_ferdig = now() + interval '90 minutes' where spiller = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du plantet %s planter for %s. Klare til høsting om 90 minutter.', p_antall, kr(pris)));
end $$;

create or replace function public.hasj_host() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; f forretning; sum_ bigint := 0; i int;
begin
  s := _meg(); perform _sjekk_fri(s);
  select * into f from forretning where spiller = s.id for update;
  if not found or f.hasj_planter = 0 then raise exception 'Du har ingen planter'; end if;
  if f.hasj_ferdig > now() then raise exception 'Plantene er ikke klare før om % minutter', ceil(sek_igjen(f.hasj_ferdig) / 60.0); end if;
  update forretning set hasj_planter = 0, hasj_ferdig = null where spiller = s.id;
  if random() < 0.1 then
    update spillere set fengsel_til = now() + interval '120 seconds' where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', 'Politiet raidet plantasjen! Alt ble beslaglagt og du må sitte inne i 120 sekunder.');
  end if;
  for i in 1..f.hasj_planter loop sum_ := sum_ + 3500 + floor(random() * 2001)::int; end loop;
  update spillere set penger = penger + sum_ where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du høstet %s planter og solgte avlingen for %s.', f.hasj_planter, kr(sum_)));
end $$;

-- ---------------------------------------------------------------------
--  RAN AV ANDRE SPILLERE
-- ---------------------------------------------------------------------
create or replace function public.ran_spiller(p_navn text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere; sjanse int; byttet bigint;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.ran_klar, 'rane igjen');
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke rane deg selv'; end if;
  if t.sted <> s.sted then raise exception '% er ikke i %', t.navn, s.sted; end if;
  if t.beskyttet_til is not null and t.beskyttet_til > now() then raise exception '% er ny og beskyttet', t.navn; end if;
  if t.fengsel_til is not null and t.fengsel_til > now() then raise exception '% sitter i fengsel', t.navn; end if;
  sjanse := greatest(15, least(85, 50 + (rank_indeks(s.exp) - rank_indeks(t.exp)) * 8));
  update spillere set ran_klar = now() + interval '180 seconds' where id = s.id;
  if random() * 100 < sjanse and t.penger > 0 then
    byttet := least(500000, greatest(1, floor(t.penger * (0.05 + random() * 0.05))));
    update spillere set penger = penger - byttet where id = t.id;
    update spillere set penger = penger + byttet, exp = exp + 3 where id = s.id;
    perform _systemmelding(t.id, 'Du ble ranet!', format('%s ranet deg for %s i %s. Sett pengene i banken!', s.navn, kr(byttet), s.sted));
    return jsonb_build_object('ok', true, 'melding', format('Du ranet %s for %s! (+3 erfaring)', t.navn, kr(byttet)));
  elsif random() < 0.4 then
    update spillere set fengsel_til = now() + interval '60 seconds', exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('%s slo alarm og du ble tatt. 60 sekunder i fengsel. (+1 erfaring)', t.navn));
  else
    update spillere set exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', format('%s hadde ingenting du fikk tak i. (+1 erfaring)', t.navn));
  end if;
end $$;

-- ---------------------------------------------------------------------
--  KASINO: BLACKJACK (mot huset)
-- ---------------------------------------------------------------------
create table public.bj_spill (
  spiller uuid primary key references public.spillere(id) on delete cascade,
  innsats bigint not null, stokk int[] not null, hand int[] not null, dealer int[] not null,
  tid timestamptz not null default now());

create or replace function public._bj_verdi(h int[]) returns int language plpgsql immutable as $$
declare t int := 0; ess int := 0; c int; v int;
begin
  foreach c in array coalesce(h, '{}'::int[]) loop
    v := c % 13;
    if v = 0 then t := t + 11; ess := ess + 1;
    elsif v >= 9 then t := t + 10;
    else t := t + v + 1; end if;
  end loop;
  while t > 21 and ess > 0 loop t := t - 10; ess := ess - 1; end loop;
  return t;
end $$;

create or replace function public._bj_json(b bj_spill, skjul boolean) returns jsonb language sql immutable as $$
  select jsonb_build_object('aktiv', skjul, 'innsats', b.innsats, 'hand', to_jsonb(b.hand), 'hand_verdi', _bj_verdi(b.hand),
    'dealer', case when skjul then to_jsonb(array[b.dealer[1]]) else to_jsonb(b.dealer) end,
    'dealer_verdi', case when skjul then _bj_verdi(array[b.dealer[1]]) else _bj_verdi(b.dealer) end);
$$;

create or replace function public.bj_status() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b bj_spill;
begin
  s := _meg();
  select * into b from bj_spill where spiller = s.id;
  if not found then return jsonb_build_object('aktiv', false); end if;
  return _bj_json(b, true);
end $$;

create or replace function public._bj_avslutt(b bj_spill) returns jsonb language plpgsql set search_path = public as $$
declare p int; d int; gevinst bigint := 0; m text; ok boolean;
begin
  p := _bj_verdi(b.hand); d := _bj_verdi(b.dealer);
  if p > 21 then m := format('Du fikk %s og gikk over 21. Du tapte %s.', p, kr(b.innsats)); ok := false;
  elsif d > 21 or p > d then gevinst := b.innsats * 2; m := format('Du vant med %s mot %s! Gevinst %s.', p, d, kr(b.innsats)); ok := true;
  elsif p = d then gevinst := b.innsats; m := format('Uavgjort på %s. Du får innsatsen tilbake.', p); ok := null;
  else m := format('Dealeren vant med %s mot %s. Du tapte %s.', d, p, kr(b.innsats)); ok := false; end if;
  if gevinst > 0 then update spillere set penger = penger + gevinst where id = b.spiller; end if;
  delete from bj_spill where spiller = b.spiller;
  return _bj_json(b, false) || jsonb_build_object('ferdig', true, 'ok', coalesce(ok, false), 'uavgjort', ok is null, 'melding', m);
end $$;

create or replace function public.bj_start(p_innsats bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; st int[]; b bj_spill; gevinst bigint;
begin
  s := _meg(); perform _sjekk_fri(s);
  if exists (select 1 from bj_spill where spiller = s.id) then raise exception 'Du har allerede en hånd i spill'; end if;
  if p_innsats is null or p_innsats < 100 or p_innsats > 2000000 then raise exception 'Innsatsen må være mellom 100 kr og 2 000 000 kr'; end if;
  if p_innsats > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  update spillere set penger = penger - p_innsats where id = s.id;
  select array_agg(x order by random()) into st from generate_series(0, 51) x;
  insert into bj_spill (spiller, innsats, stokk, hand, dealer) values (s.id, p_innsats, st[5:52], array[st[1], st[3]], array[st[2], st[4]])
    returning * into b;
  if _bj_verdi(b.hand) = 21 then
    delete from bj_spill where spiller = s.id;
    if _bj_verdi(b.dealer) = 21 then
      update spillere set penger = penger + b.innsats where id = s.id;
      return _bj_json(b, false) || jsonb_build_object('ferdig', true, 'ok', false, 'uavgjort', true, 'melding', 'Begge fikk blackjack. Uavgjort.');
    end if;
    gevinst := floor(b.innsats * 2.5);
    update spillere set penger = penger + gevinst where id = s.id;
    return _bj_json(b, false) || jsonb_build_object('ferdig', true, 'ok', true, 'melding', format('Blackjack! Du vant %s.', kr(gevinst - b.innsats)));
  end if;
  return _bj_json(b, true) || jsonb_build_object('ferdig', false);
end $$;

create or replace function public.bj_trekk() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b bj_spill;
begin
  s := _meg();
  select * into b from bj_spill where spiller = s.id for update;
  if not found then raise exception 'Du har ingen hånd i spill'; end if;
  update bj_spill set hand = hand || stokk[1], stokk = stokk[2:] where spiller = s.id returning * into b;
  if _bj_verdi(b.hand) > 21 then return _bj_avslutt(b); end if;
  if _bj_verdi(b.hand) = 21 then return bj_staa(); end if;
  return _bj_json(b, true) || jsonb_build_object('ferdig', false);
end $$;

create or replace function public.bj_staa() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; b bj_spill;
begin
  s := _meg();
  select * into b from bj_spill where spiller = s.id for update;
  if not found then raise exception 'Du har ingen hånd i spill'; end if;
  while _bj_verdi(b.dealer) < 17 loop
    b.dealer := b.dealer || b.stokk[1]; b.stokk := b.stokk[2:];
  end loop;
  return _bj_avslutt(b);
end $$;

-- ---------------------------------------------------------------------
--  KASINO: UTFORDRINGER (terningduell og streetracing)
-- ---------------------------------------------------------------------
create table public.utfordringer (
  id bigint generated always as identity primary key,
  type text not null check (type in ('terning','race')),
  utfordrer uuid references public.spillere(id) on delete set null, utfordrer_navn text not null,
  utfordrer_bil text, utfordrer_verdi int,
  motstander uuid references public.spillere(id) on delete set null, motstander_navn text,
  innsats bigint not null, status text not null default 'apen', vinner text, resultat text,
  tid timestamptz not null default now(), ferdig timestamptz);
create index on public.utfordringer (type, status, tid desc);

create or replace function public.utfordringer_liste(p_type text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere;
begin
  s := _meg();
  return jsonb_build_object(
    'apne', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'navn', utfordrer_navn, 'innsats', innsats, 'bil', utfordrer_bil, 'min', utfordrer = s.id, 'tid', tid) order by tid desc), '[]')
             from utfordringer where type = p_type and status = 'apen'),
    'siste', (select coalesce(jsonb_agg(jsonb_build_object('resultat', resultat, 'vinner', vinner, 'innsats', innsats, 'tid', ferdig) order by ferdig desc), '[]')
              from (select * from utfordringer where type = p_type and status = 'ferdig' order by ferdig desc limit 10) x));
end $$;

create or replace function public.lag_utfordring(p_type text, p_innsats bigint, p_bil bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g garasje;
begin
  s := _meg(); perform _sjekk_fri(s);
  if p_type not in ('terning','race') then raise exception 'Ukjent spill'; end if;
  if p_innsats is null or p_innsats < 1000 or p_innsats > 10000000 then raise exception 'Innsatsen må være mellom 1 000 kr og 10 000 000 kr'; end if;
  if p_innsats > s.penger then raise exception 'Du har ikke så mye kontanter'; end if;
  if (select count(*) from utfordringer where utfordrer = s.id and status = 'apen') >= 3 then raise exception 'Du kan ha maks 3 åpne utfordringer'; end if;
  if p_type = 'race' then
    select * into g from garasje where id = p_bil and eier = s.id;
    if not found then raise exception 'Velg en bil fra garasjen din'; end if;
  end if;
  update spillere set penger = penger - p_innsats where id = s.id;
  insert into utfordringer (type, utfordrer, utfordrer_navn, innsats, utfordrer_bil, utfordrer_verdi) values (p_type, s.id, s.navn, p_innsats, g.bil, g.verdi);
  return jsonb_build_object('ok', true, 'melding', format('Utfordringen er lagt ut med innsats %s.', kr(p_innsats)));
end $$;

create or replace function public.avbryt_utfordring(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; u utfordringer;
begin
  s := _meg();
  delete from utfordringer where id = p_id and utfordrer = s.id and status = 'apen' returning * into u;
  if not found then raise exception 'Fant ikke en åpen utfordring fra deg'; end if;
  update spillere set penger = penger + u.innsats where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Utfordringen er trukket og %s er tilbakebetalt.', kr(u.innsats)));
end $$;

create or replace function public.godta_utfordring(p_id bigint, p_bil bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; u utfordringer; g garasje; a int; b int; vinner uuid; vnavn text; res text; pott bigint; meg_vant boolean;
begin
  s := _meg(); perform _sjekk_fri(s);
  select * into u from utfordringer where id = p_id and status = 'apen' for update;
  if not found then raise exception 'Utfordringen er ikke lenger åpen'; end if;
  if u.utfordrer = s.id then raise exception 'Du kan ikke godta din egen utfordring'; end if;
  if u.innsats > s.penger then raise exception 'Innsatsen er %. Du har ikke nok kontanter.', kr(u.innsats); end if;
  if u.type = 'race' then
    select * into g from garasje where id = p_bil and eier = s.id;
    if not found then raise exception 'Velg en bil fra garasjen din'; end if;
  end if;
  update spillere set penger = penger - u.innsats where id = s.id;
  pott := floor(u.innsats * 2 * 0.97);
  if u.type = 'terning' then
    loop
      a := 2 + floor(random() * 6)::int + floor(random() * 6)::int;
      b := 2 + floor(random() * 6)::int + floor(random() * 6)::int;
      exit when a <> b;
    end loop;
    res := format('%s kastet %s, %s kastet %s.', u.utfordrer_navn, a, s.navn, b);
  else
    a := floor(ln(greatest(u.utfordrer_verdi, 100)) * 10 + random() * 30)::int;
    b := floor(ln(greatest(g.verdi, 100)) * 10 + random() * 30)::int;
    if a = b then b := b + 1; end if;
    res := format('%s (%s) mot %s (%s).', u.utfordrer_navn, u.utfordrer_bil, s.navn, g.bil);
  end if;
  if a > b then vinner := u.utfordrer; vnavn := u.utfordrer_navn; else vinner := s.id; vnavn := s.navn; end if;
  meg_vant := coalesce(vinner = s.id, false);
  if vinner is not null then update spillere set penger = penger + pott where id = vinner; end if;
  update utfordringer set status = 'ferdig', motstander = s.id, motstander_navn = s.navn, vinner = vnavn,
    resultat = res || format(' %s vant %s.', vnavn, kr(pott)), ferdig = now() where id = u.id;
  if u.utfordrer is not null then
    perform _systemmelding(u.utfordrer, case when u.type = 'race' then 'Streetrace avgjort' else 'Terningduell avgjort' end,
      res || case when meg_vant then format(' Du tapte %s.', kr(u.innsats)) else format(' Du vant %s!', kr(pott)) end);
  end if;
  if u.innsats >= 1000000 then perform _avis(format('%s vant %s i %s mot %s.', vnavn, kr(pott), case when u.type = 'race' then 'streetrace' else 'terningduell' end,
    case when meg_vant then u.utfordrer_navn else s.navn end)); end if;
  return jsonb_build_object('ok', meg_vant, 'melding', res || case when meg_vant then format(' Du vant %s!', kr(pott)) else format(' Du tapte %s.', kr(u.innsats)) end);
end $$;

-- ---------------------------------------------------------------------
--  KASINO: GRUPPESPILL (battle royale og dødsterninger)
-- ---------------------------------------------------------------------
create table public.gruppespill (
  id bigint generated always as identity primary key,
  type text not null check (type in ('royale','terninger')),
  innsats bigint not null, maks int not null check (maks between 3 and 8),
  status text not null default 'apen', vinner text, logg text,
  opprettet timestamptz not null default now(), ferdig timestamptz);
create table public.gruppe_deltaker (
  spill_id bigint not null references public.gruppespill(id) on delete cascade,
  spiller uuid not null references public.spillere(id) on delete cascade,
  navn text not null, vapen int not null default 0, primary key (spill_id, spiller));

create or replace function public._gruppe_avgjor(p_id bigint) returns void language plpgsql set search_path = public as $$
declare g gruppespill; igjen text[]; ute text; runde int := 0; v_logg text := ''; pott bigint; vid uuid; kast record; laveste int; tapere text[];
begin
  select * into g from gruppespill where id = p_id for update;
  select array_agg(navn) into igjen from gruppe_deltaker where spill_id = g.id;
  pott := floor(g.innsats * array_length(igjen, 1) * 0.95);
  while array_length(igjen, 1) > 1 loop
    runde := runde + 1;
    if g.type = 'royale' then
      select d.navn into ute from gruppe_deltaker d where d.spill_id = g.id and d.navn = any(igjen)
        order by -ln(1 - random()) * (1 + d.vapen * 0.35) limit 1;
      v_logg := v_logg || format('Runde %s: %s ble tatt ut.', runde, ute) || E'\n';
      igjen := array_remove(igjen, ute);
    else
      tapere := '{}'; laveste := 99;
      for kast in select n, 2 + floor(random() * 6)::int + floor(random() * 6)::int as sum from unnest(igjen) n loop
        v_logg := v_logg || format('%s: %s  ', kast.n, kast.sum);
        if kast.sum < laveste then laveste := kast.sum; tapere := array[kast.n];
        elsif kast.sum = laveste then tapere := tapere || kast.n; end if;
      end loop;
      if array_length(tapere, 1) = 1 then
        v_logg := v_logg || format(E'\nRunde %s: %s ryker ut.', runde, tapere[1]) || E'\n';
        igjen := array_remove(igjen, tapere[1]);
      else
        v_logg := v_logg || format(E'\nRunde %s: likt på %s, nytt kast.', runde, laveste) || E'\n';
      end if;
    end if;
    exit when runde > 60;
  end loop;
  select spiller into vid from gruppe_deltaker where spill_id = g.id and navn = igjen[1];
  update spillere set penger = penger + pott where id = vid;
  update gruppespill set status = 'ferdig', vinner = igjen[1], ferdig = now(), logg = v_logg || format('%s vant %s!', igjen[1], kr(pott)) where id = g.id;
  perform _systemmelding(d.spiller, case when g.type = 'royale' then 'Battle royale avgjort' else 'Dødsterninger avgjort' end,
      format('%s vant potten på %s.', igjen[1], kr(pott))) from gruppe_deltaker d where d.spill_id = g.id;
  perform _avis(format('%s vant %s i %s.', igjen[1], kr(pott), case when g.type = 'royale' then 'battle royale' else 'dødsterninger' end));
end $$;

create or replace function public.gruppespill_liste(p_type text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; gammel record;
begin
  s := _meg();
  -- Rydd spill som har stått åpne i over én time: alle får pengene tilbake.
  for gammel in select id, innsats from gruppespill where type = p_type and status = 'apen' and opprettet < now() - interval '1 hour' loop
    update spillere set penger = penger + gammel.innsats where id in (select spiller from gruppe_deltaker where spill_id = gammel.id);
    delete from gruppespill where id = gammel.id;
  end loop;
  return jsonb_build_object(
    'apne', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'innsats', g.innsats, 'maks', g.maks,
               'deltakere', (select jsonb_agg(navn) from gruppe_deltaker where spill_id = g.id),
               'med', exists (select 1 from gruppe_deltaker where spill_id = g.id and spiller = s.id)) order by g.opprettet), '[]')
             from gruppespill g where g.type = p_type and g.status = 'apen'),
    'siste', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'vinner', vinner, 'innsats', innsats, 'maks', maks, 'logg', logg, 'tid', ferdig) order by ferdig desc), '[]')
              from (select * from gruppespill where type = p_type and status = 'ferdig' order by ferdig desc limit 5) x));
end $$;

create or replace function public.bli_med_gruppespill(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g gruppespill; n int;
begin
  s := _meg(); perform _sjekk_fri(s);
  select * into g from gruppespill where id = p_id and status = 'apen' for update;
  if not found then raise exception 'Spillet er ikke lenger åpent'; end if;
  if exists (select 1 from gruppe_deltaker where spill_id = g.id and spiller = s.id) then raise exception 'Du er allerede med'; end if;
  if g.innsats > s.penger then raise exception 'Innsatsen er %. Du har ikke nok kontanter.', kr(g.innsats); end if;
  update spillere set penger = penger - g.innsats where id = s.id;
  insert into gruppe_deltaker (spill_id, spiller, navn, vapen) values (g.id, s.id, s.navn, s.vapen);
  select count(*) into n from gruppe_deltaker where spill_id = g.id;
  if n >= g.maks then
    perform _gruppe_avgjor(g.id);
    return jsonb_build_object('ok', true, 'avgjort', true, 'melding', (select logg from gruppespill where id = g.id));
  end if;
  return jsonb_build_object('ok', true, 'melding', format('Du er med! %s av %s plasser er fylt.', n, g.maks));
end $$;

create or replace function public.lag_gruppespill(p_type text, p_innsats bigint, p_maks int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; nid bigint;
begin
  s := _meg(); perform _sjekk_fri(s);
  if p_type not in ('royale','terninger') then raise exception 'Ukjent spill'; end if;
  if p_innsats is null or p_innsats < 1000 or p_innsats > 5000000 then raise exception 'Innsatsen må være mellom 1 000 kr og 5 000 000 kr'; end if;
  if p_maks is null or p_maks < 3 or p_maks > 8 then raise exception 'Velg 3–8 spillere'; end if;
  if exists (select 1 from gruppespill g join gruppe_deltaker d on d.spill_id = g.id where g.type = p_type and g.status = 'apen' and d.spiller = s.id) then
    raise exception 'Du er allerede med i et åpent spill';
  end if;
  insert into gruppespill (type, innsats, maks) values (p_type, p_innsats, p_maks) returning id into nid;
  return bli_med_gruppespill(nid);
end $$;

create or replace function public.forlat_gruppespill(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; g gruppespill;
begin
  s := _meg();
  select * into g from gruppespill where id = p_id and status = 'apen' for update;
  if not found then raise exception 'Spillet er ikke lenger åpent'; end if;
  delete from gruppe_deltaker where spill_id = g.id and spiller = s.id;
  if not found then raise exception 'Du er ikke med i dette spillet'; end if;
  update spillere set penger = penger + g.innsats where id = s.id;
  if not exists (select 1 from gruppe_deltaker where spill_id = g.id) then delete from gruppespill where id = g.id; end if;
  return jsonb_build_object('ok', true, 'melding', format('Du forlot spillet og fikk %s tilbake.', kr(g.innsats)));
end $$;

-- ---------------------------------------------------------------------
--  KASINO: LOTTO (trekning hver mandag kl. 00:00)
-- ---------------------------------------------------------------------
create table public.lotto_kuponger (runde int not null, spiller uuid not null references public.spillere(id) on delete cascade, navn text not null, antall int not null, primary key (runde, spiller));
create table public.lotto_trekninger (runde int primary key, vinner text, pott bigint not null, kuponger int not null, tid timestamptz not null default now());

create or replace function public._lotto_runde() returns int language sql stable as
$$ select floor(extract(epoch from date_trunc('week', now() at time zone 'Europe/Oslo')) / 604800)::int $$;

create or replace function public._lotto_trekk() returns void language plpgsql set search_path = public as $$
declare r int; total int; x int; k record; vinner lotto_kuponger; pott bigint;
begin
  for r in select distinct runde from lotto_kuponger where runde < _lotto_runde() and runde not in (select runde from lotto_trekninger) loop
    select sum(antall) into total from lotto_kuponger where runde = r;
    x := floor(random() * total)::int;
    for k in select * from lotto_kuponger where runde = r order by spiller loop
      x := x - k.antall;
      if x < 0 then vinner := k; exit; end if;
    end loop;
    pott := floor(total * 5000 * 0.9) + 100000;
    update spillere set bank = bank + pott where id = vinner.spiller;
    insert into lotto_trekninger (runde, vinner, pott, kuponger) values (r, vinner.navn, pott, total);
    perform _systemmelding(vinner.spiller, 'Du vant i lotto!', format('Gratulerer! Du vant %s i ukens lotto. Pengene er satt inn i banken.', kr(pott)));
    perform _avis(format('%s vant %s i lotto!', vinner.navn, kr(pott)));
  end loop;
end $$;

create or replace function public.lotto_info() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; total int;
begin
  s := _meg(); perform _lotto_trekk();
  select coalesce(sum(antall), 0) into total from lotto_kuponger where runde = _lotto_runde();
  return jsonb_build_object('pott', floor(total * 5000 * 0.9) + 100000, 'kuponger', total, 'pris', 5000,
    'mine', coalesce((select antall from lotto_kuponger where runde = _lotto_runde() and spiller = s.id), 0),
    'trekning', (date_trunc('week', now() at time zone 'Europe/Oslo') + interval '7 days') at time zone 'Europe/Oslo',
    'siste', (select coalesce(jsonb_agg(jsonb_build_object('vinner', vinner, 'pott', pott, 'kuponger', kuponger, 'tid', tid) order by runde desc), '[]')
              from (select * from lotto_trekninger order by runde desc limit 5) x));
end $$;

create or replace function public.kjop_lotto(p_antall int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; pris bigint; mine int;
begin
  s := _meg(); perform _lotto_trekk();
  if p_antall is null or p_antall < 1 or p_antall > 100 then raise exception 'Du kan kjøpe 1–100 kuponger om gangen'; end if;
  select coalesce(antall, 0) into mine from lotto_kuponger where runde = _lotto_runde() and spiller = s.id;
  if coalesce(mine, 0) + p_antall > 500 then raise exception 'Maks 500 kuponger per uke'; end if;
  pris := p_antall * 5000;
  if pris > s.penger then raise exception 'Det koster %. Du har ikke nok kontanter.', kr(pris); end if;
  update spillere set penger = penger - pris where id = s.id;
  insert into lotto_kuponger (runde, spiller, navn, antall) values (_lotto_runde(), s.id, s.navn, p_antall)
    on conflict (runde, spiller) do update set antall = lotto_kuponger.antall + excluded.antall;
  return jsonb_build_object('ok', true, 'melding', format('Du kjøpte %s %s for %s. Lykke til!', p_antall, case when p_antall = 1 then 'kupong' else 'kuponger' end, kr(pris)));
end $$;

-- ---------------------------------------------------------------------
--  KASINO: NUMMERSPILLET (gjett tallet 1–1000)
-- ---------------------------------------------------------------------
create table public.nummerspill (
  id bigint generated always as identity primary key, hemmelig int not null, pott bigint not null,
  ferdig boolean not null default false, vinner text, startet timestamptz not null default now(), avsluttet timestamptz);
create table public.nummer_gjett (
  id bigint generated always as identity primary key,
  spill_id bigint not null references public.nummerspill(id) on delete cascade,
  spiller uuid references public.spillere(id) on delete set null, tall int not null, hint text not null, tid timestamptz not null default now());

create or replace function public._nummer_aktiv() returns nummerspill language plpgsql set search_path = public as $$
declare n nummerspill;
begin
  select * into n from nummerspill where not ferdig order by id desc limit 1 for update;
  if not found then
    insert into nummerspill (hemmelig, pott) values (1 + floor(random() * 1000)::int, 50000) returning * into n;
  end if;
  return n;
end $$;

create or replace function public.nummer_info() returns jsonb language plpgsql set search_path = public as $$
declare s spillere; n nummerspill;
begin
  s := _meg(); n := _nummer_aktiv();
  return jsonb_build_object('pott', n.pott, 'pris', 2500, 'gjetninger', (select count(*) from nummer_gjett where spill_id = n.id),
    'mine', (select coalesce(jsonb_agg(jsonb_build_object('tall', tall, 'hint', hint) order by id desc), '[]')
             from (select * from nummer_gjett where spill_id = n.id and spiller = s.id order by id desc limit 15) x),
    'siste', (select coalesce(jsonb_agg(jsonb_build_object('vinner', vinner, 'tall', hemmelig, 'pott', pott, 'tid', avsluttet) order by id desc), '[]')
              from (select * from nummerspill where ferdig order by id desc limit 5) x),
    'klar', s.kasino_klar);
end $$;

create or replace function public.nummer_gjett(p_tall int) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; n nummerspill; hint text;
begin
  s := _meg(); perform _vent(s.kasino_klar, 'gjette igjen');
  if p_tall is null or p_tall < 1 or p_tall > 1000 then raise exception 'Gjett et tall fra 1 til 1000'; end if;
  if s.penger < 2500 then raise exception 'Et gjett koster 2 500 kr'; end if;
  n := _nummer_aktiv();
  update spillere set penger = penger - 2500, kasino_klar = now() + interval '8 seconds' where id = s.id;
  if p_tall = n.hemmelig then
    update nummerspill set ferdig = true, vinner = s.navn, avsluttet = now(), pott = pott + 2500 where id = n.id;
    insert into nummer_gjett (spill_id, spiller, tall, hint) values (n.id, s.id, p_tall, 'riktig');
    update spillere set penger = penger + n.pott + 2500 where id = s.id;
    perform _avis(format('%s gjettet det hemmelige tallet %s og vant %s!', s.navn, p_tall, kr(n.pott + 2500)));
    return jsonb_build_object('ok', true, 'melding', format('Riktig! Tallet var %s. Du vant %s!', p_tall, kr(n.pott + 2500)));
  end if;
  hint := case when p_tall < n.hemmelig then 'høyere' else 'lavere' end;
  update nummerspill set pott = pott + 2500 where id = n.id;
  insert into nummer_gjett (spill_id, spiller, tall, hint) values (n.id, s.id, p_tall, hint);
  return jsonb_build_object('ok', false, 'melding', format('Feil. Det hemmelige tallet er %s enn %s.', hint, p_tall));
end $$;

-- ---------------------------------------------------------------------
--  API: eneste inngang fra nettleseren (erstatter forrige versjon)
-- ---------------------------------------------------------------------
create or replace function public.api(p_uid uuid, p_fn text, a jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare r jsonb; exp_for int; exp_etter int; mitt_navn text; ok boolean;
begin
  perform set_config('app.uid', coalesce(p_uid::text, ''), true);
  a := coalesce(a, '{}');
  select exp, navn into exp_for, mitt_navn from spillere where id = p_uid;

  case p_fn
    -- konto og status
    when 'spill_data'       then r := spill_data();
    when 'opprett_spiller'  then r := opprett_spiller(a->>'p_navn');
    when 'min_status'       then perform _verv_sjekk(p_uid); r := min_status();
    when 'sett_verver'      then r := sett_verver(a->>'p_navn');
    when 'verv_info'        then r := verv_info();
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
    -- kasino
    when 'rulett'           then r := rulett((a->>'p_innsats')::bigint, a->>'p_valg');
    when 'bj_status'        then r := bj_status();
    when 'bj_start'         then r := bj_start((a->>'p_innsats')::bigint);
    when 'bj_trekk'         then r := bj_trekk();
    when 'bj_staa'          then r := bj_staa();
    when 'utfordringer_liste' then r := utfordringer_liste(a->>'p_type');
    when 'lag_utfordring'   then r := lag_utfordring(a->>'p_type', (a->>'p_innsats')::bigint, (a->>'p_bil')::bigint);
    when 'godta_utfordring' then r := godta_utfordring((a->>'p_id')::bigint, (a->>'p_bil')::bigint);
    when 'avbryt_utfordring' then r := avbryt_utfordring((a->>'p_id')::bigint);
    when 'gruppespill_liste' then r := gruppespill_liste(a->>'p_type');
    when 'lag_gruppespill'  then r := lag_gruppespill(a->>'p_type', (a->>'p_innsats')::bigint, (a->>'p_maks')::int);
    when 'bli_med_gruppespill' then r := bli_med_gruppespill((a->>'p_id')::bigint);
    when 'forlat_gruppespill' then r := forlat_gruppespill((a->>'p_id')::bigint);
    when 'lotto_info'       then r := lotto_info();
    when 'kjop_lotto'       then r := kjop_lotto((a->>'p_antall')::int);
    when 'nummer_info'      then r := nummer_info();
    when 'nummer_gjett'     then r := nummer_gjett((a->>'p_tall')::int);
    else raise exception 'Ukjent handling';
  end case;

  -- Statistikk for oppdrag og prestasjoner
  if p_uid is not null and exp_for is not null and jsonb_typeof(r) = 'object' then
    ok := coalesce((r->>'ok')::boolean, false);
    case p_fn
      when 'begaa_krim' then perform _tell(p_uid, 'krim'); if ok then perform _tell(p_uid, 'krim_ok'); end if;
      when 'stjel_bil'  then perform _tell(p_uid, 'bil');  if ok then perform _tell(p_uid, 'bil_ok'); end if;
      when 'ran_spiller' then perform _tell(p_uid, 'ran'); if ok then perform _tell(p_uid, 'ran_ok'); end if;
      when 'bryt_ut'    then perform _tell(p_uid, 'utbrudd'); if ok then perform _tell(p_uid, 'utbrudd_ok'); end if;
      when 'reis'       then perform _tell(p_uid, 'reise');
      when 'angrip'     then
        perform _tell(p_uid, 'angrep');
        if coalesce((r->>'drept')::boolean, false) then
          perform _tell(p_uid, 'drap');
          perform _avis(format('%s ble drept av %s.', a->>'p_navn', mitt_navn));
        end if;
      when 'rulett', 'bj_start', 'lag_utfordring', 'godta_utfordring', 'lag_gruppespill', 'bli_med_gruppespill', 'kjop_lotto', 'nummer_gjett' then
        perform _tell(p_uid, 'kasino');
      else null;
    end case;

    -- Rank opp?
    select exp into exp_etter from spillere where id = p_uid;
    if exp_etter is not null and rank_indeks(exp_etter) > rank_indeks(exp_for) then
      perform _avis(format('%s rykket opp til %s.', mitt_navn, rank_navn(exp_etter)));
      r := r || jsonb_build_object('rankopp', rank_navn(exp_etter));
    end if;

    if p_fn = 'min_status' and r->'spiller' is not null and jsonb_typeof(r->'spiller') = 'object' then
      r := r || jsonb_build_object('varsler', _varsler(p_uid), 'gjeng_tag',
        (select tag from gjenger g join spillere s on s.gjeng_id = g.id where s.id = p_uid));
    end if;
  end if;
  return r;
end $$;
