-- Allow only administrators to update product options from the owner page.
DROP POLICY IF EXISTS "Admins can update product options" ON public.product_options;

CREATE POLICY "Admins can update product options"
ON public.product_options
FOR UPDATE
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());
