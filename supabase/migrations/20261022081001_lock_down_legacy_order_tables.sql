-- Remove public anonymous access to legacy menu and order-item tables.
-- The active ordering flow uses menu_products, product_options, orders and RPCs.
DROP POLICY IF EXISTS anon_insert_menu ON public.menu;
DROP POLICY IF EXISTS anon_update_menu ON public.menu;
DROP POLICY IF EXISTS anon_delete_menu_options ON public.menu_options;
DROP POLICY IF EXISTS anon_update_menu_options ON public.menu_options;
DROP POLICY IF EXISTS anon_delete_order_items ON public.order_items;
DROP POLICY IF EXISTS anon_insert_order_items ON public.order_items;
DROP POLICY IF EXISTS anon_select_order_items ON public.order_items;
DROP POLICY IF EXISTS anon_update_order_items ON public.order_items;
