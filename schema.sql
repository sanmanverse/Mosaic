-- MOSAIC production foundation — run in Supabase SQL Editor.
-- Re-runnable schema. Keep RLS enabled; never expose the service_role key to the browser.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null default 'Mosaic writer',
  bio text not null default '',
  avatar_url text,
  website_url text,
  interests jsonb not null default '{"technology":20,"science":20,"business":20,"society":20,"arts_culture":20,"topics":[]}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 180),
  excerpt text not null default '' check (char_length(excerpt) <= 300),
  body text not null,
  topics text[] not null default '{}',
  composition jsonb not null default '{"technology":20,"science":20,"business":20,"society":20,"arts_culture":20}'::jsonb,
  cover_url text,
  image_urls text[] not null default '{}',
  theme_key text not null default 'classic' check(theme_key in ('classic','modern','atelier','fieldnotes','noir')),
  read_time integer not null default 1 check (read_time between 1 and 120),
  status text not null default 'published' check (status in ('draft','published','archived')),
  search_document tsvector generated always as (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(excerpt,'') || ' ' || coalesce(body,'') || ' ' || array_to_string(topics,' '))) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint article_composition_total check (
    coalesce((composition->>'technology')::numeric,0) between 0 and 100 and
    coalesce((composition->>'science')::numeric,0) between 0 and 100 and
    coalesce((composition->>'business')::numeric,0) between 0 and 100 and
    coalesce((composition->>'society')::numeric,0) between 0 and 100 and
    coalesce((composition->>'arts_culture')::numeric,0) between 0 and 100 and
    coalesce((composition->>'technology')::numeric,0) +
    coalesce((composition->>'science')::numeric,0) +
    coalesce((composition->>'business')::numeric,0) +
    coalesce((composition->>'society')::numeric,0) +
    coalesce((composition->>'arts_culture')::numeric,0) = 100
  )
);

