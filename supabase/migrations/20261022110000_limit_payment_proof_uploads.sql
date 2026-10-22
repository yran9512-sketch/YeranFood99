-- Enforce payment-proof upload limits at Storage level, not only in the browser.
-- The customer UI already accepts JPEG, PNG and WebP files up to 5 MiB.
UPDATE storage.buckets
SET file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
WHERE id = 'payments';
