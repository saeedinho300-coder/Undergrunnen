-- Fjerner første testkonto (passord glemt) slik at e-posten kan registreres på nytt.
delete from public.kontoer where lower(epost) = 'saeed_carlos3@hotmail.com';
