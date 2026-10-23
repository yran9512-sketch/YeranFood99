-- Phase 1: enforce product + option stock, server-side ordering dates, and admin RPC grants.
-- This migration changes function definitions/privileges only; it does not rewrite historical orders.

CREATE OR REPLACE FUNCTION public.get_product_stock(p_product_id bigint, p_meal_date date)
RETURNS TABLE(total integer, ordered integer, remaining integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    mp.max_portions::integer,
    COALESCE((
      SELECT SUM(o.quantity)
      FROM public.orders o
      WHERE o.product_id = mp.id
        AND o.meal_date = p_meal_date
    ), 0)::integer,
    GREATEST(0, mp.max_portions - COALESCE((
      SELECT SUM(o.quantity)
      FROM public.orders o
      WHERE o.product_id = mp.id
        AND o.meal_date = p_meal_date
    ), 0))::integer
  FROM public.menu_products mp
  WHERE mp.id = p_product_id
    AND mp.active = true
  LIMIT 1;
$function$;

-- Separate option-level stock endpoint; product stock and option stock are independent caps.
CREATE OR REPLACE FUNCTION public.get_product_option_stock(
  p_option_id bigint,
  p_meal_date date
)
RETURNS TABLE(total integer, ordered integer, remaining integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    po.max_portions::integer,
    COALESCE((
      SELECT SUM(o.quantity)
      FROM public.orders o
      WHERE o.product_option_id = po.id
        AND o.meal_date = p_meal_date
    ), 0)::integer,
    GREATEST(0, po.max_portions - COALESCE((
      SELECT SUM(o.quantity)
      FROM public.orders o
      WHERE o.product_option_id = po.id
        AND o.meal_date = p_meal_date
    ), 0))::integer
  FROM public.product_options po
  JOIN public.menu_products mp ON mp.id = po.product_id
  WHERE po.id = p_option_id
    AND po.enabled = true
    AND mp.active = true
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.create_order_v2(
  p_request_id uuid,
  p_name text,
  p_quantity integer,
  p_note text,
  p_meal_date date,
  p_meal_period text,
  p_payment_method text,
  p_product_id bigint,
  p_option_id bigint DEFAULT NULL
)
RETURNS TABLE(order_code text, total numeric, quantity integer, meal_type text, payment_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing text;
  v_product public.menu_products%rowtype;
  v_option public.product_options%rowtype;
  v_ordered integer;
  v_pending integer;
  v_option_ordered integer;
  v_option_pending integer;
  v_code text;
  v_total numeric;
  v_meal_type text;
  v_now timestamp without time zone;
  v_today date;
  v_expected_meal_date date;
  v_hour integer;
  v_today_isodow integer;
  v_meal_isodow integer;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST'; END IF;
  IF length(trim(coalesce(p_name, ''))) < 1 OR length(trim(p_name)) > 80 THEN
    RAISE EXCEPTION 'INVALID_NAME';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 50 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;
  IF coalesce(p_meal_period, '') NOT IN ('lunch', 'breakfast', 'drink') THEN
    RAISE EXCEPTION 'INVALID_MEAL_PERIOD';
  END IF;
  IF coalesce(p_payment_method, '') NOT IN ('cash', 'online') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;
  IF p_product_id IS NULL OR p_meal_date IS NULL THEN
    RAISE EXCEPTION 'INVALID_PRODUCT_OR_DATE';
  END IF;

  -- Preserve idempotent retries even if the ordering window has since closed.
  SELECT r.order_code INTO v_existing
  FROM public.order_requests r
  WHERE r.request_id = p_request_id;

  IF v_existing IS NOT NULL THEN
    RETURN QUERY
      SELECT o.order_code, o.total, o.quantity, o.meal_type,
             coalesce(o.payment_status, 'pending')
      FROM public.orders o
      WHERE o.order_code = v_existing;
    RETURN;
  END IF;

  -- Match the customer UI, but enforce it on the server in Malaysia local time.
  v_now := now() AT TIME ZONE 'Asia/Kuala_Lumpur';
  v_today := v_now::date;
  v_hour := extract(hour FROM v_now)::integer;
  v_today_isodow := extract(isodow FROM v_now)::integer;

  IF v_today_isodow = 6 OR (v_today_isodow = 7 AND v_hour < 15) THEN
    RAISE EXCEPTION 'ORDERING_CLOSED';
  END IF;

  IF p_meal_period = 'breakfast' THEN
    IF v_hour < 15 THEN RAISE EXCEPTION 'ORDERING_CLOSED'; END IF;
  ELSE
    IF NOT (v_hour >= 15 OR v_hour < 10) THEN
      RAISE EXCEPTION 'ORDERING_CLOSED';
    END IF;
  END IF;

  v_expected_meal_date := v_today + CASE WHEN v_hour >= 15 THEN 1 ELSE 0 END;
  IF p_meal_date <> v_expected_meal_date THEN
    RAISE EXCEPTION 'INVALID_MEAL_DATE';
  END IF;

  v_meal_isodow := extract(isodow FROM p_meal_date)::integer;
  IF v_meal_isodow IN (6, 7) THEN
    RAISE EXCEPTION 'MEAL_DATE_CLOSED';
  END IF;
  IF p_meal_period = 'lunch' AND v_meal_isodow = 5 THEN
    RAISE EXCEPTION 'FRIDAY_LUNCH_CLOSED';
  END IF;

  SELECT mp.* INTO v_product
  FROM public.menu_products mp
  WHERE mp.id = p_product_id
    AND mp.menu_type = p_meal_period
    AND mp.active = true
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE'; END IF;

  IF p_option_id IS NOT NULL THEN
    SELECT po.* INTO v_option
    FROM public.product_options po
    WHERE po.id = p_option_id
      AND po.product_id = v_product.id
      AND po.enabled = true
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'OPTION_UNAVAILABLE'; END IF;

    v_total := round(coalesce(v_option.price, 0) * p_quantity, 2);
    v_meal_type := coalesce(v_option.label_zh, v_option.label_en,
                            v_product.name_zh, v_product.name_en, '—');
  ELSE
    v_total := round(coalesce(v_product.price, 0) * p_quantity, 2);
    v_meal_type := coalesce(v_product.name_zh, v_product.name_en, '—');
  END IF;

  SELECT coalesce(sum(o.quantity), 0)::integer INTO v_ordered
  FROM public.orders o
  WHERE o.meal_date = p_meal_date AND o.product_id = v_product.id;
  SELECT coalesce(sum(p.quantity), 0)::integer INTO v_pending
  FROM public.pending_online_orders p
  WHERE p.meal_date = p_meal_date AND p.product_id = v_product.id;

  IF v_ordered + v_pending + p_quantity > v_product.max_portions THEN
    RAISE EXCEPTION 'OUT_OF_STOCK';
  END IF;

  IF p_option_id IS NOT NULL THEN
    SELECT coalesce(sum(o.quantity), 0)::integer INTO v_option_ordered
    FROM public.orders o WHERE o.meal_date = p_meal_date AND o.product_option_id = v_option.id;
    SELECT coalesce(sum(p.quantity), 0)::integer INTO v_option_pending
    FROM public.pending_online_orders p WHERE p.meal_date = p_meal_date AND p.product_option_id = v_option.id;

    IF v_option_ordered + v_option_pending + p_quantity > v_option.max_portions THEN
      RAISE EXCEPTION 'OPTION_OUT_OF_STOCK';
    END IF;
  END IF;

  v_code := 'YF-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  INSERT INTO public.orders(
    order_code, name, quantity, total, meal_type, note, payment_method,
    payment_proof, paid, meal_date, meal_period, payment_status,
    product_id, product_option_id
  )
  VALUES(
    v_code, trim(p_name), p_quantity, v_total, v_meal_type,
    nullif(trim(coalesce(p_note, '')), ''), p_payment_method,
    NULL, false, p_meal_date, p_meal_period,
    CASE WHEN p_payment_method = 'online' THEN 'awaiting_proof' ELSE 'pending' END,
    v_product.id, CASE WHEN p_option_id IS NULL THEN NULL ELSE v_option.id END
  );

  INSERT INTO public.order_requests(request_id, order_code)
  VALUES(p_request_id, v_code);

  RETURN QUERY
    SELECT v_code, v_total, p_quantity, v_meal_type,
           CASE WHEN p_payment_method = 'online' THEN 'awaiting_proof' ELSE 'pending' END;
END;
$function$;

-- Stock RPCs remain available to the public menu; management RPCs are admin-only.
REVOKE EXECUTE ON FUNCTION public.get_product_stock(bigint, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_product_stock(bigint, date) TO anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.get_product_option_stock(bigint, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_product_option_stock(bigint, date) TO anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.create_order_v2(uuid, text, integer, text, date, text, text, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order_v2(uuid, text, integer, text, date, text, text, bigint, bigint) TO anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.confirm_order_paid(bigint) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_order(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_order_paid(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_order(bigint) TO authenticated, service_role;
