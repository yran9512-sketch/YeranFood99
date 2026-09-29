-- Restore the existing breakfast option into the new product_options architecture.
insert into public.product_options (
  product_id, label_zh, label_en, price, max_portions, enabled, sort, desc_zh, desc_en
)
select
  mp.id,
  mo.label_zh,
  mo.label_en,
  mo.price,
  coalesce(mo.max_portions, mp.max_portions),
  mo.enabled,
  mo.sort,
  mo.desc_zh,
  mo.desc_en
from public.menu_products mp
join public.menu_options mo
  on mo.menu_type = mp.menu_type
 and mo.label_zh = mp.name_zh
where mp.menu_type = 'breakfast'
  and mp.active = true
  and mo.enabled = true
  and not exists (
    select 1
    from public.product_options po
    where po.product_id = mp.id
      and po.label_zh = mo.label_zh
  );
