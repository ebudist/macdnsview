# MacDNSView

Look up DNS records for many domains and IP addresses at once, against your system resolver or any DNS server, and export the results. A native macOS app plus a CLI.

Status: early development. Nothing usable yet.

## Planned for 0.1

- Record types: A, AAAA, CNAME, MX, NS, SOA, SRV, TXT, CAA, DMARC, and PTR for IP addresses.
- Any DNS server, or the system configuration including VPN scoped servers.
- TTL, response section, and answering server on every row.
- Export to CSV, TSV, JSON, plain text, and HTML.
- CLI for scripts: `macdnsview example.com 1.1.1.1 --type A,MX --format json`

## Build

Requires macOS 14 and Swift 6 (Command Line Tools are enough).

```
swift build
swift test
```

## Credits

Inspired by [DNSDataView](https://www.nirsoft.net/utils/dns_records_viewer.html) by Nir Sofer, which is Windows only. MacDNSView is an independent reimplementation and is not affiliated with NirSoft.

## License

MIT
