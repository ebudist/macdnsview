# Own DNS wire client instead of the system resolver

MacDNSView sends queries with its own DNS message encoder and decoder over Network.framework (UDP, retried over TCP when the response is truncated). The app must query any server the user names and show per-record TTL and section (answer, authority, additional), and neither `dnssd` nor `libresolv` gives that cleanly: `dnssd` always goes through the system resolver, and `res_nquery` works but has awkward IPv6 nameserver handling and a dated C API. The default server comes from SystemConfiguration, not from `/etc/resolv.conf`.

With no Server given, each Target goes to the system-configured Server whose match domain is the longest suffix of the Target, falling back to the default Server. This matches the system resolver and differs from `dig`, which ignores scoped Servers. Every row shows the Server that answered.

## Considered Options

- `DNSServiceQueryRecord` (dnssd): no way to pick the server, no section info.
- `res_nquery` (libresolv): usable, but harder to test and to extend with new record types.

## Consequences

Record types are only as good as the decoder. Each new type needs a parser and a test fixture captured from a real response.
