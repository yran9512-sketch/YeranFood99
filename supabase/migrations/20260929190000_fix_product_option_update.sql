-- Fix admin option toggles: updates must go through an admin-checked RPC
CREATE OR REPLACE FUNCTION public.update_product_option(
  p_option_id bigint,
  p_field text,
  p_value text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_field = 'enabled' THEN
    UPDATE public.product_options
    SET enabled = lower(trim(p_value)) = 'true'
    WHERE id = p_option_id;
  ELSIF p_field = 'price' THEN
    UPDATE public.product_options
    SET price = p_value::numeric
    WHERE id = p_option_id;
  ELSIF p_field = 'sort' THEN
    UPDATE public.product_options
    SET sort = p_value::integer
    WHERE id = p_option_id;
  ELSIF p_field = 'max_portions' THEN
    UPDATE public.product_options
    SET max_portions = p_value::integer
    WHERE id = p_option_id;
  ELSIF p_field IN ('label_zh','label_en','desc_zh','desc_en') THEN
    EXECUTE format('UPDATE public.product_options SET %I = $1 WHERE id = $2', p_field)
      USING p_value, p_option_id;
  ELSE
    RAISE EXCEPTION 'INVALID_FIELD';
  END IF;

  RETURN FOUND;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.update_product_option(bigint,text,text) TO authenticated;
