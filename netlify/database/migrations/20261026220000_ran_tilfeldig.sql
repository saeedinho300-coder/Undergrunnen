-- Ran er nå tilfeldig: spillet velger et offer i samme by.
-- Boter kan fortsatt angi et navn (de raner bare andre boter).
create or replace function public.ran_spiller(p_navn text) returns jsonb language plpgsql set search_path = public as $$
declare s spillere; t spillere; sjanse int; byttet bigint;
begin
  s := _meg(); perform _sjekk_fri(s); perform _vent(s.ran_klar, 'rane igjen');
  if s.er_bot and coalesce(trim(p_navn), '') <> '' then
    t := _finn(p_navn);
    if t.id = s.id then raise exception 'Du kan ikke rane deg selv'; end if;
    if t.sted <> s.sted then raise exception '% er ikke i %', t.navn, s.sted; end if;
    if t.beskyttet_til is not null and t.beskyttet_til > now() then raise exception '% er ny og beskyttet', t.navn; end if;
    if t.fengsel_til is not null and t.fengsel_til > now() then raise exception '% sitter i fengsel', t.navn; end if;
  else
    select * into t from spillere
      where id <> s.id and sted = s.sted and penger > 0
        and (fengsel_til is null or fengsel_til <= now()) and (beskyttet_til is null or beskyttet_til <= now())
        and (not s.er_bot or er_bot)
      order by random() limit 1 for update;
    if not found then raise exception 'Det er ingen å rane i % akkurat nå. Prøv igjen senere eller reis til en annen by.', s.sted; end if;
  end if;
  sjanse := greatest(15, least(85, 50 + (rank_indeks(s.exp) - rank_indeks(t.exp)) * 8));
  update spillere set ran_klar = now() + interval '180 seconds' where id = s.id;
  if random() * 100 < sjanse and t.penger > 0 then
    byttet := least(500000, greatest(1, floor(t.penger * (0.05 + random() * 0.05))));
    update spillere set penger = penger - byttet where id = t.id;
    update spillere set penger = penger + byttet, exp = exp + 3 where id = s.id;
    perform _systemmelding(t.id, 'Du ble ranet!', format('%s ranet deg for %s i %s. Sett pengene i banken!', s.navn, kr(byttet), s.sted));
    return jsonb_build_object('ok', true, 'melding', format('Du fant %s på gata og ranet hen for %s! (+3 erfaring)', t.navn, kr(byttet)));
  elsif random() < 0.4 then
    update spillere set fengsel_til = now() + interval '60 seconds', exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'fengsel', true, 'melding', format('Du prøvde å rane %s, men hen slo alarm. 60 sekunder i fengsel. (+1 erfaring)', t.navn));
  else
    update spillere set exp = exp + 1 where id = s.id;
    return jsonb_build_object('ok', false, 'melding', format('Du prøvde å rane %s, men hen slapp unna. (+1 erfaring)', t.navn));
  end if;
end $$;
