# DNS over HTTPS and DNS over TLS as Server forms

A Server can also be a DoH URL (`https://dns.example/dns-query`, RFC 8484) or a DoT address (`tls://host`, or any address on port 853, RFC 7858). Some networks block or rewrite port 53 while 443 and 853 pass, and comparing an encrypted resolver with the plain one is part of debugging split DNS and filtering.

Both reuse the message encoder and decoder from ADR-0001, so every record type, the Validated flag, and the Differs comparison work the same. DoH goes through URLSession with a POST of `application/dns-message`. DoT goes through Network.framework, which frames messages the same way as plain TCP, with TLS added. Both stay within Apple frameworks, so no package dependency comes in.

Certificates are checked by the system as for any HTTPS or TLS connection. For DoT, the name in the Server field is the name checked against the certificate, so `tls://1.1.1.1` works only because Cloudflare's certificate lists the IP address. A failed check is an Error row, never a silent fallback to plain DNS. The Server column shows the full form (`https://...` or `tls://...`), so rows from different transports stay apart.

## Considered Options

- DNS over QUIC and DNSCrypt: left out. Network.framework has QUIC, but few resolvers serve DoQ, and DNSCrypt needs its own crypto.
- A separate Protocol picker next to the Server field: rejected. A URL or `tls://` prefix fits the comma separated Server list and the CLI `--server` flag without new controls.

## Consequences

DoH and DoT answers come over a connection that is opened per query, the same as plain TCP today. That is slower than a resolver that keeps the connection open, and the Time column includes the TLS handshake.
