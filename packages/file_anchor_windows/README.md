# file_anchor_windows

The Windows implementation of [`file_anchor`](../file_anchor). Registered
automatically.

**Pure Dart — no C++.** `IFileOpenDialog` is reachable straight from Dart through
`package:win32`, and Windows hands out real paths, so `dart:io` does the rest.

## MSIX packaging

In an unpackaged build — how Flutter Windows apps are usually shipped — a path is
durable as-is and survives reboots.

Inside an MSIX package it is not: Windows grants a packaged app access to a
picked location for the session only, and durable access needs the WinRT
`StorageApplicationPermissions.FutureAccessList`. That is not wired up yet, so
rather than handing back a token that quietly dies on restart, packaging is
detected and reported through `capabilities.persistsAcrossReboot`. Check it before
persisting a token in a packaged build.
