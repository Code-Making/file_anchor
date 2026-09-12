# file_anchor_macos

The macOS implementation of [`file_anchor`](../file_anchor), using `NSOpenPanel`
and security-scoped bookmarks. Registered automatically. Requires macOS 10.15.

A sandboxed app needs this entitlement:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

Without the sandbox, macOS cannot mint a security-scoped bookmark at all. Rather
than failing, the plugin falls back to a plain path token, which is equally
durable for an unsandboxed build.

macOS is the one platform that can show `purpose` to the user, via
`NSOpenPanel.message`.
