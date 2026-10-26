-- Ranksystem: Don er høyeste rank, og alle viktige handlinger gir erfaring.
--   Kriminalitet:  full erfaring ved suksess, +1 ved mislykket forsøk
--   Biltyveri:     +4/+6/+8 ved suksess (etter sted), +1 ved mislykket forsøk
--   Bryte ut:      +5 ved suksess, +1 ved mislykket forsøk
--   Angrep:        +1 bom, +3 treff, drap gir 40 + 15 per rank offeret hadde
--   Reise:         +1
insert into public.ranker (indeks, navn, exp) values (9, 'Don', 40000)
on conflict (indeks) do update set navn = excluded.navn, exp = excluded.exp;

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
    update spillere set fengsel_til = now() + make_interval(secs => straff), exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('Politiet tok deg! Du må sitte inne i %s sekunder. (+1 erfaring)', straff));
  else
    update spillere set exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', 'Det gikk ikke, men du kom deg unna. (+1 erfaring)');
  end if;
end $$;

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
    return jsonb_build_object('ok', true, 'melding', format('Du stjal en %s verdt %s! (+%s erfaring)', b.navn, kr(b.verdi), 2 + st.tier * 2));
  elsif random() < 0.5 then
    straff := 60 + floor(random() * 60)::int;
    update spillere set fengsel_til = now() + make_interval(secs => straff), exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('Alarmen gikk og politiet tok deg! %s sekunder i fengsel. (+1 erfaring)', straff));
  else
    update spillere set exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', 'Du fikk ikke bilen i gang og stakk av tomhendt. (+1 erfaring)');
  end if;
end $$;

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
    update spillere set exp = exp + 5 where id = s.id;
    perform _systemmelding(t.id, 'Du ble brutt ut!', format('%s brøt deg ut av fengselet.', s.navn));
    return jsonb_build_object('ok', true, 'melding', format('Du brøt ut %s og fikk 5 erfaring!', t.navn));
  elsif random() < 0.5 then
    update spillere set fengsel_til = now() + interval '75 seconds', exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', 'Vakten så deg! Du havnet selv i fengsel i 75 sekunder. (+1 erfaring)');
  else
    update spillere set exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', 'Utbruddet mislyktes, men du kom deg unna. (+1 erfaring)');
  end if;
end $$;

create or replace function public.reis(p_by text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.reise_klar, 'reise igjen');
  if not exists (select 1 from byer where navn = p_by) then raise exception 'Ukjent by'; end if;
  if s.sted = p_by then raise exception 'Du er allerede i %', p_by; end if;
  if s.penger < 800 then raise exception 'Flybilletten koster 800 kr'; end if;
  update spillere set penger = penger - 800, sted = p_by, reise_klar = now() + interval '5 minutes', exp = exp + 1 where id = s.id;
  return jsonb_build_object('ok', true, 'melding', format('Du landet i %s. (+1 erfaring)', p_by));
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
    update spillere set angrep_klar = now() + interval '60 seconds', beskyttet_til = null, exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', format('Du lette etter %s i %s, men fant ingen. Bruk en detektiv. (+1 erfaring)', t.navn, s.sted));
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
    update spillere set exp = exp + case when skade > 0 then 3 else 1 end where id = s.id;
    perform _systemmelding(t.id, 'Du ble skutt!',
      format('%s skjøt på deg i %s. Du mistet %s helse og har %s igjen. Kom deg til sykehuset!', s.navn, s.sted, skade, t.helse - skade));
    return jsonb_build_object('ok', skade > 0, 'drept', false,
      'melding', case when skade = 0 then format('Kulene prellet av %s. Ingen skade. (+1 erfaring)', t.navn)
                      else format('Du traff %s for %s skade. Hen har %s helse igjen. (+3 erfaring)', t.navn, skade, t.helse - skade) end);
  end if;
end $$;
