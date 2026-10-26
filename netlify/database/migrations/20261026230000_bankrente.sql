-- 2 % rente per døgn på penger i banken. Utbetales én gang per dato (norsk tid),
-- kalt fra den planlagte funksjonen som kjører hvert kvarter.
create table if not exists public.rente_kjoring (
  dato date primary key,
  kjort timestamptz not null default now(),
  spillere int not null default 0,
  utbetalt numeric not null default 0
);

create or replace function public.daglig_rente() returns jsonb language plpgsql set search_path = public as $$
declare v_dag date := (now() at time zone 'Europe/Oslo')::date; v_antall int; v_sum numeric;
begin
  insert into rente_kjoring (dato) values (v_dag) on conflict do nothing;
  if not found then return jsonb_build_object('ok', false, 'melding', 'Renten er allerede utbetalt i dag'); end if;

  with r as (
    select id, floor(bank * 0.02)::bigint as rente from spillere where bank >= 50 for update
  ), u as (
    update spillere s set bank = s.bank + r.rente from r where s.id = r.id and r.rente > 0
  ), l as (
    insert into handlingslogg (spiller, tekst, type, ok, lest)
    select id, format('Bankrente: %s (2 %%) ble satt inn i banken din.', kr(rente)), 'handling', true, true from r where rente > 0
  )
  select count(*), coalesce(sum(rente), 0) into v_antall, v_sum from r;

  update rente_kjoring set spillere = v_antall, utbetalt = v_sum where dato = v_dag;
  return jsonb_build_object('ok', true, 'spillere', v_antall, 'utbetalt', v_sum);
end $$;
