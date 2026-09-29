DROP POLICY IF EXISTS "Admins can manage product options" ON public.product_options;
CREATE POLICY "Admins can manage product options"
ON public.product_options
FOR ALL
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());
