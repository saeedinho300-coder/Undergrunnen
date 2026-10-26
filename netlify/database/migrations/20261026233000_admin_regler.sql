-- =====================================================================
--  Admin: navnet «Admin», egen adminside med full botstatistikk,
--  og en egen «Regler»-kategori i forumet som bare admin kan skrive i.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. Admins spiller heter «Admin». Navnet (og «System») er reservert.
-- ---------------------------------------------------------------------
do $$
declare v_id uuid; v_gammelt text;
begin
  select s.id, s.navn into v_id, v_gammelt from spillere s join kontoer k on k.id = s.id
   where lower(k.epost) = 'saeedinho300@gmail.com' or lower(coalesce(k.google_epost, '')) = 'saeedinho300@gmail.com'
   order by s.opprettet limit 1;
  if v_id is null then
    select s.id, s.navn into v_id, v_gammelt from spillere s join kontoer k on k.id = s.id join app_admin a
      on a.epost = lower(k.epost) or a.epost = lower(coalesce(k.google_epost, ''))
     order by s.opprettet limit 1;
  end if;
  if v_id is null or v_gammelt = 'Admin' then return; end if;

  -- Hvis noen andre allerede heter Admin, får de et nytt navn
  update spillere set navn = left('Spiller_' || substr(replace(id::text, '-', ''), 1, 8), 16)
   where lower(navn) = 'admin' and id <> v_id;

  update spillere set navn = 'Admin' where id = v_id;
  -- Navnet ligger også som tekst noen steder
  update forum_traader set forfatter = 'Admin' where forfatter = v_gammelt;
  update forum_innlegg set forfatter = 'Admin' where forfatter = v_gammelt;
  update chat set navn = 'Admin' where navn = v_gammelt;
  update meldinger set fra_navn = 'Admin' where fra_navn = v_gammelt;
  update bruktbiler set selger_navn = 'Admin' where selger = v_id;
  update lotto_kuponger set navn = 'Admin' where spiller = v_id;
end $$;

create or replace function public._reservert_navn() returns trigger language plpgsql set search_path = public as $$
begin
  if lower(new.navn) in ('admin', 'system', 'administrator') and not _er_admin(new.id) then
    raise exception 'Navnet % er opptatt', new.navn;
  end if;
  return new;
end $$;
drop trigger if exists spillere_reservert_navn on public.spillere;
create trigger spillere_reservert_navn before insert or update of navn on public.spillere
  for each row execute function public._reservert_navn();

-- ---------------------------------------------------------------------
--  2. Forum: egen kategori «Regler». Bare admin kan skrive der.
-- ---------------------------------------------------------------------
alter table public.forum_traader drop constraint if exists forum_traader_kategori_check;
alter table public.forum_traader add constraint forum_traader_kategori_check
  check (kategori in ('Regler','Generelt','Salg','Gjeng','Hjelp'));
alter table public.forum_traader add column if not exists rekkefolge int;

create or replace function public.forum_liste(p_kategori text) returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.regel desc, x.rekkefolge nulls last, x.sist_aktiv desc), '[]') from (
    select id, kategori, tittel, forfatter, antall, sist_aktiv, rekkefolge, kategori = 'Regler' as regel from forum_traader
    where p_kategori is null or p_kategori = '' or kategori = p_kategori
    order by (kategori = 'Regler') desc, rekkefolge nulls last, sist_aktiv desc limit 60) x;
$$;