create table if not exists public.reading_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  article_id uuid not null references public.articles(id) on delete cascade,
  event_type text not null check (event_type in ('view','read','complete','save','like','share')),
  created_at timestamptz not null default now()
);
create table if not exists public.saved_articles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  article_id uuid not null references public.articles(id) on delete cascade,
  created_at timestamptz not null default now(), primary key(user_id,article_id)
);
create table if not exists public.article_likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  article_id uuid not null references public.articles(id) on delete cascade,
  created_at timestamptz not null default now(), primary key(user_id,article_id)
);
create table if not exists public.writer_follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(), primary key(follower_id,followed_id),
  constraint no_self_follow check(follower_id <> followed_id)
);
create table if not exists public.article_comments (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.articles(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check(char_length(body) between 1 and 3000),
  parent_id uuid references public.article_comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.article_reports (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.articles(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check(char_length(reason) between 3 and 500),
  status text not null default 'open' check(status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now(), unique(article_id,reporter_id)
);

create index if not exists articles_search_idx on public.articles using gin(search_document);
create index if not exists articles_topics_idx on public.articles using gin(topics);
create index if not exists articles_author_idx on public.articles(author_id);
create index if not exists articles_published_idx on public.articles(created_at desc) where status='published';
create index if not exists reading_events_user_idx on public.reading_events(user_id,created_at desc);
create index if not exists reading_events_article_idx on public.reading_events(article_id,event_type);
create index if not exists comments_article_idx on public.article_comments(article_id,created_at);

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end; $$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists articles_updated_at on public.articles;
create trigger articles_updated_at before update on public.articles for each row execute function public.set_updated_at();
drop trigger if exists comments_updated_at on public.article_comments;
create trigger comments_updated_at before update on public.article_comments for each row execute function public.set_updated_at();

-- New users receive a public profile. Username collisions are resolved with a UUID suffix.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
declare base_name text;
begin
  base_name := lower(regexp_replace(split_part(coalesce(new.email,'reader'),'@',1),'[^a-zA-Z0-9_]','','g'));
  if base_name='' then base_name:='reader'; end if;
  insert into public.profiles(id,username,display_name)
  values(new.id, left(base_name,20)||'_'||substr(new.id::text,1,6), left(coalesce(new.raw_user_meta_data->>'display_name',split_part(coalesce(new.email,'Mosaic reader'),'@',1)),60))
  on conflict(id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Search RPC: full-text search with bounded offset pagination.
drop function if exists public.search_articles(text,integer);
drop function if exists public.search_articles(text,integer,integer);
create function public.search_articles(search_query text, result_limit integer default 30, result_offset integer default 0)
returns setof public.articles language sql stable security invoker set search_path=public as $$
  select * from public.articles
  where status='published'
    and (search_query is null or btrim(search_query)='' or search_document @@ websearch_to_tsquery('english', search_query)
      or exists(select 1 from unnest(topics) t where t ilike '%'||search_query||'%'))
  order by case when search_query is null or btrim(search_query)='' then 0 else ts_rank(search_document,websearch_to_tsquery('english',search_query)) end desc, created_at desc
  limit least(greatest(coalesce(result_limit,30),1),100)
  offset greatest(coalesce(result_offset,0),0);
$$;
grant execute on function public.search_articles(text,integer,integer) to anon, authenticated;

-- Enable RLS on every user-data table.
alter table public.profiles enable row level security;
alter table public.articles enable row level security;
alter table public.reading_events enable row level security;
alter table public.saved_articles enable row level security;
alter table public.article_likes enable row level security;
alter table public.writer_follows enable row level security;
alter table public.article_comments enable row level security;
alter table public.article_reports enable row level security;

-- Drop policies first so this script can be safely rerun.
do $$ declare p record; begin
  for p in select schemaname,tablename,policyname from pg_policies where schemaname='public' and tablename in ('profiles','articles','reading_events','saved_articles','article_likes','writer_follows','article_comments','article_reports') loop
    execute format('drop policy if exists %I on %I.%I',p.policyname,p.schemaname,p.tablename);
  end loop;
end $$;

create policy "Profiles are public" on public.profiles for select using(true);
create policy "Users insert own profile" on public.profiles for insert with check(auth.uid()=id);
create policy "Users update own profile" on public.profiles for update using(auth.uid()=id) with check(auth.uid()=id);

create policy "Published articles are public" on public.articles for select using(status='published' or auth.uid()=author_id);
create policy "Users create own articles" on public.articles for insert with check(auth.uid()=author_id);
create policy "Authors update own articles" on public.articles for update using(auth.uid()=author_id) with check(auth.uid()=author_id);
create policy "Authors delete own articles" on public.articles for delete using(auth.uid()=author_id);

create policy "Users read own events" on public.reading_events for select using(auth.uid()=user_id);
create policy "Users add own events" on public.reading_events for insert with check(auth.uid()=user_id);
create policy "Users manage own saved articles" on public.saved_articles for all using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy "Likes are public" on public.article_likes for select using(true);
create policy "Users add own likes" on public.article_likes for insert with check(auth.uid()=user_id);
create policy "Users remove own likes" on public.article_likes for delete using(auth.uid()=user_id);
create policy "Follows are public" on public.writer_follows for select using(true);
create policy "Users follow as themselves" on public.writer_follows for insert with check(auth.uid()=follower_id);
create policy "Users unfollow as themselves" on public.writer_follows for delete using(auth.uid()=follower_id);
create policy "Comments are public on published stories" on public.article_comments for select using(exists(select 1 from public.articles a where a.id=article_id and a.status='published'));
create policy "Signed in users comment as themselves" on public.article_comments for insert with check(auth.uid()=author_id and exists(select 1 from public.articles a where a.id=article_id and a.status='published'));
create policy "Authors edit own comments" on public.article_comments for update using(auth.uid()=author_id) with check(auth.uid()=author_id);
create policy "Authors delete own comments" on public.article_comments for delete using(auth.uid()=author_id);
create policy "Users submit own reports" on public.article_reports for insert with check(auth.uid()=reporter_id);
create policy "Users see own reports" on public.article_reports for select using(auth.uid()=reporter_id);
create policy "Moderators review reports" on public.article_reports for select using((auth.jwt()->'app_metadata'->>'mosaic_role')='admin');
create policy "Moderators update reports" on public.article_reports for update using((auth.jwt()->'app_metadata'->>'mosaic_role')='admin') with check((auth.jwt()->'app_metadata'->>'mosaic_role')='admin');

-- Public read, authenticated upload in a per-user folder: article-covers/<auth.uid()>/filename
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('article-covers','article-covers',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
drop policy if exists "Public read article covers" on storage.objects;
drop policy if exists "Upload own article covers" on storage.objects;
drop policy if exists "Update own article covers" on storage.objects;
drop policy if exists "Delete own article covers" on storage.objects;
create policy "Public read article covers" on storage.objects for select using(bucket_id='article-covers');
create policy "Upload own article covers" on storage.objects for insert to authenticated with check(bucket_id='article-covers' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Update own article covers" on storage.objects for update to authenticated using(bucket_id='article-covers' and (storage.foldername(name))[1]=auth.uid()::text) with check(bucket_id='article-covers' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Delete own article covers" on storage.objects for delete to authenticated using(bucket_id='article-covers' and (storage.foldername(name))[1]=auth.uid()::text);


-- Additional profile validation. Admin privileges are never stored in editable profile columns.
do $$ begin
  if not exists(select 1 from pg_constraint where conname='profiles_username_format') then
    alter table public.profiles add constraint profiles_username_format check(username ~ '^[a-z0-9_]{3,24}$');
  end if;
  if not exists(select 1 from pg_constraint where conname='profiles_bio_length') then
    alter table public.profiles add constraint profiles_bio_length check(char_length(bio)<=240);
  end if;
  if not exists(select 1 from pg_constraint where conname='profiles_display_name_length') then
    alter table public.profiles add constraint profiles_display_name_length check(char_length(display_name) between 1 and 60);
  end if;
  if not exists(select 1 from pg_constraint where conname='profiles_website_protocol') then
    alter table public.profiles add constraint profiles_website_protocol check(website_url is null or website_url ~* '^https?://');
  end if;
end $$;
create unique index if not exists profiles_username_lower_unique on public.profiles(lower(username));
create index if not exists profiles_search_idx on public.profiles using gin(to_tsvector('simple',coalesce(display_name,'')||' '||coalesce(username,'')||' '||coalesce(bio,'')));
create index if not exists articles_author_created_idx on public.articles(author_id,created_at desc);
create index if not exists reports_status_created_idx on public.article_reports(status,created_at desc);

-- Lightweight database-side abuse throttles. Limits are per authenticated user and use rolling windows.
create or replace function public.enforce_mosaic_rate_limits() returns trigger
language plpgsql security definer set search_path=public as $$
declare actor uuid := auth.uid(); hits integer;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  if tg_table_name='article_comments' then
    select count(*) into hits from public.article_comments where author_id=actor and created_at>now()-interval '1 hour';
    if hits>=30 then raise exception 'Comment limit reached. Please try again later.'; end if;
  elsif tg_table_name='articles' then
    select count(*) into hits from public.articles where author_id=actor and created_at>now()-interval '24 hours';
    if hits>=10 then raise exception 'Daily publishing limit reached.'; end if;
  elsif tg_table_name='reading_events' then
    select count(*) into hits from public.reading_events where user_id=actor and created_at>now()-interval '1 hour';
    if hits>=300 then raise exception 'Activity limit reached. Please slow down.'; end if;
  elsif tg_table_name='article_reports' then
    select count(*) into hits from public.article_reports where reporter_id=actor and created_at>now()-interval '24 hours';
    if hits>=10 then raise exception 'Daily report limit reached.'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists comments_rate_limit on public.article_comments;
create trigger comments_rate_limit before insert on public.article_comments for each row execute function public.enforce_mosaic_rate_limits();
drop trigger if exists articles_rate_limit on public.articles;
create trigger articles_rate_limit before insert on public.articles for each row execute function public.enforce_mosaic_rate_limits();
drop trigger if exists reading_events_rate_limit on public.reading_events;
create trigger reading_events_rate_limit before insert on public.reading_events for each row execute function public.enforce_mosaic_rate_limits();
drop trigger if exists reports_rate_limit on public.article_reports;
create trigger reports_rate_limit before insert on public.article_reports for each row execute function public.enforce_mosaic_rate_limits();

-- A server-controlled app_metadata claim grants moderator access. Set only through the Supabase
-- service-role/admin environment, never from the browser or user-editable user_metadata.
create or replace function public.is_mosaic_moderator() returns boolean
language sql stable security invoker set search_path=public as $$
  select coalesce(auth.jwt()->'app_metadata'->>'mosaic_role'='admin',false);
$$;

-- Moderation action is exposed as a narrow RPC; normal users cannot archive other authors' stories.
create or replace function public.moderate_article(target_article_id uuid, new_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_mosaic_moderator() then raise exception 'Moderator permission required'; end if;
  if new_status not in ('published','archived') then raise exception 'Unsupported moderation status'; end if;
  update public.articles set status=new_status where id=target_article_id;
  if not found then raise exception 'Story not found'; end if;
end; $$;
revoke all on function public.moderate_article(uuid,text) from public;
grant execute on function public.moderate_article(uuid,text) to authenticated;

-- Keep personal recommendation preferences private instead of exposing them on public profiles.
create table if not exists public.profile_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  interests jsonb not null default '{"technology":20,"science":20,"business":20,"society":20,"arts_culture":20,"topics":[]}'::jsonb,
  updated_at timestamptz not null default now()
);
do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='interests') then
    insert into public.profile_preferences(user_id,interests)
    select id,interests from public.profiles where interests is not null
    on conflict(user_id) do nothing;
  end if;
end $$;
insert into public.profile_preferences(user_id) select id from public.profiles on conflict(user_id) do nothing;
alter table public.profiles drop column if exists interests;
alter table public.profile_preferences enable row level security;
drop trigger if exists profile_preferences_updated_at on public.profile_preferences;
create trigger profile_preferences_updated_at before update on public.profile_preferences for each row execute function public.set_updated_at();
drop policy if exists "Users read own preferences" on public.profile_preferences;
drop policy if exists "Users insert own preferences" on public.profile_preferences;
drop policy if exists "Users update own preferences" on public.profile_preferences;
create policy "Users read own preferences" on public.profile_preferences for select using(auth.uid()=user_id);
create policy "Users insert own preferences" on public.profile_preferences for insert with check(auth.uid()=user_id);
create policy "Users update own preferences" on public.profile_preferences for update using(auth.uid()=user_id) with check(auth.uid()=user_id);
grant select,insert,update on public.profile_preferences to authenticated;
revoke all on public.profile_preferences from anon;

-- Replace broad profile table grants with a public-field allowlist. Private reading preferences
-- live only in profile_preferences and are never selectable through public profile joins.
revoke select on public.profiles from anon, authenticated;
grant select (id,username,display_name,bio,avatar_url,website_url,created_at,updated_at) on public.profiles to anon, authenticated;
revoke update on public.profiles from anon, authenticated;
grant update (username,display_name,bio,avatar_url,website_url) on public.profiles to authenticated;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
declare base_name text;
begin
  base_name := lower(regexp_replace(split_part(coalesce(new.email,'reader'),'@',1),'[^a-zA-Z0-9_]','','g'));
  if base_name='' then base_name:='reader'; end if;
  insert into public.profiles(id,username,display_name)
  values(new.id, left(base_name,20)||'_'||substr(new.id::text,1,6), left(coalesce(new.raw_user_meta_data->>'display_name',split_part(coalesce(new.email,'Mosaic reader'),'@',1)),60))
  on conflict(id) do nothing;
  insert into public.profile_preferences(user_id) values(new.id) on conflict(user_id) do nothing;
  return new;
end; $$;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='profile_preferences_composition_total') then
    alter table public.profile_preferences add constraint profile_preferences_composition_total check (
      coalesce((interests->>'technology')::numeric,0) between 0 and 100 and
      coalesce((interests->>'science')::numeric,0) between 0 and 100 and
      coalesce((interests->>'business')::numeric,0) between 0 and 100 and
      coalesce((interests->>'society')::numeric,0) between 0 and 100 and
      coalesce((interests->>'arts_culture')::numeric,0) between 0 and 100 and
      coalesce((interests->>'technology')::numeric,0)+coalesce((interests->>'science')::numeric,0)+
      coalesce((interests->>'business')::numeric,0)+coalesce((interests->>'society')::numeric,0)+
      coalesce((interests->>'arts_culture')::numeric,0)=100
    );
  end if;
end $$;

create table if not exists public.moderation_actions (
  id bigint generated always as identity primary key,
  report_id uuid references public.article_reports(id) on delete set null,
  moderator_id uuid references public.profiles(id) on delete set null,
  action text not null check(action in ('report_reviewing','report_resolved','report_dismissed','article_archived','article_restored')),
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists moderation_actions_created_idx on public.moderation_actions(created_at desc);
alter table public.moderation_actions enable row level security;
drop policy if exists "Moderators read moderation audit" on public.moderation_actions;
create policy "Moderators read moderation audit" on public.moderation_actions for select using(public.is_mosaic_moderator());
revoke all on public.moderation_actions from anon, authenticated;
grant select on public.moderation_actions to authenticated;

create or replace function public.moderate_report(target_report_id uuid,new_status text,moderation_notes text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_mosaic_moderator() then raise exception 'Moderator permission required'; end if;
  if new_status not in ('reviewing','resolved','dismissed') then raise exception 'Unsupported report status'; end if;
  update public.article_reports set status=new_status where id=target_report_id;
  if not found then raise exception 'Report not found'; end if;
  insert into public.moderation_actions(report_id,moderator_id,action,notes)
  values(target_report_id,auth.uid(),'report_'||new_status,left(moderation_notes,1000));
end; $$;
revoke all on function public.moderate_report(uuid,text,text) from public;
grant execute on function public.moderate_report(uuid,text,text) to authenticated;

create or replace function public.moderate_article(target_article_id uuid, new_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_mosaic_moderator() then raise exception 'Moderator permission required'; end if;
  if new_status not in ('published','archived') then raise exception 'Unsupported moderation status'; end if;
  update public.articles set status=new_status where id=target_article_id;
  if not found then raise exception 'Story not found'; end if;
  insert into public.moderation_actions(moderator_id,action,notes)
  values(auth.uid(),case when new_status='archived' then 'article_archived' else 'article_restored' end,target_article_id::text);
end; $$;
revoke all on function public.moderate_article(uuid,text) from public;
grant execute on function public.moderate_article(uuid,text) to authenticated;

create or replace function public.search_writers(search_query text, result_limit integer default 30)
returns setof public.profiles language sql stable security invoker set search_path=public as $$
  select p.* from public.profiles p
  where search_query is not null and btrim(search_query)<>'' and
    (to_tsvector('simple',coalesce(p.display_name,'')||' '||coalesce(p.username,'')||' '||coalesce(p.bio,'')) @@ plainto_tsquery('simple',search_query)
      or p.username ilike '%'||search_query||'%')
  order by ts_rank(to_tsvector('simple',coalesce(p.display_name,'')||' '||coalesce(p.username,'')||' '||coalesce(p.bio,'')),plainto_tsquery('simple',search_query)) desc,p.username
  limit least(greatest(coalesce(result_limit,30),1),100);
$$;
grant execute on function public.search_writers(text,integer) to anon,authenticated;

-- Editorial presentation: optional story gallery and writer-selected article themes.
alter table public.articles add column if not exists image_urls text[] not null default '{}';
alter table public.articles add column if not exists theme_key text not null default 'classic';
alter table public.articles drop constraint if exists articles_theme_key_check;
alter table public.articles add constraint articles_theme_key_check check(theme_key in ('classic','modern','atelier','fieldnotes','noir'));
