-- Ensure a payment proof path is bound to the order/request being attached.
-- The customer UI names uploaded proofs as proof_<order_code>_<random-id>.<ext>.
CREATE OR REPLACE FUNCTION public.attach_payment_proof(p_request_id uuid, p_path text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pending public.pending_online_orders%rowtype;
  v_product public.menu_products%rowtype;
  v_ordered integer;
  v_order_id bigint;
begin
  if p_path is null or length(p_path) > 300 or p_path not like 'proof_%' then
    raise exception 'INVALID_PROOF_PATH';
  end if;

  select * into v_pending
  from public.pending_online_orders
  where request_id = p_request_id
  for update;

  if not found then
    select r.order_code into v_pending.order_code
    from public.order_requests r
    where r.request_id = p_request_id;
    if v_pending.order_code is null then raise exception 'ORDER_NOT_FOUND'; end if;

    if left(p_path, length('proof_' || v_pending.order_code || '_'))
       <> 'proof_' || v_pending.order_code || '_' then
      raise exception 'PROOF_PATH_ORDER_MISMATCH';
    end if;

    update public.orders
    set payment_proof = p_path,
        payment_status = 'verification',
        paid = false
    where order_code = v_pending.order_code;
    return true;
  end if;

  if left(p_path, length('proof_' || v_pending.order_code || '_'))
     <> 'proof_' || v_pending.order_code || '_' then
    raise exception 'PROOF_PATH_ORDER_MISMATCH';
  end if;

  select * into v_product
  from public.menu_products
  where id = v_pending.product_id
    and menu_type = v_pending.meal_period
    and active = true
  for update;

  if not found then raise exception 'PRODUCT_UNAVAILABLE'; end if;

  select coalesce(sum(o.quantity),0) into v_ordered
  from public.orders o
  where o.meal_date = v_pending.meal_date
    and o.product_id = v_pending.product_id;

  if v_ordered + v_pending.quantity > v_product.max_portions then
    raise exception 'OUT_OF_STOCK';
  end if;

  insert into public.orders (
    order_code, name, quantity, total, meal_type, note,
    payment_method, payment_proof, paid, meal_date, meal_period,
    payment_status, product_id, product_option_id
  ) values (
    v_pending.order_code, v_pending.name, v_pending.quantity, v_pending.total,
    v_pending.meal_type, v_pending.note, 'online', p_path, false,
    v_pending.meal_date, v_pending.meal_period, 'verification',
    v_pending.product_id, v_pending.product_option_id
  )
  returning id into v_order_id;

  insert into public.order_requests(request_id, order_code)
  values (v_pending.request_id, v_pending.order_code);

  delete from public.pending_online_orders where request_id = p_request_id;

  return true;
end;
$function$;
