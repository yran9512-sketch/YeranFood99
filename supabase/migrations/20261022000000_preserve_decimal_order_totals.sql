ALTER TABLE public.orders
  ALTER COLUMN total TYPE numeric(10,2)
  USING total::numeric(10,2);
