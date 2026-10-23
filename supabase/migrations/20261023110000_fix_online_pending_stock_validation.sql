-- Harden online-payment orders: validate ordering windows and reserve both product and option stock.
-- Pending online orders count against inventory until proof is attached or the pending row is removed.

CREATE OR REPLACE FUNCTION public.create_online_order_pending(
  p_request_id uuid,
  p_name text,
  p_quantity integer,
  p_note text,
  p_meal_date date,
  p_meal_period text,
  p_product_id bigint,
  p_option_id bigint DEFAULT NULL
)
RETURNS TABLE(order_code text, total numeric, quantity integer, meal_type text, payment_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing public.pending_online_orders%rowtype;
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
  IF length(trim(coalesce(p_name,''))) < 1 OR length(trim(p_name)) > 80 THEN RAISE EXCEPTION 'INVALID_NAME'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 50 THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;
  IF coalesce(p_meal_period,'') NOT IN ('lunch','breakfast','drink') THEN RAISE EXCEPTION 'INVALID_MEAL_PERIOD'; END IF;
  IF p_product_id IS NULL OR p_meal_date IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT_OR_DATE'; END IF;

  -- A retry returns its existing reservation even if ordering has since closed.
  SELECT * INTO v_existing FROM public.pending_online_orders
  WHERE request_id = p_request_id FOR UPDATE;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.order_code, v_existing.total, v_existing.quantity,
                        v_existing.meal_type, 'awaiting_proof'::text;
    RETURN;
  END IF;

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
    IF NOT (v_hour >= 15 OR v_hour < 10) THEN RAISE EXCEPTION 'ORDERING_CLOSED'; END IF;
  END IF;
  v_expected_meal_date := v_today + CASE WHEN v_hour >= 15 THEN 1 ELSE 0 END;
  IF p_meal_date <> v_expected_meal_date THEN RAISE EXCEPTION 'INVALID_MEAL_DATE'; END IF;
  v_meal_isodow := extract(isodow FROM p_meal_date)::integer;
  IF v_meal_isodow IN (6,7) THEN RAISE EXCEPTION 'MEAL_DATE_CLOSED'; END IF;
  IF p_meal_period = 'lunch' AND v_meal_isodow = 5 THEN
    RAISE EXCEPTION 'FRIDAY_LUNCH_CLOSED';
  END IF;

  -- All reservation/confirmation paths lock product first, then option, to serialize stock changes.
  SELECT * INTO v_product FROM public.menu_products
  WHERE id = p_product_id AND menu_type = p_meal_period AND active = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE'; END IF;

  IF p_option_id IS NOT NULL THEN
    SELECT * INTO v_option FROM public.product_options
    WHERE id = p_option_id AND product_id = v_product.id AND enabled = true
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPTION_UNAVAILABLE'; END IF;
    v_total := round(coalesce(v_option.price,0) * p_quantity,2);
    v_meal_type := coalesce(v_option.label_zh,v_option.label_en,v_product.name_zh,v_product.name_en,'—');
  ELSE
    v_total := round(coalesce(v_product.price,0) * p_quantity,2);
    v_meal_type := coalesce(v_product.name_zh,v_product.name_en,'—');
  END IF;

  SELECT coalesce(sum(quantity),0)::integer INTO v_ordered
  FROM public.orders WHERE product_id = v_product.id AND meal_date = p_meal_date;
  SELECT coalesce(sum(quantity),0)::integer INTO v_pending
  FROM public.pending_online_orders WHERE product_id = v_product.id AND meal_date = p_meal_date;
  IF v_ordered + v_pending + p_quantity > v_product.max_portions THEN RAISE EXCEPTION 'OUT_OF_STOCK'; END IF;

  IF p_option_id IS NOT NULL THEN
    SELECT coalesce(sum(quantity),0)::integer INTO v_option_ordered
    FROM public.orders WHERE product_option_id = v_option.id AND meal_date = p_meal_date;
    SELECT coalesce(sum(quantity),0)::integer INTO v_option_pending
    FROM public.pending_online_orders WHERE product_option_id = v_option.id AND meal_date = p_meal_date;
    IF v_option_ordered + v_option_pending + p_quantity > v_option.max_portions THEN
      RAISE EXCEPTION 'OPTION_OUT_OF_STOCK';
    END IF;
  END IF;

  v_code := 'YF-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  INSERT INTO public.pending_online_orders(
    request_id,order_code,name,quantity,total,meal_type,note,meal_date,meal_period,product_id,product_option_id
  ) VALUES (
    p_request_id,v_code,trim(p_name),p_quantity,v_total,v_meal_type,
    nullif(trim(coalesce(p_note,'')),''),p_meal_date,p_meal_period,v_product.id,
    CASE WHEN p_option_id IS NULL THEN NULL ELSE v_option.id END
  );
  RETURN QUERY SELECT v_code,v_total,p_quantity,v_meal_type,'awaiting_proof'::text;
END;
$function$;

