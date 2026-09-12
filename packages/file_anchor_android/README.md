# file_anchor_android

The Android implementation of [`file_anchor`](../file_anchor), built on the
Storage Access Framework. Registered automatically.

Notes for anyone reading the Kotlin:

- The persistable grant is taken **inside `onActivityResult`**. Taken later it
  dies with the process, and the anchor silently stops working on the next cold
  start. `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` is also set on the request, or
  the grant cannot be persisted at all.
- A plugin cannot use `registerForActivityResult` — that needs an
  `ActivityResultCaller`, which only the host Activity is. The sanctioned
  equivalent is `ActivityPluginBinding.addActivityResultListener`.
- Built on `DocumentsContract`, not `androidx.documentfile`. DocumentFile issues
  one query per file, the main reason hand-rolled SAF traversal feels slow;
  listing here keeps a cursor open across calls so one query serves a batch.
- The persisted-grant cap is guarded **proactively**. Android evicts the oldest
  grants past its limit *silently* rather than throwing, so anchoring is refused
  at 120 and callers are pointed at `FileAnchor.releaseUnused()`.
- No storage permissions are declared. SAF grants access per user selection,
  which is why it needs none and works unchanged under scoped storage.

`purpose` is accepted and ignored: Android's picker shows no caller-supplied
prompt, and inventing a dialog to carry one would be worse than the platform UI.
