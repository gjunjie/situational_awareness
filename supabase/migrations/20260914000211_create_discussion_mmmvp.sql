-- Situational Awareness discussion-board MMMVP.
-- Only Google-authenticated users can read, post, or reply.
-- Post author IDs intentionally have no SELECT grant in the Data API.

create table public.posts (
  id bigint generated always as identity primary key,
  author_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null,
  body text not null,
  created_at timestamptz not null default now(),
  constraint posts_title_length check (
    title = btrim(title)
    and char_length(title) between 3 and 120
  ),
  constraint posts_body_length check (
    body = btrim(body)
    and char_length(body) between 1 and 4000
  )
);

create table public.replies (
  id bigint generated always as identity primary key,
  post_id bigint not null references public.posts (id) on delete cascade,
  author_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  author_name text not null default left(
    coalesce(
      nullif(auth.jwt() -> 'user_metadata' ->> 'full_name', ''),
      nullif(auth.jwt() -> 'user_metadata' ->> 'name', ''),
      'Google 用户'
    ),
    80
  ),
  author_avatar_url text default left(
    nullif(auth.jwt() -> 'user_metadata' ->> 'avatar_url', ''),
    2048
  ),
  body text not null,
  created_at timestamptz not null default now(),
  constraint replies_author_name_length check (char_length(author_name) between 1 and 80),
  constraint replies_avatar_url_length check (
    author_avatar_url is null or char_length(author_avatar_url) <= 2048
  ),
  constraint replies_body_length check (
    body = btrim(body)
    and char_length(body) between 1 and 2000
  )
);

create index posts_created_at_id_idx on public.posts (created_at desc, id desc);
create index posts_author_id_idx on public.posts (author_id);
create index replies_post_id_created_at_idx on public.replies (post_id, created_at, id);
create index replies_author_id_idx on public.replies (author_id);

alter table public.posts enable row level security;
alter table public.replies enable row level security;

-- Start from no Data API access, then grant only the columns each operation needs.
revoke all on table public.posts from anon, authenticated;
revoke all on table public.replies from anon, authenticated;
revoke all on sequence public.posts_id_seq from anon, authenticated;
revoke all on sequence public.replies_id_seq from anon, authenticated;

grant usage on schema public to authenticated;
grant select (id, title, body, created_at) on table public.posts to authenticated;
grant insert (title, body) on table public.posts to authenticated;
grant select (
  id,
  post_id,
  author_name,
  author_avatar_url,
  body,
  created_at
) on table public.replies to authenticated;
grant insert (post_id, body) on table public.replies to authenticated;
grant usage, select on sequence public.posts_id_seq to authenticated;
grant usage, select on sequence public.replies_id_seq to authenticated;

create policy "Google members can read posts"
on public.posts
for select
to authenticated
using (
  (select auth.uid()) is not null
  and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'
);

create policy "Google members can create anonymous posts"
on public.posts
for insert
to authenticated
with check (
  (select auth.uid()) = author_id
  and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'
);

create policy "Google members can read replies"
on public.replies
for select
to authenticated
using (
  (select auth.uid()) is not null
  and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'
);

create policy "Google members can create named replies"
on public.replies
for insert
to authenticated
with check (
  (select auth.uid()) = author_id
  and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'
);

comment on table public.posts is
  'Anonymous discussion posts. author_id is deliberately hidden from client SELECT grants.';
comment on table public.replies is
  'Named replies. Display identity is snapshotted from the authenticated Google JWT.';
