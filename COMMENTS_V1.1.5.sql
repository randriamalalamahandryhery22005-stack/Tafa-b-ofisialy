-- TAFAß V1.1.5.6 — COMMENTS / REPLIES SCHEMA COMPATIBILITY
-- The existing database requires public.comments.text NOT NULL.
-- The frontend therefore writes BOTH text and content.

ALTER TABLE public.comments
ADD COLUMN IF NOT EXISTS content text;

UPDATE public.comments
SET content = text
WHERE content IS NULL;

CREATE OR REPLACE FUNCTION public.tafa_validate_comment_parent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.comments parent
    WHERE parent.id = NEW.parent_id
      AND parent.post_id = NEW.post_id
  ) THEN
    RAISE EXCEPTION 'La réponse doit appartenir à la même publication que le commentaire parent.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tafa_validate_comment_parent ON public.comments;
CREATE TRIGGER trg_tafa_validate_comment_parent
BEFORE INSERT OR UPDATE OF parent_id, post_id
ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.tafa_validate_comment_parent();

-- Keep the two possible text columns synchronized.
CREATE OR REPLACE FUNCTION public.tafa_sync_comment_text()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.text IS NULL OR btrim(NEW.text) = '' THEN
    NEW.text := COALESCE(NEW.content, '');
  END IF;
  IF NEW.content IS NULL OR btrim(NEW.content) = '' THEN
    NEW.content := NEW.text;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tafa_sync_comment_text ON public.comments;
CREATE TRIGGER trg_tafa_sync_comment_text
BEFORE INSERT OR UPDATE OF text, content
ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.tafa_sync_comment_text();

CREATE OR REPLACE FUNCTION public.tafa_notify_new_comment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recipient uuid;
  v_actor_name text;
  v_message text;
  v_recipient_col text;
  v_cols text[] := ARRAY[]::text[];
  v_vals text[] := ARRAY[]::text[];
  v_sql text;
BEGIN
  -- Determine notification recipient.
  IF NEW.parent_id IS NULL THEN
    SELECT p.owner_id INTO v_recipient
    FROM public.posts p WHERE p.id = NEW.post_id;
  ELSE
    SELECT c.user_id INTO v_recipient
    FROM public.comments c WHERE c.id = NEW.parent_id;
  END IF;

  IF v_recipient IS NULL OR v_recipient = NEW.user_id THEN
    RETURN NEW;
  END IF;

  -- Do not let notification-schema differences break comments/replies.
  -- Detect the recipient column actually present in this installation.
  SELECT c.column_name INTO v_recipient_col
  FROM information_schema.columns c
  WHERE c.table_schema='public'
    AND c.table_name='notifications'
    AND c.column_name IN ('recipient_id','user_id','receiver_id','target_user_id')
  ORDER BY CASE c.column_name
    WHEN 'recipient_id' THEN 1
    WHEN 'user_id' THEN 2
    WHEN 'receiver_id' THEN 3
    WHEN 'target_user_id' THEN 4
  END
  LIMIT 1;

  -- If this installation has no recipient column, the comment itself must
  -- still succeed; simply skip persistence of the optional notification.
  IF v_recipient_col IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT trim(concat_ws(' ', pr.first_name, pr.last_name))
  INTO v_actor_name
  FROM public.profiles pr WHERE pr.id = NEW.user_id;

  v_actor_name := coalesce(nullif(v_actor_name,''),'Un utilisateur');

  IF NEW.parent_id IS NULL THEN
    v_message := v_actor_name || ' a commenté votre publication.';
  ELSE
    v_message := v_actor_name || ' a répondu à votre commentaire.';
  END IF;

  -- Build an INSERT using only columns that exist in the real notifications table.
  v_cols := ARRAY[v_recipient_col];
  v_vals := ARRAY['$1'];

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='actor_id') THEN
    v_cols := array_append(v_cols, 'actor_id'); v_vals := array_append(v_vals, '$2');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='type') THEN
    v_cols := array_append(v_cols, 'type'); v_vals := array_append(v_vals, '$3');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='title') THEN
    v_cols := array_append(v_cols, 'title'); v_vals := array_append(v_vals, '$4');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='message') THEN
    v_cols := array_append(v_cols, 'message'); v_vals := array_append(v_vals, '$5');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='entity_type') THEN
    v_cols := array_append(v_cols, 'entity_type'); v_vals := array_append(v_vals, '$6');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='entity_id') THEN
    v_cols := array_append(v_cols, 'entity_id'); v_vals := array_append(v_vals, '$7');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='is_read') THEN
    v_cols := array_append(v_cols, 'is_read'); v_vals := array_append(v_vals, '$8');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='notifications' AND column_name='created_at') THEN
    v_cols := array_append(v_cols, 'created_at'); v_vals := array_append(v_vals, '$9');
  END IF;

  v_sql := format(
    'INSERT INTO public.notifications (%s) VALUES (%s)',
    array_to_string(ARRAY(SELECT format('%I',x) FROM unnest(v_cols) x), ', '),
    array_to_string(v_vals, ', ')
  );

  BEGIN
    EXECUTE v_sql
    USING
      v_recipient,
      NEW.user_id,
      CASE WHEN NEW.parent_id IS NULL THEN 'comment' ELSE 'reply' END,
      CASE WHEN NEW.parent_id IS NULL THEN 'Nouveau commentaire' ELSE 'Nouvelle réponse' END,
      v_message,
      CASE WHEN NEW.parent_id IS NULL THEN 'post' ELSE 'comment' END,
      CASE WHEN NEW.parent_id IS NULL THEN NEW.post_id ELSE NEW.parent_id END,
      false,
      now();
  EXCEPTION WHEN OTHERS THEN
    -- Notification persistence is secondary; never block comment/reply creation.
    RAISE WARNING 'TAFA notification skipped: %', SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tafa_new_comment_notification ON public.comments;
CREATE TRIGGER trg_tafa_new_comment_notification
AFTER INSERT ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.tafa_notify_new_comment();

CREATE INDEX IF NOT EXISTS comments_parent_created_idx
ON public.comments(parent_id, created_at ASC);

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.comments;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

NOTIFY pgrst, 'reload schema';
SELECT 'TAFA V1.1.5.6 — text + content COMPATIBILITY OK' AS status;
