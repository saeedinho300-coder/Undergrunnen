-- =====================================================================
--  Hitman: rank 3 heter nå «Hitman». Du må være Hitman for å drepe,
--  og alle under Hitman har nybegynnerbeskyttelse mot drap.
-- =====================================================================
update public.ranker set navn = 'Hitman' where indeks = 3;

create or replace function public._hitman() returns int language sql stable set search_path = public as $$
  select coalesce((select indeks from ranker where navn = 'Hitman'), 3);
$$;

create or replace function public.angrip(p_navn text, p_kuler int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s spillere; t spillere; vm numeric; bm numeric; skade int; utbytte bigint; ekstra int;
begin
  s := _meg(); perform _sjekk_fri(s);
  if rank_indeks(s.exp) < _hitman() then raise exception 'Du må være Hitman for å drepe. Fortsett å jobbe deg opp.'; end if;
  perform _vent(s.angrep_klar, 'angripe igjen');
  if s.vapen = 0 then raise exception 'Du trenger et våpen. Kjøp et i butikken.'; end if;
  if p_kuler is null or p_kuler < 1 then raise exception 'Du må bruke minst 1 kule'; end if;
  if p_kuler > s.kuler then raise exception 'Du har bare % kuler', s.kuler; end if;
  t := _finn(p_navn);
  if t.id = s.id then raise exception 'Du kan ikke skyte deg selv'; end if;
  if rank_indeks(t.exp) < _hitman() then
    raise exception '% har nybegynnerbeskyttelse og kan ikke drepes før hen blir Hitman', t.navn;
  end if;
  if t.fengsel_til is not null and t.fengsel_til > now() then raise exception '% sitter i fengsel', t.navn; end if;

  if t.sted <> s.sted then
    update spillere set angrep_klar = now() + interval '60 seconds', exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', format('Du lette etter %s i %s, men fant ingen. Bruk en detektiv. (+1 erfaring)', t.navn, s.sted));
  end if;

  select styrke into vm from vapen_typer where nivaa = s.vapen;
  bm := coalesce((select styrke from beskyttelse_typer where nivaa = t.beskyttelse), 1.0);
  skade := floor(p_kuler * vm * (1 + rank_indeks(s.exp) * 0.2) / (bm * (1 + rank_indeks(t.exp) * 0.2)) / 10)::int;

  update spillere set kuler = kuler - p_kuler, angrep_klar = now() + interval '5 minutes' where id = s.id;

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

-- Reglene i forumet oppdateres
update public.forum_innlegg i set tekst = replace(i.tekst, 'Torpedo – ', 'Hitman – ')
  from public.forum_traader t where t.id = i.traad_id and t.kategori = 'Regler';
update public.forum_innlegg i set tekst = replace(replace(i.tekst,
    E'Du trenger våpen og kuler.', E'Du må være [b]Hitman[/b] for å drepe, og du trenger våpen og kuler.'),
    E'– Nye spillere er beskyttet de første 12 timene. Angriper du selv, mister du beskyttelsen.',
    E'– [b]Nybegynnerbeskyttelse:[/b] Spillere under Hitman kan ikke drepes.')
  from public.forum_traader t where t.id = i.traad_id and t.kategori = 'Regler';
update public.forum_innlegg i set tekst = replace(i.tekst,
    'Høyere rank gir bedre sjanser, og nye handlinger låses opp.',
    'Høyere rank gir bedre sjanser, og nye handlinger innen kriminalitet og biltyveri dukker opp når du når riktig rank. Som [b]Hitman[/b] kan du drepe.')
  from public.forum_traader t where t.id = i.traad_id and t.kategori = 'Regler';
