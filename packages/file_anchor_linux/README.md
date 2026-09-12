# file_anchor_linux

The Linux implementation of [`file_anchor`](../file_anchor). Registered
automatically.

**Pure Dart — no C or GTK.** The picker goes through the **XDG desktop portal**
over D-Bus via `package:dbus`, and Linux hands out real paths, so `dart:io` does
the rest.

The portal is used rather than a GTK file chooser for a concrete reason: inside
Flatpak or Snap a sandboxed app cannot open an arbitrary path, and the portal is
what grants access. It returns a document-portal path the app genuinely can read,
and on an unsandboxed system it returns the real path — one code path, correct in
both.

Requires `xdg-desktop-portal` plus a backend such as `xdg-desktop-portal-gtk`,
which is the default on current desktops. Folder selection needs portal
`FileChooser` version 3 or newer.
