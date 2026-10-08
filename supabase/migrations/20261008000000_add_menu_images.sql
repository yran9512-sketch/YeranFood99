-- Menu product images
alter table public.menu_products
  add column if not exists image_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'menu-images',
  'menu-images',
  true,
  5242880,
  array['image/jpeg','image/png','image/webp']::text[]
)
on conflict (id) do update
set public = true,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']::text[];

drop policy if exists "menu_images_admin_insert" on storage.objects;
drop policy if exists "menu_images_admin_update" on storage.objects;
drop policy if exists "menu_images_admin_delete" on storage.objects;

create policy "menu_images_admin_insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'menu-images' and is_admin());

create policy "menu_images_admin_update"
on storage.objects for update to authenticated
using (bucket_id = 'menu-images' and is_admin())
with check (bucket_id = 'menu-images' and is_admin());

create policy "menu_images_admin_delete"
on storage.objects for delete to authenticated
using (bucket_id = 'menu-images' and is_admin());
