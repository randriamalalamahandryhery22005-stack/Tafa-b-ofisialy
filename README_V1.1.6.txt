TAFAß V1.1.6 — COMMENTS / REACTIONS / CLICKABLE NOTIFICATIONS

Fixes:
- Comment reactions use SECURITY DEFINER RPC tafa_set_comment_like.
- Post reactions notify the publication owner.
- Comment/reply notifications are persisted server-side.
- Notification rows now have comment_id as a source pointer.
- Clicking a notification opens the publication and scrolls to the related post/comment.
- text + content remain synchronized for comments.

SUPABASE:
Run COMMENTS_V1.1.6.sql once in SQL Editor.
Do not run older V1.1.5.x comment SQL after this.

Expected success:
TAFA V1.1.6 — COMMENTS + REACTIONS + CLICKABLE NOTIFICATIONS OK
