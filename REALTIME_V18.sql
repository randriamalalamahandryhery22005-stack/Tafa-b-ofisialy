-- TAFAß V18 — REALTIME COMPLETE
-- Run once in Supabase SQL Editor.
-- Does not change the existing UI.

-- Notifications: allow authenticated users to create notifications as themselves.
drop policy if exists "notifications_insert_actor" on public.notifications;
create policy "notifications_insert_actor"
on public.notifications
for insert to authenticated
with check (actor_id = auth.uid());

-- Real-time messages/conversations.
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'private',
  members uuid[] not null default '{}',
  name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid references public.profiles(id) on delete cascade,
  text text not null default '',
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.conversations enable row level security;
alter table public.messages enable row level security;

drop policy if exists "conversations_select_member" on public.conversations;
create policy "conversations_select_member" on public.conversations
for select to authenticated using (auth.uid() = any(members));

drop policy if exists "conversations_insert_member" on public.conversations;
create policy "conversations_insert_member" on public.conversations
for insert to authenticated with check (auth.uid() = any(members));

drop policy if exists "conversations_update_member" on public.conversations;
create policy "conversations_update_member" on public.conversations
for update to authenticated using (auth.uid() = any(members)) with check (auth.uid() = any(members));

drop policy if exists "messages_select_member" on public.messages;
create policy "messages_select_member" on public.messages
for select to authenticated using (
  sender_id = auth.uid() or recipient_id = auth.uid()
  or exists (select 1 from public.conversations c where c.id=conversation_id and auth.uid()=any(c.members))
);

drop policy if exists "messages_insert_sender" on public.messages;
create policy "messages_insert_sender" on public.messages
for insert to authenticated with check (sender_id = auth.uid());

drop policy if exists "messages_update_recipient" on public.messages;
create policy "messages_update_recipient" on public.messages
for update to authenticated using (recipient_id = auth.uid() or sender_id = auth.uid())
with check (recipient_id = auth.uid() or sender_id = auth.uid());

create index if not exists conversations_members_gin_idx on public.conversations using gin(members);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at);

-- Enable Supabase Realtime for the social core. Existing members are ignored.
do $$
declare t text;
begin
  foreach t in array array['profiles','posts','post_reactions','comments','friend_requests','friendships','notifications','conversations','messages'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;
