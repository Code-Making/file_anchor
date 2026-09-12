# file_anchor

Pick a file or folder once and keep durable access to it across app restarts and
device reboots, on **Android, iOS, macOS, Windows and Linux**.

```dart
// Ask once.
final anchor = await FileAnchor.pickDirectory(purpose: 'Choose your vault');
await prefs.setString('vault', anchor!.token);

// Any later launch.
final vault = await FileAnchor.resolve(prefs.getString('vault')!);
await vault.use(() async {
  await for (final entry in vault.list(recursive: true)) {
    print(entry.relativePath);
  }
  await vault.writeAsString('notes.md', 'hello');
});
```

## Why a token and not a path

A filesystem path is the wrong abstraction, because the platforms disagree about
what a location even is:

| Platform | What a location really is |
| --- | --- |
| Android | A revocable `content://` grant |
| iOS, macOS | A security-scoped bookmark whose path moves under you |
| Windows, Linux | An actual path |

`Anchor.token` is an opaque, versioned string that all five can represent
honestly. Persist it, hand it back to `FileAnchor.resolve`, never parse it.

## Three failure states, not one

`AnchorError` is a sealed hierarchy, so `switch` is exhaustive — and the cases
demand different responses:

```dart
switch (error) {
  AnchorStale()       => 'Moved. Re-prompt.',
  AnchorRevoked()     => 'Permission withdrawn. Re-prompt.',
  AnchorUnavailable() => 'Drive detached. Retry later, do NOT re-prompt.',
  _                   => 'Something else.',
}
```

Collapsing *unavailable* into *revoked* is why apps nag people to re-pick a
folder just because a USB drive was unplugged.

## `use()` is not optional

iOS and macOS need a security scope opened before any I/O and balanced after.
Miss the open and reads fail **silently**; miss the close and a kernel resource
leaks. `use()` makes both impossible to get wrong, is reference-counted for
nesting, and is a no-op on Android, Windows and Linux — so always wrap I/O in it.

## Capabilities are reported, not faked

Platforms genuinely differ. `anchor.capabilities` tells you the truth rather than
silently no-opping an unsupported operation. Notably, an MSIX-packaged Windows
build reports `persistsAcrossReboot: false`, because durable access there needs
`FutureAccessList`, which is not implemented yet.

## Testing

`MemoryAnchor` ships in the package, so file logic is testable under plain
`flutter test` with no device:

```dart
final anchor = MemoryAnchor(files: {'notes.md': utf8.encode('hello')});
expect(await anchor.readAsString('notes.md'), 'hello');

final dead = MemoryAnchor.failing(const AnchorRevoked());
expect(() => dead.list().toList(), throwsA(isA<AnchorRevoked>()));
```
