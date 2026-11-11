-- Client roles should never be able to TRUNCATE application tables.
-- TRUNCATE bypasses row-level security, so RLS policies cannot protect against it.
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- Keep the same protection for tables created in the future by the migration owner.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE TRUNCATE ON TABLES FROM anon, authenticated;
