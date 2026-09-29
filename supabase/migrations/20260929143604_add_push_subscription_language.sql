alter table public.push_subscriptions
  add column if not exists language text not null default 'zh';

alter table public.push_subscriptions
  drop constraint if exists push_subscriptions_language_check;

alter table public.push_subscriptions
  add constraint push_subscriptions_language_check
  check (language in ('zh', 'en'));

create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_language text default 'zh'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_language text;
begin
  if coalesce(trim(p_endpoint), '') = ''
     or coalesce(trim(p_p256dh), '') = ''
     or coalesce(trim(p_auth), '') = '' then
    raise exception 'invalid push subscription';
  end if;

  v_language := case
    when p_language = 'en' then 'en'
    else 'zh'
  end;

  insert into public.push_subscriptions(endpoint, p256dh, auth, language, updated_at)
  values (p_endpoint, p_p256dh, p_auth, v_language, now())
  on conflict (endpoint)
  do update set
    p256dh = excluded.p256dh,
    auth = excluded.auth,
    language = excluded.language,
    updated_at = now();

  return true;
end;
$function$;
