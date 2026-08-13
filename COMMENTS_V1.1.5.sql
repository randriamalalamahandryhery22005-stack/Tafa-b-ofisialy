-- TAFAß V1.1.5.8 — COMMENTS / REPLIES / LIKES / NOTIFICATIONS FINAL FIX
-- Canonical existing schema: comments.text NOT NULL, posts.owner_id, notifications.recipient_id.
-- content is kept only for compatibility with older rows/clients.

create extension if not exists pgcrypto;

-- ============================================================
-- 1. COMMENTS
-- ============================================================
alter table public.comments add column if not exists content text;

update public.comments
set content = text
where content is null;

update public.comments
set text = coalesce(nullif(text,''), content, '')
where text is null or btrim(text) = '';

alter table public.comments alter column text set not null;

alter table public.comments enable row level security;
grant select, insert, update, delete on public.comments to authenticated;

drop policy if exists "comments_select_authenticated" on public.comments;
create policy "comments_select_authenticated"
on public.comments for select to authenticated
using (true);

drop policy if exists "comments_insert_own" on public.comments;
create policy "comments_insert_own"
on public.comments for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.posts p where p.id = post_id)
  and (parent_id is null or exists (
    select 1 from public.comments pc
    where pc.id = parent_id and pc.post_id = post_id
  ))
);

drop policy if exists "comments_update_own" on public.comments;
create policy "comments_update_own"
on public.comments for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "comments_delete_own" on public.comments;
create policy "comments_delete_own"
on public.comments for delete to authenticated
using (user_id = auth.uid());

create or replace function public.tafa_sync_comment_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.text is null or btrim(new.text) = '' then
    new.text := coalesce(new.content, '');
  end if;
  if new.content is null or btrim(new.content) = '' then
    new.content := new.text;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tafa_sync_comment_text on public.comments;
create trigger trg_tafa_sync_comment_text
before insert or update of text, content on public.comments
for each row execute function public.tafa_sync_comment_text();

create or replace function public.tafa_validate_comment_parent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.parent_id is not null and not exists (
    select 1 from public.comments parent
    where parent.id = new.parent_id and parent.post_id = new.post_id
  ) then
    raise exception 'La réponse doit appartenir à la même publication que le commentaire parent.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tafa_validate_comment_parent on public.comments;
create trigger trg_tafa_validate_comment_parent
before insert or update of parent_id, post_id on public.comments
for each row execute function public.tafa_validate_comment_parent();

-- ============================================================
-- 2. COMMENT LIKES — explicit RLS + grants
-- ============================================================
create table if not exists public.comment_likes (
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);

alter table public.comment_likes enable row level security;
grant select, insert, delete on public.comment_likes to authenticated;

drop policy if exists "comment_likes_select_authenticated" on public.comment_likes;
drop policy if exists "comment_likes_select" on public.comment_likes;
create policy "comment_likes_select_authenticated"
on public.comment_likes for select to authenticated
using (true);

drop policy if exists "comment_likes_insert_own" on public.comment_likes;
drop policy if exists "comment_likes_insert" on public.comment_likes;
create policy "comment_likes_insert_own"
on public.comment_likes for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.comments c where c.id = comment_id)
);

drop policy if exists "comment_likes_delete_own" on public.comment_likes;
drop policy if exists "comment_likes_delete" on public.comment_likes;
create policy "comment_likes_delete_own"
on public.comment_likes for delete to authenticated
using (user_id = auth.uid());

create index if not exists comment_likes_comment_idx
on public.comment_likes(comment_id);

-- ============================================================
-- 3. NOTIFICATIONS — canonical existing schema
-- ============================================================
-- Ensure the expected notification table exists if it was not created yet.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null default 'activity',
  title text not null default '',
  message text not null default '',
  entity_type text default '',
  entity_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications enable row level security;
grant select, update, delete on public.notifications to authenticated;

drop policy if exists "notifications_select_own" on public.notifications;
create policy "notifications_select_own"
on public.notifications for select to authenticated
using (recipient_id = auth.uid());

drop policy if exists "notifications_update_own" on public.notifications;
create policy "notifications_update_own"
on public.notifications for update to authenticated
using (recipient_id = auth.uid())
with check (recipient_id = auth.uid());

drop policy if exists "notifications_delete_own" on public.notifications;
create policy "notifications_delete_own"
on public.notifications for delete to authenticated
using (recipient_id = auth.uid());

create index if not exists notifications_recipient_created_idx
on public.notifications(recipient_id, created_at desc);

-- SECURITY DEFINER: clients never need INSERT permission on notifications.
create or replace function public.tafa_create_notification(
  p_recipient_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_entity_type text default '',
  p_entity_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_recipient_id is null or p_recipient_id = auth.uid() then
    return null;
  end if;

  insert into public.notifications(
    recipient_id, actor_id, type, title, message,
    entity_type, entity_id, is_read, created_at
  )
  values(
    p_recipient_id, auth.uid(), coalesce(p_type,'activity'),
    coalesce(p_title,''), coalesce(p_message,''),
    coalesce(p_entity_type,''), p_entity_id, false, now()
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.tafa_create_notification(uuid,text,text,text,text,uuid) to authenticated;

-- ============================================================
-- 4. AUTOMATIC COMMENT / REPLY NOTIFICATIONS
-- ============================================================
create or replace function public.tafa_notify_new_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient uuid;
  v_actor_name text;
  v_message text;
  v_type text;
  v_title text;
  v_entity_type text;
  v_entity_id uuid;
begin
  if new.parent_id is null then
    -- The actual project schema uses posts.owner_id.
    select p.owner_id into v_recipient
    from public.posts p
    where p.id = new.post_id;

    v_type := 'comment';
    v_title := 'Nouveau commentaire';
    v_message := 'a commenté votre publication.';
    v_entity_type := 'post';
    v_entity_id := new.post_id;
  else
    select c.user_id into v_recipient
    from public.comments c
    where c.id = new.parent_id;

    v_type := 'reply';
    v_title := 'Nouvelle réponse';
    v_message := 'a répondu à votre commentaire.';
    v_entity_type := 'comment';
    v_entity_id := new.parent_id;
  end if;

  if v_recipient is null or v_recipient = new.user_id then
    return new;
  end if;

  select trim(concat_ws(' ', p.first_name, p.last_name))
  into v_actor_name
  from public.profiles p
  where p.id = new.user_id;

  v_actor_name := coalesce(nullif(v_actor_name,''), 'Un utilisateur');

  begin
    insert into public.notifications(
      recipient_id, actor_id, type, title, message,
      entity_type, entity_id, is_read, created_at
    )
    values(
      v_recipient, new.user_id, v_type, v_title,
      v_actor_name || ' ' || v_message,
      v_entity_type, v_entity_id, false, now()
    );
  exception when others then
    raise warning 'TAFA notification skipped: %', SQLERRM;
  end;

  return new;
end;
$$;

drop trigger if exists trg_tafa_new_comment_notification on public.comments;
create trigger trg_tafa_new_comment_notification
after insert on public.comments
for each row execute function public.tafa_notify_new_comment();

-- ============================================================
-- 5. REALTIME
-- ============================================================
do $$
begin
  alter publication supabase_realtime add table public.comments;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.comment_likes;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';
select 'TAFA V1.1.5.8 — COMMENTS + LIKES + NOTIFICATIONS OK' as status;