create or replace function public.ny_traad(p_kategori text, p_tittel text, p_tekst text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; nid bigint; adm boolean;
begin
  s := _meg(); adm := _er_admin(s.id);
  if not adm then perform _vent(s.forum_klar, 'skrive i forumet igjen'); end if;
  p_tittel := trim(coalesce(p_tittel, '')); p_tekst := trim(coalesce(p_tekst, ''));
  if p_kategori not in ('Regler','Generelt','Salg','Gjeng','Hjelp') then raise exception 'Velg en kategori'; end if;
  if p_kategori = 'Regler' and not adm then raise exception 'Bare Admin kan skrive regler'; end if;
  if length(p_tittel) < 3 or length(p_tittel) > 80 then raise exception 'Tittelen må være 3–80 tegn'; end if;
  if length(p_tekst) < 1 or length(p_tekst) > 6000 then raise exception 'Innlegget må være 1–6000 tegn'; end if;
  insert into forum_traader (kategori, tittel, forfatter, rekkefolge)
    values (p_kategori, p_tittel, s.navn, case when p_kategori = 'Regler' then (select coalesce(max(rekkefolge), 0) + 1 from forum_traader where kategori = 'Regler') end)
    returning id into nid;
  insert into forum_innlegg (traad_id, forfatter, tekst) values (nid, s.navn, p_tekst);
  if not adm then update spillere set forum_klar = now() + interval '60 seconds' where id = s.id; end if;
  return jsonb_build_object('ok', true, 'melding', 'Tråden er opprettet.', 'id', nid);
end $$;

create or replace function public.svar_traad(p_id bigint, p_tekst text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; adm boolean; kat text;
begin
  s := _meg(); adm := _er_admin(s.id);
  select kategori into kat from forum_traader where id = p_id;
  if not found then raise exception 'Fant ikke tråden'; end if;
  if kat = 'Regler' and not adm then raise exception 'Bare Admin kan skrive i regeltrådene'; end if;
  if not adm then perform _vent(s.forum_klar, 'skrive i forumet igjen'); end if;
  p_tekst := trim(coalesce(p_tekst, ''));
  if length(p_tekst) < 1 or length(p_tekst) > 6000 then raise exception 'Svaret må være 1–6000 tegn'; end if;
  insert into forum_innlegg (traad_id, forfatter, tekst) values (p_id, s.navn, p_tekst);
  update forum_traader set sist_aktiv = now(), antall = antall + 1 where id = p_id;
  if not adm then update spillere set forum_klar = now() + interval '15 seconds' where id = s.id; end if;
  return jsonb_build_object('ok', true, 'melding', 'Svaret er publisert.');
end $$;

-- Admin kan rette eller slette regeltråder
create or replace function public.rediger_regel(p_id bigint, p_tittel text, p_tekst text) returns jsonb language plpgsql set search_path = public as $$
begin
  if not _er_admin(app_uid()) then raise exception 'Ingen tilgang'; end if;
  p_tittel := trim(coalesce(p_tittel, '')); p_tekst := trim(coalesce(p_tekst, ''));
  if length(p_tittel) < 3 or length(p_tittel) > 80 then raise exception 'Tittelen må være 3–80 tegn'; end if;
  if length(p_tekst) < 1 or length(p_tekst) > 6000 then raise exception 'Teksten må være 1–6000 tegn'; end if;
  update forum_traader set tittel = p_tittel, sist_aktiv = now() where id = p_id and kategori = 'Regler';
  if not found then raise exception 'Fant ikke regeltråden'; end if;
  update forum_innlegg set tekst = p_tekst where id = (select min(id) from forum_innlegg where traad_id = p_id);
  return jsonb_build_object('ok', true, 'melding', 'Regelen er oppdatert.');
end $$;

create or replace function public.slett_traad(p_id bigint) returns jsonb language plpgsql set search_path = public as $$
begin
  if not _er_admin(app_uid()) then raise exception 'Ingen tilgang'; end if;
  delete from forum_traader where id = p_id;
  if not found then raise exception 'Fant ikke tråden'; end if;
  return jsonb_build_object('ok', true, 'melding', 'Tråden er slettet.');
end $$;

-- ---------------------------------------------------------------------
--  3. Reglene
-- ---------------------------------------------------------------------
do $$
declare v_ranker text; v_id bigint; r record;
begin
  if exists (select 1 from forum_traader where kategori = 'Regler') then return; end if;
  select string_agg(format('%s – %s erfaring', navn, replace(to_char(exp, 'FM999,999,990'), ',', ' ')), E'\n' order by indeks) into v_ranker from ranker;

  for r in select * from (values
    (1, 'Spilleregler – les dette først', $t$[b]Velkommen til Undergrunnen![/b]
Disse reglene gjelder for alle. Brudd kan gi advarsel, tap av penger og rank, eller utestengelse.

[b]1.[/b] Én konto per person. Flere kontoer for å hjelpe deg selv er ikke lov.
[b]2.[/b] Ingen juks: ikke bruk programmer, skript eller makroer som spiller for deg.
[b]3.[/b] Finner du en feil i spillet, si fra til Admin. Å utnytte feil er juks.
[b]4.[/b] Ikke kjøp eller selg spillpenger, poeng eller kontoer for ekte penger.
[b]5.[/b] Ikke del kontoen din, og ikke spør andre om passordet deres.
[b]6.[/b] Vis respekt i chat, forum og meldinger. Ingen trusler, rasisme, hets eller trakassering.
[b]7.[/b] Ingen reklame, spam eller lenker til skadelige sider.
[b]8.[/b] Det er lov å rane, drepe og lure hverandre [i]i spillet[/i]. Det er ikke lov å true noen i virkeligheten.
[b]9.[/b] Admin har siste ord, og reglene kan endres.

[i]Undergrunnen har også datastyrte spillere (boter). De spiller som alle andre og kan ranes og angripes.[/i]$t$),
    (2, 'Rank og erfaring', $t$[b]Alt du gjør gir erfaring.[/b] Lykkes du, får du mest. Mislykkes du, får du likevel +1.

[b]Kriminalitet:[/b] +2 til +25
[b]Biltyveri:[/b] +4 / +6 / +8
[b]Ran av spiller:[/b] +3
[b]Bryte ut fra fengsel:[/b] +5
[b]Drap:[/b] +40 og mer (mer jo høyere rank offeret har)

[b]Rankstigen[/b]
#RANKER#

Høyeste rank er [b]Don[/b]. Høyere rank gir bedre sjanser, og nye handlinger låses opp.$t$),
    (3, 'Kriminalitet, biler og fengsel', $t$[b]Kriminalitet[/b]
Velg en handling. Ventetiden er 60–180 sekunder, avhengig av hva du gjør. Mislykkes du, er det 50 % sjanse for fengsel i 45–105 sekunder.

[b]Biler[/b]
Du kan stjele en bil hvert 4. minutt. Garasjen har plass til 30 biler. Biler kan selges eller legges ut på bruktbilmarkedet.

[b]Fengsel[/b]
Mens du sitter inne, kan du ikke gjøre handlinger.
– Du kan kjøpe deg ut for 25 kr per sekund som er igjen.
– Andre kan bryte deg ut. Den som prøver, risikerer selv 75 sekunder i fengsel.$t$),
    (4, 'Ran og drap', $t$[b]Ran[/b]
Du raner en tilfeldig spiller i samme by som deg. Du kan rane hvert 3. minutt.
– Lykkes du, tar du 5–10 % av kontantene til offeret (maks 500 000 kr).
– Mislykkes du, er det 40 % sjanse for 60 sekunder i fengsel.
– Bare kontanter kan ranes. [b]Penger i banken er trygge.[/b]

[b]Drap[/b]
Du trenger våpen og kuler. Offeret må være i samme by – bruk en detektiv for å finne folk. Du kan angripe hvert 5. minutt.
– Dreper du noen, får du alle kontantene deres, og de havner på gravplassen.
– Nye spillere er beskyttet de første 12 timene. Angriper du selv, mister du beskyttelsen.
– Beskyttelse (vest) gjør deg vanskeligere å drepe.$t$),
    (5, 'Bank og penger', $t$[b]Banken[/b]
– Sett inn og ta ut når du vil.
– Penger i banken kan ikke ranes og tas ikke av den som dreper deg.
– [b]Banken gir 2 % rente hver dag.[/b] Renten settes inn like etter midnatt (norsk tid) og regnes av det som står i banken da.

[b]Overføringer[/b]
Du kan overføre penger, kuler og poeng til andre spillere. Overføringer mellom egne kontoer er juks (se regel 1).$t$),
    (6, 'Kasino og lotto', $t$[b]Blackjack[/b] – du spiller mot banken. Kom nærmest 21 uten å gå over.
[b]Terninger[/b] – du og banken kaster to terninger hver. Høyest sum vinner, og vinner du, får du innsatsen dobbelt tilbake.
Innsats: 100 kr – 2 000 000 kr.

[b]Alt som tapes i blackjack og terninger, går til lottopotten.[/b]

[b]Lotto[/b]
– En kupong koster 5 000 kr. Du kan kjøpe 1–100 om gangen og maks 500 per uke.
– Trekningen skjer hver mandag ved midnatt (norsk tid). Én vinner trekkes, og flere kuponger gir større sjanse.
– Potten er 100 000 kr + 5 000 kr per kupong + alt som er tapt i kasinoet den uka.
– Kjøper ingen kuponger, går kasinopotten videre til neste uke.
– Gevinsten settes inn i banken.$t$),
    (7, 'Reise og sykehus', $t$[b]Reise[/b]
En flybillett koster 800 kr, og du kan reise hvert 5. minutt. Ran og drap skjer bare i samme by, så det å bytte by kan redde deg.

[b]Sykehus[/b]
Har du blitt skadet, kan du bli lappet sammen for 200 kr per prosent helse som mangler.$t$)
  ) as v(nr, tittel, tekst) loop
    insert into forum_traader (kategori, tittel, forfatter, rekkefolge) values ('Regler', r.tittel, 'Admin', r.nr) returning id into v_id;
    insert into forum_innlegg (traad_id, forfatter, tekst) values (v_id, 'Admin', replace(r.tekst, '#RANKER#', v_ranker));
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  4. Profil: viser Admin-merke. Botenes statistikk vises bare for admin.
-- ---------------------------------------------------------------------
create or replace function public.profil(p_navn text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t spillere; meg uuid := app_uid(); skjul boolean;
begin
  select * into t from spillere where lower(navn) = lower(trim(p_navn));
  if not found then raise exception 'Fant ingen spiller som heter %', p_navn; end if;
  skjul := t.er_bot and not _er_admin(meg);
  return jsonb_build_object('navn', t.navn, 'rank', rank_navn(t.exp), 'drap', case when skjul then null else t.drap end, 'min', t.id = meg,
    'admin', _er_admin(t.id),
    'opprettet', t.opprettet, 'sist_aktiv', t.sist_aktiv, 'online', t.sist_aktiv > now() - interval '5 minutes',
    'gjeng', (select navn from gjenger where id = t.gjeng_id), 'tag', (select tag from gjenger where id = t.gjeng_id),
    'pengestatus', _pengestatus(t.penger + t.bank), 'kjonn', t.kjonn, 'bot', t.er_bot,
    'bilde', _bilde(t.id), 'musikk', t.musikk_url,
    'bio', case when t.vis_bio or t.id = meg then t.bio else '' end,
    'prestasjoner', (select count(*) from prestasjon_hentet where spiller = t.id),
    'prestasjoner_totalt', (select count(*) from prestasjon_typer),
    'prestasjonspoeng', (select coalesce(sum(p.poeng), 0) from prestasjon_hentet h join prestasjon_typer p on p.id = h.prestasjon where h.spiller = t.id),
    'statistikk_skjult', skjul,
    'meldinger_sendt', case when skjul then null else _stat(t.id, 'melding') end,
    'krim', case when skjul then null else _stat(t.id, 'krim_ok') end,
    'biler', case when skjul then null else _stat(t.id, 'bil_ok') end,
    'fengsel', coalesce(t.fengsel_til > now(), false), 'beskyttet', coalesce(t.beskyttet_til > now(), false));
end $$;

-- ---------------------------------------------------------------------
--  5. Adminside: oversikt over spillet og alt botene gjør
-- ---------------------------------------------------------------------
create or replace function public.admin_oversikt() returns jsonb language plpgsql set search_path = public as $$
declare v_dag date := _idag();
begin
  if not _er_admin(app_uid()) then raise exception 'Ingen tilgang'; end if;
  return jsonb_build_object(
    'spillere', (select count(*) from spillere where not er_bot),
    'boter', (select count(*) from spillere where er_bot),
    'online', (select count(*) from spillere where not er_bot and sist_aktiv > now() - interval '5 minutes'),
    'nye_idag', (select count(*) from spillere where not er_bot and opprettet::date = current_date),
    'penger_spillere', (select coalesce(sum(penger + bank), 0) from spillere where not er_bot),
    'penger_boter', (select coalesce(sum(penger + bank), 0) from spillere where er_bot),
    'lottopott', _lotto_pott(_lotto_runde()),
    'rente', (select coalesce(jsonb_agg(jsonb_build_object('dato', dato, 'spillere', spillere, 'utbetalt', utbetalt) order by dato desc), '[]')
              from (select * from rente_kjoring order by dato desc limit 7) r),
    -- Summer for alle botene: totalt og i dag
    'bot_totalt', (select coalesce(jsonb_object_agg(nokkel, sum), '{}') from (
                     select st.nokkel, sum(st.antall) from stat st join spillere s on s.id = st.spiller where s.er_bot group by st.nokkel) x),
    'bot_idag', (select coalesce(jsonb_object_agg(nokkel, sum), '{}') from (
                   select d.nokkel, sum(d.antall) from dagstat d join spillere s on s.id = d.spiller where s.er_bot and d.dato = v_dag group by d.nokkel) x),
    -- Hver bot
    'botliste', (select coalesce(jsonb_agg(jsonb_build_object(
        'navn', s.navn, 'rank', rank_navn(s.exp), 'exp', s.exp, 'penger', s.penger, 'bank', s.bank, 'sted', s.sted,
        'kuler', s.kuler, 'drap', s.drap, 'sist_aktiv', s.sist_aktiv, 'fengsel', coalesce(s.fengsel_til > now(), false),
        'gjeng', (select tag from gjenger where id = s.gjeng_id),
        'stat', (select coalesce(jsonb_object_agg(nokkel, antall), '{}') from stat where spiller = s.id),
        'idag', (select coalesce(jsonb_object_agg(nokkel, antall), '{}') from dagstat where spiller = s.id and dato = v_dag)
      ) order by s.exp desc), '[]') from spillere s where s.er_bot),
    -- Ekte spillere
    'spillerliste', (select coalesce(jsonb_agg(jsonb_build_object('navn', navn, 'rank', rank_navn(exp), 'penger', penger + bank,
        'sist_aktiv', sist_aktiv, 'opprettet', opprettet) order by sist_aktiv desc), '[]')
      from (select * from spillere where not er_bot order by sist_aktiv desc limit 100) s));
end $$;

-- ---------------------------------------------------------------------
--  6. API: nye admin- og forumfunksjoner legges i en tynn ytre funksjon,
--     resten går til forrige versjon (uendret).
-- ---------------------------------------------------------------------
alter function public.api(uuid, text, jsonb) rename to api_v3;

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
    else return api_v3(p_uid, p_fn, a);
  end case;
  return r;
end $$;
