DROP POLICY IF EXISTS "Admins can manage menu products" ON public.menu_products;
CREATE POLICY "Admins can manage menu products"
ON public.menu_products
FOR ALL
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());
