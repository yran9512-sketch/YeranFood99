-- Restrict admin-only RPCs to signed-in callers; functions still enforce is_admin().
REVOKE EXECUTE ON FUNCTION public.confirm_order_paid(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_order_paid(bigint) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.delete_order(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_order(bigint) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.update_product_option(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_product_option(bigint, text, text) TO authenticated, service_role;
