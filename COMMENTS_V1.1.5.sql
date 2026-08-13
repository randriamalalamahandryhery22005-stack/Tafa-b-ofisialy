-- ============================================================
-- TAFAß V1.1.5.1 — FIX COMMENT CONTENT COLUMN
-- Correction for databases where public.comments.content is NOT NULL.
-- The frontend now writes to content (not text).
-- ============================================================

-- Ensure content exists and is populated from legacy columns when possible.
alter table public.comments add column if not exists content text;

update public.comments
set content = coalesce(nullif(content, ''), nullif(text, ''), nullif(body, ''), '')
where content is null or content = '';

alter table public.comments alter column content set not null;

-- Parent validation: a reply must belong to the same publication.
create or replace function public.tafa_validate_comment_parent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.parent_id is not null and not exists (
    select 1 from public.comments parent
    where parent.id = new.parent_id
      and parent.post_id = new.post_id
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

-- Server notification for comments/replies.
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
begin
  select p.owner_id into v_recipient
  from public.posts p where p.id = new.post_id;

  if new.parent_id is not null then
    select c.user_id into v_recipient
    from public.comments c where c.id = new.parent_id;
  end if;

  if v_recipient is null or v_recipient = new.user_id then
    return new;
  end if;

  select trim(concat_ws(' ', pr.first_name, pr.last_name))
    into v_actor_name
  from public.profiles pr where pr.id = new.user_id;
  v_actor_name := coalesce(nullif(v_actor_name,''),'Un utilisateur');

  if new.parent_id is null then
    v_message := v_actor_name || ' a commenté votre publication.';
  else
    v_message := v_actor_name || ' a répondu à votre commentaire.';
  end if;

  insert into public.notifications(
    recipient_id, actor_id, type, title, message,
    entity_type, entity_id, is_read, created_at
  ) values(
    v_recipient, new.user_id,
    case when new.parent_id is null then 'comment' else 'reply' end,
    case when new.parent_id is null then 'Nouveau commentaire' else 'Nouvelle réponse' end,
    v_message,
    case when new.parent_id is null then 'post' else 'comment' end,
    case when new.parent_id is null then new.post_id else new.parent_id end,
    false, now()
  );
  return new;
end;
$$;

drop trigger if exists trg_tafa_new_comment_notification on public.comments;
create trigger trg_tafa_new_comment_notification
after insert on public.comments
for each row execute function public.tafa_notify_new_comment();

create index if not exists comments_parent_created_idx
on public.comments(parent_id, created_at asc);

do $$
begin
  alter publication supabase_realtime add table public.comments;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';
select 'TAFA V1.1.5.1 — content FIX OK' as status;
