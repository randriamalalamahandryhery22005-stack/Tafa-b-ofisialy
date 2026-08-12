-- TAFAß PUBLICATIONS V4 — SCHEMA FIX
-- Run this ONCE in Supabase SQL Editor.
-- It is designed for an existing public.posts table and does not recreate it.

BEGIN;

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS owner_id uuid,
  ADD COLUMN IF NOT EXISTS text text;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='posts' AND column_name='user_id'
  ) THEN
    EXECUTE 'UPDATE public.posts SET owner_id = user_id WHERE owner_id IS NULL AND user_id IS NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='posts' AND column_name='content'
  ) THEN
    EXECUTE 'UPDATE public.posts SET text = content WHERE (text IS NULL OR text = '''') AND content IS NOT NULL';
  END IF;
END $$;

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "posts_insert_own" ON public.posts;
CREATE POLICY "posts_insert_own"
ON public.posts FOR INSERT TO authenticated
WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "posts_update_own" ON public.posts;
CREATE POLICY "posts_update_own"
ON public.posts FOR UPDATE TO authenticated
USING (owner_id = auth.uid())
WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "posts_delete_own" ON public.posts;
CREATE POLICY "posts_delete_own"
ON public.posts FOR DELETE TO authenticated
USING (owner_id = auth.uid());

DROP POLICY IF EXISTS "posts_select_authenticated" ON public.posts;
DROP POLICY IF EXISTS "posts_select_friends" ON public.posts;

CREATE POLICY "posts_select_authenticated"
ON public.posts FOR SELECT TO authenticated
USING (
  visibility = 'Public'
  OR owner_id = auth.uid()
  OR (
    visibility = 'Amis'
    AND EXISTS (
      SELECT 1 FROM public.friendships f
      WHERE (f.user_id = auth.uid() AND f.friend_id = owner_id)
         OR (f.friend_id = auth.uid() AND f.user_id = owner_id)
    )
  )
  OR (auth.uid() = ANY(COALESCE(allowed_users, '{}'::uuid[])))
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'posts_owner_id_fkey'
      AND conrelid = 'public.posts'::regclass
  ) THEN
    BEGIN
      ALTER TABLE public.posts
        ADD CONSTRAINT posts_owner_id_fkey
        FOREIGN KEY (owner_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'FK posts_owner_id_fkey not added because existing rows contain an unknown owner_id.';
    END;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