CREATE OR REPLACE FUNCTION public.attach_payment_proof(p_request_id uuid, p_path text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pending public.pending_online_orders%rowtype;
  v_product public.menu_products%rowtype;
  v_option public.product_options%rowtype;
  v_ordered integer;
  v_pending_stock integer;
  v_option_ordered integer;
  v_option_pending integer;
  v_order_id bigint;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST'; END IF;
  IF p_path IS NULL OR length(p_path) > 300 OR p_path NOT LIKE 'proof_%' THEN
    RAISE EXCEPTION 'INVALID_PROOF_PATH';
  END IF;

  SELECT * INTO v_pending FROM public.pending_online_orders
  WHERE request_id = p_request_id FOR UPDATE;

  IF NOT FOUND THEN
    SELECT r.order_code INTO v_pending.order_code
    FROM public.order_requests r WHERE r.request_id = p_request_id;
    IF v_pending.order_code IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
    UPDATE public.orders SET payment_proof = p_path, payment_status = 'verification', paid = false
    WHERE order_code = v_pending.order_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
    RETURN true;
  END IF;

  SELECT * INTO v_product FROM public.menu_products
  WHERE id = v_pending.product_id AND menu_type = v_pending.meal_period AND active = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE'; END IF;

  IF v_pending.product_option_id IS NOT NULL THEN
    SELECT * INTO v_option FROM public.product_options
    WHERE id = v_pending.product_option_id AND product_id = v_product.id AND enabled = true
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPTION_UNAVAILABLE'; END IF;
  END IF;

  -- The pending row already reserves stock, so exclude it from pending totals during conversion.
  SELECT coalesce(sum(o.quantity),0)::integer INTO v_ordered
  FROM public.orders o WHERE o.meal_date = v_pending.meal_date AND o.product_id = v_pending.product_id;
  SELECT coalesce(sum(p.quantity),0)::integer INTO v_pending_stock
  FROM public.pending_online_orders p
  WHERE p.meal_date = v_pending.meal_date AND p.product_id = v_pending.product_id
    AND p.request_id <> p_request_id;
  IF v_ordered + v_pending_stock + v_pending.quantity > v_product.max_portions THEN
    RAISE EXCEPTION 'OUT_OF_STOCK';
  END IF;

  IF v_pending.product_option_id IS NOT NULL THEN
    SELECT coalesce(sum(o.quantity),0)::integer INTO v_option_ordered
    FROM public.orders o WHERE o.meal_date = v_pending.meal_date
      AND o.product_option_id = v_pending.product_option_id;
    SELECT coalesce(sum(p.quantity),0)::integer INTO v_option_pending
    FROM public.pending_online_orders p WHERE p.meal_date = v_pending.meal_date
      AND p.product_option_id = v_pending.product_option_id AND p.request_id <> p_request_id;
    IF v_option_ordered + v_option_pending + v_pending.quantity > v_option.max_portions THEN
      RAISE EXCEPTION 'OPTION_OUT_OF_STOCK';
    END IF;
  END IF;

  INSERT INTO public.orders(
    order_code,name,quantity,total,meal_type,note,payment_method,payment_proof,paid,
    meal_date,meal_period,payment_status,product_id,product_option_id
  ) VALUES (
    v_pending.order_code,v_pending.name,v_pending.quantity,v_pending.total,v_pending.meal_type,v_pending.note,
    'online',p_path,false,v_pending.meal_date,v_pending.meal_period,'verification',
    v_pending.product_id,v_pending.product_option_id
  ) RETURNING id INTO v_order_id;

  INSERT INTO public.order_requests(request_id,order_code)
  VALUES(v_pending.request_id,v_pending.order_code);

  DELETE FROM public.pending_online_orders WHERE request_id = p_request_id;
  RETURN true;
END;
$function$;

-- Stock reads must reflect online reservations, not only orders already submitted with proof.
CREATE OR REPLACE FUNCTION public.get_product_stock(p_product_id bigint, p_meal_date date)
RETURNS TABLE(total integer, ordered integer, remaining integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT mp.max_portions::integer,
    (coalesce((SELECT sum(o.quantity) FROM public.orders o
      WHERE o.product_id = mp.id AND o.meal_date = p_meal_date),0)
     + coalesce((SELECT sum(p.quantity) FROM public.pending_online_orders p
      WHERE p.product_id = mp.id AND p.meal_date = p_meal_date),0))::integer,
    greatest(0,mp.max_portions
     - coalesce((SELECT sum(o.quantity) FROM public.orders o
      WHERE o.product_id = mp.id AND o.meal_date = p_meal_date),0)
     - coalesce((SELECT sum(p.quantity) FROM public.pending_online_orders p
      WHERE p.product_id = mp.id AND p.meal_date = p_meal_date),0))::integer
  FROM public.menu_products mp WHERE mp.id = p_product_id AND mp.active = true LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_product_option_stock(p_option_id bigint, p_meal_date date)
RETURNS TABLE(total integer, ordered integer, remaining integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT po.max_portions::integer,
    (coalesce((SELECT sum(o.quantity) FROM public.orders o
      WHERE o.product_option_id = po.id AND o.meal_date = p_meal_date),0)
     + coalesce((SELECT sum(p.quantity) FROM public.pending_online_orders p
      WHERE p.product_option_id = po.id AND p.meal_date = p_meal_date),0))::integer,
    greatest(0,po.max_portions
     - coalesce((SELECT sum(o.quantity) FROM public.orders o
      WHERE o.product_option_id = po.id AND o.meal_date = p_meal_date),0)
     - coalesce((SELECT sum(p.quantity) FROM public.pending_online_orders p
      WHERE p.product_option_id = po.id AND p.meal_date = p_meal_date),0))::integer
  FROM public.product_options po JOIN public.menu_products mp ON mp.id = po.product_id
  WHERE po.id = p_option_id AND po.enabled = true AND mp.active = true LIMIT 1;
$function$;
