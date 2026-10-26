-- Innlogging med Google og med brukernavn.
-- Kolonnen "epost" holder nå enten en e-postadresse eller et brukernavn (alltid små bokstaver).
alter table public.kontoer add column if not exists google_sub text;
alter table public.kontoer add column if not exists google_epost text;
alter table public.kontoer alter column passord_hash drop not null;
create unique index if not exists kontoer_google_sub_unik on public.kontoer (google_sub) where google_sub is not null;
