-- Hemmelig nøkkel for innloggings-cookies, laget av databasen selv.
-- Brukes når miljøvariabelen SESSION_SECRET ikke er satt.
create table if not exists public.app_hemmelighet (
  id int primary key check (id = 1),
  verdi text not null
);

insert into public.app_hemmelighet (id, verdi)
values (1,
  encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text || random()::text, 'UTF8')), 'hex') ||
  encode(sha256(convert_to(gen_random_uuid()::text || random()::text, 'UTF8')), 'hex'))
on conflict (id) do nothing;
